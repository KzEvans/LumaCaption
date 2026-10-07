import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/core/asr/whisper.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';
import 'package:lumacaption/core/storage/settings.dart';

class _Warmup {
  _Warmup(this.samples, this.language, this.prompt, this.isFinal);
  final Float32List samples;
  final String language, prompt;
  final bool isFinal;
  final result = Completer<List<WhisperResult>>();

  void finish() {
    if (!result.isCompleted) {
      // Even a hallucinated warmup result must stay outside the subtitle path.
      result.complete([
        const WhisperResult('Synthetic warmup text.', 0, 1000000),
      ]);
    }
  }

  void fail() => result.completeError(StateError('Warmup failed.'));
}

class _HeldWhisper extends WhisperEngine {
  final loads = <String>[];
  final calls = <_Warmup>[];
  final loadStarted = Completer<void>();
  final warmupStarted = Completer<void>();
  final closeStarted = Completer<void>();
  final closed = Completer<void>();
  final _loadGate = Completer<void>();
  Completer<void>? closeGate;
  bool _ready = false;
  int cancellations = 0, closeCalls = 0;
  int activeCloses = 0, maximumConcurrentCloses = 0;

  @override
  bool get ready => _ready;
  @override
  String get backend => 'Fake Metal';

  @override
  Future<void> load(String path) async {
    loads.add(path);
    if (!loadStarted.isCompleted) loadStarted.complete();
    await _loadGate.future;
    _ready = true;
  }

  @override
  Future<List<WhisperResult>> transcribe(
    Float32List samples, {
    String language = 'auto',
    String prompt = '',
    bool isFinal = true,
  }) {
    final call = _Warmup(
      Float32List.fromList(samples),
      language,
      prompt,
      isFinal,
    );
    calls.add(call);
    if (!warmupStarted.isCompleted) warmupStarted.complete();
    return call.result.future;
  }

  void releaseLoad() {
    if (!_loadGate.isCompleted) _loadGate.complete();
  }

  @override
  void cancel() => cancellations++;

  @override
  Future<void> close() async {
    closeCalls++;
    activeCloses++;
    if (activeCloses > maximumConcurrentCloses) {
      maximumConcurrentCloses = activeCloses;
    }
    if (!closeStarted.isCompleted) closeStarted.complete();
    try {
      await closeGate?.future;
      _ready = false;
    } finally {
      activeCloses--;
      if (!closed.isCompleted) closed.complete();
    }
  }

  void releaseClose() {
    final gate = closeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

class _PreloadBridge extends NativeBridge {
  _PreloadBridge(this.support);
  final String support;
  final audio = StreamController<dynamic>.broadcast(sync: true);
  final methods = <String>[];

  @override
  Stream<dynamic> get stream => audio.stream;

  @override
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    methods.add(method);
    Object? response;
    switch (method) {
      case 'paths':
        response = {'support': support};
      case 'devices':
        response = <dynamic>[];
      case 'permissions':
        response = {'system': 'authorized', 'microphone': 'denied'};
      case 'start':
      case 'stop':
        break;
      default:
        throw StateError('Unexpected native call: $method');
    }
    return response as T?;
  }
}

class _TrackedController extends AppController {
  _TrackedController({required super.bridge, required super.engine});
  bool wasDisposed = false;
  int notificationsAfterDispose = 0;

  @override
  void notifyListeners() {
    if (wasDisposed) notificationsAfterDispose++;
    super.notifyListeners();
  }

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class _Harness {
  _Harness(
    this.directory,
    this.model,
    this.native,
    this.whisper,
    this.controller,
  );
  final Directory directory;
  final File model;
  final _PreloadBridge native;
  final _HeldWhisper whisper;
  final _TrackedController controller;

  static Future<_Harness> create({bool testMode = false}) async {
    final directory = await Directory.systemTemp.createTemp('luma-preload-');
    // An unknown catalog name exercises GGML validation without a trusted SHA.
    final model = File('${directory.path}/custom-preload-model.bin');
    await model.writeAsBytes(
      Uint8List(1024)..setRange(0, 4, [0x6c, 0x6d, 0x67, 0x67]),
    );
    await SettingsStore(directory.path).save(
      AppSettings()
        ..mode = 'offline'
        ..modelPath = model.path,
    );
    final native = _PreloadBridge(directory.path);
    final whisper = _HeldWhisper();
    final controller = _TrackedController(bridge: native, engine: whisper)
      ..testMode = testMode;
    return _Harness(directory, model, native, whisper, controller);
  }

  Future<void> close() async {
    whisper.releaseLoad();
    whisper.releaseClose();
    await _turn();
    for (final call in whisper.calls) {
      call.finish();
    }
    await _turn();
    if (!controller.wasDisposed) {
      if (controller.running) await controller.stop(emergency: true);
      controller.dispose();
    }
    await whisper.closed.future;
    await native.audio.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void _expectWarmup(_Warmup call) {
  expect(call.samples, hasLength(16000));
  expect(call.samples.every((sample) => sample == 0), isTrue);
  expect(call.language, 'en');
  expect(call.prompt, isEmpty);
  expect(call.isFinal, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'initialize preloads and silently warms the saved offline model',
    () async {
      final h = await _Harness.create();
      final c = h.controller;
      try {
        await c.initialize();
        await h.whisper.loadStarted.future;
        expect(c.initialized, isTrue);
        expect(c.loadingModel, isTrue);
        expect(c.running, isFalse);
        expect(h.whisper.ready, isFalse);
        expect(h.whisper.loads, [h.model.path]);

        h.whisper.releaseLoad();
        await h.whisper.warmupStarted.future;
        expect(c.loadingModel, isTrue);
        expect(h.whisper.calls, hasLength(1));
        _expectWarmup(h.whisper.calls.single);
        h.whisper.calls.single.finish();
        await _turn();

        expect(c.loadingModel, isFalse);
        expect(c.status, '模型已就绪 · Fake Metal');
        expect(
          c.modelPreparationTiming?.keys,
          containsAll([
            'verificationMs',
            'nativeLoadMs',
            'warmupMs',
            'totalMs',
          ]),
        );
        expect(c.subtitles.segments, isEmpty);
        expect(c.receivedFrames, 0);
        expect(c.receivedSamples, 0);
        expect(c.translating, isFalse);
        expect(c.error, isEmpty);
        expect(h.native.methods, ['paths', 'devices', 'permissions']);
      } finally {
        await h.close();
      }
    },
  );

  test('start waits for warmup and reuses the model across sessions', () async {
    final h = await _Harness.create();
    final c = h.controller;
    try {
      await c.initialize();
      await h.whisper.loadStarted.future;
      h.whisper.releaseLoad();
      await h.whisper.warmupStarted.future;
      expect(h.whisper.ready, isTrue);
      _expectWarmup(h.whisper.calls.single);

      var started = false;
      final starting = c.start().then((_) => started = true);
      await _turn();
      expect(started, isFalse);
      expect(c.busy, isTrue);
      expect(c.running, isFalse);
      expect(h.native.methods, isNot(contains('start')));

      h.whisper.calls.single.finish();
      await starting;
      expect(started, isTrue);
      expect(c.running, isTrue);
      expect(c.busy, isFalse);
      expect(c.generation, 1);
      expect(c.subtitles.segments, isEmpty);
      final preparationTiming = c.modelPreparationTiming;

      await c.stop();
      expect(h.whisper.ready, isTrue);
      await c.start();
      expect(c.running, isTrue);
      expect(c.generation, 2);
      expect(h.whisper.loads, [h.model.path]);
      expect(h.whisper.calls, hasLength(1));
      expect(h.whisper.closeCalls, 0);
      expect(identical(c.modelPreparationTiming, preparationTiming), isTrue);
      expect(
        h.native.methods.where((method) => method == 'start'),
        hasLength(2),
      );
      expect(c.subtitles.segments, isEmpty);
      expect(c.translating, isFalse);
      expect(c.error, isEmpty);
      await c.stop();
    } finally {
      await h.close();
    }
  });

  test(
    'testMode initialize does not automatically load or warm a model',
    () async {
      final h = await _Harness.create(testMode: true);
      try {
        await h.controller.initialize();
        await _turn();
        expect(h.controller.initialized, isTrue);
        expect(h.controller.settings.modelPath, h.model.path);
        expect(h.controller.loadingModel, isFalse);
        expect(h.whisper.loads, isEmpty);
        expect(h.whisper.calls, isEmpty);
        expect(h.controller.modelPreparationTiming, isNull);
        expect(h.controller.error, isEmpty);
        expect(h.native.methods, ['paths', 'devices', 'permissions']);
      } finally {
        await h.close();
      }
    },
  );

  test(
    'a background preload cannot queue a different model selection',
    () async {
      final h = await _Harness.create();
      final c = h.controller;
      try {
        final otherModel = await h.model.copy(
          '${h.directory.path}/other-model.bin',
        );
        await c.initialize();
        await h.whisper.loadStarted.future;

        await expectLater(c.loadModel(otherModel.path), throwsStateError);
        expect(c.settings.modelPath, h.model.path);
        expect(h.whisper.loads, [h.model.path]);
        h.whisper.releaseLoad();
        await h.whisper.warmupStarted.future;
        h.whisper.calls.single.finish();
        await _turn();

        expect(c.loadingModel, isFalse);
        expect(h.whisper.loads, [h.model.path]);
        expect(h.whisper.calls, hasLength(1));
        expect(c.error, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  test(
    'an uncommitted model selection prevents start until preparation ends',
    () async {
      final h = await _Harness.create(testMode: true);
      final c = h.controller;
      try {
        final otherModel = await h.model.copy(
          '${h.directory.path}/other-model.bin',
        );
        await c.initialize();
        final selecting = c.loadModel(otherModel.path);
        await h.whisper.loadStarted.future;
        expect(c.settings.modelPath, h.model.path);

        await c.start();
        expect(c.running, isFalse);
        expect(c.busy, isFalse);
        expect(c.generation, 0);
        expect(h.whisper.calls, isEmpty);
        expect(h.native.methods, isNot(contains('start')));

        h.whisper.releaseLoad();
        await h.whisper.warmupStarted.future;
        await c.start();
        expect(c.running, isFalse);
        expect(c.generation, 0);
        expect(h.whisper.calls, hasLength(1));
        expect(h.native.methods, isNot(contains('start')));

        h.whisper.calls.single.finish();
        await selecting;
        expect(c.settings.modelPath, otherModel.path);
        await c.start();
        expect(c.running, isTrue);
        expect(h.whisper.loads, [otherModel.path]);
        expect(h.whisper.calls, hasLength(1));
        expect(
          h.native.methods.where((method) => method == 'start'),
          hasLength(1),
        );
        expect(c.error, isEmpty);
        await c.stop();
      } finally {
        await h.close();
      }
    },
  );

  test(
    'dispose waits for held warmup failure cleanup before closing again',
    () async {
      final h = await _Harness.create();
      final c = h.controller;
      try {
        await c.initialize();
        await h.whisper.loadStarted.future;
        h.whisper.releaseLoad();
        await h.whisper.warmupStarted.future;
        h.whisper.closeGate = Completer<void>();
        h.whisper.calls.single.fail();
        await h.whisper.closeStarted.future;
        expect(c.loadingModel, isTrue);

        c.dispose();
        await _turn();
        expect(h.whisper.closeCalls, 1);
        expect(h.whisper.activeCloses, 1);
        expect(h.whisper.closed.isCompleted, isFalse);

        h.whisper.releaseClose();
        await h.whisper.closed.future;
        await _turn();
        expect(h.whisper.closeCalls, 2);
        expect(h.whisper.activeCloses, 0);
        expect(h.whisper.maximumConcurrentCloses, 1);
        expect(h.whisper.ready, isFalse);
        expect(c.loadingModel, isFalse);
        expect(c.notificationsAfterDispose, 0);
        expect(c.error, isEmpty);
        expect(c.subtitles.segments, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  for (final phase in ['load', 'warmup']) {
    test(
      'dispose during $phase closes the worker without late notifications',
      () async {
        final h = await _Harness.create();
        final c = h.controller;
        try {
          await c.initialize();
          await h.whisper.loadStarted.future;
          if (phase == 'warmup') {
            h.whisper.releaseLoad();
            await h.whisper.warmupStarted.future;
          }

          c.dispose();
          await _turn();
          expect(h.whisper.cancellations, 1);
          expect(h.whisper.closeCalls, 0);
          expect(h.whisper.closed.isCompleted, isFalse);

          if (phase == 'load') {
            h.whisper.releaseLoad();
          } else {
            h.whisper.calls.single.finish();
          }
          await h.whisper.closed.future;
          await _turn();

          expect(h.whisper.closeCalls, 1);
          expect(h.whisper.ready, isFalse);
          expect(h.whisper.calls, hasLength(phase == 'load' ? 0 : 1));
          expect(c.notificationsAfterDispose, 0);
          expect(c.subtitles.segments, isEmpty);
          expect(c.modelPreparationTiming, isNull);
          expect(h.native.methods, ['paths', 'devices', 'permissions']);
        } finally {
          await h.close();
        }
      },
    );
  }
}
