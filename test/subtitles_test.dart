import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/subtitles/subtitles.dart';

void main() {
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
