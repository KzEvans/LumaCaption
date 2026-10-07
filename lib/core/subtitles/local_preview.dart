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
    final invalidated =
        pending != null &&
        !text.toLowerCase().startsWith(pending.text.toLowerCase());
    final visible = SubtitleSegment(
      generation: incoming.generation,
      segmentId: incoming.segmentId,
      revision: (old?.visible.revision ?? 0) + 1,
      original: incoming.original,
      stash: invalidated ? '' : old?.visible.stash ?? '',
      isFinal: incoming.isFinal,
      startUs: incoming.startUs,
      endUs: incoming.endUs,
      engine: incoming.engine,
    );
    final state = old ?? _LocalPreview(incoming, visible);
    final candidate = incoming.isFinal
        ? text
        : old == null
        ? ''
        : stablePrefix(old.source.original, text);
    final snapshotEnd = audioSnapshotEndUs ?? incoming.endUs;
    final elapsedAudio = snapshotEnd == null || state.lastPreviewEndUs == null
        ? null
        : snapshotEnd - state.lastPreviewEndUs!;
    final changed = pending?.text != candidate || incoming.isFinal;
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
  static final _word = RegExp(r"[\p{L}\p{M}\p{N}'’]", unicode: true);
  static final _cjk = RegExp(r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]');
  static bool _wordPart(int rune) {
    final char = String.fromCharCode(rune);
    return _word.hasMatch(char) && !_cjk.hasMatch(char);
  }

  static String stablePrefix(String previous, String current) {
    final a = _normalize(previous), b = _normalize(current);
    final ar = a.runes.toList(), br = b.runes.toList();
    var n = 0;
    while (n < ar.length &&
        n < br.length &&
        String.fromCharCode(ar[n]).toLowerCase() ==
            String.fromCharCode(br[n]).toLowerCase()) {
      n++;
    }
    var prefix = String.fromCharCodes(br.take(n)).trimRight();
    // Do not upload a partial Latin word (ask vs asked). CJK text has no
    // whitespace boundaries; the agreed characters remain provisional too.
    if (n > 0 &&
        _wordPart(br[n - 1]) &&
        ((n < ar.length && _wordPart(ar[n])) ||
            (n < br.length && _wordPart(br[n])))) {
      final boundary = prefix.lastIndexOf(' ');
      prefix = boundary < 0 ? '' : prefix.substring(0, boundary);
    }
    final cjk = _cjk.hasMatch(prefix);
    if (cjk) return prefix.runes.length >= 4 ? prefix.trim() : '';
    return prefix.length >= 8 && prefix.split(' ').length >= 2
        ? prefix.trim()
        : '';
  }
}
