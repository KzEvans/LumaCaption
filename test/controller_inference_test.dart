import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/core/asr/whisper.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';

class _Decode {
  _Decode(this.samples, this.prompt, this.isFinal);
  final int samples;
  final String prompt;
  final bool isFinal;
  final result = Completer<List<WhisperResult>>();

  void finish(String text) {
    if (!result.isCompleted) {
      result.complete(
        text.isEmpty
            ? []
            : [WhisperResult(text, 0, samples * 1000000 ~/ 16000)],
      );
    }
  }
}

class _HeldWhisper extends WhisperEngine {
  final calls = <_Decode>[];
  int cancellations = 0;

  @override
  bool get ready => true;
  @override
  String get backend => 'Fake Whisper';

  @override
  Future<List<WhisperResult>> transcribe(
    Float32List samples, {
    String language = 'auto',
    String prompt = '',
    bool isFinal = true,
  }) {
    final decode = _Decode(samples.length, prompt, isFinal);
    calls.add(decode);
    return decode.result.future;
  }

  // Cancellation is deliberately acknowledged later to exercise the period
  // in which a real native worker can still return its previous result.
  @override
  void cancel() => cancellations++;
  @override
  Future<void> close() async {
    for (final decode in calls) {
      decode.finish('');
    }
  }
}

class _HeldBridge extends NativeBridge {
  _HeldBridge(this.support);
  final String support;
  final audio = StreamController<dynamic>.broadcast(sync: true);
  final methods = <String>[];
  final overlays = <Map<String, dynamic>>[];
  Completer<void>? stopGate;
  int _sequence = 0;

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
        break;
      case 'stop':
        await stopGate?.future;
      case 'overlay.update':
        overlays.add(Map<String, dynamic>.from(args!));
      default:
        throw StateError('Unexpected native call: $method');
    }
    return response as T?;
  }

  void frames(int count) {
    final samples = Float32List.fromList(List.filled(1600, 0.1));
    for (var i = 0; i < count; i++) {
      final sequence = _sequence++;
      audio.add({
        'type': 'audio',
        'pcm': samples.buffer.asUint8List(),
        'sampleRate': 16000,
        'channels': 1,
        'timestampUs': 1000000 + sequence * 100000,
        'sequence': sequence,
      });
    }
  }

  void releaseStop() {
    final gate = stopGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    stopGate = null;
  }
}

class _Harness {
  _Harness(this.directory, this.native, this.whisper, this.controller);
  final Directory directory;
  final _HeldBridge native;
  final _HeldWhisper whisper;
  final AppController controller;

  static Future<_Harness> create() async {
    final directory = await Directory.systemTemp.createTemp('luma-inference-');
    final native = _HeldBridge(directory.path);
    final whisper = _HeldWhisper();
    final controller = AppController(bridge: native, engine: whisper)
      ..testMode = true;
    await controller.initialize();
    expect(controller.error, isEmpty);
    controller.settings.mode = 'offline';
    // The fake engine is already ready, so no model file or FFI is accessed.
    controller.settings.modelPath = 'fake-ready-model.bin';
    return _Harness(directory, native, whisper, controller);
  }

  Future<void> close() async {
    native.releaseStop();
    for (final decode in whisper.calls) {
      decode.finish('');
    }
    // Allow a held stop to acknowledge its completed fake worker first.
    await _turn();
    if (controller.running) await controller.stop(emergency: true);
    controller.dispose();
    await native.audio.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final fails in [false, true]) {
    test(
      'disposed controller ignores pending decode ${fails ? "error" : "result"}',
      () async {
        final h = await _Harness.create();
        var disposed = false;
        try {
          await h.controller.start();
          h.native.frames(20);
          final decode = h.whisper.calls.single;
          if (fails) {
            decode.result.completeError(StateError('Canceled worker'));
          } else {
            decode.finish('Late source after exit.');
          }
          // Dispose before the completed future resumes the inference callback.
          h.controller.dispose();
          disposed = true;
          await _turn();
          expect(h.native.overlays, isEmpty);
          expect(h.controller.subtitles.segments, isEmpty);
          expect(h.controller.error, isEmpty);
        } finally {
          if (!disposed) {
            await h.close();
          } else {
            await h.native.audio.close();
            await h.directory.delete(recursive: true);
          }
        }
      },
    );
  }

  test(
    'emergency stop invalidates a held decode before native capture stop returns',
    () async {
      final h = await _Harness.create();
      final c = h.controller;
      try {
        await c.start();
        h.native.frames(20);
        expect(h.whisper.calls, hasLength(1));
        expect(h.whisper.calls.single.isFinal, false);
        final oldGeneration = c.generation;
        h.native.stopGate = Completer<void>();

        final stopping = c.stop(emergency: true);
        expect(c.generation, oldGeneration + 1);
        expect(c.subtitles.generation, c.generation);
        expect(h.whisper.cancellations, 1);
        expect(c.running, false);
        expect(c.busy, true);
        expect(h.native.methods.last, 'stop');

        h.whisper.calls.single.finish('Late source from the old session.');
        await _turn();
        expect(c.subtitles.segments, isEmpty);
        expect(h.native.overlays, isEmpty);
        expect(c.busy, true);

        h.native.releaseStop();
        await stopping;
        expect(c.busy, false);
        expect(c.status, '已停止');
        expect(c.error, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  test(
    'stopping waits for the worker and a restarted session can decode',
    () async {
      final h = await _Harness.create();
      final c = h.controller;
      try {
        await c.start();
        h.native.frames(20);
        final oldGeneration = c.generation;
        var stopped = false;
        final stopping = c.stop(emergency: true).then((_) => stopped = true);
        await _turn();
        expect(stopped, false);
        expect(c.busy, true);
        expect(c.generation, oldGeneration + 1);
        await c.start();
        expect(c.generation, oldGeneration + 1);
        expect(h.whisper.calls, hasLength(1));

        h.whisper.calls.single.finish('Canceled old source.');
        await stopping;
        expect(c.subtitles.segments, isEmpty);
        await c.start();
        expect(c.generation, oldGeneration + 2);
        h.native.frames(20);
        expect(h.whisper.calls, hasLength(2));
        expect(h.whisper.calls.last.prompt, isEmpty);
        h.whisper.calls.last.finish('New source in the restarted session.');
        await _turn();
        expect(c.subtitles.segments, hasLength(1));
        expect(c.subtitles.segments.single.generation, c.generation);
        expect(
          c.subtitles.segments.single.original,
          'New source in the restarted session.',
        );
        expect(c.error, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  test(
    'only the previous confirmed window becomes a recognition prompt',
    () async {
      final h = await _Harness.create();
      final c = h.controller;
      try {
        await c.start();
        for (var preview = 0; preview < 3; preview++) {
          h.native.frames(20);
          final decode = h.whisper.calls.last;
          expect(decode.isFinal, false);
          expect(decode.prompt, isEmpty);
          decode.finish('Unconfirmed name from preview $preview.');
          await _turn();
        }

        h.native.frames(20);
        final finalDecode = h.whisper.calls.last;
        expect(finalDecode.isFinal, true);
        expect(finalDecode.prompt, isEmpty);
        finalDecode.finish('Confirmed Amelia Frost is here.');
        await _turn();
        expect(c.subtitles.segments.single.isFinal, true);

        h.native.frames(20);
        final following = h.whisper.calls.last;
        expect(following.isFinal, false);
        expect(following.prompt, 'Confirmed Amelia Frost is here.');
        following.finish('Following audio window.');
        await _turn();
        expect(c.subtitles.segments, hasLength(2));
        expect(c.error, isEmpty);
      } finally {
        await h.close();
      }
    },
  );
}
