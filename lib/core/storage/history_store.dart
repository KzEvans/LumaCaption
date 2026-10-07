import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../subtitles/subtitles.dart';

class HistoryStore {
  HistoryStore(this.directory);
  final String directory;
  File get _file => File(p.join(directory, 'history.json'));

  Future<List<SubtitleSegment>> load({int capacity = 2000}) async {
    if (!await _file.exists()) {
      final legacy = File(p.join(directory, 'history.txt'));
      if (!await legacy.exists()) return [];
      final text = await legacy.readAsString();
      if (text.isEmpty) return [];
      return [
        SubtitleSegment(
          generation: 0,
          segmentId: 'saved-text',
          original: text,
          isFinal: true,
          engine: '已保存文本 · 无音频时间',
        ),
      ];
    }
    final data = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
    if (data['version'] != 1) throw const FormatException('历史文件版本不受支持');
    final rows = data['segments'] as List;
    return rows.skip(rows.length > capacity ? rows.length - capacity : 0).map((
      row,
    ) {
      final m = row as Map<String, dynamic>;
      return SubtitleSegment(
        generation: m['generation'] as int,
        segmentId: m['segmentId'] as String,
        revision: m['revision'] as int? ?? 0,
        startUs: m['startUs'] as int?,
        endUs: m['endUs'] as int?,
        original: m['original'] as String? ?? '',
        translation: m['translation'] as String? ?? '',
        engine: m['engine'] as String? ?? '',
        isFinal: true,
      );
    }).toList();
  }

  Future<void> save(List<SubtitleSegment> segments) async {
    await Directory(directory).create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'version': 1,
        'segments': segments
            .where((s) => s.isFinal)
            .map(
              (s) => {
                'generation': s.generation,
                'segmentId': s.segmentId,
                'revision': s.revision,
                'startUs': s.startUs,
                'endUs': s.endUs,
                'original': s.original,
                'translation': s.translation,
                'engine': s.engine,
              },
            )
            .toList(),
      }),
      flush: true,
    );
    if (Platform.isWindows && await _file.exists()) await _file.delete();
    await temp.rename(_file.path);
  }

  Future<void> clear() async {
    for (final name in ['history.json', 'history.json.tmp', 'history.txt']) {
      final file = File(p.join(directory, name));
      if (await file.exists()) await file.delete();
    }
  }
}
