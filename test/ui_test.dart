import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/app/controller.dart';
import 'package:lumacaption/app/shell.dart';
import 'package:lumacaption/app/design.dart';
import 'package:lumacaption/core/storage/native_bridge.dart';
import 'package:lumacaption/core/subtitles/subtitles.dart';

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
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'source stability colors preserve partial status in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(1120, 800);
        tester.view.devicePixelRatio = 1;
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('luma-stable-ui-'),
        ))!;
        final native = _Native(dir.path);
        final c = AppController(bridge: native)..testMode = true;
        try {
          await tester.runAsync(c.initialize);
          const original = 'Hi 👋 世界 again';
          for (final (stable, confirmed, expectedStable) in [
            ('Hi 👋 世界', false, 'Hi 👋 世界'),
            ('', false, ''),
            ('Different source', false, ''),
            ('Hi', true, original),
          ]) {
            c.subtitles.segments
              ..clear()
              ..add(
                SubtitleSegment(
                  generation: c.generation,
                  segmentId: 'test-source',
                  original: original,
                  stableOriginal: stable,
                  isFinal: confirmed,
                ),
              );
            await tester.pumpWidget(
              MaterialApp(
                theme: macContentTheme(brightness),
                home: Shell(c: c),
              ),
            );
            await tester.pumpAndSettle();
            final selectable = tester.widget<SelectableText>(
              find.byWidgetPredicate(
                (w) =>
                    w is SelectableText &&
                    w.textSpan?.toPlainText() == original,
              ),
            );
            final span = selectable.textSpan!;
            final parts = span.children!.cast<TextSpan>();
            final colors = Theme.of(
              tester.element(find.byType(Shell)),
            ).colorScheme;
            expect(span.toPlainText(), original);
            expect(parts[0].text, expectedStable);
            expect(span.style!.color, colors.onSurface);
            expect(parts[1].text, original.substring(expectedStable.length));
            expect(parts[1].style!.color, colors.onSurfaceVariant);
            expect(find.text(confirmed ? '已确认' : '识别中 · 可修订'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          c.dispose();
          await native.events.close();
          await tester.runAsync(() => dir.delete(recursive: true));
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }
  for (final (size, brightness, scale) in [
    (const Size(1120, 800), Brightness.light, 1.0),
    (const Size(1120, 800), Brightness.dark, 1.25),
    (const Size(860, 650), Brightness.light, 1.25),
    (const Size(860, 650), Brightness.dark, 1.0),
  ]) {
    testWidgets('Flutter fallback pages at $size $brightness scale $scale', (
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
              theme: macContentTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Shell(c: c),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '实时字幕');
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
