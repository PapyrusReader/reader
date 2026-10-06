import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/reader_types.dart';
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
  final PageController _pagesController = PageController();
  final ScrollController _scrollController = ScrollController();
  Future<List<EpubRichPage>>? _layout;
  List<EpubRichPage> _pages = const [];
  Object? _layoutKey;
  int _layoutGeneration = 0;
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
    _scrollController.addListener(_scrollChanged);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() {
    if (!mounted) return;
    setState(() => _layoutKey = null);
  }

  @override
  void didUpdateWidget(covariant EpubViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      oldWidget.engine.removeListener(_changed);
      oldWidget.engine.moveWithinChapter = null;
      widget.engine.addListener(_changed);
      widget.engine.moveWithinChapter = _move;
      _layoutKey = null;
    }
  }

  void _changed() {
    if (mounted && _restoration != widget.engine.restorationRevision) {
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
    _pageIndex = target ~/ _columns;
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
      if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
      widget.engine.viewportPaginationChanged(pages.length, target + 1);
      if (widget.engine.preferences.layoutMode == ReaderLayoutMode.paginated) {
        _publishCoverage(_pageIndex * _columns);
      } else {
        _scrollChanged();
      }
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

  void _publishPage(int index) {
    if (_restoring || _pages.isEmpty) return;
    _pageIndex = index;
    final page = (index * _columns).clamp(0, _pages.length - 1);
    widget.engine.viewportPositionChanged(
      _pages.length <= _columns ? 0 : page / (_pages.length - _columns),
      textOffset: _pages[page].offset,
      pageNumber: page + 1,
    );
    _publishCoverage(page);
  }

  void _publishCoverage(int page) {
    final after = math.min(page + _columns, _pages.length);
    widget.engine.viewportCoverageChanged(
      _pages[page].offset,
      after < _pages.length
          ? _pages[after].offset
          : widget.engine.contentLength,
      atEnd: after == _pages.length,
    );
  }

  void _scrollChanged() {
    if (_restoring || !_scrollController.hasClients || _pages.isEmpty) return;
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
    widget.engine.viewportPositionChanged(
      max <= 0 ? 0 : (pixels / max).clamp(0, 1),
      textOffset: offset,
      pageNumber: index + 1,
    );
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
    widget.engine.viewportCoverageChanged(
      offset,
      lastOffset.clamp(0, widget.engine.contentLength),
      atEnd: pixels >= max - 1,
    );
  }

  void _beyondChapter(int direction) {
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

  @override
  void dispose() {
    _layoutGeneration++;
    if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
    widget.engine.removeListener(_changed);
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    widget.engine.moveWithinChapter = null;
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
          final key = (
            widget.engine.contentRevision,
            contentSize,
            preferences,
            scaler,
            direction,
            _columns,
          );
          if (_layoutKey != key) {
            _layoutKey = key;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _layoutKey == key && _busy) {
                widget.engine.viewportPreparing();
              }
            });
            _restoration = -1;
            _restoring = true;
            final generation = ++_layoutGeneration;
            _busy = true;
            if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
            _layoutReady = Completer<void>();
            _layout = Future<void>.delayed(Duration.zero).then(
              (_) => layoutEpubChapter(
                widget.engine.blocks,
                contentSize: contentSize,
                preferences: preferences,
                textScaler: scaler,
                direction: direction,
                cancelled: () => !mounted || generation != _layoutGeneration,
              ),
            );
          }
          return Center(
            child: SizedBox(
              width: width,
              child: FutureBuilder<List<EpubRichPage>>(
                future: _layout,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
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
                  if (snapshot.connectionState != ConnectionState.done ||
                      !snapshot.hasData ||
                      snapshot.data!.isEmpty) {
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
                  final pages = snapshot.data!;
                  _restore(pages, width);
                  Widget content;
                  if (preferences.layoutMode == ReaderLayoutMode.scroll) {
                    final heights = [
                      for (final page in pages) _pageHeight(page),
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
                      controller: _scrollController,
                      itemExtentBuilder: (index, _) => heights[index],
                      childrenDelegate: _EpubScrollDelegate(
                        (context, index) => _page(pages[index], scroll: true),
                        childCount: pages.length,
                        extent: cumulative,
                      ),
                    );
                  } else {
                    content = PageView.builder(
                      controller: _pagesController,
                      onPageChanged: _publishPage,
                      itemCount: (pages.length / _columns).ceil(),
                      itemBuilder: (context, index) => Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var column = 0; column < _columns; column++)
                            Expanded(
                              child: index * _columns + column < pages.length
                                  ? _page(pages[index * _columns + column])
                                  : const SizedBox.shrink(),
                            ),
                        ],
                      ),
                    );
                  }
                  // Pointer tracking does not claim the gesture arena from text
                  // selection, links or scrolling. Only a drag past a boundary turns.
                  return Listener(
                    onPointerDown: (_) {
                      _drag = 0;
                      _startPage = _pageIndex;
                      _startScroll = _scrollController.hasClients
                          ? _scrollController.offset
                          : 0;
                    },
                    onPointerMove: (event) => _drag +=
                        preferences.layoutMode == ReaderLayoutMode.scroll
                        ? event.delta.dy
                        : event.delta.dx,
                    onPointerUp: (_) {
                      if (_drag.abs() < 70) return;
                      if (preferences.layoutMode == ReaderLayoutMode.scroll &&
                          _scrollController.hasClients) {
                        final p = _scrollController.position;
                        if (_drag < 0 &&
                            _startScroll >= p.maxScrollExtent - 1) {
                          _beyondChapter(1);
                        }
                        if (_drag > 0 && _startScroll <= 1) _beyondChapter(-1);
                      } else {
                        if (_drag < 0 &&
                            _startPage ==
                                (pages.length / _columns).ceil() - 1) {
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
                        : SelectionArea(child: content),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  double _pageHeight(EpubRichPage page) =>
      widget.engine.preferences.pageMargins.vertical +
      page.fragments.fold<double>(
        0,
        (sum, fragment) =>
            sum + fragment.height + fragment.spacing(widget.engine.preferences),
      );

  Widget _page(EpubRichPage page, {bool scroll = false}) {
    final preferences = widget.engine.preferences;
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
