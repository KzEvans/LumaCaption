import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

class WhisperResult {
  const WhisperResult(this.text, this.startUs, this.endUs);
  final String text;
  final int startUs, endUs;
}

class _Bindings {
  _Bindings(String path) : lib = DynamicLibrary.open(path) {
    final version = lib.lookupFunction<Int32 Function(), int Function()>(
      'luma_abi_version',
    )();
    if (version != 2) throw StateError('Whisper 原生库版本不兼容，请重新安装完整应用');
  }
  final DynamicLibrary lib;
  late final create = lib
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int)
      >('luma_create');
  late final run = lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Float>,
          Int32,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Int32,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Float>,
          int,
          Pointer<Utf8>,
          Pointer<Utf8>,
          int,
        )
      >('luma_run');
  late final prepare = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('luma_prepare');
  late final backend = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>),
        Pointer<Utf8> Function(Pointer<Void>)
      >('luma_backend');
  late final count = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('luma_count');
  late final text = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int)
      >('luma_text');
  late final start = lib
      .lookupFunction<
        Int64 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('luma_start');
  late final end = lib
      .lookupFunction<
        Int64 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('luma_end');
  late final cancel = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('luma_cancel');
  late final destroy = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('luma_destroy');
}

class WhisperEngine {
  _Bindings? _bindings;
  SendPort? _port;
  ReceivePort? _receive;
  StreamSubscription<dynamic>? _sub;
  Isolate? _isolate;
  int _handle = 0, _id = 0;
  bool _closing = false;
  String _backend = 'Whisper · 未加载';
  final Map<int, Completer<List<WhisperResult>>> _pending = {};
  bool get ready => _handle != 0 && !_closing;
  String get backend => _backend;
  static String libraryPath() {
    final custom = Platform.environment['LUMA_WHISPER_LIBRARY'];
    if (custom != null) return custom;
    final executable = p.dirname(Platform.resolvedExecutable);
    if (Platform.isMacOS) {
      final bundled = p.normalize(
        p.join(executable, '../Frameworks/liblumawhisper.dylib'),
      );
      if (File(bundled).existsSync()) return bundled;
      return p.absolute('build/whisper/liblumawhisper.dylib');
    }
    if (Platform.isWindows) return p.join(executable, 'lumawhisper.dll');
    return p.absolute('build/whisper/liblumawhisper.so');
  }

  Future<void> load(String model) async {
    await close();
    _closing = false;
    final path = libraryPath();
    _bindings = _Bindings(path);
    final loaded = Completer<void>();
    _receive = ReceivePort();
    _sub = _receive!.listen((dynamic message) {
      final m = message as Map;
      if (m['type'] == 'ready') {
        _port = m['port'] as SendPort;
        _handle = m['handle'] as int;
        _backend = m['backend'] as String;
        if (!loaded.isCompleted) loaded.complete();
      }
      if (m['type'] == 'loadError') {
        if (!loaded.isCompleted) {
          loaded.completeError(StateError(m['message'] as String));
        }
      }
      if (m['type'] == 'result') {
        final c = _pending.remove(m['id']);
        if (c == null) return;
        if (m['error'] != null) {
          c.completeError(StateError(m['error'] as String));
        } else {
          c.complete(
            (m['segments'] as List)
                .map(
                  (dynamic s) =>
                      WhisperResult(s[0] as String, s[1] as int, s[2] as int),
                )
                .toList(),
          );
        }
      }
    });
    _isolate = await Isolate.spawn(_worker, [
      _receive!.sendPort,
      path,
      model,
      Platform.numberOfProcessors.clamp(1, 8),
    ]);
    try {
      await loaded.future.timeout(const Duration(seconds: 90));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<List<WhisperResult>> transcribe(
    Float32List samples, {
    String language = 'auto',
    String prompt = '',
    bool isFinal = true,
  }) async {
    if (!ready) throw StateError('模型尚未加载');
    if (_pending.isNotEmpty) throw StateError('推理工作线程忙');
    final id = ++_id, c = Completer<List<WhisperResult>>();
    _pending[id] = c;
    _bindings!.prepare(Pointer<Void>.fromAddress(_handle));
    _port!.send({
      'type': 'run',
      'id': id,
      'samples': TransferableTypedData.fromList([
        samples.buffer.asUint8List(
          samples.offsetInBytes,
          samples.lengthInBytes,
        ),
      ]),
      'language': language,
      'prompt': prompt,
      'isFinal': isFinal,
    });
    final timer = Timer(const Duration(seconds: 45), () {
      cancel();
    });
    try {
      return await c.future;
    } finally {
      timer.cancel();
    }
  }

  void cancel() {
    if (_handle != 0) _bindings!.cancel(Pointer<Void>.fromAddress(_handle));
  }

  Future<void> close() async {
    _closing = true;
    cancel();
    // Do not free native memory while inference uses it. The worker receives
    // close only after the synchronous FFI call finishes/acknowledges abort.
    if (_port != null) {
      final closed = ReceivePort();
      _port!.send({'type': 'close', 'reply': closed.sendPort});
      await closed.first;
      closed.close();
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('识别已取消'));
    }
    _pending.clear();
    await _sub?.cancel();
    _receive?.close();
    _isolate = null;
    _port = null;
    _handle = 0;
    _bindings = null;
    _backend = 'Whisper · 未加载';
  }
}

void _worker(List<dynamic> args) async {
  final out = args[0] as SendPort;
  final commands = ReceivePort();
  _Bindings? b;
  Pointer<Void> handle = nullptr;
  try {
    b = _Bindings(args[1] as String);
    final path = (args[2] as String).toNativeUtf8();
    try {
      handle = b.create(path, args[3] as int);
    } finally {
      calloc.free(path);
    }
    if (handle == nullptr) throw StateError('模型格式不兼容、文件损坏或内存不足');
    out.send({
      'type': 'ready',
      'port': commands.sendPort,
      'handle': handle.address,
      'backend': b.backend(handle).toDartString(),
    });
  } catch (e) {
    out.send({'type': 'loadError', 'message': e.toString()});
    commands.close();
    return;
  }
  await for (final dynamic message in commands) {
    final m = message as Map;
    if (m['type'] == 'close') {
      b.destroy(handle);
      (m['reply'] as SendPort).send(true);
      commands.close();
      break;
    }
    if (m['type'] == 'run') {
      final samples = (m['samples'] as TransferableTypedData)
          .materialize()
          .asFloat32List();
      final ptr = calloc<Float>(samples.length);
      final language = (m['language'] as String).toNativeUtf8();
      final prompt = (m['prompt'] as String).toNativeUtf8();
      try {
        ptr.asTypedList(samples.length).setAll(0, samples);
        final code = b.run(
          handle,
          ptr,
          samples.length,
          language,
          prompt,
          m['isFinal'] == true ? 1 : 0,
        );
        if (code != 0) throw StateError('Whisper 已取消或推理失败 ($code)');
        final result = <List<dynamic>>[];
        for (var i = 0; i < b.count(handle); i++) {
          result.add([
            b.text(handle, i).toDartString(),
            b.start(handle, i),
            b.end(handle, i),
          ]);
        }
        out.send({'type': 'result', 'id': m['id'], 'segments': result});
      } catch (e) {
        out.send({'type': 'result', 'id': m['id'], 'error': e.toString()});
      } finally {
        calloc.free(ptr);
        calloc.free(language);
        calloc.free(prompt);
      }
    }
  }
}
