import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/app/shell.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';

class _Native extends NativeBridge {
  _Native(this.path);
  final String path;
  final events = StreamController<dynamic>.broadcast();
  @override
  Stream<dynamic> get stream => events.stream;
  @override
  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    dynamic result;
    if (method == 'paths') result = {'support': path, 'documents': path};
    if (method == 'devices') {
      result = [
        {'id': 'system', 'name': 'System audio', 'source': 'system'},
      ];
    }
    if (method == 'permissions') {
      result = {'system': 'notGranted', 'microphone': 'notDetermined'};
    }
    if (method == 'files.freeBytes') result = 1000000000;
    return result as T?;
  }
}

void main() {
  for (final size in [const Size(1120, 800), const Size(860, 650)]) {
    testWidgets('desktop pages actionable at $size without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('luma-ui-'),
      ))!;
      final native = _Native(dir.path);
      final c = AppController(bridge: native);
      try {
        await tester.runAsync(c.initialize);
        await tester.pumpWidget(
          ListenableBuilder(
            listenable: c,
            builder: (context, _) => MaterialApp(
              theme: ThemeData(useMaterial3: true),
              home: Shell(c: c),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('字幕，从这里开始'), findsOneWidget);
        expect(find.textContaining('上传音频至翻译服务'), findsWidgets);
        for (final label in ['模型管理', '翻译服务', '字幕外观', '历史与导出', '设置与诊断']) {
          await tester.tap(find.text(label).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: label);
        }
        await tester.tap(find.text('开始字幕'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Workspace ID'), findsWidgets);
        expect(tester.takeException(), isNull);
        c.settings.theme = 'dark';
        await tester.runAsync(c.save);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await native.events.close();
        await tester.runAsync(() => dir.delete(recursive: true));
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }
}
