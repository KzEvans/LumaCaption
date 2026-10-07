import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/subtitles/subtitles.dart';

void main() {
  test('stable original defaults empty and survives translation updates', () {
    const defaultSource = SubtitleSegment(generation: 1, segmentId: 'default');
    expect(defaultSource.stableOriginal, isEmpty);
    const source = SubtitleSegment(
      generation: 1,
      segmentId: 'local:preview',
      original: 'Your country needs your help',
      stableOriginal: 'Your country needs',
    );
    final partial = source.translated('你的国家需要', translationFinal: false);
    final interrupted = partial.translated(
      '你的国家需要',
      translationFinal: false,
      interrupted: true,
    );
    final completed = interrupted.translated('你的国家需要你的帮助。');
    for (final updated in [partial, interrupted, completed]) {
      expect(updated.stableOriginal, 'Your country needs');
      expect(updated.original, source.original);
      expect(updated.isFinal, false);
      expect(exportSubtitles([updated]), isEmpty);
    }
  });

  test(
    'streaming translation stays provisional while original is confirmed',
    () {
      const source = SubtitleSegment(
        generation: 1,
        segmentId: 'local:1',
        original: 'A confirmed sentence.',
        stableOriginal: 'A confirmed sentence.',
        isFinal: true,
      );
      final store = SubtitleStore()..reset(1);
      store.put(source);
      final partial = source.translated('暂定译文', translationFinal: false);
      expect(store.put(partial), isTrue);
      expect(partial.isFinal, isTrue);
      expect(partial.stableOriginal, source.original);
      expect(partial.stash, '暂定译文');
      expect(exportSubtitles(store.segments), 'A confirmed sentence.');
      final interrupted = partial.translated(
        '暂定译文',
        translationFinal: false,
        interrupted: true,
      );
      expect(interrupted.error, '译文未完成');
      expect(interrupted.translation, isEmpty);
      final finalText = partial.translated('已确认的译文。');
      expect(store.put(finalText), isTrue);
      expect(finalText.stash, isEmpty);
      expect(finalText.stableOriginal, source.original);
      expect(exportSubtitles(store.segments), contains('已确认的译文。'));
    },
  );
  test('generation and stale revisions cannot rewrite finals', () {
    final s = SubtitleStore()..reset(2);
    expect(s.put(const SubtitleSegment(generation: 1, segmentId: 'x')), false);
    s.put(
      const SubtitleSegment(
        generation: 2,
        segmentId: 'x',
        revision: 2,
        isFinal: true,
        translation: '完成',
      ),
    );
    expect(
      s.put(
        const SubtitleSegment(
          generation: 2,
          segmentId: 'x',
          revision: 1,
          translation: '旧',
        ),
      ),
      false,
    );
    expect(
      s.put(const SubtitleSegment(generation: 2, segmentId: 'x', revision: 3)),
      false,
    );
    expect(s.segments.single.translation, '完成');
  });
  test('CJK overlap and English overlap', () {
    expect(deduplicateOverlap('今天我们讨论机器学习', '机器学习的应用'), '的应用');
    expect(deduplicateOverlap('hello world', 'world is here'), 'is here');
    expect(deduplicateOverlap('abc', 'def'), 'def');
  });
  test('export finals only, skips unknown timestamps, repairs overlaps', () {
    const input = [
      SubtitleSegment(
        generation: 1,
        segmentId: '1',
        startUs: 0,
        endUs: 2000000,
        original: '你好\n世界',
        translation: 'Hello',
        isFinal: true,
      ),
      SubtitleSegment(
        generation: 1,
        segmentId: '2',
        startUs: 1500000,
        endUs: 3000000,
        original: '继续',
        isFinal: true,
      ),
      SubtitleSegment(
        generation: 1,
        segmentId: '3',
        translation: 'untimed',
        isFinal: true,
      ),
      SubtitleSegment(generation: 1, segmentId: '4', translation: 'partial'),
    ];
    final out = exportSubtitles(input, format: 'srt');
    expect(out, contains('00:00:02,000 --> 00:00:03,000'));
    expect(out, contains('你好\n世界\nHello'));
    expect(out, isNot(contains('untimed')));
    expect(out, isNot(contains('partial')));
    expect(exportSubtitles(input, format: 'vtt'), startsWith('WEBVTT'));
    expect(exportSubtitles(input), contains('untimed'));
  });
}
