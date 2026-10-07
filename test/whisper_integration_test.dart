import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/asr/whisper.dart';
import 'package:lumacaption/core/audio/audio.dart';
import 'package:lumacaption/core/models/model_manager.dart';

void main() {
  final model = Platform.environment['LUMA_TEST_MODEL'],
      wav = Platform.environment['LUMA_TEST_WAV'];
  test(
    'real native backend, prompted preview/final, cancellation and release',
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
        expect(
          engine.backend,
          matches(r'^(Metal|CPU) · whisper\.cpp v1\.8\.1$'),
        );
        final expectedBackend = Platform.environment['LUMA_TEST_BACKEND'];
        if (expectedBackend != null) {
          expect(engine.backend, startsWith('$expectedBackend ·'));
        }
        final preview = await engine.transcribe(
          Float32List.sublistView(samples, 0, 16000 * 8),
          language: 'en',
          prompt: 'My fellow Americans.',
          isFinal: false,
        );
        expect(
          preview.map((r) => r.text).join(' ').toLowerCase(),
          contains('country'),
        );
        // A cancellation made immediately after submitting must survive until
        // the worker enters native code, then the next request must recover.
        final canceled = engine.transcribe(samples, language: 'en');
        engine.cancel();
        await expectLater(canceled, throwsA(isA<StateError>()));
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
          'native workflow: ${watch.elapsedMilliseconds}ms for load, prompted preview, cancellation and final; audio=${(samples.length / 16000).toStringAsFixed(2)}s; backend=${engine.backend}; currentRSS=${ProcessInfo.currentRss} bytes',
        );
      } finally {
        await engine.close();
      }
      expect(engine.ready, false);
      expect(engine.backend, 'Whisper · 未加载');
    },
    skip: model == null || wav == null
        ? 'Set LUMA_TEST_MODEL and LUMA_TEST_WAV to run native inference.'
        : false,
  );
}
