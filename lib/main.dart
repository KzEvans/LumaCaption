import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
  final testMode = option('test-mode') ?? 'offline';
  final onlineTest = option('test-online') == 'true';
  final pacedTest = option('test-paced') == 'true';
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
        if (!['offline', 'realtime', 'text'].contains(testMode)) {
          throw const FormatException('test-mode 仅支持 offline、realtime 或 text');
        }
        if (output == null || (testMode != 'realtime' && model == null)) {
          throw const FormatException('测试入口需要 test-output；本地识别还需要 test-model');
        }
        if (wav != null && source != null) {
          throw const FormatException('请选择 WAV 文件或原生采集中的一种测试');
        }
        if (testMode != 'offline' &&
            (wav == null || !onlineTest || !pacedTest)) {
          throw const FormatException(
            '在线验收仅支持明确指定 WAV、test-online=true 和 test-paced=true',
          );
        }
        await report({'status': 'loadingModel'});
        await controller.initialize();
        controller.settings.mode = testMode;
        controller.settings.sourceLanguage =
            option('test-source-language') ??
            controller.settings.sourceLanguage;
        controller.settings.targetLanguage =
            option('test-target-language') ??
            controller.settings.targetLanguage;
        final modelWatch = Stopwatch()..start();
        if (testMode == 'realtime') {
          controller.settings.modelPath = '';
          controller.settings.cloudTranscription = true;
        } else {
          await controller.loadModel(model!);
        }
        modelWatch.stop();
        controller.measureSession = pacedTest;
        await controller.toggleOverlay();
        if (wav != null) {
          await controller.processFile(
            inputPath: wav,
            paced: pacedTest,
            allowOnline: onlineTest,
          );
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
          'mode': testMode,
          'paced': pacedTest,
          'sourceLanguage': controller.settings.sourceLanguage,
          'targetLanguage': controller.settings.targetLanguage,
          if (testMode == 'realtime')
            'translationModel': controller.settings.modelId,
          if (testMode == 'text')
            'translationModel': controller.settings.textModel,
          'modelLoadMs': testMode == 'realtime'
              ? null
              : modelWatch.elapsedMilliseconds,
          if (testMode != 'realtime')
            'modelPreparation': controller.modelPreparationTiming,
          if (controller.sessionTiming != null)
            'timing': controller.sessionTiming!.report(),
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
          'finalSubtitles': controller.subtitles.segments
              .where((s) => s.generation == controller.generation && s.isFinal)
              .map(
                (s) => {
                  'id': s.segmentId,
                  'original': s.original,
                  'translation': s.translation,
                  'startUs': s.startUs,
                  'endUs': s.endUs,
                  'engine': s.engine,
                  'error': s.error,
                },
              )
              .toList(),
          'captureAfterStop': await controller.native.call<Map>('audio.status'),
          'permissions': controller.permissions,
          'overlayVisible': visible,
          'overlayClickThrough': through,
          'overlayRecovered': recovered,
        });
      } catch (e) {
        if (controller.running) await controller.stop(emergency: true);
        controller.fail(e);
        await report({
          'status': 'failed',
          'mode': testMode,
          'message': controller.error,
          if (controller.sessionTiming != null)
            'timing': controller.sessionTiming!.report(),
        });
      }
    }());
  }
}
