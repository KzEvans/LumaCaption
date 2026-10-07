import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/audio/audio.dart';

void main() {
  AudioFrame frame(Float32List v, int rate, {int channels = 1}) => AudioFrame(
    samples: v,
    sampleRate: rate,
    channels: channels,
    timestampUs: 0,
    sequence: 0,
    generation: 1,
  );
  test('stereo downmix and real PCM16 saturation', () {
    final c = PcmConverter();
    final v = c.convert(
      frame(Float32List.fromList([1, -1, 0.5, 0.5]), 16000, channels: 2),
    );
    expect(v, [0, 0.5]);
    expect(
      ByteData.sublistView(
        PcmConverter.pcm16(Float32List.fromList([-2, 2])),
      ).getInt16(0, Endian.little),
      -32767,
    );
  });
  test('48k to16k retains1k suppresses12k and continuity across chunks', () {
    Float32List tone(double hz) => Float32List.fromList(
      List.generate(48000, (i) => sin(2 * pi * hz * i / 48000)),
    );
    final c = PcmConverter();
    final low = c.convert(frame(tone(1000), 48000));
    c.reset();
    final high = c.convert(frame(tone(12000), 48000));
    expect(low.length, closeTo(16000, 12));
    expect(PcmConverter.rms(low), greaterThan(.6));
    expect(PcmConverter.rms(high), lessThan(.03));
    final split = PcmConverter(), parts = <double>[];
    final data = tone(1000);
    for (var i = 0; i < 48000; i += 480) {
      parts.addAll(
        split.convert(frame(Float32List.sublistView(data, i, i + 480), 48000)),
      );
    }
    expect(parts.length, low.length);
    for (var i = 0; i < low.length; i++) {
      expect(parts[i], closeTo(low[i], .0001));
    }
  });
  test(
    'VAD bounds long speech, flush retains final audio, silence has no inference',
    () {
      final s = AudioSegmenter();
      expect(s.add(Float32List(16000 * 10), 0), isEmpty);
      final chunks = s.add(
        Float32List.fromList(List.filled(128000, .1)),
        10000000,
      );
      expect(chunks.length, 1);
      expect(chunks.first.samples.length, lessThanOrEqualTo(16000 * 9));
      expect(s.flush(), isNotNull);
      expect(s.flush(), isNull);
    },
  );
  test('WAV invalid input rejected', () {
    expect(() => WavAudio.decode(Uint8List(44)), throwsFormatException);
  });
  test('speech previews revise one segment before final confirmation', () {
    final segmenter = AudioSegmenter();
    final speech = Float32List.fromList(List.filled(32000, .1));
    final first = segmenter.add(speech, 0).single;
    final second = segmenter.add(speech, 2000000).single;
    final finalChunk = segmenter.add(Float32List(9600), 4000000).single;
    expect(first.isFinal, false);
    expect(second.segmentId, first.segmentId);
    expect(second.revision, greaterThan(first.revision));
    expect(finalChunk.segmentId, first.segmentId);
    expect(finalChunk.revision, greaterThan(second.revision));
    expect(finalChunk.isFinal, true);
    expect(finalChunk.endUs, 4600000);
    expect(segmenter.flush(), isNull);
  });
  test(
    'fast previews keep context and final boundary while checking every second',
    () {
      final s = AudioSegmenter(previewInterval: const Duration(seconds: 1));
      AudioChunk add(int seconds) => s
          .add(Float32List.fromList(List.filled(16000 * seconds, .1)), 0)
          .single;
      final first = add(2), second = add(1), third = add(1);
      expect(first.endUs, 2000000);
      expect(second.endUs, 3000000);
      expect(third.endUs, 4000000);
      expect(second.segmentId, first.segmentId);
      expect(second.isFinal, false);
      final finalChunk = add(4);
      expect(finalChunk.isFinal, true);
      expect(finalChunk.endUs, 8000000);
    },
  );
  test(
    'adaptive previews retain the first two seconds then use fast cadence',
    () {
      final segmenter = AudioSegmenter(
        enableAdaptive: true,
        previewInterval: const Duration(seconds: 1),
      );
      final oneSecond = Float32List.fromList(List.filled(16000, .1));
      segmenter.observeInference(const Duration(milliseconds: 450));
      expect(segmenter.previewInterval, const Duration(microseconds: 562500));
      expect(segmenter.add(oneSecond, 0), isEmpty);
      final first = segmenter.add(oneSecond, 1000000).single;
      expect(first.endUs, 2000000);
      final second = segmenter.add(oneSecond, 2000000).single;
      expect(second.endUs, 3000000);
      expect(second.segmentId, first.segmentId);
      expect(second.isFinal, false);
    },
  );
  test(
    'aggressive adaptive previews start at one second then every half second',
    () {
      final segmenter = AudioSegmenter(
        firstPreview: const Duration(seconds: 1),
        previewInterval: const Duration(milliseconds: 500),
        enableAdaptive: true,
      );
      final frame = Float32List.fromList(List.filled(1600, .1));
      final chunks = <AudioChunk>[];
      for (var i = 0; i < 80; i++) {
        chunks.addAll(segmenter.add(frame, i * 100000));
      }
      expect(chunks.first.endUs, 1000000);
      expect(
        chunks.where((chunk) => !chunk.isFinal).map((chunk) => chunk.endUs),
        orderedEquals(List.generate(14, (i) => 1000000 + i * 500000)),
      );
      expect(
        chunks.every((chunk) => chunk.segmentId == chunks.first.segmentId),
        true,
      );
      // Eight seconds is also due for a preview; the final takes precedence.
      expect(chunks.last.isFinal, true);
      expect(chunks.last.endUs, 8000000);
      expect(chunks.where((chunk) => chunk.isFinal).length, 1);
    },
  );
  test(
    'aggressive cadence backs off under load then returns to half a second',
    () {
      final segmenter = AudioSegmenter(
        firstPreview: const Duration(seconds: 1),
        previewInterval: const Duration(milliseconds: 500),
        enableAdaptive: true,
      );
      Float32List speech(int milliseconds) =>
          Float32List.fromList(List.filled(milliseconds * 16, .1));
      final first = segmenter.add(speech(1000), 0).single;
      segmenter.observeInference(const Duration(seconds: 4));
      expect(segmenter.previewInterval, const Duration(seconds: 3));
      expect(segmenter.add(speech(2500), 1000000), isEmpty);
      final slowed = segmenter.add(speech(500), 3500000).single;
      expect(slowed.endUs, 4000000);
      for (var i = 0; i < 13; i++) {
        segmenter.observeInference(const Duration(milliseconds: 200));
      }
      expect(segmenter.previewInterval, const Duration(milliseconds: 500));
      expect(segmenter.add(speech(400), 4000000), isEmpty);
      final recovered = segmenter.add(speech(100), 4400000).single;
      expect(recovered.endUs, 4500000);
      expect(recovered.segmentId, first.segmentId);
      expect(recovered.isFinal, false);
    },
  );
  test(
    'slow inference backs previews off without changing the eight-second final',
    () {
      final segmenter = AudioSegmenter(
        enableAdaptive: true,
        previewInterval: const Duration(seconds: 1),
      );
      List<AudioChunk> add(int seconds) => segmenter.add(
        Float32List.fromList(List.filled(16000 * seconds, .1)),
        0,
      );
      final first = add(2).single;
      segmenter.observeInference(const Duration(seconds: 4));
      expect(segmenter.previewInterval, const Duration(seconds: 3));
      expect(add(1), isEmpty);
      expect(add(1), isEmpty);
      final next = add(1).single;
      expect(next.endUs, 5000000);
      expect(next.segmentId, first.segmentId);
      expect(add(2), isEmpty);
      final finalChunk = add(1).single;
      expect(finalChunk.isFinal, true);
      expect(finalChunk.endUs, 8000000);
      expect(finalChunk.samples.length, 128000);
    },
  );
  test(
    'adaptive inference estimate recovers gradually within half to three seconds',
    () {
      final segmenter = AudioSegmenter(enableAdaptive: true);
      segmenter.observeInference(const Duration(seconds: 4));
      expect(segmenter.previewInterval, const Duration(seconds: 3));
      segmenter.observeInference(const Duration(milliseconds: 200));
      expect(segmenter.previewInterval, const Duration(seconds: 3));
      final intervals = <int>[];
      for (var i = 0; i < 12; i++) {
        segmenter.observeInference(const Duration(milliseconds: 200));
        intervals.add(segmenter.previewInterval.inMicroseconds);
      }
      expect(
        intervals.every((value) => value >= 500000 && value <= 3000000),
        true,
      );
      expect(
        intervals,
        orderedEquals(intervals.toList()..sort((a, b) => b.compareTo(a))),
      );
      expect(segmenter.previewInterval, const Duration(milliseconds: 500));
      segmenter.observeInference(Duration.zero);
      segmenter.observeInference(const Duration(microseconds: -1));
      expect(segmenter.previewInterval, const Duration(milliseconds: 500));
    },
  );
  test('final decode observations gently adjust the preview cadence', () {
    final segmenter = AudioSegmenter(enableAdaptive: true);
    segmenter.observeInference(const Duration(milliseconds: 800));
    expect(segmenter.previewInterval, const Duration(seconds: 1));
    segmenter.observeInference(const Duration(seconds: 3), isFinal: true);
    expect(segmenter.previewInterval, const Duration(microseconds: 1412500));
    segmenter.reset();
    expect(segmenter.previewInterval, const Duration(microseconds: 1412500));
  });
  test(
    'adaptive cadence preserves the six-hundred-millisecond silence final',
    () {
      final segmenter = AudioSegmenter(enableAdaptive: true);
      final first = segmenter
          .add(Float32List.fromList(List.filled(32000, .1)), 0)
          .single;
      segmenter.observeInference(const Duration(seconds: 5));
      expect(segmenter.add(Float32List(3200), 2000000), isEmpty);
      expect(segmenter.add(Float32List(3200), 2200000), isEmpty);
      final finalChunk = segmenter.add(Float32List(3200), 2400000).single;
      expect(finalChunk.isFinal, true);
      expect(finalChunk.segmentId, first.segmentId);
      expect(finalChunk.endUs, 2600000);
      expect(segmenter.flush(), isNull);
    },
  );
  test(
    'default offline cadence stays at two seconds despite inference observations',
    () {
      final segmenter = AudioSegmenter();
      segmenter.observeInference(const Duration(milliseconds: 100));
      segmenter.observeInference(const Duration(seconds: 6), isFinal: true);
      expect(segmenter.previewInterval, const Duration(seconds: 2));
      final oneSecond = Float32List.fromList(List.filled(16000, .1));
      expect(segmenter.add(oneSecond, 0), isEmpty);
      expect(segmenter.add(oneSecond, 1000000).single.endUs, 2000000);
      expect(segmenter.add(oneSecond, 2000000), isEmpty);
      expect(segmenter.add(oneSecond, 3000000).single.endUs, 4000000);
    },
  );

  // These probabilities exercise segmentation, not a real VAD's accuracy.
  List<AudioChunk> classified(
    AudioSegmenter segmenter,
    int count,
    int startUs,
    double probability, {
    double value = 0,
  }) => [
    for (var i = 0; i < count; i++)
      ...segmenter.addClassified(
        Float32List.fromList(List.filled(512, value)),
        startUs + i * 32000,
        speechProbability: probability,
      ),
  ];

  test('neural endpoint accepts short speech after exactly 384ms silence', () {
    final s = AudioSegmenter();
    expect(classified(s, 8, 0, .5, value: .5), isEmpty);
    expect(classified(s, 11, 256000, .1), isEmpty);
    final finalChunk = classified(s, 1, 608000, .1).single;
    expect(finalChunk.isFinal, true);
    expect(finalChunk.endpointReason, 'silence');
    expect(finalChunk.startUs, 0);
    expect(finalChunk.speechEndUs, 256000);
    expect(finalChunk.endUs, 352000);
    expect(finalChunk.samples.length, 5632);
    expect(finalChunk.samples.take(4096), everyElement(.5));
    expect(finalChunk.samples.skip(4096), everyElement(0));
    expect(s.flush(), isNull);
  });

  test('neural start/continue hysteresis uses probability rather than RMS', () {
    final s = AudioSegmenter();
    // Loud input below start threshold is pre-roll, not speech evidence.
    expect(classified(s, 10, 0, .49, value: .75), isEmpty);
    expect(classified(s, 1, 320000, .5), isEmpty);
    expect(classified(s, 7, 352000, .35), isEmpty);
    expect(classified(s, 11, 576000, .34), isEmpty);
    final result = classified(s, 1, 928000, .49).single;
    // .49 cannot restart after .34 exited the speech state.
    expect(result.endpointReason, 'silence');
    expect(result.speechEndUs, 576000);
    expect(result.endUs, 672000);
  });

  test('short neural gaps retain one utterance and all internal audio', () {
    final s = AudioSegmenter();
    expect(classified(s, 8, 0, .9, value: .5), isEmpty);
    expect(classified(s, 6, 256000, .1), isEmpty); // 192ms pause.
    expect(classified(s, 8, 448000, .9, value: .75), isEmpty);
    final results = classified(s, 12, 704000, .1);
    final result = results.where((c) => c.isFinal).single;
    expect(result.startUs, 0);
    expect(result.speechEndUs, 704000);
    expect(result.endUs, 800000);
    expect(result.samples.sublist(4096, 7168), everyElement(0));
    expect(result.samples.sublist(7168, 11264), everyElement(.75));
    expect(s.flush(), isNull);
  });

  test(
    'pure silence and less than 250ms classified bursts produce no final',
    () {
      final silence = AudioSegmenter();
      expect(classified(silence, 100, 0, .1, value: .75), isEmpty);
      expect(silence.flush(), isNull);
      final burst = AudioSegmenter();
      expect(classified(burst, 7, 0, .9, value: .5), isEmpty); // 224ms.
      expect(
        burst.flush(tail: Float32List(511), tailTimestampUs: 224000),
        isNull,
      );
      final endpointBurst = AudioSegmenter();
      expect(classified(endpointBurst, 7, 0, .9), isEmpty);
      expect(classified(endpointBurst, 12, 224000, .1), isEmpty);
      expect(endpointBurst.flush(), isNull);
      expect(
        AudioSegmenter().flush(tail: Float32List(137), tailTimestampUs: 0),
        isNull,
      );
    },
  );

  test('silence trim retains actual 400ms pre-roll for the next utterance', () {
    final s = AudioSegmenter();
    classified(s, 20, 0, .1, value: .25);
    classified(s, 8, 640000, .9, value: .5);
    final first = classified(s, 12, 896000, .1).single;
    expect(first.startUs, 240000);
    expect(first.speechEndUs, 896000);
    expect(first.endUs, 992000);
    expect(first.samples.take(6400), everyElement(.25));
    // Detection happened at 1.280s; the trimmed 288ms still enters pre-roll.
    classified(s, 8, 1280000, .9, value: .75);
    final second = classified(s, 12, 1536000, .1).single;
    expect(second.segmentId, isNot(first.segmentId));
    expect(second.startUs, 880000);
    expect(second.speechEndUs, 1536000);
    expect(second.endUs, 1632000);
    expect(second.samples.take(256), everyElement(.5));
    expect(second.samples.sublist(256, 6400), everyElement(0));
    expect(second.samples.sublist(6400, 10496), everyElement(.75));
  });

  test(
    'neural eight-second cap keeps overlap and a crossing-window remainder',
    () {
      final s = AudioSegmenter();
      classified(s, 20, 0, .1);
      final chunks = <AudioChunk>[];
      for (var i = 0; i < 238; i++) {
        chunks.addAll(
          s.addClassified(
            Float32List.fromList(List.filled(512, i / 512)),
            640000 + i * 32000,
            speechProbability: .9,
          ),
        );
      }
      final bounded = chunks.where((c) => c.isFinal).single;
      expect(bounded.endpointReason, 'maxWindow');
      expect(bounded.startUs, 240000);
      expect(bounded.endUs, 8240000);
      expect(bounded.speechEndUs, 8240000);
      expect(bounded.samples.length, 128000);
      final remainder = s.flush()!;
      expect(remainder.endpointReason, 'eof');
      expect(remainder.startUs, 7740000);
      expect(remainder.endUs, 8256000);
      expect(remainder.speechEndUs, 8256000);
      expect(remainder.samples.length, 8256); // 500ms overlap + 16ms new audio.
      expect(
        remainder.samples.take(8000),
        orderedEquals(bounded.samples.skip(120000)),
      );
      expect(remainder.samples.skip(8000), everyElement(237 / 512));
      expect(s.flush(), isNull);
    },
  );

  test('neural EOF includes real unclassified residual without padding', () {
    final s = AudioSegmenter();
    classified(s, 8, 0, .9, value: .5);
    final result = s.flush(
      tail: Float32List.fromList(List.filled(137, .75)),
      tailTimestampUs: 256000,
    )!;
    expect(result.endpointReason, 'eof');
    expect(result.speechEndUs, 256000); // Latest classified speech end.
    expect(result.endUs, 264562);
    expect(result.samples.length, 4233);
    expect(result.samples.skip(4096), everyElement(.75));
    expect(s.flush(), isNull);
  });

  test(
    'energy fallback retains classified short speech and pending PCM order',
    () {
      final s = AudioSegmenter();
      expect(classified(s, 6, 0, .9, value: .25), isEmpty);
      s.useEnergyFallback();
      final pending = Float32List.fromList([
        ...List.filled(128, .5),
        ...List.filled(1600, .75),
      ]);
      expect(s.add(pending, 192000), isEmpty);
      final result = s.flush()!;
      expect(result.startUs, 0);
      expect(result.endUs, 300000);
      expect(result.samples.length, 4800);
      expect(result.samples.take(3072), everyElement(.25));
      expect(result.samples.sublist(3072, 3200), everyElement(.5));
      expect(result.samples.skip(3200), everyElement(.75));
      expect(result.speechEndUs, isNull);
      expect(s.flush(), isNull);
    },
  );

  test('energy fallback preserves preview identity revision and cadence', () {
    final s = AudioSegmenter(
      firstPreview: const Duration(seconds: 1),
      previewInterval: const Duration(milliseconds: 500),
    );
    final first = classified(s, 32, 0, .9, value: .5).single;
    s.useEnergyFallback();
    final next = s
        .add(Float32List.fromList(List.filled(8000, .75)), 1024000)
        .single;
    expect(next.isFinal, false);
    expect(next.segmentId, first.segmentId);
    expect(next.revision, first.revision + 1);
    expect(next.startUs, first.startUs);
    expect(next.endUs, 1524000);
    final finalChunk = s.flush()!;
    expect(finalChunk.segmentId, first.segmentId);
    expect(finalChunk.revision, next.revision + 1);
    expect(finalChunk.samples.length, 24384);
  });

  test('neural discontinuity flushes old speech and clears hysteresis', () {
    final s = AudioSegmenter();
    classified(s, 8, 0, .9);
    final previous = classified(s, 1, 288000, .4).single;
    expect(previous.endpointReason, 'eof');
    expect(previous.startUs, 0);
    expect(previous.endUs, 256000);
    expect(classified(s, 8, 320000, .4), isEmpty);
    expect(s.flush(), isNull);
    // An explicit reset also requires a fresh >=.5 start probability.
    classified(s, 1, 576000, .9);
    s.reset();
    expect(classified(s, 8, 608000, .4), isEmpty);
    expect(s.flush(), isNull);
  });

  test('neural previews preserve first interval and adaptive cadence', () {
    final s = AudioSegmenter(
      firstPreview: const Duration(seconds: 1),
      previewInterval: const Duration(milliseconds: 500),
      enableAdaptive: true,
    );
    final previews = classified(s, 48, 0, .9);
    expect(previews.map((c) => c.endUs), orderedEquals([1024000, 1536000]));
    expect(previews.every((c) => !c.isFinal), true);
    s.observeInference(const Duration(seconds: 4));
    expect(s.previewInterval, const Duration(seconds: 3));
    expect(classified(s, 93, 1536000, .9), isEmpty);
    expect(classified(s, 1, 4512000, .9).single.endUs, 4544000);
    final rest = classified(s, 108, 4544000, .9);
    final finalChunk = rest.where((c) => c.isFinal).single;
    expect(finalChunk.endpointReason, 'maxWindow');
    expect(finalChunk.endUs, 8000000);
  });

  test('neural API rejects malformed windows, probabilities and EOF tails', () {
    final s = AudioSegmenter();
    expect(
      () => s.addClassified(Float32List(511), 0, speechProbability: .9),
      throwsArgumentError,
    );
    expect(
      () => s.addClassified(Float32List(512), 0, speechProbability: double.nan),
      throwsArgumentError,
    );
    expect(
      () => s.addClassified(Float32List(512), 0, speechProbability: 1.1),
      throwsArgumentError,
    );
    classified(s, 8, 0, .9);
    expect(
      () => s.flush(tail: Float32List(512), tailTimestampUs: 256000),
      throwsArgumentError,
    );
    expect(
      () => s.flush(tail: Float32List(32), tailTimestampUs: 256001),
      throwsArgumentError,
    );
    expect(s.flush()?.endUs, 256000);
  });
}
