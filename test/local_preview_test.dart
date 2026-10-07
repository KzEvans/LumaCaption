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
      expect(agreed.request!.text, 'And so my');
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
        'And so my fellow Americans',
      );
    },
  );

  test(
    'stable source updates independently of throttled translation requests',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      final first = p.source(source(1, 'And so my fellow', endUs: 1000000))!;
      expect(first.segment.stableOriginal, isEmpty);
      final second = p.source(
        source(2, 'And so my fellow Americans', endUs: 1500000),
      )!;
      expect(second.segment.stableOriginal, 'And so my');
      expect(second.segment.isFinal, false);
      expect(second.request!.source.stableOriginal, second.request!.text);
      expect(exportSubtitles([second.segment]), isEmpty);

      final growing = p.source(
        source(3, 'And so my fellow Americans ask', endUs: 2000000),
      )!;
      expect(growing.request, isNull);
      expect(growing.segment.stableOriginal, 'And so my fellow');
      final translated = p.translated(target(2, '我的同胞们'))!;
      expect(translated.stableOriginal, 'And so my fellow');
      expect(translated.isFinal, false);
      expect(exportSubtitles([translated]), isEmpty);
    },
  );

  test(
    'a real rewrite can retract the agreed source without claiming finality',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      p.source(source(1, 'You should ask your country now'));
      final stable = p.source(source(2, 'You should ask your country now'))!;
      expect(stable.segment.stableOriginal, 'You should ask your country');
      p.translated(target(2, '你应该问你的国家'));

      final rewrite = p.source(
        source(3, 'You should not ask your country now'),
      )!;
      expect(rewrite.segment.stableOriginal, isEmpty);
      expect(rewrite.segment.stash, isEmpty);
      expect(rewrite.segment.isFinal, false);
      expect(rewrite.cancelPending, true);
      final settled = p.source(
        source(4, 'You should not ask your country now'),
      )!;
      expect(settled.segment.stableOriginal, 'You should not ask your country');
      expect(settled.segment.isFinal, false);
      expect(exportSubtitles([settled.segment]), isEmpty);

      final done = p.source(
        source(5, 'You should not ask your country now.', finalSource: true),
      )!;
      expect(done.segment.stableOriginal, done.segment.original);
      expect(done.segment.isFinal, true);
      expect(exportSubtitles([done.segment]), done.segment.original);
    },
  );

  test(
    'stable display prefix retains current original whitespace and punctuation',
    () {
      final p = LocalPreviewPipeline()..reset(1);
      p.source(source(1, 'Well I know your country needs you'));
      const original = '  WELL,\tI know—your  country needs you!';
      final update = p.source(source(2, original))!;
      expect(
        update.segment.stableOriginal,
        '  WELL,\tI know—your  country needs',
      );
      expect(original.startsWith(update.segment.stableOriginal), true);
      expect(original.substring(update.segment.stableOriginal.length), ' you!');
      expect(update.request!.text, 'WELL, I know—your country needs');
      expect(update.segment.isFinal, false);
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
      expect(retracted.segment.stableOriginal, isEmpty);
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
    p.source(source(1, 'All right, all right again.'));
    p.source(source(2, 'All right, all right again.'));
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
        '今天我们讨',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'They will always ask',
          'They will always asked yesterday',
        ),
        'They will',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'They will always asked yesterday',
          'They will always ask',
        ),
        'They will',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'They often discussed naï',
          'They often discussed naïve',
        ),
        'They often',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'And so my fellow',
          'and so my fellow',
        ),
        'and so my',
      );
      expect(LocalPreviewPipeline.stablePrefix('ask', 'asked'), isEmpty);
      final p = LocalPreviewPipeline()..reset(2);
      expect(p.source(source(1, 'Old generation source')), isNull);
      expect(p.translated(target(1, '过时译文')), isNull);
    },
  );

  test(
    'word alignment ignores punctuation and case but keeps current form',
    () {
      expect(
        LocalPreviewPipeline.stablePrefix(
          'Well I know your country needs you',
          'WELL, I know—your country needs you!',
        ),
        'WELL, I know—your country needs',
      );
      expect(
        LocalPreviewPipeline.stablePrefix(
          'Nous discutons naïvement demain',
          'NOUS, discutons naïvement demain.',
        ),
        'NOUS, discutons naïvement',
      );
    },
  );

  test('punctuation-only updates neither cancel nor retranslate a preview', () {
    final p = LocalPreviewPipeline()..reset(1);
    p.source(source(1, 'Well I know your country needs you'));
    final preview = p.source(source(2, 'Well, I know your country needs you'))!;
    expect(preview.request!.text, 'Well, I know your country needs');
    p.translated(target(2, '我知道你的国家需要你'));
    final restyled = p.source(
      source(4, 'WELL I know—your country needs you.'),
    )!;
    expect(restyled.request, isNull);
    expect(restyled.cancelPending, false);
    expect(restyled.segment.original, 'WELL I know—your country needs you.');
    expect(restyled.segment.stash, '我知道你的国家需要你');
    expect(
      p.translated(target(2, '我知道你的国家需要你。', eventRevision: 2))!.stash,
      '我知道你的国家需要你。',
    );
    final finalSource = p.source(
      source(5, 'Well, I know your country needs you!', finalSource: true),
    )!;
    expect(finalSource.request!.text, 'Well, I know your country needs you!');
    expect(finalSource.request!.isFinal, true);
    expect(p.translated(target(2, '迟到草稿', eventRevision: 3)), isNull);
  });

  test('an internal apostrophe is preserved but its glyph can change', () {
    final p = LocalPreviewPipeline()..reset(1);
    p.source(source(1, "We don't want your country to wait"));
    final preview = p.source(source(2, 'We don’t want your country to wait'))!;
    expect(preview.request!.text, 'We don’t want your country to');
    p.translated(target(2, '我们不想让你的国家等候'));
    final punctuation = p.source(
      source(4, "WE don't want your country to wait!"),
    )!;
    expect(punctuation.cancelPending, false);
    expect(punctuation.request, isNull);
    final missingApostrophe = p.source(
      source(5, 'We dont want your country to wait'),
    )!;
    expect(missingApostrophe.cancelPending, true);
    expect(missingApostrophe.segment.stash, isEmpty);
    expect(p.translated(target(2, '迟到草稿', eventRevision: 2)), isNull);
  });

  test(
    'negation and complete word changes retract an incompatible preview',
    () {
      for (final replacement in [
        'You should not ask your country to wait',
        'You should asked your country to wait',
      ]) {
        final p = LocalPreviewPipeline()..reset(1);
        p.source(source(1, 'You should ask your country to wait'));
        p.source(source(2, 'You should ask your country to wait'));
        p.translated(target(2, '你应该让你的国家等候'));
        final rewrite = p.source(source(3, replacement))!;
        expect(rewrite.cancelPending, true);
        expect(rewrite.segment.stash, isEmpty);
        expect(p.translated(target(2, '迟到草稿', eventRevision: 2)), isNull);
      }
    },
  );

  test(
    'one boundary token stays revisable without loosening content minimum',
    () {
      expect(
        LocalPreviewPipeline.stablePrefix(
          'Your country needs you',
          'Your country needs you',
        ),
        'Your country needs',
      );
      expect(
        LocalPreviewPipeline.stablePrefix('Hello world', 'Hello world'),
        isEmpty,
      );
      expect(
        LocalPreviewPipeline.stablePrefix('I am ready', 'I am ready'),
        isEmpty,
      );
      final p = LocalPreviewPipeline()..reset(1);
      p.source(source(1, 'Hello world'));
      expect(p.source(source(2, 'Hello world'))!.request, isNull);
      expect(
        p.source(source(3, 'Hello world!', finalSource: true))!.request!.text,
        'Hello world!',
      );
    },
  );

  test(
    'CJK punctuation is ignored and the minimum is based on CJK characters',
    () {
      expect(
        LocalPreviewPipeline.stablePrefix('今天我们讨论天气', '今天，我们讨论天气。'),
        '今天，我们讨论天',
      );
      expect(LocalPreviewPipeline.stablePrefix('我们讨论问题', '我们讨论答案'), isEmpty);
      expect(LocalPreviewPipeline.stablePrefix('你好！！！世界', '你好世界'), isEmpty);
      expect(
        LocalPreviewPipeline.stablePrefix('𠀀𠀁𠀂𠀃𠀄𠀅', '𠀀，𠀁𠀂𠀃𠀄𠀅'),
        '𠀀，𠀁𠀂𠀃𠀄',
      );
      final p = LocalPreviewPipeline()..reset(1);
      p.source(source(1, '今天我们讨论天气'));
      p.source(source(2, '今天，我们讨论天气。'));
      p.translated(target(2, 'Today we discuss the weather'));
      final punctuation = p.source(source(4, '今天我们讨论天气'))!;
      expect(punctuation.cancelPending, false);
      expect(punctuation.request, isNull);
      expect(punctuation.segment.stash, isNotEmpty);
    },
  );
}
