import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/asr/local_context.dart';

void main() {
  test(
    'confirmed context applies only to a following window of this session',
    () {
      final context = LocalRecognitionContext()..reset(3);
      context.confirmed(
        generation: 3,
        startUs: 0,
        endUs: 8000000,
        text: 'And so my fellow Americans.',
      );
      expect(context.promptFor(generation: 3, audioStartUs: 0), isEmpty);
      expect(context.promptFor(generation: 2, audioStartUs: 7500000), isEmpty);
      expect(
        context.promptFor(generation: 3, audioStartUs: 7500000),
        'And so my fellow Americans.',
      );
      expect(context.promptFor(generation: 3, audioStartUs: 39000000), isEmpty);
      context.reset(4);
      expect(context.promptFor(generation: 4, audioStartUs: 40000000), isEmpty);
    },
  );

  test(
    'older or stale finals cannot replace context and empty final clears it',
    () {
      final context = LocalRecognitionContext()..reset(1);
      void put(int generation, int start, int end, String text) =>
          context.confirmed(
            generation: generation,
            startUs: start,
            endUs: end,
            text: text,
          );
      put(1, 0, 8000000, 'Confirmed name');
      put(1, 0, 7000000, 'Out of date');
      put(2, 8000000, 16000000, 'Wrong session');
      expect(
        context.promptFor(generation: 1, audioStartUs: 7500000),
        'Confirmed name',
      );
      put(1, 7500000, 16000000, '');
      expect(context.promptFor(generation: 1, audioStartUs: 15500000), isEmpty);
    },
  );

  test(
    'prompt is bounded and Unicode text is not split into surrogate halves',
    () {
      final context = LocalRecognitionContext()..reset(1);
      context.confirmed(
        generation: 1,
        startUs: 0,
        endUs: 8,
        text: List.generate(80, (i) => 'word$i').join(' '),
      );
      final english = context.promptFor(generation: 1, audioStartUs: 9);
      expect(english.split(' ').length, 32);
      expect(english, startsWith('word48'));
      context.confirmed(
        generation: 1,
        startUs: 9,
        endUs: 16,
        text: List.filled(300, '字😀').join(),
      );
      final unicode = context.promptFor(generation: 1, audioStartUs: 17);
      expect(unicode.runes.length, 256);
      expect(unicode, endsWith('字😀'));
    },
  );
}
