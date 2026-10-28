import 'dart:async';
import 'dart:math' as math;

import 'epub_rich_layout.dart';

/// A resumable page cursor. Reading ahead consumes pages, not whole spine items.
/// Requests share the same cursor so foreground navigation reuses prefetch work.
final class EpubPageLayout {
  EpubPageLayout(
    Stream<EpubRichPage> source, {
    Stream<EpubRichPage> Function()? countSource,
  }) : _iterator = StreamIterator(source),
       _countSource = countSource;

  final StreamIterator<EpubRichPage> _iterator;
  final Stream<EpubRichPage> Function()? _countSource;
  StreamIterator<EpubRichPage>? _counter;
  Future<void>? _countPending;
  int _countedPages = 0;
  int? _exactCount;
  bool _countFailed = false;
  final Map<Timer, Completer<void>> _yieldTimers = {};
  final List<EpubRichPage> pages = [];
  bool complete = false;
  bool _disposed = false;
  Object? _failure;
  StackTrace? _failureStack;

  Future<void> yieldWork() {
    if (_disposed) return Future.value();
    final ready = Completer<void>();
    late final Timer timer;
    timer = Timer(Duration.zero, () {
      _yieldTimers.remove(timer);
      ready.complete();
    });
    _yieldTimers[timer] = ready;
    return ready.future;
  }

  int? get pageCount => complete ? pages.length : _exactCount;

  int estimatedPageCount(int contentLength) {
    final exact = pageCount;
    if (exact != null) return exact;
    if (pages.length < 2 || pages.last.offset <= 0) {
      return math.max(1, pages.length);
    }

    final estimate = (contentLength * (pages.length - 1) / pages.last.offset)
        .ceil();
    return math.max(pages.length, estimate);
  }

  /// Counts without retaining the remaining pages or advancing the reading cursor.
  /// A cancelled background request can resume from the same counting cursor.
  Future<void> countPages({bool Function()? cancelled}) async {
    if (_countSource == null || _countFailed) return;

    while (!_disposed && pageCount == null && !(cancelled?.call() ?? false)) {
      await (_countPending ??= _countNext().whenComplete(
        () => _countPending = null,
      ));
    }
  }

  Future<void> _countNext() async {
    final counter = _counter ??= StreamIterator(_countSource!());
    try {
      if (await counter.moveNext()) {
        _countedPages++;
      } else if (!_disposed) {
        _exactCount = _countedPages;
        _counter = null;
      }
    } catch (_) {
      _countFailed = true;
      rethrow;
    }
  }

  Future<void> ensure({
    int count = 1,
    int? offset,
    bool toEnd = false,
    bool Function()? cancelled,
  }) async {
    while (!_disposed && !complete && !(cancelled?.call() ?? false)) {
      if (_failure case final failure?) {
        Error.throwWithStackTrace(failure, _failureStack!);
      }

      final hasOffset =
          offset == null || (pages.isNotEmpty && pages.last.offset > offset);

      if (!toEnd && pages.length >= count && hasOffset) return;
      await _advance();
    }
  }

  Future<void>? _pending;

  Future<void> _advance() {
    return _pending ??= _readNext().whenComplete(() => _pending = null);
  }

  Future<void> _readNext() async {
    try {
      if (await _iterator.moveNext()) {
        if (!_disposed) pages.add(_iterator.current);
      } else {
        complete = true;
      }
    } catch (error, stack) {
      _failure = error;
      _failureStack = stack;
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _yieldTimers.entries) {
      entry.key.cancel();
      entry.value.complete();
    }
    _yieldTimers.clear();
    unawaited(_iterator.cancel());
    unawaited(_counter?.cancel());
  }
}
