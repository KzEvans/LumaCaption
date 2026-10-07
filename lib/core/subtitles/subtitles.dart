class SubtitleSegment {
  const SubtitleSegment({
    required this.generation,
    required this.segmentId,
    this.revision = 0,
    this.startUs,
    this.endUs,
    this.original = '',
    this.translation = '',
    this.stash = '',
    this.isFinal = false,
    this.engine = '',
    this.error,
  });
  final int generation, revision;
  final String segmentId, original, translation, stash, engine;
  final int? startUs, endUs;
  final bool isFinal;
  final String? error;
  SubtitleSegment translated(String text) => SubtitleSegment(
    generation: generation,
    segmentId: segmentId,
    revision: revision + 1,
    startUs: startUs,
    endUs: endUs,
    original: original,
    translation: text,
    isFinal: isFinal,
    engine: engine,
  );
}

/// Remove only a matching suffix/prefix; works without whitespace (CJK).
String deduplicateOverlap(String previous, String current) {
  final a = previous.trimRight().runes.toList(),
      b = current.trimLeft().runes.toList();
  final limit = a.length < b.length ? a.length : b.length;
  for (var n = limit > 160 ? 160 : limit; n >= 2; n--) {
    var equal = true;
    for (var i = 0; i < n; i++) {
      if (a[a.length - n + i] != b[i]) {
        equal = false;
        break;
      }
    }
    if (equal) return String.fromCharCodes(b.sublist(n)).trim();
  }
  return current.trim();
}

class SubtitleStore {
  SubtitleStore({this.capacity = 2000});
  final int capacity;
  int generation = 0;
  int discarded = 0;
  final List<SubtitleSegment> segments = [];
  void reset(int value, {bool clear = false}) {
    generation = value;
    if (clear) {
      segments.clear();
      discarded = 0;
    }
  }

  bool put(SubtitleSegment event) {
    if (event.generation != generation) return false;
    final i = segments.indexWhere(
      (s) => s.generation == event.generation && s.segmentId == event.segmentId,
    );
    if (i >= 0) {
      if (segments[i].revision > event.revision ||
          (segments[i].isFinal && !event.isFinal)) {
        return false;
      }
      segments[i] = event;
    } else {
      segments.add(event);
      if (segments.length > capacity) {
        segments.removeAt(0);
        discarded++;
      }
    }
    return true;
  }
}

String exportSubtitles(
  List<SubtitleSegment> segments, {
  String format = 'txt',
  String display = 'bilingual',
}) {
  String text(SubtitleSegment s) => [
    if (display != 'translation' && s.original.isNotEmpty) s.original,
    if (display != 'original' && s.translation.isNotEmpty) s.translation,
  ].join('\n').replaceAll('\r', '').replaceAll('\u0000', '');
  final finals = segments
      .where((s) => s.isFinal && text(s).isNotEmpty)
      .toList();
  if (format == 'txt') return finals.map(text).join('\n\n');
  final timed =
      finals.where((s) => s.startUs != null && s.endUs != null).toList()
        ..sort((a, b) => a.startUs!.compareTo(b.startUs!));
  // Missing API timing is never replaced by receipt time. Only timed cues export.
  String stamp(int us) {
    final ms = us ~/ 1000;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}${format == 'srt' ? ',' : '.'}${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final cues = <String>[];
  var previousEnd = 0;
  for (final s in timed) {
    final start = s.startUs! < previousEnd ? previousEnd : s.startUs!;
    final end = s.endUs!;
    if (end <= start) continue;
    previousEnd = end;
    cues.add(
      '${format == 'srt' ? '${cues.length + 1}\n' : ''}${stamp(start)} --> ${stamp(end)}\n${text(s).replaceAll('-->', '→')}',
    );
  }
  return '${format == 'vtt' ? 'WEBVTT\n\n' : ''}${cues.join('\n\n')}\n';
}
