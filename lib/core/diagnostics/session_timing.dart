/// Timing for one explicitly requested benchmark session.
///
/// Call [received] only after an accepted, nonempty subtitle becomes visible.
/// All times use one monotonic clock. Text and caller-provided segment IDs stay
/// out of reports; numeric segment ordinals preserve their association.
class SessionTiming {
  SessionTiming({
    required this.generation,
    int Function()? elapsedMicroseconds,
  }) {
    if (elapsedMicroseconds != null) {
      _clock = elapsedMicroseconds;
    } else {
      final watch = Stopwatch()..start();
      _clock = () => watch.elapsedMicroseconds;
    }
  }

  final int generation;
  late final int Function() _clock;
  final Map<String, _SegmentTiming> _segments = {};
  final List<Map<String, Object?>> _events = [];
  int? _lastClockUs, _preparationUs, _readyUs, _audioUs, _eofUs, _stoppedUs;
  int? _firstSourceUs, _firstSourceFinalUs;
  int? _firstTranslationUs, _firstTranslationFinalUs;
  int? _lastSourceFinalUs, _lastTranslationFinalUs;
  int _frames = 0, _scheduledEndUs = 0, _latenessTotalUs = 0;
  int? _latenessMinUs, _latenessMaxUs;

  int _now() {
    final now = _clock();
    if (now < 0 || (_lastClockUs != null && now < _lastClockUs!)) {
      throw StateError(
        'Session timing requires a monotonic microsecond clock.',
      );
    }
    _lastClockUs = now;
    return now;
  }

  void _record(
    String event,
    int now, [
    Map<String, Object?> fields = const {},
  ]) {
    _events.add({
      'order': _events.length,
      'event': event,
      'elapsedMs': _ms(now - _preparationUs!),
      if (_audioUs != null) 'audioMs': _ms(now - _audioUs!),
      ...fields,
    });
  }

  void preparationStarted() {
    if (_preparationUs != null) return;
    _preparationUs = _now();
    _record('preparationStarted', _preparationUs!);
  }

  void translationReady() {
    if (_readyUs != null || _stoppedUs != null) return;
    _requirePreparation();
    _readyUs = _now();
    _record('translationReady', _readyUs!);
  }

  void audioStarted() {
    if (_audioUs != null || _stoppedUs != null) return;
    _requirePreparation();
    _audioUs = _now();
    _record('audioStarted', _audioUs!);
  }

  /// [scheduledEndUs] is the frame's sample-end offset from [audioStarted].
  /// Signed lateness exposes early delivery as well as delayed delivery.
  void audioFrame({required int scheduledEndUs}) {
    _requireAudio();
    if (_eofUs != null || _stoppedUs != null) return;
    if (scheduledEndUs <= _scheduledEndUs) {
      throw ArgumentError('Audio frame end offsets must increase.');
    }
    final now = _now();
    final lateness = now - _audioUs! - scheduledEndUs;
    _frames++;
    _scheduledEndUs = scheduledEndUs;
    _latenessTotalUs += lateness;
    _latenessMinUs = _latenessMinUs == null || lateness < _latenessMinUs!
        ? lateness
        : _latenessMinUs;
    _latenessMaxUs = _latenessMaxUs == null || lateness > _latenessMaxUs!
        ? lateness
        : _latenessMaxUs;
    _record('audioFrame', now, {
      'frame': _frames,
      'scheduledEndMs': _ms(scheduledEndUs),
      'schedulerLatenessMs': _ms(lateness),
    });
  }

  /// Source and target revisions are independent, including when they share ID.
  /// Repeated finals can revise the trace without counting a second final or
  /// changing the time at which that segment first became final.
  bool received({
    required String segmentId,
    required String channel,
    required int revision,
    required bool isFinal,
    int? audioEndUs,
    int? generation,
  }) {
    if ((generation != null && generation != this.generation) ||
        _stoppedUs != null) {
      return false;
    }
    _requireAudio();
    if (channel != 'source' && channel != 'translation') {
      throw ArgumentError('Subtitle channel must be source or translation.');
    }
    if (segmentId.isEmpty || revision < 0 || (audioEndUs ?? 0) < 0) {
      throw ArgumentError('Subtitle ID, revision, or audio end is invalid.');
    }
    final segment = _segments.putIfAbsent(
      segmentId,
      () => _SegmentTiming(_segments.length + 1),
    );
    final result = channel == 'source' ? segment.source : segment.translation;
    if (revision <= result.revision || (result.isFinal && !isFinal)) {
      return false;
    }
    final now = _now();
    result.revision = revision;
    result.firstVisibleUs ??= now;
    final firstFinal = isFinal && !result.isFinal;
    if (firstFinal) {
      result.firstFinalUs = now;
      result.finalAudioEndUs = audioEndUs;
      result.isFinal = true;
    }
    if (channel == 'source') {
      _firstSourceUs ??= now;
      if (firstFinal) {
        _firstSourceFinalUs ??= now;
        _lastSourceFinalUs = now;
      }
    } else {
      _firstTranslationUs ??= now;
      if (firstFinal) {
        _firstTranslationFinalUs ??= now;
        _lastTranslationFinalUs = now;
      }
    }
    _record('subtitleReceived', now, {
      'segment': segment.ordinal,
      'channel': channel,
      'revision': revision,
      'isFinal': isFinal,
      'firstFinal': firstFinal,
      'audioEndMs': _ms(audioEndUs),
    });
    return true;
  }

  void audioFinished() {
    if (_eofUs != null || _stoppedUs != null) return;
    _requireAudio();
    _eofUs = _now();
    _record('audioFinished', _eofUs!);
  }

  void stopped() {
    if (_stoppedUs != null) return;
    _requirePreparation();
    _stoppedUs = _now();
    _record('stopped', _stoppedUs!);
  }

  /// Null means the corresponding phase or reliable audio timestamp was absent.
  /// Final-after-EOF values are signed: a negative value finished before EOF.
  Map<String, Object?> report() => {
    'generation': generation,
    'setupMs': _difference(_readyUs, _preparationUs),
    'preparationMs': _difference(_audioUs, _preparationUs),
    'firstSourceMs': _difference(_firstSourceUs, _audioUs),
    'firstSourceFinalMs': _difference(_firstSourceFinalUs, _audioUs),
    'firstTranslationMs': _difference(_firstTranslationUs, _audioUs),
    'firstTranslationFinalMs': _difference(_firstTranslationFinalUs, _audioUs),
    'audioDurationMs': _audioUs == null ? null : _ms(_scheduledEndUs),
    'audioElapsedMs': _difference(_eofUs, _audioUs),
    'drainMs': _difference(_stoppedUs, _eofUs),
    'lastSourceFinalAfterEofMs': _difference(_lastSourceFinalUs, _eofUs),
    'lastTranslationFinalAfterEofMs': _difference(
      _lastTranslationFinalUs,
      _eofUs,
    ),
    'sourceFinalSegments': _segments.values
        .where((s) => s.source.isFinal)
        .length,
    'translationFinalSegments': _segments.values
        .where((s) => s.translation.isFinal)
        .length,
    'audioFrames': _frames,
    'schedulerLatenessMs': {
      'min': _ms(_latenessMinUs),
      'max': _ms(_latenessMaxUs),
      'mean': _frames == 0 ? null : _latenessTotalUs / _frames / 1000,
    },
    'segments': [
      for (final s in _segments.values)
        {
          'segment': s.ordinal,
          'source': _channelReport(s.source),
          'translation': _channelReport(s.translation),
        },
    ],
    'events': [for (final event in _events) Map<String, Object?>.of(event)],
  };

  Map<String, Object?> _channelReport(_ChannelTiming channel) => {
    'latestRevision': channel.revision < 0 ? null : channel.revision,
    'firstVisibleMs': _difference(channel.firstVisibleUs, _audioUs),
    'firstFinalMs': _difference(channel.firstFinalUs, _audioUs),
    'audioEndMs': _ms(channel.finalAudioEndUs),
    'endLagMs': channel.finalAudioEndUs == null || _audioUs == null
        ? null
        : _difference(
            channel.firstFinalUs,
            _audioUs! + channel.finalAudioEndUs!,
          ),
  };

  void _requirePreparation() {
    if (_preparationUs == null) {
      throw StateError('Start session preparation before recording timing.');
    }
  }

  void _requireAudio() {
    if (_audioUs == null) {
      throw StateError('Start session audio before recording subtitle timing.');
    }
  }

  static double? _ms(int? us) => us == null ? null : us / 1000;
  static double? _difference(int? end, int? start) =>
      end == null || start == null ? null : _ms(end - start);
}

class _SegmentTiming {
  _SegmentTiming(this.ordinal);
  final int ordinal;
  final source = _ChannelTiming();
  final translation = _ChannelTiming();
}

class _ChannelTiming {
  int revision = -1;
  bool isFinal = false;
  int? firstVisibleUs, firstFinalUs, finalAudioEndUs;
}
