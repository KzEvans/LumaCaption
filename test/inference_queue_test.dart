import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/asr/inference_queue.dart';
import 'package:lumacaption/core/audio/audio.dart';

AudioChunk chunk(
  int id, {
  int revision = 1,
  bool isFinal = false,
  int? startUs,
}) => AudioChunk(
  Float32List(16),
  startUs ?? id * 1000000,
  (startUs ?? id * 1000000) + revision * 100000,
  segmentId: id,
  revision: revision,
  isFinal: isFinal,
);

void main() {
  test(
    'newest preview replaces pending work while finals take chronological priority',
    () {
      final queue = InferenceQueue();
      queue.add(chunk(1, isFinal: true));
      queue.add(chunk(2, isFinal: true));
      queue.add(chunk(3));
      final latestPreview = chunk(3, revision: 8);
      queue.add(latestPreview);
      expect(queue.length, 3);
      expect(queue.take()!.segmentId, 1);
      expect(queue.take()!.segmentId, 2);
      expect(queue.take(), same(latestPreview));
      expect(queue.take(), isNull);
      expect(queue.isEmpty, true);
      expect(queue.droppedFinalCount, 0);
    },
  );
  test(
    'final ordering follows audio chronology rather than insertion order',
    () {
      final queue = InferenceQueue();
      final later = chunk(20, isFinal: true, startUs: 2000000);
      final earlier = chunk(10, isFinal: true, startUs: 1000000);
      queue.add(later);
      queue.add(earlier);
      queue.add(chunk(21));
      expect(queue.take(), same(earlier));
      expect(queue.take(), same(later));
      expect(queue.take()!.segmentId, 21);
    },
  );
  test(
    'final evicts its pending preview and later stale snapshots stay obsolete',
    () {
      final queue = InferenceQueue();
      queue.add(chunk(4, revision: 1));
      final finalChunk = chunk(4, revision: 5, isFinal: true);
      queue.add(finalChunk);
      expect(queue.length, 1);
      expect(queue.add(chunk(4, revision: 6)), false);
      expect(queue.take(), same(finalChunk));
      expect(queue.add(chunk(4, revision: 7)), false);
      expect(queue.isEmpty, true);
      expect(queue.droppedFinalCount, 0);
    },
  );
  test('final for an earlier segment retains the newer pending preview', () {
    final queue = InferenceQueue();
    final preview = chunk(5, revision: 3);
    queue.add(preview);
    queue.add(chunk(4, isFinal: true));
    expect(queue.take()!.segmentId, 4);
    expect(queue.take(), same(preview));
  });
  test('obsolete preview updates cannot replace the newest snapshot', () {
    final queue = InferenceQueue();
    final latest = chunk(8, revision: 6);
    expect(queue.add(latest), true);
    expect(queue.add(chunk(7, revision: 99)), false);
    expect(queue.add(chunk(8, revision: 5)), false);
    expect(queue.add(chunk(8, revision: 6)), false);
    expect(queue.take(), same(latest));
    expect(queue.droppedFinalCount, 0);
  });
  test('only final overflow increments the dropped final counter', () {
    final queue = InferenceQueue();
    queue.add(chunk(1, isFinal: true));
    queue.add(chunk(2, isFinal: true));
    for (var revision = 1; revision <= 100; revision++) {
      queue.add(chunk(4, revision: revision));
    }
    expect(queue.length, 3);
    expect(queue.droppedFinalCount, 0);
    expect(queue.add(chunk(3, isFinal: true)), true);
    expect(queue.droppedFinalCount, 1);
    expect(queue.length, 3);
    expect(queue.take()!.segmentId, 2);
    expect(queue.take()!.segmentId, 3);
    expect(queue.take()!.segmentId, 4);
  });
  test(
    'late oldest final overflow reports rejection instead of growing the queue',
    () {
      final queue = InferenceQueue();
      queue.add(chunk(2, isFinal: true));
      queue.add(chunk(3, isFinal: true));
      expect(queue.add(chunk(1, isFinal: true)), false);
      expect(queue.droppedFinalCount, 1);
      expect(queue.length, 2);
      expect(queue.take()!.segmentId, 2);
      expect(queue.take()!.segmentId, 3);
    },
  );
  test(
    'a corrected pending final replaces its earlier revision without overflow',
    () {
      final queue = InferenceQueue();
      queue.add(chunk(1, isFinal: true));
      queue.add(chunk(2, isFinal: true));
      final correction = chunk(1, revision: 2, isFinal: true);
      expect(queue.add(correction), true);
      expect(queue.add(chunk(1, revision: 1, isFinal: true)), false);
      expect(queue.length, 2);
      expect(queue.droppedFinalCount, 0);
      expect(queue.take(), same(correction));
    },
  );
  test('clear resets work, dropped count, and obsolete snapshot watermark', () {
    final queue = InferenceQueue(maxPendingFinals: 1);
    queue.add(chunk(1, isFinal: true));
    queue.add(chunk(2, isFinal: true));
    queue.add(chunk(3));
    expect(queue.droppedFinalCount, 1);
    queue.clear();
    expect(queue.isEmpty, true);
    expect(queue.length, 0);
    expect(queue.droppedFinalCount, 0);
    expect(queue.add(chunk(1)), true);
    expect(queue.isNotEmpty, true);
    expect(queue.take()!.segmentId, 1);
  });
}
