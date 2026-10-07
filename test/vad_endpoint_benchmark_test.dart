import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/core/asr/vad.dart';
import 'package:lumacaption/core/asr/whisper.dart';
import 'package:lumacaption/core/audio/audio.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';

// This bridge provides temporary settings storage and consumes UI updates. It
// cannot access macOS capture, audio output, microphones or stored credentials.
class _FileBenchmarkBridge extends NativeBridge {
  _FileBenchmarkBridge(this.support);
  final String support;
  final methods = <String>[];
  final events = StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get stream => events.stream;

  @override
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    methods.add(method);
    Object? response;
    switch (method) {
      case 'paths':
        response = {'support': support};
      case 'devices':
        response = <dynamic>[];
      case 'permissions':
        response = {'system': 'notRequested', 'microphone': 'notRequested'};
      case 'stop':
      case 'overlay.update':
        break;
      default:
        throw StateError('Benchmark attempted unexpected native call: $method');
    }
    return response as T?;
  }
}

class _Route {
  _Route(this.name, this.controller, this.native, this.whisper, this.vad);
  final String name;
  final AppController controller;
  final _FileBenchmarkBridge native;
  final WhisperEngine whisper;
  final SileroVadEngine vad;

  static Future<_Route> create(
    String name,
    Directory directory,
    String model,
  ) async {
    final support = Directory('${directory.path}/$name');
    await support.create();
    final native = _FileBenchmarkBridge(support.path);
    final whisper = WhisperEngine();
    final vad = SileroVadEngine();
    final controller =
        AppController(bridge: native, engine: whisper, detector: vad)
          ..testMode = true
          ..measureSession = true
          ..enableNeuralVad = name == 'vad-preempt'
          ..preemptFinalPreviews = name == 'vad-preempt';
    final route = _Route(name, controller, native, whisper, vad);
    try {
      await controller.initialize();
      expect(controller.error, isEmpty);
      controller.settings
        ..mode = 'offline'
        ..sourceLanguage = 'en';
      await controller.loadModel(model);
      expect(whisper.backend, startsWith('Metal ·'));
      return route;
    } catch (_) {
      await route.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (controller.running) await controller.stop(emergency: true);
    // AppController.dispose starts an unawaited close. Await native workers
    // first so WhisperEngine never receives two simultaneous close requests.
    await whisper.close();
    await vad.close();
    controller.dispose();
    await native.events.close();
  }
}

double? _difference(Map<String, dynamic>? end, Map<String, dynamic>? start) {
  final last = end?['audioMs'], first = start?['audioMs'];
  return last is num && first is num ? (last - first).toDouble() : null;
}

Map<String, Object?> _phases(Map<String, Object?> timing) {
  final events = (timing['events'] as List)
      .map((dynamic e) => Map<String, dynamic>.from(e as Map))
      .toList();
  final inference = events
      .where((e) => e['event'] == 'localInference')
      .toList();
  final finalEnqueues = inference
      .where((e) => e['stage'] == 'enqueued' && e['isFinal'] == true)
      .toList();
  final endpoints = <Map<String, Object?>>[];
  for (final enqueued in finalEnqueues) {
    Map<String, dynamic>? stage(String name) => inference
        .where(
          (e) =>
              e['segment'] == enqueued['segment'] &&
              e['sourceRevision'] == enqueued['sourceRevision'] &&
              e['stage'] == name,
        )
        .firstOrNull;
    final started = stage('started'), completed = stage('completed');
    final visible = events
        .where(
          (e) =>
              e['event'] == 'subtitleReceived' &&
              e['channel'] == 'source' &&
              e['isFinal'] == true &&
              e['segment'] == enqueued['segment'] &&
              e['revision'] == enqueued['sourceRevision'],
        )
        .firstOrNull;
    final speechEnd = enqueued['speechEndMs'];
    final observation = enqueued['audioMs'];
    endpoints.add({
      'segment': enqueued['segment'],
      'sourceRevision': enqueued['sourceRevision'],
      'reason': enqueued['endpointReason'],
      'speechEndMs': speechEnd,
      'snapshotEndMs': enqueued['audioSnapshotEndMs'],
      'enqueuedAudioMs': observation,
      // Includes frame delivery and VAD/segmenter processing; it is not a
      // measurement of classifier execution time or true acoustic word end.
      'detectedSpeechEndToEnqueueMs': speechEnd is num && observation is num
          ? (observation - speechEnd).toDouble()
          : null,
      'queueWaitMs': _difference(started, enqueued),
      'finalAsrMs': _difference(completed, started),
      'decodeToVisibleMs': _difference(visible, completed),
      'enqueuedToVisibleMs': _difference(visible, enqueued),
    });
  }
  final cancellations = <Map<String, Object?>>[];
  for (final requested in inference.where(
    (e) => e['stage'] == 'cancelRequested',
  )) {
    final acknowledged = inference
        .where(
          (e) =>
              e['segment'] == requested['segment'] &&
              e['sourceRevision'] == requested['sourceRevision'] &&
              e['stage'] == 'cancelAcknowledged',
        )
        .firstOrNull;
    cancellations.add({
      'segment': requested['segment'],
      'sourceRevision': requested['sourceRevision'],
      'requestedAudioMs': requested['audioMs'],
      'acknowledgedAudioMs': acknowledged?['audioMs'],
      'acknowledgmentMs': _difference(acknowledged, requested),
    });
  }
  final vad = events.where((e) => e['event'] == 'vadProcessed').toList();
  final costs = vad.map((e) => (e['processingMs'] as num).toDouble()).toList()
    ..sort();
  final vadTotal = costs.fold<double>(0, (sum, cost) => sum + cost);
  final duration = timing['audioDurationMs'] as num?;
  return {
    'vad': {
      'batches': vad.length,
      'classifiedWindows': vad.fold<int>(
        0,
        (sum, e) => sum + (e['windows'] as int),
      ),
      'processedInputSamples': vad.fold<int>(
        0,
        (sum, e) => sum + (e['samples'] as int),
      ),
      'processingTotalMs': vadTotal,
      'processingMedianMs': costs.isEmpty
          ? null
          : costs.length.isOdd
          ? costs[costs.length ~/ 2]
          : (costs[costs.length ~/ 2 - 1] + costs[costs.length ~/ 2]) / 2,
      'processingMaxMs': costs.lastOrNull,
      'processingMsPerAudioSecond': duration == null || duration <= 0
          ? null
          : vadTotal * 1000 / duration,
      'scope': 'Worker round trip including IPC, not native CPU time alone',
    },
    'endpoints': endpoints,
    'cancellations': cancellations,
    'asr': {
      'previewsStarted': inference
          .where((e) => e['stage'] == 'started' && e['isFinal'] == false)
          .length,
      'previewsCompleted': inference
          .where((e) => e['stage'] == 'completed' && e['isFinal'] == false)
          .length,
      'finalsStarted': inference
          .where((e) => e['stage'] == 'started' && e['isFinal'] == true)
          .length,
      'finalsCompleted': inference
          .where((e) => e['stage'] == 'completed' && e['isFinal'] == true)
          .length,
    },
    'eof': {
      'drainMs': timing['drainMs'],
      'lastSourceFinalAfterEofMs': timing['lastSourceFinalAfterEofMs'],
      'syntheticZerosAddedDuringDrain': false,
    },
  };
}

Map<String, Object?> _wer(String reference, String hypothesis) {
  List<String> words(String text) => RegExp(
    r"[a-z0-9]+(?:['’][a-z]+)?",
  ).allMatches(text.toLowerCase()).map((match) => match[0]!).toList();
  final expected = words(reference), actual = words(hypothesis);
  final matrix = List.generate(
    expected.length + 1,
    (_) => List<int>.filled(actual.length + 1, 0),
  );
  for (var i = 0; i <= expected.length; i++) {
    matrix[i][0] = i;
  }
  for (var j = 0; j <= actual.length; j++) {
    matrix[0][j] = j;
  }
  for (var i = 1; i <= expected.length; i++) {
    for (var j = 1; j <= actual.length; j++) {
      final substitution =
          matrix[i - 1][j - 1] + (expected[i - 1] == actual[j - 1] ? 0 : 1);
      final deletion = matrix[i - 1][j] + 1, insertion = matrix[i][j - 1] + 1;
      matrix[i][j] = [
        substitution,
        deletion,
        insertion,
      ].reduce((a, b) => a < b ? a : b);
    }
  }
  var i = expected.length, j = actual.length;
  var substitutions = 0, deletions = 0, insertions = 0;
  while (i > 0 || j > 0) {
    if (i > 0 &&
        j > 0 &&
        matrix[i][j] ==
            matrix[i - 1][j - 1] + (expected[i - 1] == actual[j - 1] ? 0 : 1)) {
      if (expected[i - 1] != actual[j - 1]) substitutions++;
      i--;
      j--;
    } else if (i > 0 && matrix[i][j] == matrix[i - 1][j] + 1) {
      deletions++;
      i--;
    } else {
      insertions++;
      j--;
    }
  }
  return {
    'referenceWords': expected.length,
    'hypothesisWords': actual.length,
    'substitutions': substitutions,
    'deletions': deletions,
    'insertions': insertions,
    'errors': matrix.last.last,
    'wer': matrix.last.last / expected.length,
    'normalization': 'Lowercase English words; punctuation ignored',
    'scope': 'Complete public JFK words only; synthetic replays identified',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const requiredVariables = [
    'LUMA_ENDPOINT_BENCHMARK_OUTPUT',
    'LUMA_TEST_VAD_MODEL',
    'LUMA_WHISPER_LIBRARY',
    'LUMA_TEST_WHISPER_MODEL',
    'LUMA_TEST_WHISPER_WAV',
  ];
  final missing = requiredVariables.where(
    (key) => (Platform.environment[key] ?? '').isEmpty,
  );
  test(
    'silent paced paired energy vs Silero endpoint and drain benchmark',
    () async {
      final temporary = await Directory.systemTemp.createTemp('luma-endpoint-');
      final output = File(
        Platform.environment['LUMA_ENDPOINT_BENCHMARK_OUTPUT']!,
      );
      final routes = <_Route>[];
      final runs = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'schemaVersion': 1,
        'status': 'running',
        'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'platform': Platform.operatingSystem,
        'benchmark': 'Same-build resident-model paced offline file comparison',
        'playback': false,
        'capture': false,
        'network': false,
        'modelFile': Platform.environment['LUMA_TEST_WHISPER_MODEL']!
            .split(Platform.pathSeparator)
            .last,
        'baseline': {'detector': 'RMS', 'silenceMs': 600, 'preempt': false},
        'experiment': {
          'detector': 'Silero v5.1.2',
          'silenceMs': AudioSegmenter.neuralSilenceMs,
          'preempt': true,
        },
        'preview': {
          'firstMs': 1000,
          'minimumIntervalMs': 500,
          'adaptive': true,
        },
        'runs': runs,
      };
      Future<void> writeReport() async {
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          flush: true,
        );
      }

      try {
        final fixtureDirectory = Directory('${temporary.path}/fixtures');
        final prepare = await Process.run('python3', [
          'scripts/prepare_vad_endpoint_fixtures.py',
          '--source',
          Platform.environment['LUMA_TEST_WHISPER_WAV']!,
          '--output-dir',
          fixtureDirectory.path,
        ]);
        expect(prepare.exitCode, 0, reason: '${prepare.stderr}');
        final fixtureManifest =
            jsonDecode(
                  await File(
                    '${fixtureDirectory.path}/manifest.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        report['fixtureProvenance'] = fixtureManifest;
        final selection =
            Platform.environment['LUMA_ENDPOINT_BENCHMARK_FIXTURES'];
        final requested = selection
            ?.split(',')
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet();
        final fixtures = (fixtureManifest['fixtures'] as List)
            .map((dynamic e) => Map<String, dynamic>.from(e as Map))
            .where(
              (fixture) =>
                  requested == null || requested.contains(fixture['id']),
            )
            .toList();
        expect(fixtures, isNotEmpty);
        if (requested != null) {
          expect(
            fixtures.length,
            requested.length,
            reason: 'Unknown fixture ID',
          );
        }
        report['selectedFixtures'] = fixtures
            .map((fixture) => fixture['id'])
            .toList();
        await writeReport();
        for (final name in ['energy-baseline', 'vad-preempt']) {
          routes.add(
            await _Route.create(
              name,
              temporary,
              Platform.environment['LUMA_TEST_WHISPER_MODEL']!,
            ),
          );
        }
        report['modelPreparation'] = {
          for (final route in routes)
            route.name: route.controller.modelPreparationTiming,
        };
        final rounds =
            int.tryParse(
              Platform.environment['LUMA_ENDPOINT_BENCHMARK_ROUNDS'] ?? '1',
            ) ??
            1;
        expect(rounds, inInclusiveRange(1, 3));
        for (var round = 0; round < rounds; round++) {
          for (final metadata in fixtures) {
            final input = File('${fixtureDirectory.path}/${metadata['file']}');
            expect(
              (await sha256.bind(input.openRead()).first).toString(),
              metadata['sha256'],
            );
            final order = (runs.length ~/ 2 + round).isEven
                ? routes
                : routes.reversed;
            for (final route in order) {
              final controller = route.controller;
              await controller.processFile(inputPath: input.path, paced: true);
              final finals =
                  controller.subtitles.segments
                      .where(
                        (s) =>
                            s.generation == controller.generation && s.isFinal,
                      )
                      .toList()
                    ..sort(
                      (a, b) => (a.startUs ?? 0).compareTo(b.startUs ?? 0),
                    );
              final text = finals.map((s) => s.original).join(' ');
              final timing = controller.sessionTiming!.report();
              runs.add({
                'round': round + 1,
                'fixture': metadata['id'],
                'route': route.name,
                'status': controller.error.isEmpty ? 'ok' : 'error',
                'error': controller.error,
                'backend': route.whisper.backend,
                'vadBackend': controller.vadBackend,
                'receivedSamples': controller.receivedSamples,
                'receivedFrames': controller.receivedFrames,
                'droppedFrames': controller.droppedFrames,
                'finalText': text,
                'finalSubtitles': [
                  for (final segment in finals)
                    {
                      'startUs': segment.startUs,
                      'endUs': segment.endUs,
                      'original': segment.original,
                    },
                ],
                'quality': _wer(metadata['expectedText'] as String, text),
                'phases': _phases(timing),
                'timing': timing,
              });
              await writeReport();
              expect(controller.error, isEmpty);
              expect(controller.receivedSamples, metadata['samples']);
              expect(controller.droppedFrames, 0);
              expect(controller.running, false);
              expect(controller.busy, false);
              expect(
                controller.vadBackend,
                startsWith(
                  route.name == 'vad-preempt' ? 'CPU · Silero' : 'RMS ·',
                ),
              );
              expect(route.native.methods, isNot(contains('start')));
              expect(
                route.native.methods.any(
                  (method) => method.startsWith('secrets.'),
                ),
                false,
              );
            }
          }
        }
        report['status'] = 'measurementsComplete';
        await writeReport();
        for (final route in routes) {
          await route.close();
        }
        routes.clear();
        report['status'] = 'ok';
        report['nativeWorkersClosed'] = true;
        report['finishedAtUtc'] = DateTime.now().toUtc().toIso8601String();
        await writeReport();
      } catch (error) {
        report['status'] = 'failed';
        report['failure'] = error.toString();
        await writeReport();
        rethrow;
      } finally {
        for (final route in routes) {
          await route.close();
        }
        await temporary.delete(recursive: true);
      }
    },
    skip: missing.isNotEmpty
        ? 'Set ${requiredVariables.join(', ')} for the public silent benchmark.'
        : false,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
