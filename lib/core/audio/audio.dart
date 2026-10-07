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
  });
  final Float32List samples;
  final int startUs, endUs, segmentId, revision;
  final bool isFinal;
}

/// Bounded energy VAD with revisable previews, 8s utterance windows,
/// 400ms pre-roll and 500ms overlap. This is a segmentation heuristic.
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
                 1000000,
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
      microseconds: (_inferenceUs! * 1.25).round().clamp(1000000, 3000000),
    );
  }

  final List<double> _samples = [];
  int? _startUs;
  int _silence = 0, _id = 0, _revision = 0, _lastPreview = 0;
  bool _speech = false;
  void reset() {
    _samples.clear();
    _startUs = null;
    _silence = 0;
    _speech = false;
    _revision = 0;
    _lastPreview = 0;
    _id++;
  }

  AudioChunk _snapshot(bool finalResult) => AudioChunk(
    Float32List.fromList(_samples),
    _startUs!,
    _startUs! + _samples.length * 1000000 ~/ 16000,
    segmentId: _id,
    revision: ++_revision,
    isFinal: finalResult,
  );
  List<AudioChunk> add(Float32List samples, int timestampUs) {
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
      final result = _snapshot(true);
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

  AudioChunk? flush() {
    if (!_speech || _samples.length < 1600) {
      reset();
      return null;
    }
    final c = _snapshot(true);
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
