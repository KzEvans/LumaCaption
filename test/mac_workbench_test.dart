import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/app/mac_workbench.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';
import 'package:lumacaption/core/subtitles/subtitles.dart';

class QuietBridge extends NativeBridge {
  final calls = <String>[];
  @override
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    calls.add(method);
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late QuietBridge native;
  late AppController c;
  late MacWorkbenchCoordinator coordinator;
  setUp(() {
    native = QuietBridge();
    c = AppController(bridge: native)..testMode = true;
    coordinator = MacWorkbenchCoordinator(
      c,
      channel: const MethodChannel('test/workbench'),
    );
  });
  tearDown(() {
    coordinator.dispose();
    c.dispose();
  });
  test(
    'native configuration preserves model paths and unrelated settings',
    () async {
      c.settings.modelPath = '/models/ggml-tiny.bin';
      c.settings.workspace = 'example-workspace';
      c.settings.endpoint = 'wss://example.test/realtime';
      await coordinator.configure({'theme': 'dark', 'fontSize': 36.0});
      expect(c.settings.modelPath, '/models/ggml-tiny.bin');
      expect(c.settings.workspace, 'example-workspace');
      expect(c.settings.endpoint, 'wss://example.test/realtime');
      expect(c.settings.theme, 'dark');
      expect(native.calls, contains('overlay.configure'));
    },
  );
  test('capture configuration is locked during a live session', () async {
    c.running = true;
    await expectLater(
      coordinator.configure({'source': 'microphone'}),
      throwsStateError,
    );
    expect(c.settings.source, 'system');
    await coordinator.configure({'display': 'original'});
    expect(c.settings.display, 'original');
    c.running = false;
  });
  test(
    'invalid native actions cannot write arbitrary settings or invoke capture',
    () async {
      await expectLater(
        coordinator.configure({'modelPath': '/unexpected.bin'}),
        throwsFormatException,
      );
      await expectLater(
        coordinator.configure({'mode': 'unknown'}),
        throwsFormatException,
      );
      await expectLater(
        coordinator.dispatch({'action': 'unknown'}),
        throwsFormatException,
      );
      expect(native.calls, isEmpty);
    },
  );
  test('snapshots expose view state without PCM or credentials', () {
    final snapshot = coordinator.snapshot();
    expect(snapshot['settings'], c.settings.toJson());
    expect(snapshot.containsKey('key'), isFalse);
    expect(snapshot.containsKey('pcm'), isFalse);
    expect((snapshot['settings'] as Map).containsKey('apiKey'), isFalse);
    expect(snapshot['segments'], isEmpty);
    expect(native.calls, isEmpty);
  });
  test(
    'native snapshot carries stable source without confirming its preview',
    () {
      c.subtitles.reset(7);
      c.subtitles.put(
        const SubtitleSegment(
          generation: 7,
          segmentId: 'preview',
          original: 'Hi 👋 世界 again',
          stableOriginal: 'Hi 👋 世界',
        ),
      );
      c.subtitles.put(
        const SubtitleSegment(
          generation: 7,
          segmentId: 'final',
          original: 'A confirmed sentence.',
          isFinal: true,
        ),
      );
      final segments = coordinator.snapshot()['segments'] as List;
      expect(segments[0]['original'], 'Hi 👋 世界 again');
      expect(segments[0]['stableOriginal'], 'Hi 👋 世界');
      expect(segments[0]['final'], isFalse);
      expect(segments[1]['stableOriginal'], '');
      expect(segments[1]['final'], isTrue);
      expect(native.calls, isEmpty);
    },
  );
}
