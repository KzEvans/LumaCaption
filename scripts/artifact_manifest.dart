import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    throw ArgumentError(
      'Usage: artifact_manifest.dart <file> <platform> <arch> [app]',
    );
  }
  final file = File(args[0]);
  final platform = args[1];
  Map<String, dynamic>? vadModel;
  if (platform == 'macos' && args.length > 3) {
    final vadDirectory = p.join(args[3], 'Contents', 'Resources', 'vad');
    final metadataFile = File(p.join(vadDirectory, 'manifest.json'));
    if (await metadataFile.exists()) {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final weights = File(p.join(vadDirectory, metadata['file'] as String));
      final weightsDigest = await sha256.bind(weights.openRead()).first;
      if (await weights.length() != metadata['bytes'] ||
          weightsDigest.toString() != metadata['sha256']) {
        throw StateError('Bundled VAD model failed size/SHA256 verification');
      }
      vadModel = {
        'bundled': true,
        'modelId': metadata['modelId'],
        'revision': metadata['revision'],
        'bytes': metadata['bytes'],
        'sha256': metadata['sha256'],
        'license': metadata['license'],
        'source': metadata['source'],
        'resourcePath': 'Contents/Resources/vad/${metadata['file']}',
      };
    }
  }
  final signature = <String, dynamic>{
    'status': 'unsigned',
    'notarization': platform == 'macos'
        ? 'notSubmittedByBuild'
        : 'notApplicable',
  };
  if (platform == 'macos' && args.length > 3) {
    final result = await Process.run('codesign', [
      '-dv',
      '--verbose=4',
      args[3],
    ]);
    if (result.exitCode != 0) throw StateError('Cannot inspect app signature');
    final details = '${result.stdout}\n${result.stderr}';
    signature['status'] = details.contains('Signature=adhoc')
        ? 'ad-hoc'
        : 'certificateSigned';
    final authority = RegExp(
      r'^Authority=(.+)$',
      multiLine: true,
    ).firstMatch(details);
    if (authority != null) signature['authority'] = authority[1];
    signature['hardenedRuntime'] = details.contains('(runtime)');
  }
  final revision = await Process.run('git', ['rev-parse', '--verify', 'HEAD']);
  final changes = await Process.run('git', ['status', '--porcelain']);
  final pubspec = await File('pubspec.yaml').readAsString();
  final version = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec)![1];
  final digest = await sha256.bind(file.openRead()).first;
  await File('${file.path}.artifact.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'file': p.basename(file.path),
      'version': version,
      'platform': platform,
      'architecture': args[2],
      'minimumOS': platform == 'macos' ? '13.3' : 'Windows 10 22H2 (19045)',
      'builtAtUtc': (await file.lastModified()).toUtc().toIso8601String(),
      'bytes': await file.length(),
      'sha256': digest.toString(),
      'signature': signature,
      'sourceRevision': revision.exitCode == 0
          ? '${revision.stdout}'.trim()
          : null,
      'uncommittedSource': '${changes.stdout}'.trim().isNotEmpty,
      'toolchain': {
        'flutter': '3.47.6',
        'dart': Platform.version.split(' ').first,
        'whisper.cpp': '1.8.1',
      },
      'inferenceBackend': platform == 'macos'
          ? 'Metal with CPU fallback'
          : 'CPU',
      if (platform == 'macos') 'metalKernels': 'embeddedSourceInNativeLibrary',
      'whisperAbiVersion': 2,
      'modelWeightsBundled': false,
      'modelWeightsBundledScope': 'Whisper ASR',
      'vadModel': ?vadModel,
      'platformAcceptance':
          'See docs/testing.md; a build does not prove capture acceptance',
    }),
    flush: true,
  );
}
