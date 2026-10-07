import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/audio/audio.dart';
import '../core/asr/whisper.dart';
import '../core/models/model_manager.dart';
import '../core/storage/native_bridge.dart';
import '../core/storage/settings.dart';
import '../core/storage/history_store.dart';
import '../core/subtitles/subtitles.dart';
import '../core/translation/translation.dart';
import '../core/diagnostics/session_timing.dart';

class AppController extends ChangeNotifier {
  AppController({NativeBridge? bridge}) : native = bridge ?? NativeBridge();
  final NativeBridge native;
  AppSettings settings = AppSettings();
  SettingsStore? settingsStore;
  ModelManager? models;
  final SubtitleStore subtitles = SubtitleStore();
  final WhisperEngine whisper = WhisperEngine();
  final PcmConverter converter = PcmConverter();
  final AudioSegmenter segmenter = AudioSegmenter();
  final Queue<AudioChunk> _chunks = Queue();
  StreamSubscription<dynamic>? _nativeSub;
  RealtimeTranslator? _realtime;
  TextTranslationQueue? _textQueue;
  TextTranslator? _textAdapter;
  Future<void>? _inferenceTask;
  bool initialized = false,
      running = false,
      paused = false,
      busy = false,
      overlayVisible = false,
      clickThrough = false;
  bool translating = false, loadingModel = false;
  bool testMode = false;
  bool measureSession = false;
  SessionTiming? sessionTiming;
  bool _historyReadable = true;
  bool fileInput = false;
  int receivedFrames = 0, receivedSamples = 0;
  double peakLevel = 0;
  Future<void>? _initialization;
  int _previousFinalEndUs = 0;
  int generation = 0, _baseUs = 0, _previousSequence = -1, droppedFrames = 0;
  double level = 0, rtf = 0;
  int? finalLatencyMs;
  String status = '正在初始化',
      error = '',
      supportDirectory = '',
      _previousText = '';
  List<Map<String, dynamic>> devices = [];
  Map<String, dynamic> permissions = {};
  final List<String> diagnostics = [];
  Timer? _refresh;
  String get privacy => switch (settings.mode) {
    'offline' => '完全本地 · 不上传音频或文本',
    'text' => '仅上传已确认文本',
    _ => '上传音频至翻译服务',
  };
  String get modeName => switch (settings.mode) {
    'offline' => '离线原文字幕',
    'text' => '本地识别 + 文本翻译',
    _ => '千问实时音频翻译',
  };
  String get selectedModel => settings.modelPath.isEmpty
      ? '尚未选择'
      : p
            .basename(settings.modelPath)
            .replaceAll('ggml-', '')
            .replaceAll('.bin', '');
  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      final paths = await native.call<Map<dynamic, dynamic>>('paths');
      supportDirectory = paths?['support'] as String? ?? '';
      if (supportDirectory.isEmpty) throw StateError('无法获取应用数据目录');
      settingsStore = SettingsStore(supportDirectory);
      settings = await settingsStore!.load();
      if (settings.modelDirectory.isEmpty) {
        settings.modelDirectory = p.join(supportDirectory, 'models');
      }
      models = ModelManager(
        settings.modelDirectory,
        freeBytes: (path) =>
            native.call<int>('files.freeBytes', {'path': path}),
      );
      models!.addListener(notifyListeners);
      await models!.initialize();
      if (!testMode) {
        try {
          final saved = await HistoryStore(supportDirectory).load();
          subtitles.segments.addAll(saved);
          for (final s in saved) {
            if (s.generation > generation) generation = s.generation;
          }
          subtitles.reset(generation);
        } catch (_) {
          _historyReadable = false;
          error = '已保存历史无法读取，原文件仍保留。请检查应用数据目录。';
        }
      }
      _nativeSub = native.stream.listen(
        _onNative,
        onError: (Object e) {
          fail(e);
        },
      );
      await refreshDevices();
      status = '准备就绪';
      _refresh = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (running) notifyListeners();
      });
    } catch (e) {
      fail(e);
    }
    initialized = true;
    notifyListeners();
  }

  void record(String message) {
    diagnostics.add(
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (diagnostics.length > 100) diagnostics.removeAt(0);
  }

  void clearError() {
    error = '';
    notifyListeners();
  }

  void fail(Object e) {
    error = switch (e) {
      TranslationFailure f => f.message,
      PlatformException f => f.message ?? f.code,
      FileSystemException f => f.message,
      _ => e.toString().replaceFirst('Bad state: ', ''),
    };
    if (e is PlatformException) {
      final details = e.details;
      final nativeReason =
          details is Map &&
              details['domain'] is String &&
              details['nativeCode'] is num
          ? ' · ${details['domain']}/${details['nativeCode']}'
          : '';
      record('原生操作失败 · ${e.code}$nativeReason');
    } else {
      record('操作失败');
    }
    notifyListeners();
  }

  Future<void> guard(Future<void> Function() action) async {
    try {
      error = '';
      await action();
    } catch (e) {
      fail(e);
    }
  }

  Future<void> refreshDevices() async {
    final list = await native.call<List<dynamic>>('devices');
    devices = (list ?? [])
        .map((dynamic e) => Map<String, dynamic>.from(e as Map))
        .toList();
    await refreshPermissions();
  }

  Future<void> refreshPermissions() async {
    permissions = Map<String, dynamic>.from(
      await native.call<Map>('permissions') ?? {},
    );
    notifyListeners();
  }

  Future<void> save() async {
    if (!testMode) await settingsStore?.save(settings);
    notifyListeners();
  }

  Uri get realtimeUri => RealtimeConfig(
    apiKey: 'resolve-only',
    endpoint: settings.endpoint.isEmpty
        ? 'wss://{WorkspaceId}.${settings.region}.maas.aliyuncs.com/api-ws/v1/realtime'
        : settings.endpoint,
    workspaceId: settings.workspace,
    modelId: settings.modelId,
    targetLanguage: settings.targetLanguage,
  ).uri;
  Future<void> saveKey(String key, {bool text = false}) async {
    final uri = text ? textServiceUri : realtimeUri;
    await native.saveSecret(AppSettings.credentialAccount(uri), key);
    await save();
    status = '凭据已存入系统安全存储';
    notifyListeners();
  }

  Future<String> _key(bool text) async {
    final uri = text ? textServiceUri : realtimeUri;
    return await native.secret(AppSettings.credentialAccount(uri)) ?? '';
  }

  Uri get textServiceUri => validateTranslationEndpoint(
    settings.textBaseUrl,
    webSocket: false,
    workspaceId: settings.workspace,
  );

  Future<void> loadModel(String path) async {
    if (running || busy) throw StateError('请先停止当前会话');
    loadingModel = true;
    notifyListeners();
    try {
      await _verifySelectedModel(path);
      await whisper.load(path);
      settings.modelPath = path;
      await save();
      status = '模型已就绪 · ${whisper.backend}';
    } finally {
      loadingModel = false;
      notifyListeners();
    }
  }

  Future<void> _verifySelectedModel(String path) async {
    final trusted = models?.catalog
        .where((m) => m.filename == p.basename(path))
        .firstOrNull;
    await verifyModel(path, expectedSha256: trusted?.checksum);
  }

  Future<void> importModel() async {
    final f = await native.call<String>('files.pickModel');
    if (f == null) return;
    final dest = await models!.importFile(f);
    await loadModel(dest);
  }

  Future<void> changeModelDirectory() async {
    if (models!.downloading || models!.verifying) throw StateError('请先结束模型下载');
    final d = await native.call<String>('files.pickDirectory');
    if (d == null) return;
    settings.modelDirectory = d;
    models!.directory = d;
    await models!.refresh();
    await save();
  }

  Future<void> _setupTranslation(int g, {String? mode}) async {
    final selectedMode = mode ?? settings.mode;
    if (selectedMode == 'realtime') {
      final realtime = RealtimeTranslator(
        RealtimeConfig(
          apiKey: await _key(false),
          endpoint: realtimeUri.toString(),
          workspaceId: settings.workspace,
          region: settings.region,
          modelId: settings.modelId,
          sourceLanguage: settings.sourceLanguage,
          targetLanguage: settings.targetLanguage,
          cloudTranscription: settings.cloudTranscription,
          proxy: settings.proxy.isEmpty ? null : settings.proxy,
        ),
        generation: g,
      );
      _realtime = realtime;
      realtime.events.listen((event) {
        if (event.generation != generation) return;
        final accepted = subtitles.put(
          SubtitleSegment(
            generation: g,
            segmentId: 'cloud:${event.segmentId}',
            revision: event.revision,
            original: event.isSource ? event.original ?? '' : '',
            translation: event.isSource ? '' : event.text,
            stash: event.stash,
            isFinal: event.isFinal,
            startUs: event.audioStart?.inMicroseconds,
            endUs: event.audioEnd?.inMicroseconds,
            engine: event.engine,
            error: event.interrupted ? '未完成' : null,
          ),
        );
        if (accepted && !event.interrupted) {
          final text = event.isSource ? event.original ?? '' : event.text;
          if (text.trim().isNotEmpty) {
            sessionTiming?.received(
              generation: g,
              segmentId: 'cloud:${event.segmentId}',
              channel: event.isSource ? 'source' : 'translation',
              revision: event.revision,
              isFinal: event.isFinal,
              audioEndUs: event.audioEnd?.inMicroseconds,
            );
          }
        }
        _updateOverlay();
        notifyListeners();
      });
      realtime.errors.listen((e) {
        if (g != generation) return;
        translating = false;
        fail(e);
        status = whisper.ready ? '翻译中断 · 本地原文继续' : '翻译中断 · 请停止后重连';
      });
      await realtime.connect();
      translating = true;
    } else if (selectedMode == 'text') {
      final config = TextTranslationConfig(
        apiKey: await _key(true),
        baseUrl: settings.textBaseUrl,
        modelId: settings.textModel,
        workspaceId: settings.workspace,
        proxy: settings.proxy.isEmpty ? null : settings.proxy,
        stream: settings.textProvider == 'qwen',
      );
      _textAdapter = settings.textProvider == 'qwen'
          ? QwenMtTranslator(config)
          : OpenAiTextTranslator(config);
      _textQueue = TextTranslationQueue(
        _textAdapter!,
        generation: g,
        onEvent: (event) {
          if (event.generation != generation) return;
          final i = subtitles.segments.indexWhere(
            (s) => s.generation == g && s.segmentId == event.segmentId,
          );
          if (i >= 0) {
            final accepted = subtitles.put(
              subtitles.segments[i].translated(
                event.text,
                translationFinal: event.isFinal && !event.interrupted,
                interrupted: event.interrupted,
              ),
            );
            if (accepted &&
                !event.interrupted &&
                event.text.trim().isNotEmpty) {
              sessionTiming?.received(
                generation: g,
                segmentId: event.segmentId,
                channel: 'translation',
                revision: event.revision,
                isFinal: event.isFinal,
                audioEndUs: event.audioEnd?.inMicroseconds,
              );
            }
            _updateOverlay();
            notifyListeners();
          }
        },
        onFailure: (e) {
          fail(e);
        },
      );
      translating = true;
    }
  }

  Future<void> start({bool fileInput = false}) async {
    if (running || busy) return;
    busy = true;
    error = '';
    status = '准备音频与模型';
    if (measureSession) {
      sessionTiming = SessionTiming(generation: generation + 1)
        ..preparationStarted();
    }
    notifyListeners();
    try {
      if (settings.mode != 'realtime' && settings.modelPath.isEmpty) {
        throw StateError('请先在模型管理中下载或导入 Whisper 模型');
      }
      if (settings.modelPath.isNotEmpty && !whisper.ready) {
        await _verifySelectedModel(settings.modelPath);
        await whisper.load(settings.modelPath);
      }
      generation++;
      subtitles.reset(generation);
      converter.reset();
      segmenter.reset();
      _chunks.clear();
      _baseUs = 0;
      _previousSequence = -1;
      _previousText = '';
      _previousFinalEndUs = 0;
      droppedFrames = 0;
      receivedFrames = 0;
      receivedSamples = 0;
      peakLevel = 0;
      this.fileInput = fileInput;
      await _setupTranslation(generation);
      sessionTiming?.translationReady();
      if (!fileInput) {
        await native.call<void>('start', {
          'source': settings.source,
          if (settings.deviceId.isNotEmpty) 'deviceId': settings.deviceId,
        });
      }
      running = true;
      paused = false;
      status = fileInput ? '正在处理测试音频' : '正在聆听';
      record('开始会话 · ${settings.mode} · ${settings.source}');
      await save();
    } catch (e) {
      await _realtime?.dispose();
      _realtime = null;
      _textQueue?.dispose();
      _textQueue = null;
      _textAdapter?.dispose();
      _textAdapter = null;
      translating = false;
      status = '无法开始字幕';
      rethrow;
    } finally {
      if (!fileInput) {
        try {
          await refreshPermissions();
        } catch (_) {
          // A status read must not replace the actual capture failure.
          record('权限状态刷新失败');
        }
      }
      busy = false;
      notifyListeners();
    }
  }

  void _onNative(dynamic value) {
    final m = Map<String, dynamic>.from(value as Map);
    if (m['type'] == 'command' || m['type'] == 'control') {
      final command = m['command'] ?? m['action'];
      if (command == 'start') {
        unawaited(guard(start));
      }
      if (command == 'stop') {
        unawaited(guard(() => stop()));
      }
      if (command == 'overlayRecovered') {
        clickThrough = false;
        overlayVisible = true;
        notifyListeners();
      }
      return;
    }
    if (m['type'] == 'error') {
      fail(
        PlatformException(
          code: m['code'] as String? ?? 'capture',
          message: m['message'] as String?,
          details: m['details'],
        ),
      );
      if (running) unawaited(guard(() => stop(emergency: true)));
      return;
    }
    if (m['type'] != 'audio' || !running || paused) return;
    try {
      _onAudio(AudioFrame.fromMap(m, generation));
    } catch (e) {
      fail(e);
    }
  }

  void _onAudio(AudioFrame frame) {
    if (_previousSequence >= 0 && frame.sequence > _previousSequence + 1) {
      droppedFrames += frame.sequence - _previousSequence - 1;
    }
    _previousSequence = frame.sequence;
    if (_baseUs == 0) _baseUs = frame.timestampUs;
    final samples = converter.convert(frame);
    level = PcmConverter.rms(samples);
    receivedFrames++;
    receivedSamples += samples.length;
    if (level > peakLevel) peakLevel = level;
    if (translating && _realtime != null) {
      final pcm = PcmConverter.pcm16(samples);
      for (var start = 0; start < pcm.length; start += 3200) {
        final end = (start + 3200).clamp(0, pcm.length);
        unawaited(
          _realtime!
              .sendAudio(Uint8List.sublistView(pcm, start, end))
              .catchError((Object e) {
                if (translating) {
                  translating = false;
                  fail(e);
                }
              }),
        );
      }
    }
    if (whisper.ready &&
        (settings.mode != 'realtime' ||
            !translating ||
            !settings.cloudTranscription)) {
      for (final chunk in segmenter.add(samples, frame.timestampUs - _baseUs)) {
        _enqueue(chunk);
      }
    }
  }

  void _enqueue(AudioChunk chunk) {
    _chunks.removeWhere(
      (old) => old.segmentId == chunk.segmentId && !old.isFinal,
    );
    if (_chunks.length >= 2) {
      final obsolete = _chunks.where((old) => !old.isFinal).firstOrNull;
      if (obsolete != null) {
        _chunks.remove(obsolete);
      } else if (!chunk.isFinal) {
        return;
      } else {
        _chunks.removeFirst();
        droppedFrames++;
        error = '本地识别跟不上声音，已跳过过时音频。请选择更小的模型。';
      }
    }
    _chunks.add(chunk);
    _inferenceTask ??= _infer(
      generation,
    ).whenComplete(() => _inferenceTask = null);
  }

  Future<void> _infer(int g) async {
    while (_chunks.isNotEmpty && g == generation) {
      final chunk = _chunks.removeFirst();
      final watch = Stopwatch()..start();
      try {
        final results = await whisper.transcribe(
          chunk.samples,
          language: settings.sourceLanguage,
        );
        if (g != generation) return;
        rtf = watch.elapsedMicroseconds / (chunk.endUs - chunk.startUs);
        if (results.isNotEmpty) {
          var text = results.map((r) => r.text).join().trim();
          if (chunk.startUs < _previousFinalEndUs) {
            text = deduplicateOverlap(_previousText, text);
          }
          final id = 'local:${chunk.segmentId}';
          final start = chunk.startUs + results.first.startUs;
          final end = (chunk.startUs + results.last.endUs).clamp(
            start,
            chunk.endUs,
          );
          if (text.isNotEmpty) {
            final accepted = subtitles.put(
              SubtitleSegment(
                generation: g,
                segmentId: id,
                revision: chunk.revision,
                original: text,
                startUs: start,
                endUs: end,
                isFinal: chunk.isFinal,
                engine: whisper.backend,
              ),
            );
            if (accepted) {
              sessionTiming?.received(
                generation: g,
                segmentId: id,
                channel: 'source',
                revision: chunk.revision,
                isFinal: chunk.isFinal,
                audioEndUs: end,
              );
            }
            if (chunk.isFinal) {
              _previousText = results.map((r) => r.text).join().trim();
              _previousFinalEndUs = end;
              _textQueue?.submit(
                id,
                text,
                sourceLanguage: settings.sourceLanguage,
                targetLanguage: settings.textProvider == 'qwen'
                    ? languageName(settings.targetLanguage)
                    : settings.targetLanguage,
                audioStart: Duration(microseconds: start),
                audioEnd: Duration(microseconds: end),
              );
            }
          }
        }
        finalLatencyMs = watch.elapsedMilliseconds;
        _updateOverlay();
        notifyListeners();
      } catch (e) {
        if (g == generation) fail(e);
      }
    }
  }

  Future<void> pause() async {
    if (!running || busy) return;
    if (paused) {
      await native.call<void>('resume');
      paused = false;
      status = '正在聆听';
    } else {
      await native.call<void>('pause');
      paused = true;
      level = 0;
      final c = segmenter.flush();
      if (c != null) _enqueue(c);
      status = '已暂停';
    }
    notifyListeners();
  }

  Future<void> stop({bool emergency = false}) async {
    if (busy) return;
    busy = true;
    paused = false;
    status = emergency ? '立即停止上传' : '正在收尾最后一句';
    running = false;
    level = 0;
    notifyListeners();
    try {
      await native.call<void>('stop');
      if (emergency) {
        generation++;
        subtitles.reset(generation);
        _chunks.clear();
        segmenter.reset();
        whisper.cancel();
        await _realtime?.cancel();
        _textQueue?.dispose();
      } else {
        final chunk = segmenter.flush();
        if (chunk != null) _enqueue(chunk);
        await _inferenceTask;
        await _realtime?.finish();
        await _textQueue?.drain().timeout(const Duration(seconds: 30));
      }
    } finally {
      await _realtime?.dispose();
      _realtime = null;
      _textQueue?.dispose();
      _textQueue = null;
      _textAdapter?.dispose();
      _textAdapter = null;
      translating = false;
      busy = false;
      status = '已停止';
      record('会话已停止');
      await _persistHistory();
      sessionTiming?.stopped();
      notifyListeners();
    }
  }

  Future<void> processFile({
    String? inputPath,
    bool paced = false,
    bool allowOnline = false,
  }) async {
    if (settings.mode != 'offline' && !(testMode && allowOnline)) {
      throw StateError('测试文件入口使用离线模式，请先选择「离线原文字幕」');
    }
    final path = inputPath ?? await native.call<String>('files.pickAudio');
    if (path == null) return;
    final f = File(path);
    if (await f.length() > 64 * 1024 * 1024) {
      throw StateError('测试 WAV 请小于 64 MB');
    }
    final wav = WavAudio.decode(await f.readAsBytes());
    await start(fileInput: true);
    final g = generation;
    final pacing = Stopwatch()..start();
    sessionTiming?.audioStarted();
    try {
      final size = (wav.sampleRate ~/ 10) * wav.channels;
      for (
        var i = 0;
        i < wav.samples.length && g == generation && running;
        i += size
      ) {
        final end = (i + size).clamp(0, wav.samples.length);
        final scheduledEndUs = end * 1000000 ~/ (wav.sampleRate * wav.channels);
        if (paced) {
          final remaining = scheduledEndUs - pacing.elapsedMicroseconds;
          if (remaining > 0) {
            await Future<void>.delayed(Duration(microseconds: remaining));
          }
        } else {
          while (_chunks.isNotEmpty || _inferenceTask != null) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            if (g != generation || !running) return;
          }
        }
        if (g != generation || !running) return;
        sessionTiming?.audioFrame(scheduledEndUs: scheduledEndUs);
        _onAudio(
          AudioFrame(
            samples: Float32List.sublistView(wav.samples, i, end),
            sampleRate: wav.sampleRate,
            channels: wav.channels,
            timestampUs:
                1000000 + i * 1000000 ~/ (wav.sampleRate * wav.channels),
            sequence: i ~/ size,
            generation: g,
          ),
        );
      }
    } finally {
      sessionTiming?.audioFinished();
      if (running) await stop();
    }
  }

  Future<void> toggleOverlay() async {
    overlayVisible = !overlayVisible;
    await native.call<void>(overlayVisible ? 'overlay.show' : 'overlay.hide');
    await configureOverlay();
    _updateOverlay();
    notifyListeners();
  }

  Future<void> configureOverlay() async {
    await native.call<void>('overlay.configure', {
      'fontSize': settings.fontSize,
      'opacity': settings.opacity,
      'clickThrough': clickThrough,
      'display': settings.display,
      'theme': settings.theme,
    });
    await save();
  }

  void _updateOverlay() {
    String original = '', translation = '';
    for (final s in subtitles.segments.reversed) {
      if (s.generation != generation) continue;
      if (original.isEmpty && s.original.isNotEmpty) original = s.original;
      if (translation.isEmpty &&
          (s.translation.isNotEmpty || s.stash.isNotEmpty)) {
        translation = s.translation + s.stash;
      }
      if (original.isNotEmpty && translation.isNotEmpty) break;
    }
    unawaited(
      native
          .call<void>('overlay.update', {
            'original': original,
            'translation': translation,
          })
          .catchError((Object e) {
            fail(e);
          }),
    );
  }

  Future<void> export(String format, String display, {int? session}) async {
    final eligible = subtitles.segments
        .where((s) => s.isFinal && (session == null || s.generation == session))
        .toList();
    if (format != 'txt' &&
        eligible.map((s) => s.generation).toSet().length > 1) {
      throw StateError('SRT/VTT 请先选择一个会话，避免合并不同音频时间线');
    }
    if (format != 'txt' &&
        !eligible.any((s) => s.startUs != null && s.endUs != null)) {
      throw StateError('当前字幕没有可靠音频时间，暂可导出 TXT');
    }
    await native.call<String>('files.saveText', {
      'text': exportSubtitles(eligible, format: format, display: display),
      'suggestedName': 'LumaCaption.$format',
    });
  }

  Future<void> clearHistory() async {
    subtitles.segments.clear();
    if (!testMode) await HistoryStore(supportDirectory).clear();
    _historyReadable = true;
    notifyListeners();
  }

  Future<void> _persistHistory() async {
    if (settings.persistHistory && !testMode) {
      if (!_historyReadable) {
        throw StateError('已有历史无法读取，尚未覆盖。请检查原文件或清空历史后再保存。');
      }
      await HistoryStore(supportDirectory).save(subtitles.segments);
    }
  }

  Future<void> setPersistHistory(bool value) async {
    settings.persistHistory = value;
    await save();
    if (value) await _persistHistory();
  }

  Future<void> testConnection() async {
    if (running) throw StateError('请先停止当前会话');
    await _setupTranslation(
      generation,
      mode: settings.mode == 'text' ? 'text' : 'realtime',
    );
    if (_realtime != null) {
      await _realtime!.finish();
      await _realtime!.dispose();
      _realtime = null;
    } else {
      await _textAdapter!.translate(
        'Hello.',
        sourceLanguage: 'English',
        targetLanguage: languageName(settings.targetLanguage),
      );
      _textQueue?.dispose();
      _textQueue = null;
      _textAdapter?.dispose();
      _textAdapter = null;
    }
    translating = false;
    status = '服务连接测试通过';
    notifyListeners();
  }

  static String languageName(String code) =>
      const {
        'zh': 'Chinese',
        'en': 'English',
        'ja': 'Japanese',
        'ko': 'Korean',
        'fr': 'French',
        'de': 'German',
        'es': 'Spanish',
      }[code] ??
      code;
  @override
  void dispose() {
    _refresh?.cancel();
    _nativeSub?.cancel();
    _realtime?.dispose();
    _textQueue?.dispose();
    _textAdapter?.dispose();
    whisper.close();
    models?.dispose();
    super.dispose();
  }
}
