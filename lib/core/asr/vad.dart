import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'whisper.dart';

class VadFrame {
  const VadFrame({
    required this.generation,
    required this.startSample,
    required this.endSample,
    required this.probability,
  });
  final int generation, startSample, endSample;
  final double probability;
}

/// Samples and offsets are mono 16k PCM. Processing and resets are serialized
/// by one worker; frames contain only newly classified complete 512-sample
/// windows. Unclassified residual samples remain in memory until more arrive.
abstract class VadDetector {
  bool get ready;
  String get backend;
  Future<void> load(String path);
  Future<List<VadFrame>> process(
    Float32List samples, {
    required int generation,
    required int sampleOffset,
  });
  Future<void> reset(int generation);
  Future<void> close();
}

class _VadBindings {
  _VadBindings(String path) : lib = DynamicLibrary.open(path) {
    final version = lib.lookupFunction<Int32 Function(), int Function()>(
      'luma_vad_version',
    )();
    if (version != 1) throw StateError('VAD 原生库版本不兼容');
  }
  final DynamicLibrary lib;
  late final create = lib
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int)
      >('luma_vad_create');
  late final run = lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Float>,
          Int32,
          Pointer<Float>,
          Int32,
        ),
        int Function(Pointer<Void>, Pointer<Float>, int, Pointer<Float>, int)
      >('luma_vad_run_probs');
  late final free = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('luma_vad_free');
}

class SileroVadEngine extends VadDetector {
  SendPort? _port;
  ReceivePort? _receive;
  StreamSubscription<dynamic>? _sub;
  Isolate? _isolate;
  ReceivePort? _exitReceive;
  Future<dynamic>? _workerExited;
  Future<void>? _opening, _closing;
  bool _isClosing = true;
  int _id = 0, _loadEpoch = 0;
  final Map<int, Completer<dynamic>> _pending = {};

  @override
  bool get ready => _port != null && !_isClosing;
  @override
  String get backend => ready ? 'CPU · Silero VAD v5.1.2' : 'VAD · 未加载';

  static String modelPath() {
    final testModel = Platform.environment['LUMA_TEST_VAD_MODEL'];
    if (testModel != null && testModel.isNotEmpty) return testModel;
    return p.normalize(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        '../Resources/vad/ggml-silero-v5.1.2.bin',
      ),
    );
  }

  @override
  Future<void> load(String path) async {
    final epoch = ++_loadEpoch;
    _isClosing = true;
    await _finishClose();
    if (epoch != _loadEpoch) throw StateError('VAD 加载已取消');
    _closing = null;
    _isClosing = false;
    final operation = _open(path);
    _opening = operation;
    try {
      await operation;
      if (epoch != _loadEpoch) throw StateError('VAD 加载已取消');
    } catch (_) {
      _isClosing = true;
      await _finishClose();
      rethrow;
    } finally {
      if (identical(_opening, operation)) _opening = null;
    }
  }

  Future<void> _open(String model) async {
    final loaded = Completer<void>();
    _receive = ReceivePort();
    _sub = _receive!.listen((dynamic message) {
      final m = message as Map;
      if (m['type'] == 'ready') {
        _port = m['port'] as SendPort;
        loaded.complete();
      } else if (m['type'] == 'loadError') {
        loaded.completeError(StateError(m['message'] as String));
      } else if (m['type'] == 'result') {
        final completer = _pending.remove(m['id']);
        if (completer == null) return;
        if (m['error'] != null) {
          completer.completeError(StateError(m['error'] as String));
        } else {
          completer.complete(m['frames']);
        }
      }
    });
    _exitReceive = ReceivePort();
    _workerExited = _exitReceive!.first;
    _isolate = await Isolate.spawn(_vadWorker, [
      _receive!.sendPort,
      WhisperEngine.libraryPath(),
      model,
    ], onExit: _exitReceive!.sendPort);
    await loaded.future;
  }

  @override
  Future<List<VadFrame>> process(
    Float32List samples, {
    required int generation,
    required int sampleOffset,
  }) async {
    if (sampleOffset < 0 || generation < 0) {
      throw ArgumentError('VAD generation 和 sampleOffset 不能为负');
    }
    if (!ready) throw StateError('VAD 尚未加载');
    if (samples.isEmpty) return [];
    final frames =
        await _command({
              'type': 'process',
              'samples': TransferableTypedData.fromList([
                samples.buffer.asUint8List(
                  samples.offsetInBytes,
                  samples.lengthInBytes,
                ),
              ]),
              'generation': generation,
              'sampleOffset': sampleOffset,
            })
            as List;
    return frames
        .map(
          (dynamic frame) => VadFrame(
            generation: frame[0] as int,
            startSample: frame[1] as int,
            endSample: frame[2] as int,
            probability: frame[3] as double,
          ),
        )
        .toList();
  }

  @override
  Future<void> reset(int generation) async {
    if (generation < 0) throw ArgumentError.value(generation, 'generation');
    if (!ready) return;
    await _command({'type': 'reset', 'generation': generation});
  }

  Future<dynamic> _command(Map<String, dynamic> message) {
    final id = ++_id, completer = Completer<dynamic>();
    _pending[id] = completer;
    _port!.send({...message, 'id': id});
    return completer.future;
  }

  @override
  Future<void> close() {
    _loadEpoch++;
    _isClosing = true;
    return _finishClose();
  }

  Future<void> _finishClose() => _closing ??= _closeWorker();

  Future<void> _closeWorker() async {
    final opening = _opening;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        // A worker that could not load reports its error and exits itself.
      }
    }
    if (_port != null) {
      // The worker frees its native context only after all earlier synchronous
      // probability computations finish. Never kill an active native call.
      await _command({'type': 'close'});
    }
    if (_isolate != null) await _workerExited;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('VAD 已关闭'));
    }
    _pending.clear();
    await _sub?.cancel();
    _receive?.close();
    _exitReceive?.close();
    _port = null;
    _receive = null;
    _sub = null;
    _isolate = null;
    _exitReceive = null;
    _workerExited = null;
  }
}

class _VadHistory {
  static const windowSamples = 512;
  static const replaySamples = 48 * windowSamples; // 1536ms at 16k.
  final List<double> _samples = [];
  int generation = 0;
  int? _startSample, _expectedOffset, _consumedEnd;

  void reset(int value) {
    generation = value;
    _samples.clear();
    _startSample = _expectedOffset = _consumedEnd = null;
  }

  List<List<num>> process(
    Float32List samples,
    int value,
    int offset,
    _VadBindings bindings,
    Pointer<Void> handle,
    Pointer<Float> input,
    Pointer<Float> output,
  ) {
    if (value != generation) return [];
    final expected = _expectedOffset;
    if (expected != null && offset < expected) return [];
    if (expected != null && offset > expected) reset(value);
    _startSample ??= offset;
    _consumedEnd ??= offset;
    _expectedOffset = offset + samples.length;
    _samples.addAll(samples);
    final completeEnd =
        _startSample! + _samples.length ~/ windowSamples * windowSamples;
    final frames = <List<num>>[];
    while (_consumedEnd! < completeEnd) {
      final end = math.min(completeEnd, _consumedEnd! + replaySamples);
      final start = math.max(_startSample!, end - replaySamples);
      final count = end - start;
      input
          .asTypedList(count)
          .setAll(
            0,
            _samples.getRange(start - _startSample!, end - _startSample!),
          );
      final n = bindings.run(handle, input, count, output, 48);
      if (n != count ~/ windowSamples) {
        throw StateError('Silero VAD 计算失败 ($n)');
      }
      final probabilities = output.asTypedList(n);
      for (var i = (_consumedEnd! - start) ~/ windowSamples; i < n; i++) {
        final begin = start + i * windowSamples;
        frames.add([value, begin, begin + windowSamples, probabilities[i]]);
      }
      _consumedEnd = end;
    }
    final keepFrom = math.max(_startSample!, _consumedEnd! - replaySamples);
    final remove = keepFrom - _startSample!;
    if (remove > 0) {
      _samples.removeRange(0, remove);
      _startSample = keepFrom;
    }
    return frames;
  }
}

void _vadWorker(List<dynamic> args) async {
  final out = args[0] as SendPort;
  final commands = ReceivePort();
  _VadBindings? bindings;
  Pointer<Void> handle = nullptr;
  Pointer<Float> input = nullptr, output = nullptr;
  try {
    bindings = _VadBindings(args[1] as String);
    final path = (args[2] as String).toNativeUtf8();
    try {
      handle = bindings.create(path, 2);
    } finally {
      calloc.free(path);
    }
    if (handle == nullptr) throw StateError('无法加载 Silero VAD 模型');
    input = calloc<Float>(_VadHistory.replaySamples);
    output = calloc<Float>(48);
    out.send({'type': 'ready', 'port': commands.sendPort});
  } catch (e) {
    if (handle != nullptr) bindings?.free(handle);
    if (input != nullptr) calloc.free(input);
    if (output != nullptr) calloc.free(output);
    out.send({'type': 'loadError', 'message': e.toString()});
    commands.close();
    return;
  }
  final history = _VadHistory();
  await for (final dynamic message in commands) {
    final m = message as Map;
    if (m['type'] == 'close') {
      bindings.free(handle);
      calloc.free(input);
      calloc.free(output);
      out.send({'type': 'result', 'id': m['id'], 'frames': <dynamic>[]});
      commands.close();
      break;
    }
    try {
      List<List<num>> frames = [];
      if (m['type'] == 'reset') {
        final generation = m['generation'] as int;
        if (generation >= history.generation) history.reset(generation);
      } else if (m['type'] == 'process') {
        final samples = (m['samples'] as TransferableTypedData)
            .materialize()
            .asFloat32List();
        frames = history.process(
          samples,
          m['generation'] as int,
          m['sampleOffset'] as int,
          bindings,
          handle,
          input,
          output,
        );
      }
      out.send({'type': 'result', 'id': m['id'], 'frames': frames});
    } catch (e) {
      out.send({'type': 'result', 'id': m['id'], 'error': e.toString()});
    }
  }
}
