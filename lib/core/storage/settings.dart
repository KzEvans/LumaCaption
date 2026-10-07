import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class AppSettings {
  String mode = 'realtime',
      source = 'system',
      deviceId = '',
      modelPath = '',
      modelDirectory = '';
  String endpoint = '',
      workspace = '',
      region = 'cn-beijing',
      modelId = 'qwen3.8-livetranslate-flash-realtime',
      sourceLanguage = 'auto',
      targetLanguage = 'zh';
  String textProvider = 'qwen',
      textBaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      textModel = 'qwen-mt-flash';
  String proxy = '', theme = 'system', display = 'bilingual';
  double fontSize = 28, opacity = 0.8;
  bool cloudTranscription = false, persistHistory = false;
  Map<String, dynamic> toJson() => {
    'mode': mode,
    'source': source,
    'deviceId': deviceId,
    'modelPath': modelPath,
    'modelDirectory': modelDirectory,
    'endpoint': endpoint,
    'workspace': workspace,
    'region': region,
    'modelId': modelId,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'textProvider': textProvider,
    'textBaseUrl': textBaseUrl,
    'textModel': textModel,
    'proxy': proxy,
    'theme': theme,
    'display': display,
    'fontSize': fontSize,
    'opacity': opacity,
    'cloudTranscription': cloudTranscription,
    'persistHistory': persistHistory,
  };
  void apply(Map<String, dynamic> m) {
    mode = m['mode'] as String? ?? mode;
    source = m['source'] as String? ?? source;
    deviceId = m['deviceId'] as String? ?? '';
    modelPath = m['modelPath'] as String? ?? '';
    modelDirectory = m['modelDirectory'] as String? ?? '';
    endpoint = m['endpoint'] as String? ?? '';
    workspace = m['workspace'] as String? ?? '';
    region = m['region'] as String? ?? region;
    modelId = m['modelId'] as String? ?? modelId;
    sourceLanguage = m['sourceLanguage'] as String? ?? 'auto';
    targetLanguage = m['targetLanguage'] as String? ?? 'zh';
    textProvider = m['textProvider'] as String? ?? 'qwen';
    textBaseUrl = m['textBaseUrl'] as String? ?? textBaseUrl;
    textModel = m['textModel'] as String? ?? textModel;
    proxy = m['proxy'] as String? ?? '';
    theme = m['theme'] as String? ?? 'system';
    display = m['display'] as String? ?? 'bilingual';
    fontSize = (m['fontSize'] as num? ?? 28).toDouble().clamp(14, 72);
    opacity = (m['opacity'] as num? ?? 0.8).toDouble().clamp(0.1, 1);
    cloudTranscription = m['cloudTranscription'] == true;
    persistHistory = m['persistHistory'] == true;
  }

  static String credentialAccount(Uri uri) =>
      'lumacaption:${uri.scheme}:${uri.host}:${uri.hasPort ? uri.port : 443}';
}

class SettingsStore {
  SettingsStore(this.directory);
  final String directory;
  Future<AppSettings> load() async {
    final s = AppSettings();
    final f = File(p.join(directory, 'settings.json'));
    if (await f.exists()) {
      try {
        s.apply(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      } on FormatException {
        /* recover invalid user settings */
      }
    }
    return s;
  }

  Future<void> save(AppSettings s) async {
    await Directory(directory).create(recursive: true);
    final f = File(p.join(directory, 'settings.json.tmp'));
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(s.toJson()),
      flush: true,
    );
    final dest = p.join(directory, 'settings.json');
    if (Platform.isWindows && await File(dest).exists()) {
      await File(dest).delete();
    }
    await f.rename(dest);
  }
}
