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
}
