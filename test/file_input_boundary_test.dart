import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordinary file input cannot opt into uploading audio', () async {
    final controller = AppController();
    controller.settings.mode = 'realtime';
    try {
      await expectLater(
        controller.processFile(inputPath: 'unused.wav', allowOnline: true),
        throwsStateError,
      );
      expect(controller.running, isFalse);
    } finally {
      controller.dispose();
    }
  });
  test('test mode alone cannot turn an ordinary file action online', () async {
    final controller = AppController()..testMode = true;
    controller.settings.mode = 'text';
    try {
      await expectLater(
        controller.processFile(inputPath: 'unused.wav'),
        throwsStateError,
      );
      expect(controller.running, isFalse);
    } finally {
      controller.dispose();
    }
  });
}
