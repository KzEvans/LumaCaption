import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/core/storage/history_store.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';
import 'package:lumacaption/core/storage/settings.dart';
import 'package:lumacaption/core/subtitles/subtitles.dart';

class _Native extends NativeBridge {
  _Native(this.path);
  final String path;
  final events = StreamController<dynamic>.broadcast();
  String? exported;
  @override
  Stream<dynamic> get stream => events.stream;
  @override
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    dynamic result;
    if (method == 'paths') result = {'support': path};
    if (method == 'devices') result = <dynamic>[];
    if (method == 'permissions') result = <String, dynamic>{};
    if (method == 'files.saveText') exported = args!['text'] as String;
    return result as T?;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = SubtitleSegment(
    generation: 3,
    segmentId: 'a',
    original: '已确认原文',
    translation: 'Final translation',
    startUs: 0,
    endUs: 1000000,
    isFinal: true,
  );
  const second = SubtitleSegment(
    generation: 7,
    segmentId: 'b',
    original: 'Another session',
    startUs: 0,
    endUs: 2000000,
    isFinal: true,
  );

  test('test-mode history clearing preserves saved user history', () async {
    final dir = await Directory.systemTemp.createTemp('luma-history-');
    final native = _Native(dir.path);
    final c = AppController(bridge: native)
      ..testMode = true
      ..supportDirectory = dir.path;
    final store = HistoryStore(dir.path);
    try {
      await store.save([first]);
      c.subtitles.segments.add(second);
      await c.clearHistory();
      expect(c.subtitles.segments, isEmpty);
      expect((await store.load()).single.original, first.original);
    } finally {
      c.dispose();
      await native.events.close();
      await dir.delete(recursive: true);
    }
  });

  test('saved finals survive restart; sessions export separately', () async {
    final dir = await Directory.systemTemp.createTemp('luma-history-');
    final native = _Native(dir.path);
    final c = AppController(bridge: native);
    final store = HistoryStore(dir.path);
    try {
      await store.save([
        first,
        second,
        const SubtitleSegment(
          generation: 7,
          segmentId: 'partial',
          original: '未确认',
        ),
      ]);
      await c.initialize();
      expect(c.settings.persistHistory, false);
      expect(c.subtitles.segments.length, 2);
      expect(c.generation, 7);
      expect(c.subtitles.segments.first.translation, first.translation);
      await expectLater(c.export('srt', 'original'), throwsStateError);
      await c.export('vtt', 'original', session: 3);
      expect(native.exported, contains('已确认原文'));
      expect(native.exported, isNot(contains('Another session')));
      c.subtitles.segments.add(
        const SubtitleSegment(
          generation: 8,
          segmentId: 'c',
          original: 'New final',
          isFinal: true,
        ),
      );
      await c.setPersistHistory(false);
      expect((await store.load()).length, 2);
      await c.setPersistHistory(true);
      expect((await store.load()).length, 3);
      final settings = await SettingsStore(dir.path).load();
      expect(settings.persistHistory, true);
    } finally {
      c.dispose();
      await native.events.close();
      await dir.delete(recursive: true);
    }
  });
  test('unknown history stays intact until explicitly cleared', () async {
    final dir = await Directory.systemTemp.createTemp('luma-history-');
    final native = _Native(dir.path);
    final c = AppController(bridge: native);
    final file = File('${dir.path}/history.json');
    try {
      await file.writeAsString('{"version":99,"segments":[]}');
      await c.initialize();
      expect(c.error, contains('原文件仍保留'));
      await expectLater(c.setPersistHistory(true), throwsStateError);
      expect(await file.readAsString(), '{"version":99,"segments":[]}');
      await c.clearHistory();
      await c.setPersistHistory(true);
      expect((await HistoryStore(dir.path).load()), isEmpty);
    } finally {
      c.dispose();
      await native.events.close();
      await dir.delete(recursive: true);
    }
  });
}
