import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'controller.dart';

/// AppKit owns the complete macOS interface; Dart owns application state.
/// Only view data crosses this channel. PCM and stored credentials never do.
class MacWorkbenchCoordinator {
  MacWorkbenchCoordinator(this.c, {MethodChannel? channel})
    : channel = channel ?? const MethodChannel('lumacaption/design') {
    this.channel.setMethodCallHandler((call) async {
      if (call.method != 'action') throw MissingPluginException();
      try {
        await dispatch(Map<String, dynamic>.from(call.arguments as Map));
        return null;
      } catch (e) {
        c.fail(e);
        throw PlatformException(code: 'action', message: c.error);
      } finally {
        sync();
      }
    });
    c.addListener(_schedule);
    _schedule();
  }
  final AppController c;
  final MethodChannel channel;
  Timer? _timer;
  String? _last;

  Map<String, dynamic> snapshot() {
    final m = c.models;
    return {
      'initialized': c.initialized,
      'settings': c.settings.toJson(),
      'running': c.running,
      'paused': c.paused,
      'busy': c.busy,
      'loadingModel': c.loadingModel,
      'overlayVisible': c.overlayVisible,
      'clickThrough': c.clickThrough,
      'status': c.status,
      'error': c.error,
      'privacy': c.privacy,
      'modeName': c.modeName,
      'selectedModel': c.selectedModel,
      'generation': c.generation,
      'level': c.level,
      'rtf': c.rtf,
      'latencyMs': c.finalLatencyMs,
      'droppedFrames': c.droppedFrames,
      'devices': c.devices,
      'permissions': c.permissions,
      'diagnostics': c.diagnostics.toList(),
      'modelDirectory': m?.directory ?? '',
      'download': {
        'activeId': m?.activeId,
        'running': m?.downloading ?? false,
        'paused': m?.paused ?? false,
        'verifying': m?.verifying ?? false,
        'received': m?.received ?? 0,
        'total': m?.total ?? 0,
        'speed': m?.bytesPerSecond ?? 0,
        'error': m?.error,
      },
      'models':
          m?.catalog
              .map(
                (e) => {
                  'id': e.id,
                  'name': e.name,
                  'bytes': e.bytes,
                  'memoryMB': e.memoryMB,
                  'installed': m.installed.contains(e.id),
                  'selected': c.settings.modelPath == m.path(e),
                },
              )
              .toList() ??
          [],
      'segments': c.subtitles.segments
          .map(
            (s) => {
              'generation': s.generation,
              'id': s.segmentId,
              'revision': s.revision,
              'startUs': s.startUs,
              'endUs': s.endUs,
              'original': s.original,
              'stableOriginal': s.stableOriginal,
              'translation': s.translation + s.stash,
              'translationPreview': s.stash.isNotEmpty,
              'final': s.isFinal,
              'engine': s.engine,
              'error': s.error,
            },
          )
          .toList(),
    };
  }

  static const _editable = {
    'mode',
    'source',
    'deviceId',
    'endpoint',
    'workspace',
    'region',
    'modelId',
    'sourceLanguage',
    'targetLanguage',
    'textProvider',
    'textBaseUrl',
    'textModel',
    'proxy',
    'theme',
    'display',
    'fontSize',
    'opacity',
    'cloudTranscription',
  };
  static const _appearance = {'theme', 'display', 'fontSize', 'opacity'};
  Future<void> configure(Map<String, dynamic> patch) async {
    if (!patch.keys.every(_editable.contains)) {
      throw const FormatException('不支持的配置项');
    }
    if ((c.running || c.busy) && !patch.keys.every(_appearance.contains)) {
      throw StateError('请先停止当前会话再修改输入与翻译服务');
    }
    for (final (key, choices) in [
      ('mode', ['realtime', 'text', 'offline']),
      ('source', ['system', 'microphone']),
      ('theme', ['system', 'light', 'dark']),
      ('display', ['bilingual', 'original', 'translation']),
      ('textProvider', ['qwen', 'openai']),
    ]) {
      if (patch.containsKey(key) && !choices.contains(patch[key])) {
        throw FormatException('无效配置：$key');
      }
    }
    c.settings.apply({...c.settings.toJson(), ...patch});
    if (patch.keys.any(_appearance.contains)) {
      await c.configureOverlay();
    } else {
      await c.save();
    }
  }

  Future<void> dispatch(Map<String, dynamic> a) async {
    final patch = Map<String, dynamic>.from(a['patch'] as Map? ?? {});
    switch (a['action']) {
      case 'configure':
        await configure(patch);
      case 'toggleStart':
        await (c.running ? c.stop() : c.start());
      case 'stop':
        await c.stop();
      case 'emergency':
        await c.stop(emergency: true);
      case 'pause':
        if (c.running && !c.busy) await c.pause();
      case 'toggleOverlay':
        await c.toggleOverlay();
      case 'recoverOverlay':
        await c.native.call<void>('overlay.recover');
        c.clickThrough = false;
        c.overlayVisible = true;
        await c.save();
      case 'clickThrough':
        c.clickThrough = a['value'] == true;
        await c.configureOverlay();
      case 'saveProvider':
        await configure(patch);
        final key = a['key'] as String? ?? '';
        if (key.isNotEmpty) {
          await c.saveKey(key, text: c.settings.mode == 'text');
        }
      case 'testConnection':
        await c.testConnection();
      case 'importModel':
        _requireStopped();
        await c.importModel();
      case 'changeModelDirectory':
        _requireStopped();
        await c.changeModelDirectory();
      case 'openModels':
        await c.native.call<void>('openPath', {
          'path': c.models?.directory ?? '',
        });
      case 'pauseDownload':
        c.models?.pause();
      case 'cancelDownload':
        await c.models?.cancel();
      case 'loadModel' || 'downloadModel' || 'removeModel':
        final m = c.models;
        final model = m?.catalog.where((e) => e.id == a['id']).firstOrNull;
        if (m == null || model == null) throw const FormatException('未知模型');
        if (a['action'] == 'downloadModel') {
          await m.download(model);
        } else {
          _requireStopped();
          if (a['action'] == 'loadModel') {
            await c.loadModel(m.path(model));
          } else {
            if (c.settings.modelPath == m.path(model)) {
              c.whisper.close();
              c.settings.modelPath = '';
              await c.save();
            }
            await m.remove(model);
          }
        }
      case 'refresh':
        await c.refreshDevices();
      case 'processFile':
        await c.processFile();
      case 'persistHistory':
        await c.setPersistHistory(a['value'] == true);
      case 'clearHistory':
        _requireStopped();
        await c.clearHistory();
      case 'export':
        final format = a['format'] as String? ?? 'txt';
        final display = a['display'] as String? ?? 'bilingual';
        if (!['txt', 'srt', 'vtt'].contains(format) ||
            !['bilingual', 'original', 'translation'].contains(display)) {
          throw const FormatException('不支持的字幕导出格式');
        }
        await c.export(format, display, session: a['session'] as int?);
      case 'clearError':
        c.clearError();
      default:
        throw const FormatException('不支持的操作');
    }
  }

  void _requireStopped() {
    if (c.running || c.busy || c.loadingModel) throw StateError('请先停止当前会话');
  }

  void _schedule() {
    _timer ??= Timer(const Duration(milliseconds: 50), () {
      _timer = null;
      sync();
    });
  }

  void sync() {
    final state = snapshot();
    final signature = jsonEncode(state);
    if (_last == signature) return;
    _last = signature;
    unawaited(
      channel.invokeMethod<void>('sync', state).catchError((Object e) {
        // Transport failures should not recursively publish another failed state.
        _last = null;
      }),
    );
  }

  void dispose() {
    _timer?.cancel();
    c.removeListener(_schedule);
    channel.setMethodCallHandler(null);
  }
}
