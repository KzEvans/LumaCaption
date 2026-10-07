import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'controller.dart';

/// Bridges native AppKit controls to the same controller as the content pages.
class MacChromeCoordinator {
  MacChromeCoordinator({required this.c, required this.navigate}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'action') return;
      final value = Map<String, dynamic>.from(call.arguments as Map);
      switch (value['action']) {
        case 'navigate':
          final page = value['page'] as int?;
          if (page != null && page >= 0 && page < 6) navigate(page);
        case 'toggleStart':
          await c.guard(c.running ? () => c.stop() : c.start);
        case 'toggleOverlay':
          await c.guard(c.toggleOverlay);
      }
    });
  }
  static const _channel = MethodChannel('lumacaption/design');
  final AppController c;
  final void Function(int) navigate;
  String? _lastState;
  void sync(int page) {
    final state = {
      'page': page,
      'running': c.running,
      'busy': c.busy,
      'overlayVisible': c.overlayVisible,
      'theme': c.settings.theme,
    };
    final signature = jsonEncode(state);
    if (signature == _lastState) return;
    _lastState = signature;
    unawaited(
      _channel.invokeMethod<void>('sync', state).catchError((Object error) {
        c.fail(error);
      }),
    );
  }

  void dispose() => _channel.setMethodCallHandler(null);
}

class MacChrome extends StatelessWidget {
  const MacChrome({super.key, required this.role});
  final String role;
  @override
  Widget build(BuildContext context) => AppKitView(
    viewType: 'lumacaption/glass-chrome',
    creationParams: {'role': role},
    creationParamsCodec: const StandardMessageCodec(),
  );
}
