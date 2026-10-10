import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../domain/reader_types.dart';
import '../../domain/reader_preferences.dart';
import '../../presentation/reader_interaction_scope.dart';
import 'epub_reader_engine.dart';
import 'epub_rich_layout.dart';
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
  final Map<Object, List<EpubRichPage>> _layoutCache = {};
  Timer? _prefetchTimer;
  int _prefetchGeneration = 0;
  ReaderPreferences? _displayPreferences;
  int _displayColumns = 1;
  Timer? _loadingTimer;
  bool _showLoading = false;
  int _restoration = -1;
  int _pageIndex = 0;
  int _columns = 1;
  double _drag = 0;
  int _startPage = 0;
  double _startScroll = 0;
  bool _restoring = false;
  bool _busy = false;
  Completer<void>? _layoutReady;
  List<double> _scrollOffsets = const [];

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_changed);
    widget.engine.moveWithinChapter = _move;
    widget.engine.prepareChapter = _prepareChapter;
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
      oldWidget.engine.moveWithinChapter = null;
      oldWidget.engine.prepareChapter = null;
      _layoutCache.clear();
      _pages = const [];
      widget.engine.addListener(_changed);
      widget.engine.moveWithinChapter = _move;
      widget.engine.prepareChapter = _prepareChapter;
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
        initialPage: _pageIndex,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_pages, pages)) return;
      _restoring = true;
      if (widget.engine.preferences.layoutMode == ReaderLayoutMode.paginated) {
        if (_pagesController.hasClients) {
          _pagesController.jumpToPage(_pageIndex);
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
    final count = (_pages.length / _columns).ceil();
    final next = _pageIndex + direction;
    if (next < 0 || next >= count) return false;
    _pageIndex = next;
    if (_pagesController.hasClients) _pagesController.jumpToPage(next);
    _publishPage(next);
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
    widget.engine.viewportChanged(
      spreads <= 1 ? 0 : index / (spreads - 1),
      textOffset: restoredOffset ?? _pages[page].offset,
      pageNumber: page + 1,
      pageCount: _pages.length,
      coverageStart: _pages[page].offset,
      coverageEnd: after < _pages.length
          ? _pages[after].offset
          : widget.engine.contentLength,
      atEnd: after == _pages.length,
    );
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

  void _beyondChapter(int direction) {
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

  Future<List<EpubRichPage>> _measure(
    int index,
    List<EpubContentBlock> blocks, {
    int? prefetch,
  }) async {
    final geometry = _geometryKey;
    final key = (index, geometry);
    final cached = _layoutCache[key];

    if (cached != null) {
      return cached;
    }

    bool cancelled() =>
        !mounted ||
        geometry != _geometryKey ||
        (prefetch != null && prefetch != _prefetchGeneration);
    final pages = await layoutEpubChapter(
      blocks,
      contentSize: _contentSize,
      preferences: widget.engine.preferences,
      textScaler: _scaler,
      direction: _direction,
      cancelled: cancelled,
    );

    if (!cancelled() && pages.isNotEmpty) {
      _layoutCache[key] = pages;

      while (_layoutCache.length > 3) {
        _layoutCache.remove(_layoutCache.keys.first);
      }
    }

    return pages;
  }

  Future<void> _prepareChapter(int index, List<EpubContentBlock> blocks) async {
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
      await _measure(index, blocks);
    } while (mounted && geometry != _geometryKey);
  }

  void _schedulePrefetch() {
    _prefetchTimer?.cancel();
    final generation = ++_prefetchGeneration;
    final index = widget.engine.locator.spineIndex;
    _prefetchTimer = Timer(const Duration(milliseconds: 150), () async {
      for (final neighbor in [index + 1, index - 1]) {
        if (!mounted || generation != _prefetchGeneration) {
          return;
        }

        if (neighbor < 0 || neighbor >= widget.engine.chapterCount) {
          continue;
        }

        try {
          final chapter = await widget.engine.chapterContent(neighbor);

          if (!mounted || generation != _prefetchGeneration) {
            return;
          }

          await _measure(neighbor, [
            for (final block in chapter['blocks'] as List)
              EpubContentBlock(Map<String, Object?>.from(block as Map)),
          ], prefetch: generation);
        } catch (_) {
          // Speculative work must not interrupt the readable current page.
          // Requested navigation will surface a chapter error with retry.
        }
      }
    });
  }

  @override
  void dispose() {
    _prefetchGeneration++;
    _prefetchTimer?.cancel();
    _loadingTimer?.cancel();
    if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
    widget.engine.removeListener(_changed);
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    widget.engine.moveWithinChapter = null;
    widget.engine.prepareChapter = null;
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
      color: preferences.backgroundColor,
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
            _layoutCache.clear();
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
                  )
                : SynchronousFuture(cached);
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
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Could not lay out this chapter.',
                            style: TextStyle(
                              color: preferences.foregroundColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () => setState(() => _layoutKey = null),
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    );
                  }
                  final ready =
                      snapshot.connectionState == ConnectionState.done &&
                      snapshot.hasData &&
                      snapshot.data!.isNotEmpty;

                  if (!ready && _pages.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: preferences.foregroundColor,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Preparing pages…',
                            style: TextStyle(
                              color: preferences.foregroundColor,
                            ),
                          ),
                        ],
                      ),
                    );
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
                    content = PageView.builder(
                      key: ValueKey(_pagesController),
                      controller: _pagesController,
                      onPageChanged: _publishPage,
                      itemCount: (pages.length / columns).ceil(),
                      itemBuilder: (context, index) => Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var column = 0; column < columns; column++)
                            Expanded(
                              child: index * columns + column < pages.length
                                  ? _page(
                                      pages[index * columns + column],
                                      displayPreferences,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                        ],
                      ),
                    );
                  }
                  // Pointer tracking does not claim the gesture arena from text
                  // selection, links or scrolling. Only a drag past a boundary turns.
                  final surface = Listener(
                    onPointerDown: (_) {
                      _drag = 0;
                      _startPage = _pageIndex;
                      _startScroll = _scrollController.hasClients
                          ? _scrollController.offset
                          : 0;
                    },
                    onPointerMove: (event) => _drag +=
                        displayPreferences.layoutMode == ReaderLayoutMode.scroll
                        ? event.delta.dy
                        : event.delta.dx,
                    onPointerUp: (_) {
                      if (_drag.abs() < 70) return;
                      if (displayPreferences.layoutMode ==
                              ReaderLayoutMode.scroll &&
                          _scrollController.hasClients) {
                        final p = _scrollController.position;
                        if (_drag < 0 &&
                            _startScroll >= p.maxScrollExtent - 1) {
                          _beyondChapter(1);
                        }
                        if (_drag > 0 && _startScroll <= 1) _beyondChapter(-1);
                      } else {
                        if (_drag < 0 &&
                            _startPage == (pages.length / columns).ceil() - 1) {
                          _beyondChapter(1);
                        }
                        if (_drag > 0 && _startPage == 0) _beyondChapter(-1);
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
                            onSelectionChanged: (selection) =>
                                ReaderInteractionScope.maybeOf(
                                  context,
                                )?.onSelectionChanged(
                                  selection?.plainText.isNotEmpty ?? false,
                                ),
                            child: content,
                          ),
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(ignoring: !ready, child: surface),
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
  }) {
    final children = [
      for (final fragment in page.fragments)
        Padding(
          padding: EdgeInsets.only(bottom: fragment.spacing(preferences)),
          child: buildEpubFragment(fragment, preferences),
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
