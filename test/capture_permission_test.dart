import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';

class _PermissionBridge extends NativeBridge {
  Map<String, String> permissions = {'system': 'notVerified'};
  bool failPermissionRead = false;
  int reads = 0;

  @override
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    if (method != 'permissions') throw StateError('Unexpected call: $method');
    reads++;
    if (failPermissionRead) throw StateError('permission read failed');
    return Map<String, String>.from(permissions) as T;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'permission refresh replaces the previous permission snapshot',
    () async {
      final native = _PermissionBridge();
      final c = AppController(bridge: native)..testMode = true;
      try {
        await c.refreshPermissions();
        expect(c.permissions['system'], 'notVerified');
        native.permissions = {'system': 'authorized', 'microphone': 'denied'};
        await c.refreshPermissions();
        expect(c.permissions['system'], 'authorized');
        expect(c.permissions['microphone'], 'denied');
        expect(native.reads, 2);
      } finally {
        c.dispose();
      }
    },
  );

  test(
    'a failed start clears preparation status and refreshes permissions',
    () async {
      final native = _PermissionBridge();
      final c = AppController(bridge: native)..testMode = true;
      c.settings.mode = 'offline';
      try {
        await expectLater(c.start(), throwsStateError);
        expect(c.status, '无法开始字幕');
        expect(c.busy, isFalse);
        expect(c.running, isFalse);
        expect(native.reads, 1);
      } finally {
        c.dispose();
      }
    },
  );

  test(
    'permission read failure does not replace the actual start failure',
    () async {
      final native = _PermissionBridge()..failPermissionRead = true;
      final c = AppController(bridge: native)..testMode = true;
      c.settings.mode = 'offline';
      try {
        await expectLater(
          c.start(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Whisper'),
            ),
          ),
        );
        expect(c.busy, isFalse);
        expect(c.diagnostics.last, contains('权限状态刷新失败'));
      } finally {
        c.dispose();
      }
    },
  );

  test(
    'native error diagnostics retain the reason without recording paths',
    () {
      final c = AppController(bridge: _PermissionBridge())..testMode = true;
      try {
        c.fail(
          PlatformException(
            code: 'systemAudioStartFailed',
            message: '系统声音流启动失败',
            details: {
              'domain': 'SCStreamErrorDomain',
              'nativeCode': -3818,
              'appPath': '/private/example',
            },
          ),
        );
        expect(c.error, '系统声音流启动失败');
        expect(c.diagnostics.last, contains('SCStreamErrorDomain/-3818'));
        expect(c.diagnostics.last, isNot(contains('/private/example')));
        expect(c.error, isNot(contains('未授权')));
      } finally {
        c.dispose();
      }
    },
  );
}
