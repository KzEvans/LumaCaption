import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'qwen35_parser.dart';
import 'translation_models.dart';
export 'translation_models.dart';

class RealtimeConfig {
  const RealtimeConfig({
    required this.apiKey,
    this.endpoint =
        'wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime',
    this.workspaceId = '',
    this.region = 'cn-beijing',
    this.modelId = 'qwen3.5-livetranslate-flash-realtime',
    this.sourceLanguage,
    this.targetLanguage = 'zh',
    this.cloudTranscription = false,
    this.proxy,
    this.connectTimeout = const Duration(seconds: 15),
    this.finishTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 5),
    this.allowLocalInsecure = false,
    this.maxBufferedAudioBytes = 64000,
    this.connectionAttempts = 2,
    this.glossary = const {},
  });
  final String apiKey;
  final String endpoint;
  final String workspaceId;
  final String region;
  final String modelId;
  final String? sourceLanguage;
  final String targetLanguage;
  final bool cloudTranscription;
  final String? proxy;
  final Duration connectTimeout;
  final Duration finishTimeout;
  final Duration sendTimeout;
  final bool allowLocalInsecure;
  final int maxBufferedAudioBytes;
  final int connectionAttempts;
  final Map<String, String> glossary;

  Uri get uri {
    if (apiKey.trim().isEmpty) {
      throw const TranslationFailure('key_missing', '请先保存翻译服务 API Key。');
    }
    if (modelId.trim().isEmpty || targetLanguage.trim().isEmpty) {
      throw const TranslationFailure('configuration', '请填写模型 ID 和目标语言。');
    }
    if (modelId.startsWith('qwen3.8-')) {
      throw const TranslationFailure(
        'protocol_version',
        '此适配器仅支持 Qwen 3.5 的 text/stash 协议；3.8 需要独立适配器。',
      );
    }
    final endpointUri = validateTranslationEndpoint(
      endpoint,
      webSocket: true,
      allowLocalInsecure: allowLocalInsecure,
      workspaceId: workspaceId,
    );
    return endpointUri.replace(
      queryParameters: {...endpointUri.queryParameters, 'model': modelId},
    );
  }

  Map<String, Object?> get session => {
    'modalities': ['text'],
    'input_audio_format': 'pcm',
    'sample_rate': 16000,
    'enable_voice_clone': false,
    'turn_detection': {
      'type': 'server_vad',
      'threshold': 0.2,
      'silence_duration_ms': 800,
    },
    if (cloudTranscription ||
        (sourceLanguage != null && sourceLanguage != 'auto'))
      'input_audio_transcription': {
        if (cloudTranscription) 'model': 'qwen3-asr-flash-realtime',
        if (sourceLanguage != null && sourceLanguage != 'auto')
          'language': sourceLanguage,
      },
    'translation': {
      'language': targetLanguage,
      if (glossary.isNotEmpty)
        'corpus': {'phrases': Map.fromEntries(glossary.entries.take(1000))},
    },
  };

  @override
  String toString() =>
      'RealtimeConfig(modelId: $modelId, credentials: [redacted])';
}

class _AudioPacket {
  _AudioPacket(this.bytes);
  final Uint8List bytes;
  final Completer<void> sent = Completer<void>();
}

/// One instance is one generation and one socket lifetime. Restart with a new
/// generation after interruption. Failed sessions never replay retained audio.
class RealtimeTranslator {
  RealtimeTranslator(this.config, {required this.generation})
    : _parser = Qwen35Parser(
        generation: generation,
        cloudTranscription: config.cloudTranscription,
      );
  final RealtimeConfig config;
  final int generation;
  final Qwen35Parser _parser;
  final _events = StreamController<TranslationEvent>.broadcast();
  final _states = StreamController<RealtimeState>.broadcast();
  final _errors = StreamController<TranslationFailure>.broadcast();
  final _queue = Queue<_AudioPacket>();
  final _created = Completer<void>();
  final _configured = Completer<void>();
  final _finished = Completer<void>();
  WebSocket? _socket;
  HttpClient? _client;
  StreamSubscription<dynamic>? _subscription;
  RealtimeState _state = RealtimeState.idle;
  Future<void>? _pumpTask;
  Future<void>? _finishTask;
  int _bufferedBytes = 0;
  int _sequence = 0;
  bool _disposed = false;

  Stream<TranslationEvent> get events => _events.stream;
  Stream<RealtimeState> get states => _states.stream;
  Stream<TranslationFailure> get errors => _errors.stream;
  RealtimeState get state => _state;
  int get bufferedAudioBytes => _bufferedBytes;

  Future<void> connect() async {
    if (_state != RealtimeState.idle || _disposed) {
      throw StateError('A session can only connect once.');
    }
    final uri = config.uri;
    if (config.maxBufferedAudioBytes < 3200 ||
        config.maxBufferedAudioBytes > 320000 ||
        config.connectionAttempts < 1 ||
        config.connectionAttempts > 3) {
      throw const TranslationFailure('configuration', '音频缓冲或重试设置超出支持范围。');
    }
    // These completions can fail before connect/finish reaches the relevant
    // await; attach handlers now to avoid unhandled asynchronous errors.
    for (final completer in [_created, _configured, _finished]) {
      unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
    }
    _setState(RealtimeState.connecting);
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          final socket = await _openSocket(uri).timeout(config.connectTimeout);
          if (_state == RealtimeState.canceled || _disposed) {
            unawaited(socket.close());
            throw const TranslationFailure('canceled', '翻译会话已取消。');
          }
          _socket = socket;
          break;
        } catch (error) {
          _client?.close(force: true);
          final retryable =
              error is SocketException ||
              (error is TranslationFailure && error.retryable);
          if (!retryable ||
              attempt + 1 >= config.connectionAttempts ||
              _state != RealtimeState.connecting) {
            rethrow;
          }
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (1 << attempt)),
          );
          if (_state != RealtimeState.connecting) {
            throw const TranslationFailure('canceled', '翻译会话已取消。');
          }
        }
      }
      _socket!.pingInterval = const Duration(seconds: 20);
      _subscription = _socket!.listen(
        _receive,
        onError: (Object _) => _fail(
          const TranslationFailure(
            'network',
            '连接中断，旧音频已丢弃；可重新开始新的会话。',
            retryable: true,
          ),
        ),
        onDone: () {
          if (_state != RealtimeState.finished &&
              _state != RealtimeState.canceled &&
              _state != RealtimeState.failed) {
            _fail(
              const TranslationFailure(
                'disconnected',
                '服务提前断开，最后一句可能未完成；可重新开始。',
                retryable: true,
              ),
            );
          }
        },
      );
      await _created.future.timeout(config.connectTimeout);
      _setState(RealtimeState.configuring);
      await _write({'type': 'session.update', 'session': config.session});
      await _configured.future.timeout(config.connectTimeout);
      if (_state == RealtimeState.configuring) _setState(RealtimeState.ready);
    } catch (error) {
      final failure = _safeFailure(error);
      if (_state != RealtimeState.canceled) _fail(failure);
      throw failure;
    }
  }

  Future<WebSocket> _openSocket(Uri uri) async {
    final client = HttpClient()..connectionTimeout = config.connectTimeout;
    _client = client;
    configureProxy(client, config.proxy);
    final request = await client.getUrl(
      uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http'),
    );
    // Never follow an endpoint redirect with credentials, including another
    // host owned by the same provider. The user must explicitly change host.
    request.followRedirects = false;
    final random = Random.secure();
    final nonce = base64Encode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}')
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', nonce);
    final response = await request.close();
    if (response.statusCode != 101) {
      throw TranslationFailure.fromStatus(response.statusCode);
    }
    final expected = base64Encode(
      sha1
          .convert(
            utf8.encode(
              '$nonce'
              '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
            ),
          )
          .bytes,
    );
    if (response.headers.value('Sec-WebSocket-Accept') != expected ||
        response.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() !=
            'websocket') {
      throw const TranslationFailure(
        'handshake',
        '服务未返回有效的 WebSocket 握手，请检查 Endpoint。',
      );
    }
    final socket = await response.detachSocket();
    return WebSocket.fromUpgradedSocket(socket, serverSide: false);
  }

  /// Input must already be real little-endian PCM16, mono, 16 kHz. The native
  /// audio converter owns resampling. At most one second per submission.
  Future<void> sendAudio(Uint8List pcm16) {
    if (_state != RealtimeState.ready) {
      return Future.error(
        const TranslationFailure('not_ready', '会话尚未就绪或已停止，音频未上传。'),
      );
    }
    if (pcm16.isEmpty) return Future.value();
    if (pcm16.length.isOdd || pcm16.length > 32000) {
      return Future.error(
        const TranslationFailure('audio_format', '音频须为 PCM16，且每批不超过 1 秒。'),
      );
    }
    if (_bufferedBytes + pcm16.length > config.maxBufferedAudioBytes) {
      const failure = TranslationFailure(
        'backpressure',
        '网络发送积压，已停止上传并丢弃待发送音频；请检查网络后重新开始。',
        retryable: true,
      );
      _fail(failure);
      return Future.error(failure);
    }
    final packet = _AudioPacket(Uint8List.fromList(pcm16));
    _bufferedBytes += packet.bytes.length;
    _queue.add(packet);
    _pumpTask ??= _pump().whenComplete(() => _pumpTask = null);
    return packet.sent.future;
  }

  Future<void> _pump() async {
    while (_queue.isNotEmpty &&
        (_state == RealtimeState.ready || _state == RealtimeState.finishing)) {
      final packet = _queue.first;
      try {
        // 100 ms maximum per wire message; no reconnection per frame.
        for (var offset = 0; offset < packet.bytes.length; offset += 3200) {
          if (_state != RealtimeState.ready &&
              _state != RealtimeState.finishing) {
            break;
          }
          final end = min(offset + 3200, packet.bytes.length);
          await _write({
            'type': 'input_audio_buffer.append',
            'audio': base64Encode(
              Uint8List.sublistView(packet.bytes, offset, end),
            ),
          });
        }
        if (_queue.isNotEmpty && identical(_queue.first, packet)) {
          _queue.removeFirst();
          _bufferedBytes -= packet.bytes.length;
        }
        if (!packet.sent.isCompleted) packet.sent.complete();
      } catch (error) {
        _fail(_safeFailure(error));
        return;
      }
    }
  }

  Future<void> _write(Map<String, Object?> event) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const TranslationFailure('disconnected', '翻译连接已关闭，音频未上传。');
    }
    // addStream waits for sink consumption, in contrast to unbounded add calls.
    await socket
        .addStream(
          Stream<String>.value(
            jsonEncode({'event_id': 'g${generation}_${++_sequence}', ...event}),
          ),
        )
        .timeout(config.sendTimeout);
  }

  void _receive(dynamic raw) {
    if (_state == RealtimeState.failed ||
        _state == RealtimeState.canceled ||
        _disposed) {
      return;
    }
    try {
      if (raw is! String || raw.length > 1024 * 1024) {
        throw const TranslationFailure('protocol', '服务消息格式不受支持或大小超过限制。');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final type = decoded['type'];
      switch (type) {
        case 'session.created':
          if (!_created.isCompleted) _created.complete();
        case 'session.updated':
          if (_state == RealtimeState.configuring && !_configured.isCompleted) {
            final session = decoded['session'];
            if (session is Map &&
                session['modalities'] is List &&
                (session['modalities'] as List).any((m) => m != 'text')) {
              throw const TranslationFailure(
                'configuration',
                '服务未接受仅文本输出，已停止会话。',
              );
            }
            _configured.complete();
          }
        case 'session.finished':
          if (_state == RealtimeState.finishing) {
            if (!_finished.isCompleted) _finished.complete();
            _setState(RealtimeState.finished);
          }
        case 'error':
          final error = decoded['error'];
          _fail(
            TranslationFailure.fromService(
              error is Map ? error['code'] ?? error['type'] : null,
            ),
          );
          return;
        case 'response.text.delta':
          throw const TranslationFailure(
            'protocol_version',
            '服务返回 delta 协议，与当前 Qwen 3.5 适配器不兼容。',
          );
      }
      for (final event in _parser.accept(decoded)) {
        _events.add(event);
      }
    } catch (error) {
      _fail(_safeFailure(error));
    }
  }

  Future<void> finish() => _finishTask ??= _finish();

  Future<void> _finish() async {
    if (_state == RealtimeState.finished || _state == RealtimeState.canceled) {
      return;
    }
    if (_state != RealtimeState.ready) {
      await cancel();
      return;
    }
    _setState(RealtimeState.finishing);
    try {
      await _pumpTask;
      if (_state != RealtimeState.finishing) {
        throw const TranslationFailure('disconnected', '连接已中断，最后一句可能未完成。');
      }
      await _write({'type': 'session.finish'});
      await _finished.future.timeout(config.finishTimeout);
      await _closeSocket();
    } catch (error) {
      final failure = error is TimeoutException
          ? const TranslationFailure(
              'finish_timeout',
              '等待最后一句超时，未完成字幕已标记；会话已关闭。',
            )
          : _safeFailure(error);
      _fail(failure);
      await _closeSocket();
      throw failure;
    }
  }

  Future<void> cancel() async {
    if (_disposed) return;
    if (_state != RealtimeState.finished && _state != RealtimeState.failed) {
      _setState(RealtimeState.canceled);
      _interrupt(const TranslationFailure('canceled', '翻译会话已取消。'));
    }
    await _closeSocket();
  }

  void _fail(TranslationFailure failure) {
    if (_disposed ||
        _state == RealtimeState.failed ||
        _state == RealtimeState.canceled ||
        _state == RealtimeState.finished) {
      return;
    }
    _setState(RealtimeState.failed);
    _errors.add(failure);
    _interrupt(failure);
    unawaited(_closeSocket());
  }

  void _interrupt(TranslationFailure failure) {
    for (final event in _parser.interrupt()) {
      _events.add(event);
    }
    while (_queue.isNotEmpty) {
      final packet = _queue.removeFirst();
      if (!packet.sent.isCompleted) packet.sent.completeError(failure);
    }
    _bufferedBytes = 0;
    for (final completer in [_created, _configured, _finished]) {
      if (!completer.isCompleted) completer.completeError(failure);
    }
  }

  Future<void> _closeSocket() async {
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    _client?.close(force: true);
    _client = null;
    await subscription?.cancel();
    if (socket != null) {
      try {
        await socket.close().timeout(const Duration(seconds: 1));
      } catch (_) {
        /* Already closed. */
      }
    }
  }

  void _setState(RealtimeState value) {
    _state = value;
    if (!_disposed) _states.add(value);
  }

  TranslationFailure _safeFailure(Object error) {
    if (error is TranslationFailure) return error;
    if (error is TimeoutException) {
      return const TranslationFailure(
        'timeout',
        '翻译连接超时，请检查网络、地域和代理。',
        retryable: true,
      );
    }
    if (error is HandshakeException) {
      return const TranslationFailure('tls', 'TLS 验证失败，请检查服务地址、证书及系统时间。');
    }
    if (error is SocketException) {
      return const TranslationFailure(
        'network',
        '无法连接翻译服务，请检查网络和代理。',
        retryable: true,
      );
    }
    return const TranslationFailure(
      'protocol',
      '翻译协议处理失败，请检查服务 Endpoint 与模型设置。',
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await cancel();
    _disposed = true;
    await _events.close();
    await _states.close();
    await _errors.close();
  }
}
