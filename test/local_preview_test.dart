import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/subtitles/local_preview.dart';
import 'package:lumacaption/core/subtitles/subtitles.dart';
import 'package:lumacaption/core/translation/translation_models.dart';

void main() {
  SubtitleSegment source(
    int revision,
    String text, {
    bool finalSource = false,
    int? endUs,
  }) => SubtitleSegment(
    generation: 1,
    segmentId: 'local:1',
    revision: revision,
    original: text,
    isFinal: finalSource,
    startUs: 0,
    endUs: endUs ?? revision * 1000000,
  );
  TranslationEvent target(
    int sourceRevision,
    String text, {
    bool sourceFinal = false,
    bool finalTarget = false,
    int eventRevision = 1,
  }) => TranslationEvent(
    generation: 1,
    segmentId: 'local:1',
    revision: eventRevision,
    sourceRevision: sourceRevision,
    sourceFinal: sourceFinal,
    text: text,
    isFinal: finalTarget,
  );

  test(
    'two ASR hypotheses agree before upload; growing context is throttled',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      expect(
        p.source(source(1, 'And so my fellow', endUs: 2000000))!.request,
        isNull,
      );
      final agreed = p.source(
        source(2, 'And so my fellow Americans', endUs: 3000000),
      )!;
      expect(agreed.request!.text, 'And so my fellow');
      expect(agreed.request!.isFinal, false);
      expect(
        p
            .source(
              source(3, 'And so my fellow Americans ask', endUs: 4000000),
            )!
            .request,
        isNull,
      );
      expect(
        p
            .source(
              source(4, 'And so my fellow Americans ask not', endUs: 5000000),
            )!
            .request!
            .text,
        'And so my fellow Americans ask',
      );
    },
  );

  test('preview completion never confirms translation or enters export', () {
    final p = LocalPreviewPipeline()..reset(1);
    p.source(source(1, 'And so my fellow'));
    p.source(source(2, 'And so my fellow Americans'));
    final translated = p.translated(target(2, '我的同胞们'))!;
    expect(translated.isFinal, false);
    expect(translated.translation, isEmpty);
    expect(translated.stash, '我的同胞们');
    expect(exportSubtitles([translated]), isEmpty);
  });

  test('rewrite clears stale target and rejects delayed old request', () {
    final p = LocalPreviewPipeline()..reset(1);
    p.source(source(1, 'You should ask your country'));
    p.source(source(2, 'You should ask your country now'));
    p.translated(target(2, '你应该问你的国家'));
    final rewrite = p.source(source(3, 'You should not ask your country'))!;
    expect(rewrite.cancelPending, true);
    expect(rewrite.segment.stash, isEmpty);
    expect(p.translated(target(2, '你应该问你的国家。')), isNull);
  });

  test(
    'new source final supersedes many translation deltas and corrects export',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      final store = SubtitleStore()..reset(1);
      store.put(p.source(source(1, 'Ask what your country'))!.segment);
      final preview = p.source(source(2, 'Ask what your country can do'))!;
      store.put(preview.segment);
      for (var i = 0; i < 20; i++) {
        expect(
          store.put(p.translated(target(2, '草稿$i', eventRevision: i + 1))!),
          true,
        );
      }
      final confirmed = p.source(
        source(
          3,
          'Ask not what your country can do for you.',
          finalSource: true,
        ),
      )!;
      expect(store.put(confirmed.segment), true);
      expect(
        confirmed.request!.text,
        'Ask not what your country can do for you.',
      );
      expect(p.translated(target(2, '迟到草稿')), isNull);
      final done = p.translated(
        target(3, '不要问你的国家能为你做什么。', sourceFinal: true, finalTarget: true),
      )!;
      expect(store.put(done), true);
      expect(done.stash, isEmpty);
      expect(exportSubtitles(store.segments), contains('不要问'));
      expect(exportSubtitles(store.segments), isNot(contains('草稿')));
    },
  );

  test(
    'snapshot growth drives throttle even when ASR word end stays fixed',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      p.source(
        source(1, 'And so my fellow', endUs: 1000000),
        audioSnapshotEndUs: 2000000,
      );
      expect(
        p
            .source(
              source(2, 'And so my fellow Americans', endUs: 1000000),
              audioSnapshotEndUs: 3000000,
            )!
            .request,
        isNotNull,
      );
      expect(
        p
            .source(
              source(3, 'And so my fellow Americans ask', endUs: 1000000),
              audioSnapshotEndUs: 4000000,
            )!
            .request,
        isNull,
      );
      expect(
        p
            .source(
              source(4, 'And so my fellow Americans ask not', endUs: 1000000),
              audioSnapshotEndUs: 5000000,
            )!
            .request,
        isNotNull,
      );
    },
  );

  test(
    'empty authoritative final retracts preview and delayed translation',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      p.source(source(1, 'False recognized words'));
      p.source(source(2, 'False recognized words again'));
      p.translated(target(2, '过时草稿'));
      final retracted = p.source(source(3, '', finalSource: true))!;
      expect(retracted.cancelPending, true);
      expect(retracted.request, isNull);
      expect(retracted.segment.original, isEmpty);
      expect(retracted.segment.stash, isEmpty);
      expect(p.translated(target(2, '迟到草稿', eventRevision: 2)), isNull);
      expect(exportSubtitles([retracted.segment]), isEmpty);
    },
  );

  test('a confirmed target cannot be replaced by a delayed partial', () {
    final p = LocalPreviewPipeline()..reset(1);
    p.source(source(1, 'Final source text.', finalSource: true));
    final confirmed = p.translated(
      target(1, '最终译文', sourceFinal: true, finalTarget: true),
    )!;
    expect(
      p.translated(target(1, '迟到预览', sourceFinal: true, eventRevision: 2)),
      isNull,
    );
    expect(confirmed.translation, '最终译文');
  });

  test('identical preview is still promoted only after source final', () {
    final p = LocalPreviewPipeline()..reset(1);
    p.source(source(1, 'All right, all right.'));
    p.source(source(2, 'All right, all right.'));
    p.translated(target(2, '好的，好的。'));
    final doneSource = p.source(
      source(3, 'All right, all right.', finalSource: true),
    )!;
    expect(doneSource.request!.isFinal, true);
    expect(doneSource.segment.translation, isEmpty);
    expect(doneSource.segment.stash, '好的，好的。');
    final partial = p.translated(target(3, '好的，好的。', sourceFinal: true))!;
    expect(exportSubtitles([partial], display: 'translation'), isEmpty);
    final done = p.translated(
      target(
        3,
        '好的，好的。',
        sourceFinal: true,
        finalTarget: true,
        eventRevision: 2,
      ),
    )!;
    expect(exportSubtitles([done], display: 'translation'), '好的，好的。');
  });

  test(
    'Unicode stable prefix, partial Latin words and generation isolation',
    () {
      expect(
        LocalPreviewPipeline.stablePrefix('今天我们讨论天气', '今天我们讨论问题'),
        '今天我们讨论',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'They always ask',
          'They always asked yesterday',
        ),
        'They always',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'They always asked yesterday',
          'They always ask',
        ),
        'They always',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'They discussed naï',
          'They discussed naïve',
        ),
        'They discussed',
      );
      expect(
        LocalPreviewPipeline.stablePrefix('And so my', 'and so my fellow'),
        'and so my',
      );
      expect(LocalPreviewPipeline.stablePrefix('ask', 'asked'), isEmpty);
      final p = LocalPreviewPipeline()..reset(2);
      expect(p.source(source(1, 'Old generation source')), isNull);
      expect(p.translated(target(1, '过时译文')), isNull);
    },
  );
}
