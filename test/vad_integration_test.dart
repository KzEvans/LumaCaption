import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/asr/vad.dart';
import 'package:lumacaption/core/audio/audio.dart';

void main() {
  final model = Platform.environment['LUMA_TEST_VAD_MODEL'];
  final library = Platform.environment['LUMA_WHISPER_LIBRARY'];
  final configured =
      model != null &&
      File(model).existsSync() &&
      library != null &&
      File(library).existsSync();
  final skip = configured
      ? false
      : 'CPU VAD fixture requires LUMA_TEST_VAD_MODEL and LUMA_WHISPER_LIBRARY';

  test(
    'CPU VAD emits each complete absolute window once and never pads a residual',
    () async {
      final vad = SileroVadEngine();
      try {
        await vad.load(model!);
        expect(vad.ready, true);
        expect(vad.backend, startsWith('CPU'));
        await vad.reset(1);
        expect(
          await vad.process(Float32List(511), generation: 1, sampleOffset: 0),
          isEmpty,
        );
        final first = await vad.process(
          Float32List(1),
          generation: 1,
          sampleOffset: 511,
        );
        expect(first, hasLength(1));
        expect(first.single.startSample, 0);
        expect(first.single.endSample, 512);
        expect(first.single.generation, 1);
        expect(first.single.probability, inInclusiveRange(0, 1));
        final large = await vad.process(
          Float32List(32000),
          generation: 1,
          sampleOffset: 512,
        );
        expect(large, hasLength(62));
        for (var i = 0; i < large.length; i++) {
          expect(large[i].startSample, 512 + i * 512);
          expect(large[i].endSample, 1024 + i * 512);
          expect(large[i].probability, lessThan(0.5));
        }
        final continued = await vad.process(
          Float32List(256),
          generation: 1,
          sampleOffset: 32512,
        );
        expect(continued, hasLength(1));
        expect(continued.single.startSample, 32256);
        expect(continued.single.endSample, 32768);
      } finally {
        await vad.close();
      }
      expect(vad.ready, false);
    },
    skip: skip,
  );

  test(
    'CPU VAD isolates generations and resets history across discontinuities',
    () async {
      final vad = SileroVadEngine();
      try {
        await vad.load(model!);
        await vad.reset(2);
        await vad.process(Float32List(100), generation: 2, sampleOffset: 0);
        expect(
          await vad.process(Float32List(512), generation: 1, sampleOffset: 100),
          isEmpty,
        );
        final contiguous = await vad.process(
          Float32List(412),
          generation: 2,
          sampleOffset: 100,
        );
        expect(contiguous.single.startSample, 0);
        expect(
          await vad.process(Float32List(512), generation: 2, sampleOffset: 0),
          isEmpty,
        );
        final gap = await vad.process(
          Float32List(512),
          generation: 2,
          sampleOffset: 10000,
        );
        expect(gap.single.startSample, 10000);
        expect(gap.single.endSample, 10512);
        await vad.reset(3);
        await vad.reset(
          2,
        ); // Late stale reset cannot revive the previous epoch.
        final restarted = await vad.process(
          Float32List(512),
          generation: 3,
          sampleOffset: 20000,
        );
        expect(restarted.single.startSample, 20000);
        expect(restarted.single.generation, 3);
      } finally {
        await vad.close();
      }
    },
    skip: skip,
  );

  test(
    'CPU VAD close drains its already submitted native work before freeing',
    () async {
      final vad = SileroVadEngine();
      await vad.load(model!);
      await vad.reset(1);
      final pending = vad.process(
        Float32List(16000),
        generation: 1,
        sampleOffset: 0,
      );
      final closing = vad.close();
      expect(vad.ready, false);
      expect(await pending, hasLength(31));
      await closing;
      await vad.close();
      expect(vad.ready, false);
    },
    skip: skip,
  );

  test(
    'CPU VAD load failure closes and allows a fresh load; early close cancels load',
    () async {
      final vad = SileroVadEngine();
      try {
        await expectLater(vad.load('$model.missing'), throwsStateError);
        expect(vad.ready, false);
        await vad.load(model!);
        expect(vad.ready, true);
        await vad.close();
        final loading = vad.load(model);
        final closing = vad.close();
        await expectLater(loading, throwsStateError);
        await closing;
        expect(vad.ready, false);
        await vad.load(model);
        expect(vad.ready, true);
      } finally {
        await vad.close();
      }
    },
    skip: skip,
  );

  test(
    'CPU VAD silently classifies the public JFK file with bounded replay calls',
    () async {
      final vad = SileroVadEngine();
      final fixture = File('.tools/whisper.cpp/samples/jfk.wav');
      expect(fixture.existsSync(), true);
      final wav = WavAudio.decode(await fixture.readAsBytes());
      expect(wav.sampleRate, 16000);
      expect(wav.channels, 1);
      final elapsed = <double>[];
      final frames = <VadFrame>[];
      try {
        final loading = Stopwatch()..start();
        await vad.load(model!);
        final loadMs = loading.elapsedMicroseconds / 1000;
        await vad.reset(1);
        for (var offset = 0; offset < wav.samples.length; offset += 1600) {
          final end = (offset + 1600).clamp(0, wav.samples.length);
          final watch = Stopwatch()..start();
          frames.addAll(
            await vad.process(
              Float32List.sublistView(wav.samples, offset, end),
              generation: 1,
              sampleOffset: offset,
            ),
          );
          elapsed.add(watch.elapsedMicroseconds / 1000);
        }
        expect(frames, hasLength(wav.samples.length ~/ 512));
        expect(frames.any((frame) => frame.probability >= 0.5), true);
        for (var i = 0; i < frames.length; i++) {
          expect(frames[i].startSample, i * 512);
          expect(frames[i].endSample, (i + 1) * 512);
          expect(frames[i].probability, inInclusiveRange(0, 1));
        }
        final originalFrames = frames.length;
        // A synthetic silent tail remains only in memory, allowing endpoint
        // behavior to be checked without playing or saving any audio.
        frames.addAll(
          await vad.process(
            Float32List(16000),
            generation: 1,
            sampleOffset: wav.samples.length,
          ),
        );
        var active = false;
        int? silenceStart;
        final endpoints = <int>[];
        for (final frame in frames) {
          if (frame.probability >= 0.5) {
            active = true;
            silenceStart = null;
          } else if (active && frame.probability < 0.35) {
            silenceStart ??= frame.startSample;
            if (frame.endSample - silenceStart >= 5600) {
              endpoints.add(silenceStart);
              active = false;
              silenceStart = null;
            }
          }
        }
        expect(endpoints, isNotEmpty);
        final sorted = List<double>.from(elapsed)..sort();
        double percentile(double fraction) =>
            sorted[((sorted.length - 1) * fraction).round()];
        // Numeric timing and public fixture offsets only; no user audio/text.
        stdout.writeln(
          'vad_cpu_jfk loadMs=${loadMs.toStringAsFixed(2)} '
          'calls=${elapsed.length} frames=$originalFrames '
          'meanMs=${(elapsed.reduce((a, b) => a + b) / elapsed.length).toStringAsFixed(2)} '
          'p50Ms=${percentile(0.5).toStringAsFixed(2)} '
          'p95Ms=${percentile(0.95).toStringAsFixed(2)} '
          'maxMs=${sorted.last.toStringAsFixed(2)} '
          'speechFrames=${frames.take(originalFrames).where((f) => f.probability >= 0.5).length} '
          'endpointSamples=$endpoints',
        );
      } finally {
        await vad.close();
      }
    },
    skip: skip,
  );
}
