import 'realtime_parser.dart';
import 'translation_models.dart';

class _Segment {
  _Segment(this.event, this.itemId, this.responseId);
  final TranslationEvent event;
  final String itemId;
  final String? responseId;
}

/// Qwen 3.8 appends deltas; unlike 3.5, these are never text snapshots.
/// text.done supplies complete text, while response.done confirms whether that
/// text belongs to a completed or interrupted response.
class Qwen38Parser implements RealtimeParser {
  Qwen38Parser({
    required this.generation,
    this.modelId = 'qwen3.8-livetranslate-flash-realtime',
  });
  final int generation;
  final String modelId;
  final _segments = <String, _Segment>{};
  final _seen = <String>{};
  final _ranges = <String, (Duration?, Duration?)>{};
  final _sourceForOutput = <String, String>{};
  final _responseStatus = <String, String>{};
  final _textEnded = <String>{};

  @override
  List<TranslationEvent> accept(Map<String, dynamic> event) {
    final eventId = event['event_id'];
    if (eventId is String && !_seen.add(eventId)) return const [];
    if (_seen.length > 2048) _seen.remove(_seen.first);
    final type = event['type'];
    if (type == 'input_audio_buffer.speech_started' ||
        type == 'input_audio_buffer.speech_stopped') {
      final item = _id(event['item_id']);
      final previous = _ranges[item] ?? (null, null);
      _ranges[item] = (
        _milliseconds(event['audio_start_ms']) ?? previous.$1,
        _milliseconds(event['audio_end_ms']) ?? previous.$2,
      );
      if (_ranges.length > 256) _ranges.remove(_ranges.keys.first);
      return _refresh(item);
    }
    if (type == 'conversation.item.created') {
      final item = event['item'];
      final source = event['previous_item_id'];
      if (item is Map && item['role'] == 'assistant' && source is String) {
        _sourceForOutput[_id(item['id'])] = _id(source);
        if (_sourceForOutput.length > 256) {
          _sourceForOutput.remove(_sourceForOutput.keys.first);
        }
        return _refresh(source);
      }
      return const [];
    }
    final isSource =
        type == 'conversation.item.input_audio_transcription.delta' ||
        type == 'conversation.item.input_audio_transcription.completed';
    final isTranslation =
        type == 'response.text.delta' || type == 'response.text.done';
    if (isSource || isTranslation) {
      final item = _id(event['item_id']);
      final response = isTranslation ? _id(event['response_id']) : null;
      final index = event['content_index'] ?? 0;
      if (index is! int || index < 0) {
        throw const TranslationFailure('protocol', '翻译事件的内容索引无效。');
      }
      final id = isSource ? 'source/$item/$index' : '$response/$item/$index';
      final old = _segments[id]?.event;
      if (old?.isFinal == true ||
          old?.interrupted == true ||
          _textEnded.contains(id) ||
          (response != null && _responseStatus.containsKey(response))) {
        return const [];
      }
      final complete =
          type == 'response.text.done' ||
          type == 'conversation.item.input_audio_transcription.completed';
      final piece = _text(
        event[complete ? (isSource ? 'transcript' : 'text') : 'delta'],
      );
      final text = complete
          ? piece
          : '${isSource ? old?.original ?? '' : old?.text ?? ''}$piece';
      if (text.length > 65536) {
        throw const TranslationFailure('response_limit', '字幕长度超过限制。');
      }
      if (complete && isTranslation) {
        _textEnded.add(id);
        if (_textEnded.length > 256) _textEnded.remove(_textEnded.first);
      }
      final next = _make(
        id,
        item,
        response,
        text: isSource ? '' : text,
        original: isSource ? text : _original(item),
        isSource: isSource,
        isFinal: isSource && complete,
      );
      _save(next, item, response);
      return [next, if (isSource) ..._refresh(item)];
    }
    if (type == 'conversation.item.input_audio_transcription.failed') {
      final item = _id(event['item_id']);
      return _markInterrupted(
        (segment) => segment.event.isSource && segment.itemId == item,
      );
    }
    if (type == 'response.done') {
      final response = event['response'];
      if (response is! Map) {
        throw const TranslationFailure('protocol', '翻译完成事件缺少响应信息。');
      }
      final responseId = _id(response['id']);
      final status = response['status'];
      if (status is! String) {
        throw const TranslationFailure('protocol', '翻译完成事件缺少响应状态。');
      }
      if (_responseStatus.containsKey(responseId)) return const [];
      _responseStatus[responseId] = status;
      if (_responseStatus.length > 256) {
        _responseStatus.remove(_responseStatus.keys.first);
      }
      if (status != 'completed') {
        return _markInterrupted((segment) => segment.responseId == responseId);
      }
      final updates = <TranslationEvent>[];
      final output = response['output'];
      if (output is List) {
        for (final item in output.whereType<Map>()) {
          final content = item['content'];
          if (content is! List) continue;
          final itemId = _id(item['id']);
          for (var index = 0; index < content.length; index++) {
            final part = content[index];
            if (part is! Map || part['type'] != 'text') continue;
            final id = '$responseId/$itemId/$index';
            final next = _make(
              id,
              itemId,
              responseId,
              text: _text(part['text']),
              original: _original(itemId),
              isFinal: true,
            );
            _save(next, itemId, responseId);
            updates.add(next);
          }
        }
      }
      // Some responses omit output but still explicitly report completion.
      // Finalize the received text without inventing missing text or timing.
      for (final segment in _segments.values.toList()) {
        if (segment.responseId != responseId ||
            segment.event.isFinal ||
            segment.event.interrupted) {
          continue;
        }
        final next = _copy(segment, isFinal: true);
        _save(next, segment.itemId, segment.responseId);
        updates.add(next);
      }
      return updates;
    }
    return const [];
  }

  String? _original(String outputItem) {
    final source = _sourceForOutput[outputItem];
    return source == null
        ? null
        : _segments['source/$source/0']?.event.original;
  }

  TranslationEvent _make(
    String id,
    String item,
    String? response, {
    required String text,
    String? original,
    bool isSource = false,
    required bool isFinal,
    bool interrupted = false,
  }) {
    final range = _ranges[isSource ? item : _sourceForOutput[item]];
    return TranslationEvent(
      generation: generation,
      segmentId: id,
      revision: (_segments[id]?.event.revision ?? 0) + 1,
      text: text,
      original: original,
      isSource: isSource,
      isFinal: isFinal,
      interrupted: interrupted,
      audioStart: range?.$1,
      audioEnd: range?.$2,
      engine: modelId,
    );
  }

  TranslationEvent _copy(
    _Segment segment, {
    bool? isFinal,
    bool? interrupted,
  }) => _make(
    segment.event.segmentId,
    segment.itemId,
    segment.responseId,
    text: segment.event.text,
    original: segment.event.isSource
        ? segment.event.original
        : _original(segment.itemId) ?? segment.event.original,
    isSource: segment.event.isSource,
    isFinal: isFinal ?? segment.event.isFinal,
    interrupted: interrupted ?? segment.event.interrupted,
  );

  List<TranslationEvent> _refresh(String sourceItem) {
    final updates = <TranslationEvent>[];
    for (final segment in _segments.values.toList()) {
      if (!(segment.event.isSource && segment.itemId == sourceItem) &&
          _sourceForOutput[segment.itemId] != sourceItem) {
        continue;
      }
      final old = segment.event;
      final next = _copy(segment);
      if (old.original == next.original &&
          old.audioStart == next.audioStart &&
          old.audioEnd == next.audioEnd) {
        continue;
      }
      _save(next, segment.itemId, segment.responseId);
      updates.add(next);
    }
    return updates;
  }

  @override
  List<TranslationEvent> interrupt() =>
      _markInterrupted((segment) => !segment.event.isFinal);

  List<TranslationEvent> _markInterrupted(bool Function(_Segment) include) {
    final updates = <TranslationEvent>[];
    for (final segment in _segments.values.toList()) {
      if (!include(segment) || segment.event.interrupted) continue;
      final next = _copy(segment, isFinal: false, interrupted: true);
      _save(next, segment.itemId, segment.responseId);
      updates.add(next);
    }
    return updates;
  }

  void _save(TranslationEvent event, String item, String? response) {
    if (_segments.length >= 256 && !_segments.containsKey(event.segmentId)) {
      final completed = _segments.values.where(
        (s) => s.event.isFinal || s.event.interrupted,
      );
      if (completed.isEmpty) {
        throw const TranslationFailure('buffer', '服务产生过多未完成字幕，已停止会话，请重新开始。');
      }
      _segments.remove(completed.first.event.segmentId);
    }
    _segments[event.segmentId] = _Segment(event, item, response);
  }

  String _id(Object? value) {
    if (value is! String || value.isEmpty || value.length > 256) {
      throw const TranslationFailure('protocol', '翻译事件缺少有效关联 ID，无法可靠更新字幕。');
    }
    return value;
  }

  String _text(Object? value) {
    if (value is! String || value.length > 65536) {
      throw const TranslationFailure('protocol', '服务返回了不支持的字幕内容。');
    }
    return value;
  }

  Duration? _milliseconds(Object? value) =>
      value is int && value >= 0 ? Duration(milliseconds: value) : null;
}
