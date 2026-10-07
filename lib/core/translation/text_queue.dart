import 'dart:async';
import 'dart:collection';
import 'text_translator.dart';

class _Request {
  _Request(
    this.id,
    this.text,
    this.source,
    this.target,
    this.start,
    this.end,
    this.sourceRevision,
    this.sourceFinal,
  );
  final String id, text, source, target;
  final Duration? start, end;
  final int sourceRevision;
  final bool sourceFinal;
  final token = TranslationCancellation();
  TranslationEvent? result;
  int emittedRevision = 0;
  bool done = false;
}

class TextTranslationQueue {
  TextTranslationQueue(
    this.adapter, {
    required this.generation,
    required this.onEvent,
    this.onFailure,
    this.onTiming,
    this.debounce = const Duration(milliseconds: 350),
    this.maxPending = 8,
  });
  final TextTranslator adapter;
  int generation;
  final void Function(TranslationEvent) onEvent;
  final void Function(TranslationFailure)? onFailure;
  final void Function(
    String segmentId,
    int sourceRevision,
    TranslationRequestTiming timing,
  )?
  onTiming;
  final Duration debounce;
  final int maxPending;
  final List<_Request> _requests = [];
  final Map<String, _Request> _current = {};
  final Map<String, int> _revisions = {};
  final LinkedHashMap<String, String> _cache = LinkedHashMap();
  final Set<_Request> _started = {};
  int _active = 0;
  bool _disposed = false;
  Timer? _timer;
  final List<Completer<void>> _drainers = [];

  void submit(
    String id,
    String text, {
    String sourceLanguage = 'auto',
    String targetLanguage = 'Chinese',
    Duration? audioStart,
    Duration? audioEnd,
    int sourceRevision = 0,
    bool sourceFinal = true,
  }) {
    if (_disposed) return;
    final old = _current[id];
    if (old == null && _requests.length >= maxPending) {
      onFailure?.call(
        const TranslationFailure('queue_full', '文本翻译队列已满，当前片段未上传；请缩短分段或稍后重试。'),
      );
      return;
    }
    final request = _Request(
      id,
      text,
      sourceLanguage,
      targetLanguage,
      audioStart,
      audioEnd,
      sourceRevision,
      sourceFinal,
    );
    // A rewritten preview keeps its logical queue position and capacity slot.
    _current[id] = request;
    if (old != null) {
      final index = _requests.indexOf(old);
      if (index < 0) {
        // An event callback may submit a correction while the previous result
        // is being removed from the ordered queue.
        _requests.add(request);
      } else {
        _requests[index] = request;
      }
      old.token.cancel();
    } else {
      _requests.add(request);
    }
    _timer?.cancel();
    if (debounce == Duration.zero) {
      _pump();
    } else {
      _timer = Timer(debounce, _pump);
    }
  }

  void cancelSegment(String id) {
    final request = _current.remove(id);
    if (request == null) return;
    _requests.remove(request);
    request.token.cancel();
    _pump();
  }

  bool _isCurrent(_Request request, int g) =>
      !_disposed &&
      g == generation &&
      identical(_current[request.id], request) &&
      !request.token.isCanceled;

  void _pump() {
    if (_disposed) {
      _checkDrained();
      return;
    }
    _emitOrdered();
    while (_active < 2) {
      final waiting = _requests.where(
        (r) => !r.done && !r.token.isCanceled && !_started.contains(r),
      );
      if (waiting.isEmpty) break;
      final request = waiting.first;
      _started.add(request);
      _active++;
      unawaited(_run(request, generation));
    }
    _checkDrained();
  }

  Future<void> _run(_Request request, int g) async {
    final canceled = Completer<String>();
    final removeCancel = request.token.onCancel(() {
      if (!canceled.isCompleted) {
        canceled.completeError(
          const TranslationFailure('canceled', '文本翻译已取消。'),
        );
      }
    });
    try {
      final key =
          '${request.source}\u0000${request.target}\u0000${request.text}';
      final text =
          _cache[key] ??
          await Future.any<String>([
            adapter.translate(
              request.text,
              sourceLanguage: request.source,
              targetLanguage: request.target,
              cancellation: request.token,
              onPartial: (partial) {
                if (!_isCurrent(request, g) ||
                    request.done ||
                    partial.isEmpty) {
                  return;
                }
                request.result = _result(request, g, partial, isFinal: false);
                _emitOrdered();
              },
              onTiming: (timing) {
                if (!_disposed &&
                    g == generation &&
                    identical(_current[request.id], request)) {
                  onTiming?.call(request.id, request.sourceRevision, timing);
                }
              },
            ),
            canceled.future,
          ]);
      if (!_isCurrent(request, g)) return;
      _cache[key] = text;
      if (_cache.length > 128) _cache.remove(_cache.keys.first);
      request.result = _result(request, g, text, isFinal: request.sourceFinal);
    } catch (error) {
      if (!_isCurrent(request, g)) return;
      // An interrupted response never confirms its provisional text.
      if (request.result != null && !request.result!.isFinal) {
        request.result = _result(
          request,
          g,
          request.result!.text,
          isFinal: false,
          interrupted: true,
        );
      }
      onFailure?.call(
        error is TranslationFailure
            ? error
            : const TranslationFailure('translation', '文本翻译失败'),
      );
    } finally {
      removeCancel();
      request.done = true;
      _started.remove(request);
      _active--;
      _pump();
    }
  }

  TranslationEvent _result(
    _Request request,
    int g,
    String text, {
    required bool isFinal,
    bool interrupted = false,
  }) {
    final revision = (_revisions[request.id] ?? 0) + 1;
    _revisions[request.id] = revision;
    return TranslationEvent(
      generation: g,
      segmentId: request.id,
      revision: revision,
      text: text,
      isFinal: isFinal,
      interrupted: interrupted,
      audioStart: request.start,
      audioEnd: request.end,
      sourceRevision: request.sourceRevision,
      sourceFinal: request.sourceFinal,
      engine: adapter.capabilities.id,
    );
  }

  void _emitOrdered() {
    while (_requests.isNotEmpty && _requests.first.done) {
      final request = _requests.removeAt(0);
      _emitRequest(request);
      if (identical(_current[request.id], request)) {
        _current.remove(request.id);
      }
    }
    if (_requests.isNotEmpty) _emitRequest(_requests.first);
  }

  void _emitRequest(_Request request) {
    final result = request.result;
    if (result == null ||
        !_isCurrent(request, result.generation) ||
        result.revision <= request.emittedRevision) {
      return;
    }
    request.emittedRevision = result.revision;
    onEvent(result);
  }

  void _checkDrained() {
    if (_requests.isEmpty && _active == 0) {
      for (final completer in _drainers) {
        if (!completer.isCompleted) completer.complete();
      }
      _drainers.clear();
    }
  }

  Future<void> drain() {
    if (_disposed) return Future.value();
    _timer?.cancel();
    _pump();
    if (_requests.isEmpty && _active == 0) return Future.value();
    final completer = Completer<void>();
    _drainers.add(completer);
    return completer.future;
  }

  void changeGeneration(int g) {
    _timer?.cancel();
    _current.clear();
    for (final request in _requests) {
      request.token.cancel();
    }
    _requests.clear();
    _cache.clear();
    _revisions.clear();
    generation = g;
    _checkDrained();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _current.clear();
    for (final request in _requests) {
      request.token.cancel();
    }
    _requests.clear();
    _checkDrained();
  }
}
