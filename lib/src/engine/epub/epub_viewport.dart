import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../domain/reader_selection.dart';
import '../../domain/reader_locator.dart';

import '../../domain/reader_types.dart';
import '../../domain/reader_preferences.dart';
import '../../presentation/reader_interaction_scope.dart';
import '../../presentation/reader_loading.dart';
import '../../presentation/reader_swipe_tracker.dart';
import '../../presentation/reader_highlight_interaction.dart';
import '../../presentation/reader_text_toolbar.dart';
import 'epub_reader_engine.dart';
import 'epub_rich_layout.dart';
import 'epub_page_layout.dart';
import 'epub_content_renderer.dart';

final class EpubViewport extends StatefulWidget {
  const EpubViewport({required this.engine, super.key});
  final EpubReaderEngine engine;
  @override
  State<EpubViewport> createState() => _EpubViewportState();
}

final class _EpubViewportState extends State<EpubViewport> {
  PageController _pagesController = PageController();
  ScrollController _scrollController = ScrollController();
  Future<List<EpubRichPage>>? _layout;
  List<EpubRichPage> _pages = const [];
  Object? _layoutKey;
  Object? _geometryKey;
  Size _contentSize = Size.zero;
  TextScaler _scaler = TextScaler.noScaling;
  TextDirection _direction = TextDirection.ltr;
  int _fontRevision = 0;
  final Map<Object, EpubPageLayout> _layoutCache = {};
  List<EpubRichPage>? _turnPages;
  int _turnDirection = 0;
  int? _turnSpine;
  static const _spreadsAhead = 5;
  static const _spreadsBehind = 3;
  final Set<MemoryImage> _warmingImages = {};
  static const _turnDuration = Duration(milliseconds: 220);
  Timer? _prefetchTimer;
  int _prefetchGeneration = 0;
  ReaderPreferences? _displayPreferences;
  int _displayColumns = 1;
  Timer? _loadingTimer;
  bool _showLoading = false;
  int _restoration = -1;
  int _pageIndex = 0;
  int _pageViewCount = 0;
  int _columns = 1;
  final _swipe = ReaderSwipeTracker();
  bool get _animateTurns =>
      widget.engine.preferences.pageTurnAnimation &&
      !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  int _startPage = 0;
  double _startScroll = 0;
  bool _restoring = false;
  bool _busy = false;
  Completer<void>? _layoutReady;
  List<double> _scrollOffsets = const [];
  final _selectionKey = GlobalKey<SelectionAreaState>();
  final _selectionMenuController = ContextMenuController();
  int _menuRevision = 0;
  String _selectedText = '';
  Rect? _menuBounds;

  Iterable<EpubSelectionFragmentState> get _fragments {
    final fragments = <EpubSelectionFragmentState>[];
    void visit(Element element) {
      if (element is StatefulElement &&
          element.state is EpubSelectionFragmentState) {
        fragments.add(element.state as EpubSelectionFragmentState);
      }
      element.visitChildElements(visit);
    }

    _selectionKey.currentContext?.visitChildElements(visit);
    return fragments;
  }

  Rect? _visibleBounds(Iterable<Rect> rectangles) {
    final box = context.findRenderObject() as RenderBox;
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    Rect? bounds;
    for (final rectangle in rectangles) {
      final visible = rectangle.intersect(viewport);
      if (!visible.isEmpty) {
        bounds = bounds?.expandToInclude(visible) ?? visible;
      }
    }
    return bounds;
  }

  Rect? get _selectionBounds => _visibleBounds([
    for (final fragment in _fragments)
      if (fragment.range case final range?)
        ...fragment.rectangles(range.startOffset, range.endOffset),
  ]);

  ReaderHighlightTarget? _highlightAt(Offset position) {
    final highlights =
        ReaderInteractionScope.maybeOf(context)?.highlights ??
        const <ReaderHighlight>[];
    for (final highlight in highlights.reversed) {
      final start = highlight.selection.start;
      final end = highlight.selection.end;
      if (start is! EpubReaderLocator ||
          end is! EpubReaderLocator ||
          start.spineIndex != widget.engine.locator.spineIndex ||
          start.textOffset == null ||
          end.textOffset == null) {
        continue;
      }
      final rectangles = [
        for (final fragment in _fragments)
          ...fragment.rectangles(
            start.textOffset! - fragment.widget.fragment.offset,
            end.textOffset! - fragment.widget.fragment.offset,
          ),
      ];
      if (rectangles.any((rectangle) => rectangle.contains(position))) {
        final bounds = _visibleBounds(rectangles);
        if (bounds != null) return (highlight: highlight, bounds: bounds);
      }
    }
    return null;
  }

  ReaderSelection? _selectedPassage() {
    int? first;
    int? last;

    void visit(Element element) {
      if (element is StatefulElement &&
          element.state is EpubSelectionFragmentState) {
        final state = element.state as EpubSelectionFragmentState;
        final selection = state.range;

        if (selection != null && selection.startOffset != selection.endOffset) {
          final start =
              state.widget.fragment.offset +
              math.min(selection.startOffset, selection.endOffset);
          final end =
              state.widget.fragment.offset +
              math.max(selection.startOffset, selection.endOffset);
          first = first == null
              ? start.toInt()
              : math.min(first!, start).toInt();
          last = last == null ? end.toInt() : math.max(last!, end).toInt();
        }
      }

      element.visitChildElements(visit);
    }

    _selectionKey.currentContext?.visitChildElements(visit);

    if (first == null || last == null || _selectedText.isEmpty) {
      return null;
    }

    final locator = widget.engine.locator;
    EpubReaderLocator at(int offset) => EpubReaderLocator(
      spineIndex: locator.spineIndex,
      textOffset: offset,
      localProgression: (offset / math.max(1, widget.engine.contentLength))
          .clamp(0, 1),
      totalProgression: locator.totalProgression,
    );

    return ReaderSelection(
      text: _selectedText,
      start: at(first!),
      end: at(last!),
    );
  }

  Widget _selectionMenu(BuildContext context, SelectableRegionState state) {
    final interactions = ReaderInteractionScope.maybeOf(this.context);
    final items = <ContextMenuButtonItem>[];

    void add(String label, ValueChanged<ReaderSelection>? action) {
      if (_selectedText.isEmpty || action == null) {
        return;
      }

      items.add(
        ContextMenuButtonItem(
          label: label,
          onPressed: () {
            final selection = _selectedPassage();
            _selectionMenuController.remove();
            state.hideToolbar();
            state.clearSelection();
            if (selection != null) action(selection);
          },
        ),
      );
    }

    add('Annotate', interactions?.onAnnotate);
    add('Add note', interactions?.onNote);
    items.addAll(
      state.contextMenuButtonItems.map(
        (item) => ContextMenuButtonItem(
          type: item.type,
          label: item.label,
          onPressed: () {
            _selectionMenuController.remove();
            item.onPressed?.call();
          },
        ),
      ),
    );
    final bounds = _menuBounds;
    if (bounds == null || items.isEmpty) return const SizedBox.shrink();
    return ReaderTextToolbar(bounds: bounds, items: items);
  }

  void _selectionStatusChanged(SelectableRegionSelectionStatus status) {
    final revision = ++_menuRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _menuRevision) return;
      _selectionMenuController.remove();
      final state = _selectionKey.currentState?.selectableRegion;
      if (status != SelectableRegionSelectionStatus.finalized ||
          _selectedText.isEmpty ||
          state == null) {
        return;
      }
      _menuBounds = _selectionBounds;
      _selectionMenuController.show(
        context: context,
        contextMenuBuilder: (context) => TapRegion(
          groupId: SelectableRegion,
          child: _selectionMenu(context, state),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_changed);
    widget.engine.moveViewport = _move;
    widget.engine.prepareLocation = _prepareLocation;
    _scrollController.addListener(_scrollChanged);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() {
    if (!mounted) return;
    setState(() {
      _fontRevision++;
      _layoutKey = null;
    });
  }

  @override
  void didUpdateWidget(covariant EpubViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      oldWidget.engine.removeListener(_changed);
      oldWidget.engine.moveViewport = null;
      oldWidget.engine.prepareLocation = null;
      _clearLayouts();
      _pages = const [];
      widget.engine.addListener(_changed);
      widget.engine.moveViewport = _move;
      widget.engine.prepareLocation = _prepareLocation;
      _layoutKey = null;
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  int _target(List<EpubRichPage> pages) {
    final locator = widget.engine.locator;
    final offset = locator.textOffset;
    if (offset != null) {
      for (var i = pages.length - 1; i >= 0; i--) {
        if (pages[i].offset <= offset) return i;
      }
      return 0;
    }
    return ((pages.length - 1) * locator.localProgression).round().clamp(
      0,
      pages.length - 1,
    );
  }

  void _restore(List<EpubRichPage> pages, double width) {
    _pages = pages;
    if (_restoration == widget.engine.restorationRevision) return;
    _restoration = widget.engine.restorationRevision;
    final target = _target(pages);
    _restoring = true;
    _pageIndex = target ~/ _columns;
    if (widget.engine.preferences.layoutMode == ReaderLayoutMode.paginated) {
      final previous = _pagesController;
      _pagesController = PageController(
        initialPage: _turnPages == null
            ? _pageIndex
            : (_turnDirection > 0 ? 0 : 1),
        keepPage: false,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    } else {
      final preferences = widget.engine.preferences;
      final heights = [
        for (final page in pages) _pageHeight(page, preferences),
      ];
      final extent = math.max(
        0.0,
        heights.fold<double>(0, (total, height) => total + height) -
            _contentSize.height -
            preferences.pageMargins.vertical,
      );
      final offset = widget.engine.locator.textOffset;
      var pixels = extent * widget.engine.locator.localProgression;
      if (offset != null) {
        pixels = heights
            .take(target)
            .fold<double>(0, (total, height) => total + height);
        pixels += preferences.pageMargins.top;
        for (final fragment in pages[target].fragments) {
          if (fragment.offset >= offset ||
              fragment.block.offset + fragment.end > offset) {
            break;
          }
          pixels += fragment.height + fragment.spacing(preferences);
        }
      }
      final previous = _scrollController;
      previous.removeListener(_scrollChanged);
      _scrollController = ScrollController(
        initialScrollOffset: pixels.clamp(0, extent),
        keepScrollOffset: false,
      )..addListener(_scrollChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !identical(_pages, pages)) return;
      _restoring = true;
      if (widget.engine.preferences.layoutMode == ReaderLayoutMode.paginated) {
        if (_pagesController.hasClients) {
          if (_turnPages != null) {
            final controller = _pagesController;
            await controller.animateToPage(
              _turnDirection > 0 ? 1 : 0,
              duration: _turnDuration,
              curve: Curves.easeOutCubic,
            );

            if (!mounted || !identical(_pagesController, controller)) return;
            final replacement = PageController(
              initialPage: _pageIndex,
              keepPage: false,
            );
            setState(() {
              _turnPages = null;
              _pagesController = replacement;
            });
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => controller.dispose(),
            );
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted || !identical(_pagesController, replacement)) return;
          } else {
            _pagesController.jumpToPage(_pageIndex);
          }
        }
      } else if (_scrollController.hasClients && _scrollOffsets.isNotEmpty) {
        var pixels = _scrollOffsets[target];
        final offset = widget.engine.locator.textOffset;
        if (offset != null) {
          pixels += widget.engine.preferences.pageMargins.top;
          for (final fragment in pages[target].fragments) {
            if (fragment.offset >= offset ||
                fragment.block.offset + fragment.end > offset) {
              break;
            }
            pixels +=
                fragment.height + fragment.spacing(widget.engine.preferences);
          }
        } else {
          pixels =
              _scrollController.position.maxScrollExtent *
              widget.engine.locator.localProgression;
        }
        _scrollController.jumpTo(
          pixels.clamp(0, _scrollController.position.maxScrollExtent),
        );
      }
      _restoring = false;
      _busy = false;
      _loadingTimer?.cancel();
      _showLoading = false;
      if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
      if (widget.engine.preferences.layoutMode == ReaderLayoutMode.paginated) {
        _publishPage(
          _pageIndex,
          restoredOffset: widget.engine.locator.textOffset,
        );
      } else {
        _scrollChanged();
      }
      _schedulePrefetch();
    });
  }

  Future<bool> _move(int direction) async {
    while (_busy && mounted) {
      final ready = _layoutReady;
      if (ready == null) return true;
      await ready.future;
    }
    if (!mounted || (_pages.isEmpty && widget.engine.renderer == null)) {
      return true;
    }
    if (widget.engine.preferences.layoutMode == ReaderLayoutMode.scroll) {
      if (!_scrollController.hasClients) return true;
      final position = _scrollController.position;
      final next =
          (position.pixels + direction * position.viewportDimension * .85)
              .clamp(0.0, position.maxScrollExtent);
      if ((next - position.pixels).abs() < 1) return false;
      _scrollController.jumpTo(next);
      return true;
    }
    final next = _pageIndex + direction;
    final layout = _layoutCache[_layoutKey];

    final requiredPages = (next + 1) * _columns;
    if (next >= 0 &&
        layout != null &&
        !layout.complete &&
        layout.pages.length < requiredPages) {
      await layout.ensure(count: requiredPages);
      if (!mounted || !identical(layout, _layoutCache[_layoutKey])) return true;
      setState(() {});
    }

    final count = (_pages.length / _columns).ceil();

    if (next < 0 || next >= count) {
      final index = widget.engine.locator.spineIndex + direction;
      if (index < 0 || index >= widget.engine.chapterCount) return false;
      final animate = _animateTurns;
      final from = _pageIndex * _columns;
      final outgoing = _pages.sublist(
        from,
        math.min(from + _columns, _pages.length),
      );
      final spine = widget.engine.locator.spineIndex;

      // Prepare first, keeping the committed page interactive while work yields.
      await widget.engine.goTo(
        EpubReaderLocator(
          spineIndex: index,
          localProgression: direction < 0 ? 1 : 0,
          totalProgression: widget.engine.locator.totalProgression,
        ),
      );
      if (!mounted) return true;
      _turnPages = animate ? outgoing : null;
      _turnDirection = direction;
      _turnSpine = spine;
      await WidgetsBinding.instance.endOfFrame;
      await _layoutReady?.future;
      return true;
    }

    if (next >= _pageViewCount) {
      // A prepared page may not yet be included in the PageView's scroll extent.
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !identical(layout, _layoutCache[_layoutKey])) return true;
    }

    final controller = _pagesController;

    if (!controller.hasClients) {
      return true;
    }

    if (!_animateTurns) {
      controller.jumpToPage(next);
    } else {
      await controller.animateToPage(
        next,
        duration: _turnDuration,
        curve: Curves.easeOutCubic,
      );
    }

    // Touch input can complete the animation future before its target is reached.
    // Subsequent drag/settling updates continue through onPageChanged.
    if (mounted &&
        identical(controller, _pagesController) &&
        controller.hasClients) {
      final page = controller.page;

      if (page != null) {
        _publishPage(page.round());
      }
    }

    return true;
  }

  void _publishPage(int index, {int? restoredOffset}) {
    if (_restoring || _busy || _pages.isEmpty) {
      return;
    }

    _pageIndex = index;
    final page = (index * _columns).clamp(0, _pages.length - 1);
    final after = math.min(page + _columns, _pages.length);
    final spreads = (_pages.length / _columns).ceil();
    final layout = _layoutCache[_layoutKey];
    final complete = layout?.complete ?? true;
    final local = complete
        ? (spreads <= 1 ? 0.0 : index / (spreads - 1))
        : _pages[page].offset / math.max(1, widget.engine.contentLength);
    final int coverageEnd;
    if (after < _pages.length) {
      coverageEnd = _pages[after].offset;
    } else if (complete) {
      coverageEnd = widget.engine.contentLength;
    } else {
      final fragment = _pages.last.fragments.last;
      coverageEnd = fragment.block.offset + fragment.end;
    }

    widget.engine.viewportChanged(
      local,
      textOffset: restoredOffset ?? _pages[page].offset,
      pageNumber: page + 1,
      pageCount:
          layout?.estimatedPageCount(widget.engine.contentLength) ??
          _pages.length,
      pageCountEstimated: layout != null && layout.pageCount == null,
      coverageStart: _pages[page].offset,
      coverageEnd: coverageEnd,
      atEnd: complete && after == _pages.length,
    );
    _schedulePrefetch();
  }

  void _scrollChanged() {
    if (_restoring ||
        _busy ||
        !_scrollController.hasClients ||
        _pages.isEmpty) {
      return;
    }
    final pixels = _scrollController.position.pixels;
    var index = 0;
    for (var i = 1; i < _scrollOffsets.length; i++) {
      if (_scrollOffsets[i] > pixels) break;
      index = i;
    }
    var offset = _pages[index].offset;
    var within =
        pixels -
        _scrollOffsets[index] -
        widget.engine.preferences.pageMargins.top;
    for (final fragment in _pages[index].fragments) {
      if (within < 0) break;
      offset = fragment.offset;
      within -= fragment.height + fragment.spacing(widget.engine.preferences);
    }
    final max = _scrollController.position.maxScrollExtent;
    final bottom = pixels + _scrollController.position.viewportDimension;
    var lastOffset = offset;
    for (var i = index; i < _pages.length && _scrollOffsets[i] < bottom; i++) {
      var top = _scrollOffsets[i] + widget.engine.preferences.pageMargins.top;
      for (final fragment in _pages[i].fragments) {
        if (top >= bottom) break;
        lastOffset = fragment.block.offset + fragment.end;
        top += fragment.height + fragment.spacing(widget.engine.preferences);
      }
    }
    widget.engine.viewportChanged(
      max <= 0 ? 0 : (pixels / max).clamp(0, 1),
      textOffset: offset,
      pageNumber: index + 1,
      pageCount: _pages.length,
      coverageStart: offset,
      coverageEnd: lastOffset.clamp(0, widget.engine.contentLength),
      atEnd: pixels >= max - 1,
    );
  }

  void _requestTurn(int direction) {
    final request = ReaderInteractionScope.maybeOf(context)?.onTurn;

    if (request != null) {
      request(direction);
      return;
    }

    unawaited(
      (direction > 0 ? widget.engine.goNext() : widget.engine.goPrevious())
          .catchError((Object error, StackTrace stack) {
            // At the book boundary the viewport remains in place. Other errors
            // are visible without destroying the readable current chapter.
            if (mounted && !error.toString().contains('navigationBoundary')) {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(SnackBar(content: Text(error.toString())));
            }
          }),
    );
  }

  void _clearLayouts() {
    for (final layout in _layoutCache.values) {
      layout.dispose();
    }
    _layoutCache.clear();
    _turnPages = null;
  }

  Future<List<EpubRichPage>> _measure(
    int index,
    List<EpubContentBlock> blocks, {
    EpubReaderLocator? target,
    bool toEnd = false,
    int? prefetch,
    bool Function()? cancelled,
  }) async {
    final geometry = _geometryKey;
    final key = (index, geometry);
    bool obsolete() =>
        !mounted ||
        geometry != _geometryKey ||
        (cancelled?.call() ?? false) ||
        (prefetch != null && prefetch != _prefetchGeneration);
    final layout = _layoutCache.putIfAbsent(key, () {
      final contentSize = _contentSize;
      final preferences = widget.engine.preferences;
      final scaler = _scaler;
      final direction = _direction;
      late final EpubPageLayout cursor;
      Stream<EpubRichPage> paginate() => paginateEpub(
        blocks,
        contentSize: contentSize,
        preferences: preferences,
        textScaler: scaler,
        direction: direction,
        cancelled: () => !mounted || geometry != _geometryKey,
        yieldWork: () => cursor.yieldWork(),
      );
      cursor = EpubPageLayout(paginate(), countSource: paginate);
      return cursor;
    });

    while (_layoutCache.length > 3) {
      final oldest = _layoutCache.keys.firstWhere(
        (candidate) => candidate != _layoutKey && candidate != key,
      );
      _layoutCache.remove(oldest)!.dispose();
    }

    try {
      await layout.ensure(
        count: prefetch == null ? _columns : (_spreadsAhead + 1) * _columns + 1,
        offset: target?.textOffset,
        toEnd:
            toEnd ||
            widget.engine.preferences.layoutMode == ReaderLayoutMode.scroll ||
            (target != null &&
                target.textOffset == null &&
                target.localProgression > 0),
        cancelled: obsolete,
      );
      final offset = target?.textOffset;
      if (offset != null && !layout.complete) {
        final targetPage = layout.pages.lastIndexWhere(
          (page) => page.offset <= offset,
        );
        await layout.ensure(
          count: ((targetPage ~/ _columns) + 1) * _columns,
          cancelled: obsolete,
        );
      }
    } catch (_) {
      if (identical(_layoutCache[key], layout)) _layoutCache.remove(key);
      layout.dispose();
      rethrow;
    }

    return layout.pages;
  }

  Future<void> _prepareLocation(
    EpubReaderLocator target,
    List<EpubContentBlock> blocks,
    bool Function() cancelled,
  ) async {
    if (widget.engine.renderer != null &&
        widget.engine.preferences.layoutMode == ReaderLayoutMode.scroll) {
      return;
    }

    _prefetchGeneration++;
    _prefetchTimer?.cancel();
    // A resize can supersede measurement while navigation is waiting.
    Object? geometry;
    do {
      geometry = _geometryKey;
      await _measure(
        target.spineIndex,
        blocks,
        target: target,
        cancelled: cancelled,
      );
    } while (mounted && !cancelled() && geometry != _geometryKey);
  }

  void _publishPageCount(EpubPageLayout layout) {
    if (_busy ||
        _restoring ||
        widget.engine.preferences.layoutMode != ReaderLayoutMode.paginated ||
        !identical(layout, _layoutCache[_layoutKey])) {
      return;
    }

    widget.engine.viewportPaginationChanged(
      layout.estimatedPageCount(widget.engine.contentLength),
      _pageIndex * _columns + 1,
      estimated: layout.pageCount == null,
    );
  }

  bool _prefetchCancelled(int generation) =>
      !mounted || generation != _prefetchGeneration;

  void _warmImages(List<EpubRichPage> pages, int first, int end) {
    final limit = math.min(end, pages.length);
    for (var index = math.max(0, first); index < limit; index++) {
      for (final fragment in pages[index].fragments) {
        final bytes = fragment.block.image;
        if (bytes == null) continue;
        final image = MemoryImage(bytes);
        if (PaintingBinding.instance.imageCache.containsKey(image) ||
            !_warmingImages.add(image)) {
          continue;
        }
        unawaited(
          precacheImage(
            image,
            context,
            onError: (_, _) {},
          ).whenComplete(() => _warmingImages.remove(image)),
        );
      }
    }
  }

  Future<void> _countInBackground(EpubPageLayout layout, int generation) async {
    try {
      // Let nearby-page preparation start before spending time on exact totals.
      await layout.yieldWork();
      if (_prefetchCancelled(generation)) return;
      await layout.countPages(cancelled: () => _prefetchCancelled(generation));
      if (!_prefetchCancelled(generation)) _publishPageCount(layout);
    } catch (_) {
      // Keep the estimated total when speculative counting fails.
    }
  }

  Future<void> _prefetchNeighbor(
    int index,
    int direction,
    int generation,
  ) async {
    final neighbor = index + direction;
    if (neighbor < 0 || neighbor >= widget.engine.chapterCount) return;
    try {
      final chapter = await widget.engine.chapterContent(neighbor);
      if (_prefetchCancelled(generation)) return;
      final pages = await _measure(
        neighbor,
        EpubContentBlocks(chapter['blocks'] as List),
        toEnd: direction < 0,
        prefetch: generation,
      );
      if (_prefetchCancelled(generation)) return;
      _warmImages(
        pages,
        direction < 0 ? pages.length - _spreadsBehind * _columns : 0,
        direction < 0 ? pages.length : _spreadsAhead * _columns,
      );
      final layout = _layoutCache[(neighbor, _geometryKey)];
      if (direction > 0 && layout != null) {
        await _countInBackground(layout, generation);
      }
    } catch (_) {
      // One unreadable or slow neighbor must not block the other direction.
    }
  }

  void _schedulePrefetch() {
    _prefetchTimer?.cancel();
    final generation = ++_prefetchGeneration;
    final index = widget.engine.locator.spineIndex;
    _prefetchTimer = Timer(Duration.zero, () async {
      try {
        final current = _layoutCache[_layoutKey];
        if (current == null) return;
        final previousCount = current.pages.length;
        final wasComplete = current.complete;
        await current.ensure(
          count: (_pageIndex + _spreadsAhead + 1) * _columns + 1,
          cancelled: () => _prefetchCancelled(generation),
        );
        if (_prefetchCancelled(generation)) return;
        if (previousCount != current.pages.length ||
            wasComplete != current.complete) {
          setState(() {});
        }
        _publishPageCount(current);
        _warmImages(
          current.pages,
          (_pageIndex - _spreadsBehind) * _columns,
          (_pageIndex + _spreadsAhead + 1) * _columns,
        );

        await Future.wait([
          _prefetchNeighbor(index, 1, generation),
          if (_pageIndex < _spreadsBehind)
            _prefetchNeighbor(index, -1, generation),
          _countInBackground(current, generation),
        ]);
      } catch (_) {
        // Foreground navigation surfaces errors. Speculation preserves the page.
      }
    });
  }

  @override
  void dispose() {
    _prefetchGeneration++;
    _prefetchTimer?.cancel();
    _clearLayouts();
    _loadingTimer?.cancel();
    if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
    widget.engine.removeListener(_changed);
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    widget.engine.moveViewport = null;
    widget.engine.prepareLocation = null;
    _selectionMenuController.remove();
    _pagesController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = widget.engine.preferences;
    if (preferences.layoutMode == ReaderLayoutMode.scroll &&
        widget.engine.renderer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.engine.viewportCoverageChanged(0, 0);
      });
      return EpubScrollViewport(
        xhtml: widget.engine.currentChapterHtml,
        preferences: preferences,
        localProgression: widget.engine.locator.localProgression,
        restorationRevision: widget.engine.restorationRevision,
        renderer: widget.engine.renderer!,
        controller: _scrollController,
        onProgressChanged: (value) =>
            widget.engine.viewportPositionChanged(value),
      );
    }
    return ColoredBox(
      color: _pages.isEmpty
          ? ReaderLoadingScope.maybeOf(context)?.backgroundColor ??
                preferences.backgroundColor
          : preferences.backgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.maxWidth.isFinite ? constraints.maxWidth : 600,
            constraints.maxHeight.isFinite ? constraints.maxHeight : 800,
          );
          final scaler =
              MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
          final direction = Directionality.of(context);
          final canSpread =
              size.width >= 900 && size.height >= 240 && scaler.scale(1) <= 1.8;
          _columns =
              preferences.layoutMode == ReaderLayoutMode.paginated &&
                  canSpread &&
                  preferences.columnMode != ReaderColumnMode.single
              ? 2
              : 1;
          final width = math.min(size.width, _columns == 2 ? 1400.0 : 800.0);
          final columnWidth = width / _columns;
          final contentSize = Size(
            math.max(1, columnWidth - preferences.pageMargins.horizontal),
            math.max(1, size.height - preferences.pageMargins.vertical),
          );
          final geometry = (
            widget.engine.documentRevision,
            contentSize,
            preferences.fontFamily,
            preferences.fontSize,
            preferences.lineHeight,
            preferences.letterSpacing,
            preferences.paragraphSpacing,
            preferences.pageMargins,
            preferences.layoutMode,
            scaler,
            direction,
            _columns,
            _fontRevision,
          );

          if (_geometryKey != geometry) {
            _geometryKey = geometry;
            _contentSize = contentSize;
            _scaler = scaler;
            _direction = direction;
            _clearLayouts();
            _prefetchGeneration++;
          }

          final key = (widget.engine.locator.spineIndex, geometry);

          if (_layoutKey != key) {
            _layoutKey = key;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _layoutKey == key && _busy) {
                widget.engine.viewportPreparing();
              }
            });
            _restoration = -1;
            _restoring = true;
            _busy = true;

            if (_layoutReady?.isCompleted == false) {
              _layoutReady!.complete();
            }

            _layoutReady = Completer<void>();
            _loadingTimer?.cancel();
            _showLoading = false;
            _loadingTimer = Timer(const Duration(milliseconds: 300), () {
              if (mounted && _busy) {
                setState(() => _showLoading = true);
              }
            });
            final cached = _layoutCache[key];
            _layout = cached == null
                ? _measure(
                    widget.engine.locator.spineIndex,
                    widget.engine.blocks,
                    target: widget.engine.locator,
                  )
                : SynchronousFuture(cached.pages);
          }
          return Center(
            child: SizedBox(
              width: width,
              child: FutureBuilder<List<EpubRichPage>>(
                future: _layout,
                builder: (context, snapshot) {
                  if (snapshot.hasError && _pages.isEmpty) {
                    if (_layoutReady?.isCompleted == false) {
                      _layoutReady!.complete();
                    }
                    _busy = false;
                    return ColoredBox(
                      color: preferences.backgroundColor,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Could not prepare these pages.',
                              style: TextStyle(
                                color: preferences.foregroundColor,
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: () =>
                                  setState(() => _layoutKey = null),
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final ready =
                      snapshot.connectionState == ConnectionState.done &&
                      snapshot.hasData &&
                      snapshot.data!.isNotEmpty;

                  if (!ready && _pages.isEmpty) {
                    return const ReaderLoading();
                  }
                  if (ready) {
                    _displayPreferences = preferences;
                    _displayColumns = _columns;
                    _restore(snapshot.data!, width);
                  } else if (snapshot.hasError) {
                    _busy = false;
                    _loadingTimer?.cancel();
                    if (_layoutReady?.isCompleted == false) {
                      _layoutReady!.complete();
                    }
                  }

                  final pages = ready ? snapshot.data! : _pages;
                  final displayPreferences = ready
                      ? preferences
                      : _displayPreferences!;
                  final columns = ready ? _columns : _displayColumns;
                  Widget content;
                  if (displayPreferences.layoutMode ==
                      ReaderLayoutMode.scroll) {
                    final heights = [
                      for (final page in pages)
                        _pageHeight(page, displayPreferences),
                    ];
                    var cumulative = 0.0;
                    _scrollOffsets = [
                      for (final height in heights)
                        (() {
                          final start = cumulative;
                          cumulative += height;
                          return start;
                        })(),
                    ];
                    content = ListView.custom(
                      key: ValueKey(_scrollController),
                      controller: _scrollController,
                      itemExtentBuilder: (index, _) => heights[index],
                      childrenDelegate: _EpubScrollDelegate(
                        (context, index) => _page(
                          pages[index],
                          displayPreferences,
                          scroll: true,
                        ),
                        childCount: pages.length,
                        extent: cumulative,
                      ),
                    );
                  } else {
                    final outgoing = _turnPages;
                    _pageViewCount = outgoing == null
                        ? (pages.length / columns).ceil()
                        : 2;
                    content = PageView.builder(
                      key: ValueKey(_pagesController),
                      controller: _pagesController,
                      physics: _animateTurns
                          ? null
                          : const NeverScrollableScrollPhysics(),
                      onPageChanged: _publishPage,
                      itemCount: _pageViewCount,
                      itemBuilder: (context, index) {
                        if (outgoing != null) {
                          final oldPage = index == (_turnDirection > 0 ? 0 : 1);
                          return _spread(
                            oldPage ? outgoing : pages,
                            oldPage ? 0 : _pageIndex,
                            columns,
                            displayPreferences,
                            spine: oldPage ? _turnSpine : null,
                          );
                        }
                        return _spread(
                          pages,
                          index,
                          columns,
                          displayPreferences,
                        );
                      },
                    );
                  }
                  final surface = ReaderHighlightInteraction(
                    hitTest: _highlightAt,
                    isSelecting: () => _selectedText.isNotEmpty,
                    child: Listener(
                      onPointerDown: (event) {
                        _swipe.start(event);
                        _startPage = _pageIndex;
                        _startScroll = _scrollController.hasClients
                            ? _scrollController.offset
                            : 0;
                      },
                      onPointerMove: _swipe.update,
                      onPointerCancel: _swipe.cancel,
                      onPointerUp: (event) {
                        final offset = _swipe.end(event);

                        if (offset == null) {
                          return;
                        }

                        final scrolling =
                            displayPreferences.layoutMode ==
                            ReaderLayoutMode.scroll;
                        final drag = scrolling ? offset.dy : offset.dx;
                        final crossAxis = scrolling ? offset.dx : offset.dy;

                        if (drag.abs() < 70 || drag.abs() <= crossAxis.abs()) {
                          return;
                        }

                        if (scrolling && _scrollController.hasClients) {
                          final position = _scrollController.position;

                          if (drag < 0 &&
                              _startScroll >= position.maxScrollExtent - 1) {
                            _requestTurn(1);
                          }

                          if (drag > 0 && _startScroll <= 1) {
                            _requestTurn(-1);
                          }
                        } else {
                          if (drag < 0 &&
                              (!_animateTurns ||
                                  _startPage ==
                                      (pages.length / columns).ceil() - 1)) {
                            _requestTurn(1);
                          }

                          if (drag > 0 && (!_animateTurns || _startPage == 0)) {
                            _requestTurn(-1);
                          }
                        }
                      },
                      child:
                          Localizations.of<MaterialLocalizations>(
                                context,
                                MaterialLocalizations,
                              ) ==
                              null
                          ? content
                          : SelectionArea(
                              key: _selectionKey,
                              contextMenuBuilder: _selectionMenu,
                              onSelectionChanged: (selection) {
                                final selected =
                                    selection?.plainText.isNotEmpty ?? false;
                                _selectedText = selection?.plainText ?? '';
                                if (!selected) {
                                  _menuRevision++;
                                  _menuBounds = null;
                                  _selectionMenuController.remove();
                                }
                                _swipe.selectionChanged(selected);
                                ReaderInteractionScope.maybeOf(
                                  context,
                                )?.onSelectionChanged(selected);
                              },
                              child: _SelectionStatusObserver(
                                onChanged: _selectionStatusChanged,
                                child: content,
                              ),
                            ),
                    ),
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                        ignoring: !ready || _turnPages != null,
                        child: surface,
                      ),
                      if (!ready && _showLoading && !snapshot.hasError)
                        const PositionedDirectional(
                          top: 8,
                          end: 8,
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      if (snapshot.hasError)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: FilledButton(
                            onPressed: () => setState(() => _layoutKey = null),
                            child: const Text(
                              'Could not prepare pages. Try again',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _spread(
    List<EpubRichPage> pages,
    int index,
    int columns,
    ReaderPreferences preferences, {
    int? spine,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var column = 0; column < columns; column++)
        Expanded(
          child: index * columns + column < pages.length
              ? _page(
                  pages[index * columns + column],
                  preferences,
                  spine: spine,
                )
              : const SizedBox.shrink(),
        ),
    ],
  );

  double _pageHeight(EpubRichPage page, ReaderPreferences preferences) =>
      preferences.pageMargins.vertical +
      page.fragments.fold<double>(
        0,
        (sum, fragment) =>
            sum + fragment.height + fragment.spacing(preferences),
      );

  Widget _page(
    EpubRichPage page,
    ReaderPreferences preferences, {
    bool scroll = false,
    int? spine,
  }) {
    final highlights =
        ReaderInteractionScope.maybeOf(context)?.highlights.where((highlight) {
          final start = highlight.selection.start;
          return start is EpubReaderLocator &&
              start.spineIndex == (spine ?? widget.engine.locator.spineIndex);
        }).toList() ??
        const <ReaderHighlight>[];

    final children = [
      for (final fragment in page.fragments)
        Padding(
          padding: EdgeInsets.only(bottom: fragment.spacing(preferences)),
          child: buildEpubFragment(
            fragment,
            preferences,
            highlights: highlights,
          ),
        ),
    ];
    return Padding(
      padding: preferences.pageMargins,
      child: scroll
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            )
          // Oversized single lines remain reachable at extreme accessibility sizes.
          : ListView(
              physics: const ClampingScrollPhysics(),
              children: children,
            ),
    );
  }
}

final class _EpubScrollDelegate extends SliverChildBuilderDelegate {
  _EpubScrollDelegate(
    super.builder, {
    required super.childCount,
    required this.extent,
  });
  final double extent;
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => extent;
}

/// Observes selection completion without inserting a nested selection container.
final class _SelectionStatusObserver extends StatefulWidget {
  const _SelectionStatusObserver({
    required this.onChanged,
    required this.child,
  });
  final ValueChanged<SelectableRegionSelectionStatus> onChanged;
  final Widget child;

  @override
  State<_SelectionStatusObserver> createState() =>
      _SelectionStatusObserverState();
}

final class _SelectionStatusObserverState
    extends State<_SelectionStatusObserver> {
  ValueListenable<SelectableRegionSelectionStatus>? _status;

  void _changed() => widget.onChanged(_status!.value);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final status = SelectableRegionSelectionStatusScope.maybeOf(context);
    if (identical(status, _status)) return;
    _status?.removeListener(_changed);
    _status = status;
    _status?.addListener(_changed);
  }

  @override
  void dispose() {
    _status?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
