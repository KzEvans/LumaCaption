import 'translation_models.dart';

/// The 3.5 text/stash protocol is separate from the 3.8 delta protocol.
/// Uses the current-text interpretation in the official Python example. A real
/// multi-event trace is still required to validate it; done is authoritative.
class Qwen35Parser {
  Qwen35Parser({required this.generation, this.cloudTranscription = false});
  final int generation;
  final bool cloudTranscription;
  final _segments = <String, TranslationEvent>{};
  final _seen = <String>{};
  final _ranges = <String, (Duration?, Duration?)>{};

  List<TranslationEvent> accept(Map<String, dynamic> event) {
    final eventId = event['event_id'];
    if (eventId is String && !_seen.add(eventId)) return const [];
    if (_seen.length > 2048) _seen.remove(_seen.first);
    final type = event['type'];
    final item = event['item_id'];
    if (type == 'input_audio_buffer.speech_started' ||
        type == 'input_audio_buffer.speech_stopped') {
      if (item is String) {
        final previous = _ranges[item] ?? (null, null);
        _ranges[item] = (
          _milliseconds(event['audio_start_ms']) ?? previous.$1,
          _milliseconds(event['audio_end_ms']) ?? previous.$2,
        );
        if (_ranges.length > 256) _ranges.remove(_ranges.keys.first);
      }
      return const [];
    }
    final isSource =
        type == 'conversation.item.input_audio_transcription.text' ||
        type == 'conversation.item.input_audio_transcription.completed';
    final isTranslation =
        type == 'response.text.text' || type == 'response.text.done';
    if (isSource && !cloudTranscription) return const [];
    if (isSource || isTranslation) {
      final response = event['response_id'];
      if (item is! String || (isTranslation && response is! String)) {
        throw const TranslationFailure('protocol', '翻译事件缺少关联 ID，无法可靠更新字幕。');
      }
      final id = isSource
          ? 'source/$item'
          : '$response/$item/${event['content_index'] ?? 0}';
      final previous = _segments[id];
      final isFinal =
          type == 'response.text.done' ||
          type == 'conversation.item.input_audio_transcription.completed';
      if (previous?.isFinal == true && !isFinal) return const [];
      final text = _text(event[isSource && isFinal ? 'transcript' : 'text']);
      final stash = isFinal ? '' : _text(event['stash']);
      // Only reuse a range with the exact same server item id. In particular,
      // never pair local ASR and translation by ordinal position.
      final range = _ranges[item];
      final result = TranslationEvent(
        generation: generation,
        segmentId: id,
        revision: (previous?.revision ?? 0) + 1,
        text: isSource ? '' : text,
        stash: isSource ? '' : stash,
        original: isSource ? '$text$stash' : null,
        isSource: isSource,
        isFinal: isFinal,
        audioStart: range?.$1,
        audioEnd: range?.$2,
      );
      _save(result);
      return [result];
    }
    if (type == 'response.done') {
      final response = event['response'];
      if (response is! Map) return const [];
      final responseId = response['id'];
      final status = response['status'];
      if (status == 'failed' ||
          status == 'incomplete' ||
          status == 'cancelled' ||
          status == 'canceled') {
        return _markInterrupted(
          (segment) => segment.segmentId.startsWith('$responseId/'),
        );
      }
      // text.done normally supplies the final text. A completed response's text
      // output is also an authoritative recovery path when it was not emitted.
      final output = response['output'];
      if (status != 'completed' || output is! List || responseId is! String) {
        return const [];
      }
      final updates = <TranslationEvent>[];
      for (final item in output.whereType<Map>()) {
        final content = item['content'];
        if (content is! List || item['id'] is! String) continue;
        for (var i = 0; i < content.length; i++) {
          final part = content[i];
          if (part is! Map ||
              part['type'] != 'text' ||
              part['text'] is! String) {
            continue;
          }
          updates.addAll(
            accept({
              'type': 'response.text.done',
              'response_id': responseId,
              'item_id': item['id'],
              'content_index': i,
              'text': part['text'],
            }),
          );
        }
      }
      return updates;
    }
    return const [];
  }

  List<TranslationEvent> interrupt() =>
      _markInterrupted((segment) => !segment.isFinal);

  List<TranslationEvent> _markInterrupted(
    bool Function(TranslationEvent) include,
  ) {
    final updates = <TranslationEvent>[];
    for (final old in _segments.values.toList()) {
      if (!include(old) || old.interrupted) continue;
      final next = TranslationEvent(
        generation: old.generation,
        segmentId: old.segmentId,
        revision: old.revision + 1,
        text: old.text,
        original: old.original,
        isSource: old.isSource,
        isFinal: false,
        interrupted: true,
        audioStart: old.audioStart,
        audioEnd: old.audioEnd,
      );
      _segments[old.segmentId] = next;
      updates.add(next);
    }
    return updates;
  }

  void _save(TranslationEvent event) {
    if (_segments.length >= 256 && !_segments.containsKey(event.segmentId)) {
      final completed = _segments.values.where(
        (e) => e.isFinal || e.interrupted,
      );
      if (completed.isEmpty) {
        throw const TranslationFailure('buffer', '服务产生过多未完成字幕，已停止会话，请重新开始。');
      }
      _segments.remove(completed.first.segmentId);
    }
    _segments[event.segmentId] = event;
  }

  String _text(Object? value) {
    if (value == null) return '';
    if (value is! String || value.length > 65536) {
      throw const TranslationFailure('protocol', '服务返回了不支持的字幕内容。');
    }
    return value;
  }

  Duration? _milliseconds(Object? value) =>
      value is int && value >= 0 ? Duration(milliseconds: value) : null;
}
