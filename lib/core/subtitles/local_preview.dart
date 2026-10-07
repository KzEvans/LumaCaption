import '../translation/translation_models.dart';
import 'subtitles.dart';

class LocalTranslationSnapshot {
  const LocalTranslationSnapshot(this.source);
  final SubtitleSegment source;
  String get text => source.original;
  int get revision => source.revision;
  bool get isFinal => source.isFinal;
}

class LocalPreviewUpdate {
  const LocalPreviewUpdate(this.segment, this.request, this.cancelPending);
  final SubtitleSegment segment;
  final LocalTranslationSnapshot? request;
  final bool cancelPending;
}

class _LocalPreview {
  _LocalPreview(this.source, this.visible);
  SubtitleSegment source, visible;
  LocalTranslationSnapshot? request;
  int? lastPreviewEndUs;
  int targetRevision = 0;
  bool targetFinal = false;
}

class _WordToken {
  const _WordToken(this.word, this.end, this.cjk);
  final String word;
  final int end;
  final bool cjk;
}

/// Two successive ASR hypotheses must agree before uploading a preview.
/// Preview translations stay revisable; only authoritative ASR + completed MT
/// can populate the confirmed translation used by exports and history.
class LocalPreviewPipeline {
  LocalPreviewPipeline({this.capacity = 2000});
  final int capacity;
  final Map<String, _LocalPreview> _segments = {};
  int _generation = 0;

  void reset(int generation) {
    _generation = generation;
    _segments.clear();
  }

  LocalPreviewUpdate? source(
    SubtitleSegment incoming, {
    int? audioSnapshotEndUs,
  }) {
    if (incoming.generation != _generation) return null;
    final old = _segments[incoming.segmentId];
    if (old != null &&
        (incoming.revision <= old.source.revision || old.source.isFinal)) {
      return null;
    }
    final text = _normalize(incoming.original);
    final pending = old?.request;
    final invalidated = pending != null && !_wordPrefix(pending.text, text);
    final candidate = incoming.isFinal
        ? text
        : old == null
        ? ''
        : stablePrefix(old.source.original, text);
    final visible = SubtitleSegment(
      generation: incoming.generation,
      segmentId: incoming.segmentId,
      revision: (old?.visible.revision ?? 0) + 1,
      original: incoming.original,
      stableOriginal: incoming.isFinal
          ? incoming.original
          : _displayPrefix(incoming.original, candidate),
      stash: invalidated ? '' : old?.visible.stash ?? '',
      isFinal: incoming.isFinal,
      startUs: incoming.startUs,
      endUs: incoming.endUs,
      engine: incoming.engine,
    );
    final state = old ?? _LocalPreview(incoming, visible);
    final snapshotEnd = audioSnapshotEndUs ?? incoming.endUs;
    final elapsedAudio = snapshotEnd == null || state.lastPreviewEndUs == null
        ? null
        : snapshotEnd - state.lastPreviewEndUs!;
    final changed =
        incoming.isFinal ||
        pending == null ||
        !_sameWords(pending.text, candidate);
    final ready =
        incoming.isFinal ||
        (candidate.isNotEmpty &&
            (invalidated || elapsedAudio == null || elapsedAudio >= 1500000));
    LocalTranslationSnapshot? request;
    if (candidate.isNotEmpty && changed && ready) {
      request = LocalTranslationSnapshot(
        SubtitleSegment(
          generation: incoming.generation,
          segmentId: incoming.segmentId,
          revision: incoming.revision,
          original: candidate,
          stableOriginal: candidate,
          isFinal: incoming.isFinal,
          startUs: incoming.startUs,
          endUs: incoming.endUs,
          engine: incoming.engine,
        ),
      );
      state.request = request;
      state.targetRevision = 0;
      state.targetFinal = false;
      state.lastPreviewEndUs = snapshotEnd;
    } else if (invalidated) {
      state.request = null;
    }
    state.source = incoming;
    state.visible = visible;
    _segments[incoming.segmentId] = state;
    if (_segments.length > capacity) _segments.remove(_segments.keys.first);
    return LocalPreviewUpdate(visible, request, invalidated);
  }

  SubtitleSegment? translated(TranslationEvent event) {
    if (event.generation != _generation) return null;
    final state = _segments[event.segmentId];
    final request = state?.request;
    if (state == null ||
        request == null ||
        request.revision != event.sourceRevision ||
        request.isFinal != event.sourceFinal ||
        event.revision <= state.targetRevision ||
        state.targetFinal) {
      return null;
    }
    state.targetRevision = event.revision;
    state.targetFinal =
        event.sourceFinal && event.isFinal && !event.interrupted;
    state.visible = state.visible.translated(
      event.text,
      translationFinal:
          state.source.isFinal &&
          event.sourceFinal &&
          event.isFinal &&
          !event.interrupted,
      interrupted: event.interrupted,
    );
    return state.visible;
  }

  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _displayPrefix(String original, String normalizedPrefix) {
    if (normalizedPrefix.isEmpty) return '';
    // Translation uses normalized whitespace, but the displayed prefix must
    // index the current original exactly when the UI splits off its tail.
    final count = _tokens(normalizedPrefix).length;
    final originalTokens = _tokens(original);
    return original.substring(0, originalTokens[count - 1].end);
  }

  static final _word = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);
  static final _cjk = RegExp(
    r'[\u3400-\u9fff\u{20000}-\u{323af}\u3040-\u30ff\uac00-\ud7af]',
    unicode: true,
  );
  static bool _wordPart(int rune) {
    final char = String.fromCharCode(rune);
    return _word.hasMatch(char) && !_cjk.hasMatch(char);
  }

  static List<_WordToken> _tokens(String value) {
    final runes = value.runes.toList();
    final offsets = <int>[0];
    for (final rune in runes) {
      offsets.add(offsets.last + String.fromCharCode(rune).length);
    }
    final tokens = <_WordToken>[];
    var i = 0;
    while (i < runes.length) {
      final char = String.fromCharCode(runes[i]);
      if (_cjk.hasMatch(char)) {
        tokens.add(_WordToken(char.toLowerCase(), offsets[++i], true));
      } else if (_wordPart(runes[i])) {
        final start = i++;
        while (i < runes.length) {
          if (_wordPart(runes[i])) {
            i++;
          } else if ((runes[i] == 0x27 || runes[i] == 0x2019) &&
              i + 1 < runes.length &&
              _wordPart(runes[i + 1])) {
            // Apostrophes inside a word are meaningful: don't != dont.
            // Straight and typographic apostrophes represent the same word.
            i += 2;
          } else {
            break;
          }
        }
        tokens.add(
          _WordToken(
            value
                .substring(offsets[start], offsets[i])
                .replaceAll('’', "'")
                .toLowerCase(),
            offsets[i],
            false,
          ),
        );
      } else {
        i++;
      }
    }
    return tokens;
  }

  static bool _wordPrefix(String prefix, String text) {
    final a = _tokens(prefix), b = _tokens(text);
    if (a.length > b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].word != b[i].word) return false;
    }
    return true;
  }

  static bool _sameWords(String a, String b) {
    final at = _tokens(a), bt = _tokens(b);
    if (at.length != bt.length) return false;
    for (var i = 0; i < at.length; i++) {
      if (at[i].word != bt[i].word) return false;
    }
    return true;
  }

  static String stablePrefix(String previous, String current) {
    final a = _normalize(previous), b = _normalize(current);
    final at = _tokens(a), bt = _tokens(b);
    var n = 0;
    while (n < at.length && n < bt.length && at[n].word == bt[n].word) {
      n++;
    }
    // Even matching words at the current boundary may change when more audio
    // arrives. Hold one token back; final ASR always bypasses this preview gate.
    if (n < 2) return '';
    final kept = bt.take(n - 1).toList();
    final cjkCount = kept.where((token) => token.cjk).length;
    final contentLength = kept.map((token) => token.word).join(' ').length;
    if (cjkCount > 0 ? cjkCount < 4 : kept.length < 2 || contentLength < 8) {
      return '';
    }
    // Return the current spelling and punctuation, with only the comparison
    // normalized. Punctuation-only changes do not create another MT request.
    return b.substring(0, kept.last.end).trim();
  }
}
