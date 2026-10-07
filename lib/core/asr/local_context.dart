/// Short confirmed source context for the following audio window.
/// Partial hypotheses never become prompts for another pass of the same audio.
class LocalRecognitionContext {
  int _generation = 0;
  int? _startUs, _endUs;
  String _confirmed = '';

  void reset(int generation) {
    _generation = generation;
    _startUs = null;
    _endUs = null;
    _confirmed = '';
  }

  void confirmed({
    required int generation,
    required int startUs,
    required int endUs,
    required String text,
  }) {
    if (generation != _generation ||
        endUs <= startUs ||
        (_endUs != null && endUs <= _endUs!)) {
      return;
    }
    _startUs = startUs;
    _endUs = endUs;
    final words = text.trim().split(RegExp(r'\s+'));
    final tail = words
        .skip(words.length > 32 ? words.length - 32 : 0)
        .join(' ');
    final runes = tail.runes.toList();
    _confirmed = String.fromCharCodes(
      runes.skip(runes.length > 256 ? runes.length - 256 : 0),
    );
  }

  String promptFor({required int generation, required int audioStartUs}) {
    if (generation != _generation ||
        _startUs == null ||
        audioStartUs <= _startUs! ||
        audioStartUs - _endUs! > 30000000) {
      return '';
    }
    return _confirmed;
  }
}
