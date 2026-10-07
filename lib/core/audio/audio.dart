import 'dart:math' as math;
import 'dart:typed_data';

class AudioFrame {
  const AudioFrame({
    required this.samples,
    required this.sampleRate,
    required this.channels,
    required this.timestampUs,
    required this.sequence,
    required this.generation,
  });
  final Float32List samples;
  final int sampleRate, channels, timestampUs, sequence, generation;
  factory AudioFrame.fromMap(Map<dynamic, dynamic> m, int generation) {
    final bytes = m['pcm'] as Uint8List;
    final data = ByteData.sublistView(bytes);
    final samples = Float32List(bytes.length ~/ 4);
    for (var i = 0; i < samples.length; i++) {
      final v = data.getFloat32(i * 4, Endian.little);
      samples[i] = v.isFinite ? v.clamp(-1, 1) : 0;
    }
    return AudioFrame(
      samples: samples,
      sampleRate: (m['sampleRate'] as num).toInt(),
      channels: (m['channels'] as num).toInt(),
      timestampUs: (m['timestampUs'] as num).toInt(),
      sequence: (m['sequence'] as num).toInt(),
      generation: generation,
    );
  }
}

/// Stateful windowed-sinc low-pass resampler. Native macOS also resamples with
/// AVAudioConverter; this handles Windows device rates without aliasing.
class PcmConverter {
  PcmConverter({this.outputRate = 16000});
  final int outputRate;
  int? _rate;
  final List<double> _input = [];
  double _position = 16;
  static const radius = 16;
  void reset() {
    _rate = null;
    _input.clear();
    _position = radius.toDouble();
  }

  Float32List convert(AudioFrame frame) {
    if (frame.sampleRate < 8000 ||
        frame.channels < 1 ||
        frame.samples.length % frame.channels != 0) {
      throw const FormatException('Invalid PCM layout');
    }
    if (_rate != frame.sampleRate) {
      reset();
      _rate = frame.sampleRate;
      _input.addAll(List.filled(radius, 0));
    }
    final mono = List<double>.generate(frame.samples.length ~/ frame.channels, (
      i,
    ) {
      var v = 0.0;
      for (var c = 0; c < frame.channels; c++) {
        v += frame.samples[i * frame.channels + c];
      }
      return v / frame.channels;
    });
    if (frame.sampleRate == outputRate) {
      return Float32List.fromList(mono);
    }
    _input.addAll(mono);
    final output = <double>[];
    final step = frame.sampleRate / outputRate;
    final cutoff = math.min(1.0, outputRate / frame.sampleRate) * 0.94;
    while (_position + radius < _input.length) {
      final center = _position.floor();
      var sum = 0.0;
      var weights = 0.0;
      for (var j = center - radius + 1; j <= center + radius; j++) {
        final d = j - _position;
        final x = math.pi * d * cutoff;
        final sinc = x.abs() < 1e-8 ? 1.0 : math.sin(x) / x;
        final window = 0.5 + 0.5 * math.cos(math.pi * d / radius);
        final weight = cutoff * sinc * window;
        sum += _input[j] * weight;
        weights += weight;
      }
      output.add((sum / weights).clamp(-1, 1));
      _position += step;
    }
    final drop = math.max(0, _position.floor() - radius);
    if (drop > 0) {
      _input.removeRange(0, drop);
      _position -= drop;
    }
    return Float32List.fromList(output);
  }

  static Uint8List pcm16(Float32List input) {
    final out = ByteData(input.length * 2);
    for (var i = 0; i < input.length; i++) {
      out.setInt16(
        i * 2,
        (input[i].clamp(-1, 1) * 32767).round(),
        Endian.little,
      );
    }
    return out.buffer.asUint8List();
  }

  static double rms(Float32List input) {
    if (input.isEmpty) return 0;
    var sum = 0.0;
    for (final v in input) {
      sum += v * v;
    }
    return math.sqrt(sum / input.length);
  }
}

class AudioChunk {
  const AudioChunk(
    this.samples,
    this.startUs,
    this.endUs, {
    this.segmentId = 0,
    this.revision = 1,
    this.isFinal = true,
    this.endpointReason,
    this.speechEndUs,
  });
  final Float32List samples;
  final int startUs, endUs, segmentId, revision;
  final bool isFinal;
  final String? endpointReason;
  final int? speechEndUs;
}

/// Revisable previews, 8s utterance windows, 400ms pre-roll and 500ms overlap.
/// [add] retains the energy baseline; [addClassified] consumes neural VAD windows.
class AudioSegmenter {
  AudioSegmenter({
    Duration previewInterval = const Duration(seconds: 2),
    this.firstPreview = const Duration(seconds: 2),
    this.enableAdaptive = false,
  }) : assert(previewInterval > Duration.zero),
       assert(firstPreview > Duration.zero),
       _previewInterval = enableAdaptive
           ? Duration(
               microseconds: previewInterval.inMicroseconds.clamp(
                 500000,
                 3000000,
               ),
             )
           : previewInterval;
  final Duration firstPreview;
  final bool enableAdaptive;
  Duration _previewInterval;
  double? _inferenceUs;
  Duration get previewInterval => _previewInterval;

  /// Retain a margin above measured decode time to avoid accumulating preview
  /// work. Finals carry more audio, so they adjust the preview estimate gently.
  void observeInference(Duration elapsed, {bool isFinal = false}) {
    if (!enableAdaptive || elapsed <= Duration.zero) return;
    final observed = elapsed.inMicroseconds.toDouble();
    final previous = _inferenceUs;
    final weight = isFinal ? 0.15 : 0.3;
    _inferenceUs = previous == null
        ? observed
        : previous + (observed - previous) * weight;
    _previewInterval = Duration(
      microseconds: (_inferenceUs! * 1.25).round().clamp(500000, 3000000),
    );
  }

  final List<double> _samples = [];
  int? _startUs;
  int _silence = 0, _id = 0, _revision = 0, _lastPreview = 0;
  bool _speech = false;
  bool _neuralMode = false, _neuralTriggered = false;
  int? _nextNeuralUs, _speechEndUs;
  final List<({int start, int end})> _speechRanges = [];
  static const _neuralWindowSamples = 512;
  static const neuralSilenceMs = 1600;
  static const _neuralSilenceSamples = neuralSilenceMs * 16;
  static const _minimumSpeechSamples = 4000;
  static const _preRollSamples = 6400;
  static const _tailPadSamples =
      4096; // 256ms of real audio after detected speech.
  static const _maxSamples = 128000;
  static const _overlapSamples = 8000;
  void reset() {
    _samples.clear();
    _startUs = null;
    _silence = 0;
    _speech = false;
    _revision = 0;
    _lastPreview = 0;
    _neuralMode = false;
    _neuralTriggered = false;
    _nextNeuralUs = null;
    _speechEndUs = null;
    _speechRanges.clear();
    _id++;
  }

  AudioChunk _snapshot(bool finalResult, {String? endpointReason}) =>
      AudioChunk(
        Float32List.fromList(_samples),
        _startUs!,
        _startUs! + _samples.length * 1000000 ~/ 16000,
        segmentId: _id,
        revision: ++_revision,
        isFinal: finalResult,
        endpointReason: endpointReason,
      );
  List<AudioChunk> add(Float32List samples, int timestampUs) {
    if (_neuralMode) reset();
    _startUs ??= timestampUs;
    _samples.addAll(samples);
    final loud = PcmConverter.rms(samples) > 0.007;
    _speech |= loud;
    _silence = loud ? 0 : _silence + samples.length;
    if (!_speech && _samples.length > 6400) {
      final n = _samples.length - 6400;
      _samples.removeRange(0, n);
      _startUs = _startUs! + n * 1000000 ~/ 16000;
    }
    if (_speech &&
        ((_silence >= 9600 && _samples.length >= 16000) ||
            _samples.length >= 128000)) {
      final result = _snapshot(
        true,
        endpointReason: _silence >= 9600 ? 'silence' : 'maxWindow',
      );
      if (_silence >= 9600) {
        reset();
      } else {
        final n = _samples.length - 8000;
        _samples.removeRange(0, n);
        _startUs = _startUs! + n * 1000000 ~/ 16000;
        _silence = 0;
        _revision = 0;
        _lastPreview = 0;
        _id++;
      }
      return [result];
    }
    final previewSamples =
        (_lastPreview == 0 ? firstPreview : previewInterval).inMicroseconds *
        16000 ~/
        1000000;
    if (_speech && _samples.length - _lastPreview >= previewSamples) {
      _lastPreview = _samples.length;
      return [_snapshot(false)];
    }
    return [];
  }

  int get _neuralSpeechSamples =>
      _speechRanges.fold(0, (sum, range) => sum + range.end - range.start);

  /// Switch a failed classifier's unfinished utterance to the energy baseline.
  /// Keep its real PCM, time origin, identity and preview progress; the caller
  /// can then append the unclassified input without flushing or losing speech.
  void useEnergyFallback() {
    if (!_neuralMode) return;
    _neuralMode = false;
    _neuralTriggered = false;
    _nextNeuralUs = null;
    _speechEndUs = null;
    _speechRanges.clear();
    _speech = PcmConverter.rms(Float32List.fromList(_samples)) > 0.007;
    _silence = 0;
  }

  void _dropNeuralSamples(int count) {
    if (count <= 0) return;
    _samples.removeRange(0, count);
    _startUs = _startUs! + count * 1000000 ~/ 16000;
    final retained = <({int start, int end})>[
      for (final range in _speechRanges)
        if (range.end > count)
          (start: math.max(0, range.start - count), end: range.end - count),
    ];
    _speechRanges
      ..clear()
      ..addAll(retained);
  }

  AudioChunk _neuralSnapshot(
    bool finalResult, {
    required int sampleCount,
    String? endpointReason,
  }) {
    final endUs = _startUs! + sampleCount * 1000000 ~/ 16000;
    return AudioChunk(
      Float32List.fromList(_samples.sublist(0, sampleCount)),
      _startUs!,
      endUs,
      segmentId: _id,
      revision: ++_revision,
      isFinal: finalResult,
      endpointReason: endpointReason,
      speechEndUs: _speechEndUs == null ? null : math.min(_speechEndUs!, endUs),
    );
  }

  int get _trimmedNeuralLength => math.min(
    _samples.length,
    (_speechEndUs! - _startUs!) * 16000 ~/ 1000000 + _tailPadSamples,
  );

  // Preserve the latest real input, including audio omitted from the final's
  // trailing silence. It remains available as the next utterance's pre-roll.
  void _resetNeuralUtterance() {
    _dropNeuralSamples(math.max(0, _samples.length - _preRollSamples));
    _silence = 0;
    _speech = false;
    _neuralTriggered = false;
    _speechEndUs = null;
    _speechRanges.clear();
    _revision = 0;
    _lastPreview = 0;
    _id++;
  }

  /// Consume one new, non-overlapping 512-sample mono 16kHz VAD window.
  /// [timestampUs] is its first sample's session timestamp, not receipt time.
  /// A discontinuity flushes qualified old speech and clears VAD hysteresis.
  List<AudioChunk> addClassified(
    Float32List samples,
    int timestampUs, {
    required double speechProbability,
  }) {
    if (samples.length != _neuralWindowSamples ||
        timestampUs < 0 ||
        !speechProbability.isFinite ||
        speechProbability < 0 ||
        speechProbability > 1) {
      throw ArgumentError('Expected one 512-sample VAD window and probability');
    }
    AudioChunk? beforeGap;
    if (!_neuralMode) {
      reset();
    } else if (_nextNeuralUs != timestampUs) {
      beforeGap = flush();
    }
    _neuralMode = true;
    _startUs ??= timestampUs;
    final offset = _samples.length;
    _samples.addAll(samples);
    _nextNeuralUs = timestampUs + 32000;
    // A short dip starts a pending pause, not a new utterance. Keep the lower
    // continuation threshold until an endpoint is committed so quieter speech
    // can resume without having to cross the initial onset threshold again.
    final speaking = speechProbability >= (_neuralTriggered ? 0.35 : 0.5);
    if (speaking) {
      _neuralTriggered = true;
      if (_speechRanges.isNotEmpty && _speechRanges.last.end == offset) {
        _speechRanges[_speechRanges.length - 1] = (
          start: _speechRanges.last.start,
          end: _samples.length,
        );
      } else {
        _speechRanges.add((start: offset, end: _samples.length));
      }
      _speechEndUs = _nextNeuralUs;
      _silence = 0;
    } else {
      _silence += samples.length;
    }
    if (_speechEndUs == null) {
      _dropNeuralSamples(math.max(0, _samples.length - _preRollSamples));
      return [?beforeGap];
    }
    final qualified = _neuralSpeechSamples >= _minimumSpeechSamples;
    if (_silence >= _neuralSilenceSamples) {
      final result = qualified
          ? _neuralSnapshot(
              true,
              sampleCount: _trimmedNeuralLength,
              endpointReason: 'silence',
            )
          : null;
      _resetNeuralUtterance();
      return [?result];
    }
    if (_samples.length >= _maxSamples) {
      final result = qualified
          ? _neuralSnapshot(
              true,
              sampleCount: _maxSamples,
              endpointReason: 'maxWindow',
            )
          : null;
      // A VAD window can cross the exact 8s boundary. Retain its remainder in
      // addition to the 500ms overlap so no classified samples are lost.
      _dropNeuralSamples(_maxSamples - _overlapSamples);
      _revision = 0;
      _lastPreview = 0;
      _id++;
      return [?result];
    }
    final previewSamples =
        (_lastPreview == 0 ? firstPreview : previewInterval).inMicroseconds *
        16000 ~/
        1000000;
    if (qualified && _samples.length - _lastPreview >= previewSamples) {
      _lastPreview = _samples.length;
      return [_neuralSnapshot(false, sampleCount: _samples.length)];
    }
    return [?beforeGap];
  }

  /// [tail] is an optional real, unclassified EOF remainder (<512 samples),
  /// contiguous with the last classified window. It never adds speech evidence.
  AudioChunk? flush({Float32List? tail, int? tailTimestampUs}) {
    if (tail != null && tail.isNotEmpty) {
      if (tail.length >= _neuralWindowSamples ||
          tailTimestampUs == null ||
          tailTimestampUs < 0 ||
          (_neuralMode && tailTimestampUs != _nextNeuralUs)) {
        throw ArgumentError('Expected a contiguous unclassified VAD tail');
      }
      if (_neuralMode) _samples.addAll(tail);
    }
    if (_neuralMode) {
      final c = _neuralSpeechSamples >= _minimumSpeechSamples
          ? _neuralSnapshot(
              true,
              // At an explicit EOF, pause or stop the classifier may have
              // missed a soft ending. Preserve all received PCM, including
              // the unclassified remainder, rather than trimming that ending.
              sampleCount: _samples.length,
              endpointReason: 'eof',
            )
          : null;
      reset();
      return c;
    }
    if (!_speech || _samples.length < 1600) {
      reset();
      return null;
    }
    final c = _snapshot(true, endpointReason: 'eof');
    reset();
    return c;
  }
}

class WavAudio {
  static AudioFrame decode(Uint8List bytes, {int generation = 0}) {
    final b = ByteData.sublistView(bytes);
    String tag(int p) => String.fromCharCodes(bytes.sublist(p, p + 4));
    if (bytes.length < 44 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('请选择 PCM WAV 文件');
    }
    int? channels, rate, bits, format;
    Uint8List? payload;
    for (var p = 12; p + 8 <= bytes.length;) {
      final size = b.getUint32(p + 4, Endian.little);
      if (p + 8 + size > bytes.length) {
        throw const FormatException('WAV truncated');
      }
      if (tag(p) == 'fmt ' && size >= 16) {
        format = b.getUint16(p + 8, Endian.little);
        channels = b.getUint16(p + 10, Endian.little);
        rate = b.getUint32(p + 12, Endian.little);
        bits = b.getUint16(p + 22, Endian.little);
      }
      if (tag(p) == 'data') {
        payload = Uint8List.sublistView(bytes, p + 8, p + 8 + size);
      }
      p += 8 + size + (size % 2);
    }
    if (payload == null ||
        channels == null ||
        rate == null ||
        !((format == 1 && bits == 16) || (format == 3 && bits == 32))) {
      throw const FormatException('支持 PCM16 或 float32 WAV');
    }
    final data = ByteData.sublistView(payload);
    final count = payload.length ~/ (bits! ~/ 8);
    final samples = Float32List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = format == 1
          ? data.getInt16(i * 2, Endian.little) / 32768
          : data.getFloat32(i * 4, Endian.little);
    }
    return AudioFrame(
      samples: samples,
      sampleRate: rate,
      channels: channels,
      timestampUs: 0,
      sequence: 0,
      generation: generation,
    );
  }
}
