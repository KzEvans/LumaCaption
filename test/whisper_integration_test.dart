import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/asr/whisper.dart';
import 'package:lumacaption/core/audio/audio.dart';
import 'package:lumacaption/core/models/model_manager.dart';

void main() {
  final model = Platform.environment['LUMA_TEST_MODEL'],
      wav = Platform.environment['LUMA_TEST_WAV'];
  test(
    'real native model SHA256 load FFI inference and release',
    () async {
      await verifyModel(
        model!,
        expectedSha256:
            'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21',
      );
      final audio = WavAudio.decode(await File(wav!).readAsBytes());
      final samples = PcmConverter().convert(audio);
      final engine = WhisperEngine();
      final watch = Stopwatch()..start();
      try {
        await engine.load(model);
        final results = await engine.transcribe(samples, language: 'en');
        final text = results.map((r) => r.text).join(' ').toLowerCase();
        expect(text, contains('country'));
        expect(results, isNotEmpty);
        expect(results.first.startUs, greaterThanOrEqualTo(0));
        expect(
          results.last.endUs,
          lessThanOrEqualTo(samples.length * 1000000 ~/ 16000 + 500000),
        );
        // ignore: avoid_print
        print(
          'real inference: ${watch.elapsedMilliseconds}ms including load; audio=${(samples.length / 16000).toStringAsFixed(2)}s; backend=${engine.backend}; currentRSS=${ProcessInfo.currentRss} bytes',
        );
      } finally {
        await engine.close();
      }
      expect(engine.ready, false);
    },
    skip: model == null || wav == null
        ? 'Set LUMA_TEST_MODEL and LUMA_TEST_WAV to run native inference.'
        : false,
  );
}
