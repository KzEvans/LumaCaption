import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/models/model_manager.dart';

void main() {
  test('resume validates Range and verifies SHA256 before install', () async {
    final dir = await Directory.systemTemp.createTemp('luma-model-');
    final payload = List<int>.generate(2048, (i) => i % 256)
      ..setRange(0, 4, [0x6c, 0x6d, 0x67, 0x67]);
    final hash = sha256.convert(payload).toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var sawRange = false;
    final sub = server.listen((r) async {
      sawRange = r.headers.value('range') == 'bytes=512-';
      r.response.statusCode = 206;
      r.response.headers.set('content-range', 'bytes 512-2047/2048');
      r.response.add(payload.sublist(512));
      await r.response.close();
    });
    final m = ModelEntry({
      'modelId': 'test',
      'name': 'Test',
      'url': 'http://127.0.0.1:${server.port}/model',
      'checksum': hash,
      'bytes': 2048,
      'memoryMB': 1,
    });
    final manager = ModelManager(dir.path, freeBytes: (_) async => 100000000)
      ..catalog = [m];
    await File('${manager.path(m)}.part').writeAsBytes(payload.sublist(0, 512));
    try {
      await manager.download(m);
      expect(sawRange, true);
      expect(manager.error, isNull);
      expect(await File(manager.path(m)).readAsBytes(), payload);
      expect(manager.installed, contains('test'));
      expect(
        jsonDecode(
          await File('${manager.path(m)}.json').readAsString(),
        )['sourceVerified'],
        true,
      );
    } finally {
      manager.dispose();
      await sub.cancel();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
  test('Range unsupported replaces partial instead of fake append', () async {
    final dir = await Directory.systemTemp.createTemp('luma-model-');
    final bytes = List<int>.filled(1024, 0)
      ..setRange(0, 4, [0x6c, 0x6d, 0x67, 0x67]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((r) async {
      r.response.add(bytes);
      await r.response.close();
    });
    final m = ModelEntry({
      'modelId': 'test',
      'name': 'Test',
      'url': 'http://127.0.0.1:${server.port}/m',
      'checksum': sha256.convert(bytes).toString(),
      'bytes': 1024,
      'memoryMB': 1,
    });
    final manager = ModelManager(dir.path, freeBytes: (_) async => 100000000)
      ..catalog = [m];
    await File('${manager.path(m)}.part').writeAsBytes([1, 2, 3]);
    try {
      await manager.download(m);
      expect(manager.error, isNull);
      expect(await File(manager.path(m)).readAsBytes(), bytes);
    } finally {
      manager.dispose();
      await sub.cancel();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
  test('corrupt hash never installed; unsupported import rejected', () async {
    final dir = await Directory.systemTemp.createTemp('luma-model-');
    final f = File('${dir.path}/bad.bin');
    await f.writeAsBytes(List.filled(1024, 0));
    try {
      await expectLater(verifyModel(f.path), throwsFormatException);
      final bytes = List<int>.filled(1024, 0)
        ..setRange(0, 4, [0x6c, 0x6d, 0x67, 0x67]);
      await f.writeAsBytes(bytes);
      await expectLater(
        verifyModel(f.path, expectedSha256: '0' * 64),
        throwsFormatException,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('complete part verifies without a network request', () async {
    final dir = await Directory.systemTemp.createTemp('luma-model-');
    final bytes = List<int>.filled(1024, 0)
      ..setRange(0, 4, [0x6c, 0x6d, 0x67, 0x67]);
    final m = ModelEntry({
      'modelId': 'test',
      'name': 'Test',
      'url': 'http://127.0.0.1:1/unavailable',
      'checksum': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
      'memoryMB': 1,
    });
    final manager = ModelManager(dir.path)..catalog = [m];
    try {
      await File('${manager.path(m)}.part').writeAsBytes(bytes);
      await manager.download(m);
      expect(manager.error, isNull);
      expect(await File(manager.path(m)).readAsBytes(), bytes);
      expect(await File('${manager.path(m)}.part').exists(), false);
    } finally {
      manager.dispose();
      await dir.delete(recursive: true);
    }
  });
  test('corrupt download is discarded and retry starts from zero', () async {
    final dir = await Directory.systemTemp.createTemp('luma-model-');
    final bytes = List<int>.filled(1024, 0)
      ..setRange(0, 4, [0x6c, 0x6d, 0x67, 0x67]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    final ranges = <String?>[];
    final sub = server.listen((r) async {
      ranges.add(r.headers.value('range'));
      final body = List<int>.from(bytes);
      if (attempts++ == 0) body[900] = 1;
      r.response.add(body);
      await r.response.close();
    });
    final m = ModelEntry({
      'modelId': 'test',
      'name': 'Test',
      'url': 'http://127.0.0.1:${server.port}/model',
      'checksum': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
      'memoryMB': 1,
    });
    final manager = ModelManager(dir.path)..catalog = [m];
    try {
      await manager.download(m);
      expect(manager.error, contains('SHA256'));
      expect(await File(manager.path(m)).exists(), false);
      expect(await File('${manager.path(m)}.part').exists(), false);
      await manager.download(m);
      expect(manager.error, isNull);
      expect(ranges, [null, null]);
      expect(await File(manager.path(m)).readAsBytes(), bytes);
    } finally {
      manager.dispose();
      await sub.cancel();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
