import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class ModelEntry {
  ModelEntry(this.data);
  final Map<String, dynamic> data;
  String get id => data['modelId'] as String;
  String get name => data['name'] as String;
  String get url => data['url'] as String;
  String get checksum => data['checksum'] as String;
  int get bytes => data['bytes'] as int;
  int get memoryMB => data['memoryMB'] as int;
  String get filename => 'ggml-$id.bin';
}

class ModelManager extends ChangeNotifier {
  ModelManager(this.directory, {this.freeBytes});
  String directory;
  final Future<int?> Function(String)? freeBytes;
  List<ModelEntry> catalog = [];
  String? activeId, error;
  int received = 0, total = 0;
  double bytesPerSecond = 0;
  bool downloading = false, paused = false, verifying = false;
  bool _cancelled = false;
  HttpClient? _client;
  Future<void>? _job;
  final Set<String> installed = {};
  Future<void> initialize() async {
    final raw =
        jsonDecode(await rootBundle.loadString('assets/models.json'))
            as Map<String, dynamic>;
    catalog = (raw['models'] as List)
        .map((dynamic e) => ModelEntry(e as Map<String, dynamic>))
        .toList();
    await refresh();
  }

  String path(ModelEntry model) => p.join(directory, model.filename);
  Future<void> refresh() async {
    await Directory(directory).create(recursive: true);
    installed.clear();
    for (final m in catalog) {
      final f = File(path(m));
      if (await f.exists() && await f.length() == m.bytes) installed.add(m.id);
    }
    notifyListeners();
  }

  Future<void> download(ModelEntry m) async {
    if (downloading || verifying) throw StateError('请等待当前下载结束');
    activeId = m.id;
    error = null;
    paused = false;
    _cancelled = false;
    downloading = true;
    received = 0;
    total = m.bytes;
    bytesPerSecond = 0;
    notifyListeners();
    _job = _download(m);
    await _job;
  }

  Future<void> _download(ModelEntry m) async {
    final partial = File('${path(m)}.part');
    IOSink? sink;
    try {
      await Directory(directory).create(recursive: true);
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > m.bytes) {
        await partial.delete();
        offset = 0;
      }
      received = offset;
      // A stopped checksum step may leave a complete, valid part file.
      // Verify locally rather than requesting bytes=size- from the server.
      if (offset == m.bytes) {
        await _install(m, partial);
        return;
      }
      final available = await freeBytes?.call(directory);
      if (available != null &&
          available < m.bytes - offset + 32 * 1024 * 1024) {
        throw const FileSystemException('存储空间不足');
      }
      _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      final request = await _client!.getUrl(Uri.parse(m.url));
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == 206) {
        final range = response.headers.value(HttpHeaders.contentRangeHeader);
        if (range == null ||
            !range.startsWith('bytes $offset-') ||
            !range.endsWith('/${m.bytes}')) {
          throw const HttpException('下载服务器返回错误续传范围');
        }
      } else if (response.statusCode == 200) {
        offset = 0;
      } else {
        throw HttpException('模型下载 HTTP ${response.statusCode}');
      }
      received = offset;
      sink = partial.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      final watch = Stopwatch()..start();
      var lastUpdate = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (paused || _cancelled) break;
        if (received + chunk.length > m.bytes) {
          throw const FormatException('模型大小超出可信目录记录');
        }
        sink.add(chunk);
        received += chunk.length;
        if (watch.elapsedMilliseconds - lastUpdate >= 150) {
          bytesPerSecond =
              (received - offset) / (watch.elapsedMilliseconds / 1000);
          lastUpdate = watch.elapsedMilliseconds;
          await sink.flush();
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (paused || _cancelled) return;
      if (received != m.bytes) throw const HttpException('下载不完整，可继续或重新下载');
      await _install(m, partial);
    } catch (e) {
      // Keeping corrupt bytes would make every subsequent resume fail again.
      if (e is FormatException && await partial.exists()) {
        await partial.delete();
      }
      if (!paused && !_cancelled) {
        error = e is FileSystemException ? e.message : e.toString();
      }
    } finally {
      await sink?.close();
      _client?.close(force: true);
      _client = null;
      downloading = false;
      verifying = false;
      if (_cancelled && await partial.exists()) await partial.delete();
      await refresh();
    }
  }

  Future<void> _install(ModelEntry m, File partial) async {
    verifying = true;
    downloading = false;
    notifyListeners();
    await verifyModel(partial.path, expectedSha256: m.checksum);
    if (_cancelled) return;
    final destination = File(path(m));
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
    await File('${destination.path}.json').writeAsString(
      jsonEncode({...m.data, 'sourceVerified': true}),
      flush: true,
    );
  }

  void pause() {
    if (!downloading) return;
    paused = true;
    _client?.close(force: true);
    notifyListeners();
  }

  Future<void> cancel() async {
    _cancelled = true;
    paused = false;
    _client?.close(force: true);
    await _job;
    activeId = null;
    notifyListeners();
  }

  Future<void> remove(ModelEntry m) async {
    if (activeId == m.id && (downloading || verifying)) await cancel();
    for (final suffix in ['', '.part', '.json']) {
      final f = File('${path(m)}$suffix');
      if (await f.exists()) await f.delete();
    }
    await refresh();
  }

  Future<String> importFile(String source) async {
    await verifyModel(source);
    final filename = p.basename(source);
    if (!filename.endsWith('.bin')) {
      throw const FormatException('仅支持 whisper.cpp GGML .bin');
    }
    final destination = p.join(directory, filename);
    await Directory(directory).create(recursive: true);
    if (p.equals(p.absolute(source), p.absolute(destination))) {
      return destination;
    }
    if (await File(destination).exists()) throw StateError('目录已有同名文件，请先删除或重命名');
    final temp = await File(source).copy('$destination.part');
    await temp.rename(destination);
    await File('$destination.json').writeAsString(
      jsonEncode({
        'engine': 'whisper.cpp',
        'format': 'ggml',
        'sourceVerified': false,
        'imported': true,
      }),
    );
    await refresh();
    return destination;
  }

  @override
  void dispose() {
    _client?.close(force: true);
    super.dispose();
  }
}

Future<void> verifyModel(String path, {String? expectedSha256}) async {
  await Isolate.run(() async {
    final file = File(path);
    if (await file.length() < 1024) throw const FormatException('模型文件过小');
    final header = await file.open();
    List<int> magic;
    try {
      magic = await header.read(4);
    } finally {
      await header.close();
    }
    if (magic.length != 4 ||
        magic[0] != 0x6c ||
        magic[1] != 0x6d ||
        magic[2] != 0x67 ||
        magic[3] != 0x67) {
      throw const FormatException('不是兼容的 whisper.cpp GGML 模型（不支持 GGUF/ONNX）');
    }
    if (expectedSha256 != null) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != expectedSha256) {
        throw const FormatException('SHA256 校验失败，请重新下载');
      }
    }
  });
}
