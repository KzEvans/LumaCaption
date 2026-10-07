import '../audio/audio.dart';

/// Pending local decode work: chronological finals and one latest preview.
/// The currently running inference is owned by the controller, not this queue.
class InferenceQueue {
  InferenceQueue({this.maxPendingFinals = 2}) : assert(maxPendingFinals > 0);

  final int maxPendingFinals;
  final List<AudioChunk> _finals = [];
  AudioChunk? _preview;
  int? _latestFinalSegmentId;
  int _droppedFinalCount = 0;

  bool get isEmpty => _finals.isEmpty && _preview == null;
  bool get isNotEmpty => !isEmpty;
  int get length => _finals.length + (_preview == null ? 0 : 1);
  int get droppedFinalCount => _droppedFinalCount;

  /// Returns whether this snapshot remains queued. Replacing or discarding a
  /// preview loses no final audio and never increments [droppedFinalCount].
  bool add(AudioChunk chunk) {
    if (!chunk.isFinal) {
      final latestFinal = _latestFinalSegmentId;
      if (latestFinal != null && chunk.segmentId <= latestFinal) return false;
      final previous = _preview;
      if (previous != null &&
          (chunk.segmentId < previous.segmentId ||
              (chunk.segmentId == previous.segmentId &&
                  chunk.revision <= previous.revision))) {
        return false;
      }
      _preview = chunk;
      return true;
    }

    final previousFinal = _finals.indexWhere(
      (pending) => pending.segmentId == chunk.segmentId,
    );
    if (previousFinal >= 0) {
      if (chunk.revision <= _finals[previousFinal].revision) return false;
      _finals[previousFinal] = chunk;
    } else {
      _finals.add(chunk);
    }
    final latestFinal = _latestFinalSegmentId;
    if (latestFinal == null || chunk.segmentId > latestFinal) {
      _latestFinalSegmentId = chunk.segmentId;
    }
    final preview = _preview;
    if (preview != null && preview.segmentId <= chunk.segmentId) {
      _preview = null;
    }
    _finals.sort((first, second) {
      final byStart = first.startUs.compareTo(second.startUs);
      return byStart != 0
          ? byStart
          : first.segmentId.compareTo(second.segmentId);
    });
    if (_finals.length > maxPendingFinals) {
      final dropped = _finals.removeAt(0);
      _droppedFinalCount++;
      return !identical(dropped, chunk);
    }
    return true;
  }

  AudioChunk? take() {
    if (_finals.isNotEmpty) return _finals.removeAt(0);
    final preview = _preview;
    _preview = null;
    return preview;
  }

  void clear() {
    _finals.clear();
    _preview = null;
    _latestFinalSegmentId = null;
    _droppedFinalCount = 0;
  }
}
