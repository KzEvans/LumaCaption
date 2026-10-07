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
    this.order,
  );
  final String id, text, source, target;
  final Duration? start, end;
  final int order;
  final token = TranslationCancellation();
  TranslationEvent? result;
  bool done = false;
}

class TextTranslationQueue {
  TextTranslationQueue(
    this.adapter, {
    required this.generation,
    required this.onEvent,
    this.onFailure,
    this.debounce = const Duration(milliseconds: 350),
    this.maxPending = 8,
  });
  final TextTranslator adapter;
  int generation;
  final void Function(TranslationEvent) onEvent;
  final void Function(TranslationFailure)? onFailure;
  final Duration debounce;
  final int maxPending;
  final List<_Request> _requests = [];
  final LinkedHashMap<String, String> _cache = LinkedHashMap();
  int _active = 0, _next = 0;
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
  }) {
    if (_disposed) return;
    if (_requests.length >= maxPending) {
      onFailure?.call(
        const TranslationFailure('queue_full', '文本翻译队列已满，当前片段未上传；请缩短分段或稍后重试。'),
      );
      return;
    }
    for (final old in _requests.where((r) => r.id == id)) {
      old.token.cancel();
      old.done = true;
    }
    _requests.add(
      _Request(
        id,
        text,
        sourceLanguage,
        targetLanguage,
        audioStart,
        audioEnd,
        _next++,
      ),
    );
    _timer?.cancel();
    _timer = Timer(debounce, _pump);
  }

  void _pump() {
    if (_disposed) return;
    _emitOrdered();
    while (_active < 2) {
      final waiting = _requests
          .where((r) => !r.done && !r.token.isCanceled && r.order >= 0)
          .where((r) => !_started.contains(r));
      if (waiting.isEmpty) break;
      final r = waiting.first;
      _started.add(r);
      _active++;
      unawaited(_run(r, generation));
    }
    _checkDrained();
  }

  final Set<_Request> _started = {};
  Future<void> _run(_Request r, int g) async {
    try {
      final key = '${r.source}\u0000${r.target}\u0000${r.text}';
      final text =
          _cache[key] ??
          await adapter.translate(
            r.text,
            sourceLanguage: r.source,
            targetLanguage: r.target,
            cancellation: r.token,
          );
      if (_disposed || g != generation || r.token.isCanceled) return;
      _cache[key] = text;
      if (_cache.length > 128) _cache.remove(_cache.keys.first);
      r.result = TranslationEvent(
        generation: g,
        segmentId: r.id,
        revision: 1,
        text: text,
        isFinal: true,
        audioStart: r.start,
        audioEnd: r.end,
        engine: adapter.capabilities.id,
      );
    } catch (e) {
      if (!_disposed && g == generation && !r.token.isCanceled) {
        onFailure?.call(
          e is TranslationFailure
              ? e
              : const TranslationFailure('translation', '文本翻译失败'),
        );
      }
    } finally {
      r.done = true;
      _active--;
      _pump();
    }
  }

  void _emitOrdered() {
    while (_requests.isNotEmpty && _requests.first.done) {
      final r = _requests.removeAt(0);
      _started.remove(r);
      if (r.result != null && !r.token.isCanceled) onEvent(r.result!);
    }
  }

  void _checkDrained() {
    if (_requests.isEmpty && _active == 0) {
      for (final c in _drainers) {
        if (!c.isCompleted) c.complete();
      }
      _drainers.clear();
    }
  }

  Future<void> drain() {
    if (_disposed) return Future.value();
    _timer?.cancel();
    _pump();
    if (_requests.isEmpty && _active == 0) return Future.value();
    final c = Completer<void>();
    _drainers.add(c);
    return c.future;
  }

  void changeGeneration(int g) {
    for (final r in _requests) {
      r.token.cancel();
    }
    _requests.clear();
    _started.clear();
    _cache.clear();
    generation = g;
    _checkDrained();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final r in _requests) {
      r.token.cancel();
    }
    _requests.clear();
    _checkDrained();
  }
}
