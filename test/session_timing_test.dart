import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/diagnostics/session_timing.dart';

void main() {
  test(
    'local inference trace separates duration and adaptive cadence without text',
    () {
      var us = 0;
      final timing = SessionTiming(generation: 1, elapsedMicroseconds: () => us)
        ..preparationStarted()
        ..audioStarted();
      void mark(int generation, String stage, {int? duration}) =>
          timing.localInference(
            generation: generation,
            segmentId: 'private-source-id',
            sourceRevision: 2,
            stage: stage,
            isFinal: false,
            audioStartUs: 0,
            audioEndUs: 3000000,
            previewIntervalUs: 1250000,
            inferenceUs: duration,
          );
      us = 3000000;
      mark(1, 'started');
      us += 800000;
      mark(1, 'completed', duration: 800000);
      mark(2, 'completed', duration: 900000);
      final events = (timing.report()['events'] as List)
          .where((e) => e['event'] == 'localInference')
          .toList();
      expect(events.length, 2);
      expect(events.last['inferenceMs'], 800);
      expect(events.last['audioSnapshotEndMs'], 3000);
      expect(events.last['previewIntervalMs'], 1250);
      expect(events.last['segment'], events.first['segment']);
      expect(jsonEncode(timing.report()), isNot(contains('private-source-id')));
      timing.stopped();
      mark(1, 'completed', duration: 1000000);
      expect(
        (timing.report()['events'] as List)
            .where((e) => e['event'] == 'localInference')
            .length,
        2,
      );
    },
  );
  test(
    'request milestones join source ordinal without recording request text',
    () {
      var us = 0;
      final timing = SessionTiming(generation: 1, elapsedMicroseconds: () => us)
        ..preparationStarted()
        ..audioStarted();
      us = 3000000;
      timing.textRequest(
        generation: 1,
        segmentId: 'private-id',
        sourceRevision: 2,
        stage: 'requestStarted',
        requestElapsedMs: 0,
        attempt: 0,
      );
      us += 200000;
      timing.textRequest(
        generation: 1,
        segmentId: 'private-id',
        sourceRevision: 2,
        stage: 'firstDelta',
        requestElapsedMs: 200,
        attempt: 0,
      );
      timing.textRequest(
        generation: 2,
        segmentId: 'old-id',
        sourceRevision: 3,
        stage: 'failed',
        requestElapsedMs: 100,
        attempt: 0,
      );
      final events = timing.report()['events'] as List;
      final requests = events
          .where((e) => e['event'] == 'textRequest')
          .toList();
      expect(requests.length, 2);
      expect(requests.last['segment'], requests.first['segment']);
      expect(requests.last['requestElapsedMs'], 200);
      expect(jsonEncode(timing.report()), isNot(contains('private-id')));
    },
  );
  test(
    'paced session separates preparation, visible results and EOF drain',
    () {
      var us = 1000000;
      final timing = SessionTiming(
        generation: 7,
        elapsedMicroseconds: () => us,
      );
      timing.preparationStarted();
      us = 1250000;
      timing.translationReady();
      us = 1300000;
      timing.audioStarted();
      us = 1405000;
      timing.audioFrame(scheduledEndUs: 100000);
      us = 2000000;
      timing.received(
        segmentId: 'local:1',
        channel: 'source',
        revision: 1,
        isFinal: false,
      );
      us = 2100000;
      timing.received(
        segmentId: 'local:1',
        channel: 'source',
        revision: 2,
        isFinal: true,
        audioEndUs: 600000,
      );
      us = 2150000;
      timing.received(
        segmentId: 'local:1',
        channel: 'translation',
        revision: 1,
        isFinal: false,
      );
      us = 2310000;
      timing.audioFrame(scheduledEndUs: 1000000);
      timing.audioFinished();
      us = 2500000;
      timing.received(
        segmentId: 'local:1',
        channel: 'translation',
        revision: 2,
        isFinal: true,
        audioEndUs: 600000,
      );
      us = 2600000;
      timing.stopped();

      final report = timing.report();
      expect(report['setupMs'], 250);
      expect(report['preparationMs'], 300);
      expect(report['firstSourceMs'], 700);
      expect(report['firstSourceFinalMs'], 800);
      expect(report['firstTranslationMs'], 850);
      expect(report['firstTranslationFinalMs'], 1200);
      expect(report['audioDurationMs'], 1000);
      expect(report['audioElapsedMs'], 1010);
      expect(report['drainMs'], 290);
      expect(report['lastSourceFinalAfterEofMs'], -210);
      expect(report['lastTranslationFinalAfterEofMs'], 190);
      expect(report['schedulerLatenessMs'], {
        'min': 5.0,
        'max': 10.0,
        'mean': 7.5,
      });
      final segment = (report['segments'] as List).single as Map;
      expect((segment['source'] as Map)['endLagMs'], 200);
      expect((segment['translation'] as Map)['endLagMs'], 600);
      final events = report['events'] as List;
      for (var i = 0; i < events.length; i++) {
        expect((events[i] as Map)['order'], i);
        if (i > 0) {
          expect(
            (events[i] as Map)['elapsedMs'],
            greaterThanOrEqualTo((events[i - 1] as Map)['elapsedMs']),
          );
        }
      }
    },
  );

  test('stale generations and revisions cannot move first final metrics', () {
    var us = 0;
    final timing = SessionTiming(generation: 2, elapsedMicroseconds: () => us)
      ..preparationStarted()
      ..audioStarted();
    us = 100000;
    expect(
      timing.received(
        segmentId: 'same',
        channel: 'source',
        revision: 99,
        isFinal: true,
        generation: 1,
      ),
      false,
    );
    us = 900000;
    timing.received(
      segmentId: 'same',
      channel: 'source',
      revision: 2,
      isFinal: true,
      audioEndUs: 800000,
    );
    for (final revision in [2, 1]) {
      expect(
        timing.received(
          segmentId: 'same',
          channel: 'source',
          revision: revision,
          isFinal: true,
          audioEndUs: 800000,
        ),
        false,
      );
    }
    us = 1100000;
    expect(
      timing.received(
        segmentId: 'same',
        channel: 'source',
        revision: 3,
        isFinal: false,
      ),
      false,
    );
    expect(
      timing.received(
        segmentId: 'same',
        channel: 'source',
        revision: 3,
        isFinal: true,
        audioEndUs: 1000000,
      ),
      true,
    );
    expect(
      timing.received(
        segmentId: 'same',
        channel: 'translation',
        revision: 1,
        isFinal: false,
      ),
      true,
    );
    timing.audioFinished();
    timing.stopped();
    expect(
      timing.received(
        segmentId: 'late',
        channel: 'source',
        revision: 1,
        isFinal: true,
      ),
      false,
    );
    final report = timing.report();
    expect(report['sourceFinalSegments'], 1);
    expect(report['translationFinalSegments'], 0);
    expect(report['firstSourceFinalMs'], 900);
    expect(report['firstTranslationMs'], 1100);
    expect(report['lastSourceFinalAfterEofMs'], -200);
    final segment = (report['segments'] as List).single as Map;
    expect((segment['source'] as Map)['latestRevision'], 3);
    expect((segment['source'] as Map)['endLagMs'], 100);
    final finals = (report['events'] as List).where(
      (event) => (event as Map)['firstFinal'] == true,
    );
    expect(finals.length, 1);
  });

  test('unknown audio timing stays null and report excludes input IDs', () {
    var us = 0;
    final timing = SessionTiming(generation: 3, elapsedMicroseconds: () => us)
      ..preparationStarted()
      ..audioStarted();
    us = 1234567;
    timing.received(
      segmentId: '/private/path/credential-secret',
      channel: 'translation',
      revision: 1,
      isFinal: true,
    );
    timing.audioFinished();
    timing.stopped();
    final report = timing.report();
    expect(report['firstSourceMs'], isNull);
    expect(report['firstSourceFinalMs'], isNull);
    expect(report['firstTranslationMs'], 1234.567);
    final segment = (report['segments'] as List).single as Map;
    expect((segment['translation'] as Map)['audioEndMs'], isNull);
    expect((segment['translation'] as Map)['endLagMs'], isNull);
    expect(segment['segment'], 1);
    final encoded = jsonEncode(report);
    expect(encoded, isNot(contains('/private/path')));
    expect(encoded, isNot(contains('credential-secret')));
    expect(jsonDecode(encoded), isA<Map>());
    (report['events'] as List).clear();
    expect(timing.report()['events'], isNotEmpty);
  });

  test('zero audio end is known and early frame timing remains signed', () {
    var us = 0;
    final timing = SessionTiming(generation: 1, elapsedMicroseconds: () => us)
      ..preparationStarted()
      ..audioStarted();
    us = 90000;
    timing.audioFrame(scheduledEndUs: 100000);
    us = 100000;
    timing.received(
      segmentId: 'zero',
      channel: 'source',
      revision: 0,
      isFinal: true,
      audioEndUs: 0,
    );
    final report = timing.report();
    expect((report['schedulerLatenessMs'] as Map)['min'], -10);
    final segment = (report['segments'] as List).single as Map;
    expect((segment['source'] as Map)['audioEndMs'], 0);
    expect((segment['source'] as Map)['endLagMs'], 100);
    expect(report['drainMs'], isNull);
  });

  test(
    'phase markers are idempotent and invalid clock order fails clearly',
    () {
      var us = 1000000;
      final timing = SessionTiming(
        generation: 4,
        elapsedMicroseconds: () => us,
      );
      expect(timing.report()['setupMs'], isNull);
      expect(timing.audioStarted, throwsStateError);
      timing.preparationStarted();
      us = 1100000;
      timing.preparationStarted();
      timing.translationReady();
      us = 1200000;
      timing.translationReady();
      timing.audioStarted();
      timing.audioStarted();
      us = 1199999;
      expect(() => timing.audioFrame(scheduledEndUs: 100000), throwsStateError);
      us = 1300000;
      timing.audioFrame(scheduledEndUs: 100000);
      expect(
        () => timing.audioFrame(scheduledEndUs: 100000),
        throwsArgumentError,
      );
      expect(
        () => timing.received(
          segmentId: 'id',
          channel: 'unknown',
          revision: 1,
          isFinal: false,
        ),
        throwsArgumentError,
      );
      us = 1400000;
      timing.audioFinished();
      timing.audioFinished();
      us = 1500000;
      timing.stopped();
      timing.stopped();
      final report = timing.report();
      expect(report['setupMs'], 100);
      expect(report['preparationMs'], 200);
      expect(report['drainMs'], 100);
      expect((report['events'] as List).length, 6);
    },
  );
}
