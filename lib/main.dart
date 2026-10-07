import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app/controller.dart';
import 'app/shell.dart';
import 'core/subtitles/subtitles.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  String? option(String name) => args
      .where((a) => a.startsWith('--$name='))
      .firstOrNull
      ?.substring(name.length + 3);
  final wav = option('test-wav'),
      source = option('test-source'),
      model = option('test-model'),
      output = option('test-output');
  controller.testMode = wav != null || source != null;
  runApp(LumaApp(controller: controller));
  if (controller.testMode) {
    unawaited(() async {
      Future<void> report(Map<String, dynamic> values) async {
        if (output != null) {
          await File(output).writeAsString(
            const JsonEncoder.withIndent('  ').convert(values),
            flush: true,
          );
        }
      }

      try {
        if (model == null || output == null) {
          throw const FormatException('测试入口需要 test-model 和 test-output');
        }
        if (wav != null && source != null) {
          throw const FormatException('请选择 WAV 文件或原生采集中的一种测试');
        }
        await report({'status': 'loadingModel'});
        await controller.initialize();
        controller.settings.mode = 'offline';
        await controller.loadModel(model);
        await controller.toggleOverlay();
        if (wav != null) {
          await controller.processFile(inputPath: wav);
        } else {
          if (source != 'system' && source != 'microphone') {
            throw const FormatException('test-source 仅支持 system 或 microphone');
          }
          final duration = int.tryParse(option('test-duration') ?? '20');
          if (duration == null || duration < 1 || duration > 120) {
            throw const FormatException('test-duration 必须为 1–120 秒');
          }
          controller.settings.source = source!;
          controller.settings.deviceId = '';
          await report({'status': 'requestingCapture', 'source': source});
          await controller.start();
          await report({'status': 'capturing', 'source': source});
          await Future<void>.delayed(Duration(seconds: duration));
          if (controller.running) await controller.stop();
          if (controller.error.isEmpty && controller.receivedFrames == 0) {
            throw StateError('采集未收到音频帧，请检查系统授权和音频输出设备');
          }
        }
        final visible = await controller.native.call<Map>('overlay.status');
        controller.clickThrough = true;
        await controller.configureOverlay();
        final through = await controller.native.call<Map>('overlay.status');
        await controller.native.call<void>('overlay.recover');
        controller.clickThrough = false;
        final recovered = await controller.native.call<Map>('overlay.status');
        await controller.refreshDevices();
        await report({
          'status': controller.error.isEmpty ? 'ok' : 'failed',
          if (controller.error.isNotEmpty) 'message': controller.error,
          'input': wav != null ? 'wav' : source,
          'backend': controller.whisper.backend,
          'rtf': controller.rtf,
          'inferenceMs': controller.finalLatencyMs,
          'receivedFrames': controller.receivedFrames,
          'receivedAudioSeconds': controller.receivedSamples / 16000,
          'peakRms': controller.peakLevel,
          'detectedDrops': controller.droppedFrames,
          'segments': controller.subtitles.segments
              .where((s) => s.isFinal)
              .length,
          'text': exportSubtitles(controller.subtitles.segments),
          'captureAfterStop': await controller.native.call<Map>('audio.status'),
          'permissions': controller.permissions,
          if (Platform.isMacOS)
            'design': await const MethodChannel(
              'lumacaption/design',
            ).invokeMapMethod<String, dynamic>('status'),
          'overlayVisible': visible,
          'overlayClickThrough': through,
          'overlayRecovered': recovered,
        });
      } catch (e) {
        if (controller.running) await controller.stop(emergency: true);
        controller.fail(e);
        await report({'status': 'failed', 'message': controller.error});
      }
    }());
  }
}
