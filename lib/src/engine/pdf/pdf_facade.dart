import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/reader_types.dart';
import '../../domain/reader_selection.dart';
import '../../domain/reader_locator.dart';
import '../../presentation/reader_interaction_scope.dart';
import '../../presentation/reader_swipe_tracker.dart';
import '../../presentation/reader_highlight_interaction.dart';
import 'pdf_selection_toolbar.dart';
import 'pdf_selection_handles.dart';
import '../../domain/pdf_reader_tools.dart';

enum PdfFacadeError { invalid, encrypted }

final class PdfFacadeException implements Exception {
  const PdfFacadeException(this.error, [this.cause]);

  final PdfFacadeError error;
  final Object? cause;
}

final class PdfFacadeOutlineEntry {
  const PdfFacadeOutlineEntry({
    required this.title,
    required this.pageIndex,
    this.children = const [],
  });

  final String title;
  final int pageIndex;
  final List<PdfFacadeOutlineEntry> children;
}

final class PdfViewportConfiguration {
  const PdfViewportConfiguration({
    required this.pageIndex,
    required this.facingPages,
    required this.backgroundColor,
    required this.brightness,
    required this.layoutMode,
    required this.onPageChanged,
    this.highlightLinks = true,
    this.pageTurnAnimation = true,
    this.onPositionChanged,
    this.onVisiblePagesChanged,
    this.onContentReadyChanged,
  });

  final int pageIndex;
  final bool facingPages;
  final bool highlightLinks;
  final bool pageTurnAnimation;
  final Color backgroundColor;
  final Brightness brightness;
  final ReaderLayoutMode layoutMode;
  final ValueChanged<int> onPageChanged;
  final void Function(int pageIndex, double pageOffset)? onPositionChanged;
  final ValueChanged<List<int>>? onVisiblePagesChanged;
  final ValueChanged<bool>? onContentReadyChanged;
}

abstract interface class PdfFacade {
  int get pageCount;

  List<PdfFacadeOutlineEntry> get outline;

  Future<void> showPage(int pageIndex, double pageOffset);

  Widget buildViewport(PdfViewportConfiguration configuration);
}

abstract interface class DisposablePdfFacade {
  void dispose();
}

typedef PdfFacadeFactory = Future<PdfFacade> Function(Uint8List bytes);

abstract interface class PdfMetadataDocument {
  int get pageCount;

  List<Size> get pageSizes;

  Future<List<PdfFacadeOutlineEntry>> loadOutline();

  Future<void> dispose();
}

typedef PdfMetadataDocumentLoader = Future<PdfMetadataDocument> Function();

Future<PdfFacade> createPdfrxFacade(
  Uint8List bytes, {
  required String sourceName,
  bool preserveColors = false,
  PdfViewState? initialView,
  bool preferInitialLocator = false,
  ValueChanged<PdfViewState>? onViewChanged,
  Future<void> Function(Uri)? onOpenLink,
  PdfMetadataDocumentLoader? metadataDocumentLoader,
}) async {
  final reference = PdfDocumentRefData(
    bytes,
    sourceName: sourceName,
    key: PdfDocumentRefKey(sourceName, [bytes]),
  );
  PdfMetadataDocument? metadataDocument;
  VoidCallback? releaseDocument;

  try {
    if (metadataDocumentLoader != null) {
      metadataDocument = await metadataDocumentLoader();
    } else {
      final shared = reference.resolveListenable();
      releaseDocument = shared.addListener(() {});
      await shared.load();
      if (shared.error != null) throw shared.error!;
      metadataDocument = _PdfrxMetadataDocument(shared.document!);
    }
    final outline = await metadataDocument.loadOutline();

    final facade = _PdfrxFacade(
      documentRef: reference,
      preserveColors: preserveColors,
      initialView: initialView,
      preferInitialLocator: preferInitialLocator,
      onViewChanged: onViewChanged,
      onOpenLink: onOpenLink,
      pageCount: metadataDocument.pageCount,
      outline: List.unmodifiable(outline),
      releaseDocument: releaseDocument,
    );
    releaseDocument = null;
    return facade;
  } on PdfPasswordException catch (error) {
    throw PdfFacadeException(PdfFacadeError.encrypted, error);
  } on PdfFacadeException {
    rethrow;
  } on Object catch (error) {
    throw PdfFacadeException(PdfFacadeError.invalid, error);
  } finally {
    if (metadataDocumentLoader != null) await metadataDocument?.dispose();
    releaseDocument?.call();
  }
}

final class _PdfrxMetadataDocument implements PdfMetadataDocument {
  const _PdfrxMetadataDocument(this._document);

  final PdfDocument _document;

  @override
  int get pageCount => _document.pages.length;

  @override
  List<Size> get pageSizes => _document.pages
      .map((page) => Size(page.width, page.height))
      .toList(growable: false);

  @override
  Future<List<PdfFacadeOutlineEntry>> loadOutline() async {
    final outline = await _document.loadOutline();

    return outline.map(_convertOutline).toList(growable: false);
  }

  @override
  Future<void> dispose() => _document.dispose();
}

PdfFacadeOutlineEntry _convertOutline(PdfOutlineNode node) {
  return PdfFacadeOutlineEntry(
    title: node.title,
    pageIndex: max(0, (node.dest?.pageNumber ?? 1) - 1),
    children: List.unmodifiable(node.children.map(_convertOutline)),
  );
}

final class _PdfrxFacade extends PdfReaderTools
    implements PdfFacade, DisposablePdfFacade {
  _PdfrxFacade({
    required PdfDocumentRef documentRef,
    this.preserveColors = false,
    PdfViewState? initialView,
    bool preferInitialLocator = false,
    this.onViewChanged,
    this.onOpenLink,
    required this.pageCount,
    required this.outline,
    VoidCallback? releaseDocument,
  }) : _documentRef = documentRef,
       _releaseDocument = releaseDocument,
       _savedView = initialView,
       _preferInitialLocator = preferInitialLocator,
       _fitMode = initialView?.fitMode {
    _controller.addListener(_positionChanged);
    _searcher = PdfTextSearchSession(_controller)..addListener(_searchChanged);
  }

  final PdfDocumentRef _documentRef;
  final bool preserveColors;
  final ValueChanged<PdfViewState>? onViewChanged;
  final Future<void> Function(Uri)? onOpenLink;
  late final PdfTextSearchSession _searcher;
  PdfViewState? _savedView;
  bool _preferInitialLocator;
  PdfFitMode? _fitMode;
  final List<PdfViewState> _history = [];
  final List<PdfViewState> _forwardHistory = [];
  Timer? _saveTimer;
  String _query = '';
  List<PdfSearchMatch> _matches = const [];
  bool _applyingView = false;

  @override
  bool get isReady => !_disposed && _controller.isReady && !_restoring;
  @override
  int get pageNumber => _pageIndex + 1;
  @override
  double get zoom => _controller.isReady ? _controller.currentZoom : 1;
  @override
  double get minimumZoom => .1;
  @override
  double get maximumZoom => 8;
  @override
  bool get canReturn => _history.isNotEmpty;
  @override
  bool get canGoForward => _forwardHistory.isNotEmpty;
  @override
  bool get searching => _searcher.isSearching;
  @override
  String get query => _query;
  @override
  int? get currentMatch => _searcher.currentIndex;
  @override
  List<PdfSearchMatch> get matches => _matches;

  void _searchChanged() {
    if (_disposed) return;
    _matches = List.unmodifiable([
      for (final match in _searcher.matches)
        PdfSearchMatch(
          pageNumber: match.pageNumber,
          text: match.contextText.replaceAll(RegExp(r'\s+'), ' '),
        ),
    ]);
    if (_controller.isReady) _controller.invalidate();
    notifyListeners();
  }

  @override
  void search(String query) {
    _query = query.trim();
    if (_query.isEmpty) {
      _searcher.resetTextSearch();
    } else {
      _searcher.startTextSearch(
        _query,
        goToFirstMatch: false,
        startPageNumber: pageNumber,
      );
    }
  }

  void _rememberLocation(PdfViewState? previous) {
    final current = _captureView();
    if (previous == null || current == null) return;
    if (previous.pageIndex == current.pageIndex &&
        (previous.zoom - current.zoom).abs() < .000001 &&
        (previous.centerX - current.centerX).abs() < .000001 &&
        (previous.centerY - current.centerY).abs() < .000001) {
      return;
    }

    _history.add(previous);
    _forwardHistory.clear();
  }

  @override
  Future<void> selectMatch(int index) async {
    if (!isReady || index < 0 || index >= _searcher.matches.length) return;
    final previous = _captureView();
    final match = _searcher.matches[index];
    _pageIndex = match.pageNumber - 1;
    _fitMode = PdfFitMode.custom;
    final rect = _controller.calcRectForRectInsidePage(
      pageNumber: match.pageNumber,
      rect: match.bounds,
    );
    await _controller.setZoom(rect.center, zoom, duration: Duration.zero);
    await _searcher.goToMatchOfIndex(index);
    _rememberLocation(previous);
    _positionChanged();
  }

  @override
  Future<void> goToPage(int pageNumber) async {
    if (!isReady) return;
    RangeError.checkValueInInterval(pageNumber, 1, pageCount, 'pageNumber');
    await showPage(pageNumber - 1, 0);
    _positionChanged();
  }

  @override
  Future<void> returnToPrevious() => _restoreHistory(_history, _forwardHistory);

  @override
  Future<void> goForward() => _restoreHistory(_forwardHistory, _history);

  Future<void> _restoreHistory(
    List<PdfViewState> source,
    List<PdfViewState> destination,
  ) async {
    if (!isReady || source.isEmpty) return;
    final current = _captureView();
    if (current == null) return;
    final target = source.last;
    _savedView = target;
    _fitMode = target.fitMode;
    _pageIndex = target.pageIndex;
    await _restorePage(restoreLocation: true);
    source.removeLast();
    destination.add(current);
    _positionChanged();
  }

  @override
  Future<void> setZoom(double value) async {
    if (!isReady || !value.isFinite) return;
    _fitMode = PdfFitMode.custom;
    await _controller.setZoom(
      _controller.visibleRect.center,
      value.clamp(minimumZoom, maximumZoom),
      duration: Duration.zero,
    );
    _positionChanged();
  }

  @override
  Future<void> scrollVertically(double distance) async {
    if (!isReady || !distance.isFinite) return;
    await _controller.goTo(
      _controller.calcMatrixFor(
        _controller.visibleRect.center + Offset(0, distance),
        zoom: zoom,
      ),
      duration: Duration.zero,
    );
    _positionChanged();
  }

  @override
  Future<void> fitPage() => _fit(PdfFitMode.page);
  @override
  Future<void> fitWidth() => _fit(PdfFitMode.width);

  Future<void> _fit(PdfFitMode mode) async {
    if (!isReady) return;
    _fitMode = mode;
    _savedView = null;
    await _restorePage();
    _positionChanged();
  }

  Future<void> _openLink(PdfLink link) async {
    if (!isReady) return;
    if (link.dest case final destination?) {
      if (destination.pageNumber < 1 || destination.pageNumber > pageCount) {
        return;
      }
      final previous = _captureView();
      _pageIndex = destination.pageNumber - 1;
      _fitMode = PdfFitMode.custom;
      await _controller.goToDest(destination, duration: Duration.zero);
      _rememberLocation(previous);
      _positionChanged();
    } else if (link.url case final uri?) {
      await onOpenLink?.call(uri);
    }
  }

  PdfViewerHandleLinkTap? _handleLinkTap;
  final Set<int> _linkPointers = {};
  PointerDownEvent? _linkStart;
  bool _linkTapHandled = false;

  void _startLinkTap(PointerDownEvent event) {
    _linkPointers.add(event.pointer);
    _linkTapHandled = false;
    _linkStart =
        _linkPointers.length == 1 &&
            event.buttons == kPrimaryButton &&
            isReady &&
            !_controller.textSelectionDelegate.hasSelectedText
        ? event
        : null;
  }

  void _moveLinkTap(PointerMoveEvent event) {
    final start = _linkStart;
    if (start == null || event.pointer != start.pointer) return;
    final slop = start.kind == PointerDeviceKind.mouse
        ? kPrecisePointerHitSlop
        : kTouchSlop;

    if ((event.position - start.position).distance > slop) {
      _linkStart = null;
    }
  }

  void _endLinkTap(PointerUpEvent event) {
    _linkPointers.remove(event.pointer);
    final start = _linkStart;
    _linkStart = null;

    if (start == null ||
        event.pointer != start.pointer ||
        _linkPointers.isNotEmpty ||
        event.timeStamp - start.timeStamp >= kLongPressTimeout ||
        !isReady ||
        _controller.textSelectionDelegate.hasSelectedText) {
      return;
    }

    // Dispatch links on release instead of waiting for pdfrx's double-tap timer.
    _linkTapHandled = _handleLinkTap?.call(event.localPosition) ?? false;
  }

  void _cancelLinkTap(PointerCancelEvent event) {
    _linkPointers.remove(event.pointer);
    _linkStart = null;
  }

  PdfViewState? _captureView() {
    if (!_controller.isReady || _configuration == null || _restoring) {
      return null;
    }
    final page = _controller.layout.pageLayouts[_pageIndex];
    final center = _controller.visibleRect.center;
    return PdfViewState(
      pageIndex: _pageIndex,
      zoom: zoom.clamp(.1, 8),
      centerX: ((center.dx - page.left) / page.width).clamp(0, 1),
      centerY: ((center.dy - page.top) / page.height).clamp(0, 1),
      fitMode: _fitMode ?? PdfFitMode.page,
    );
  }

  final PdfViewerController _controller = PdfViewerController();
  int _currentPageIndex = 0;
  int get _pageIndex => _currentPageIndex;
  set _pageIndex(int value) {
    if (_currentPageIndex == value) return;
    _currentPageIndex = value;
    final pages = _pagesController;
    if (pages != null && pages.hasClients) {
      pages.jumpToPage(value ~/ _spreadStep);
    }
    notifyListeners();
  }

  double _pageOffset = 0;
  final VoidCallback? _releaseDocument;
  PdfViewportConfiguration? _configuration;
  bool _restoring = false;
  bool _scheduled = false;
  bool _disposed = false;
  Object? _viewKey;
  int _viewerRevision = 0;
  DateTime? _lastWheelTurn;
  final _swipe = ReaderSwipeTracker();
  bool _textSelected = false;
  PageController? _pagesController;
  GlobalKey _viewerKey = GlobalKey();
  PdfDocument? _previewDocument;
  PdfPageLayout? _previewLayout;
  Drag? _pageDrag;
  bool _pagingEnabled = false;
  final Set<int> _pagePointers = {};
  bool _multiTouch = false;
  int get _spreadStep => _configuration?.facingPages == true ? 2 : 1;

  @override
  final int pageCount;

  @override
  final List<PdfFacadeOutlineEntry> outline;

  @override
  Future<void> showPage(int pageIndex, double pageOffset) async {
    final previous = _captureView();
    _pageIndex = pageIndex;
    _pageOffset = pageOffset;
    final pages = _pagesController;
    if (pages != null && pages.hasClients) {
      pages.jumpToPage(pageIndex ~/ _spreadStep);
    }
    if (_controller.isReady && !_restoring) {
      _savedView = null;
      _restoring = true;
      try {
        await _restorePage();
      } finally {
        _restoring = false;
      }
      _rememberLocation(previous);
      _positionChanged();
    }
  }

  Rect get _spread => pdfSpreadRect(
    _controller.layout,
    _pageIndex,
    _configuration!.facingPages,
  );

  double get _fitZoom => min(
    _controller.viewSize.width / _spread.width,
    _controller.viewSize.height / _spread.height,
  );

  bool get _atFit =>
      _controller.isReady && _controller.currentZoom <= _fitZoom * 1.02;

  double _zoomFor(PdfFitMode mode) => switch (mode) {
    PdfFitMode.page => _fitZoom,
    PdfFitMode.width => _controller.viewSize.width / _spread.width,
    PdfFitMode.custom => _savedView?.zoom ?? zoom,
  };

  Future<void> _restorePage({bool restoreLocation = false}) async {
    final config = _configuration;
    if (config == null) return;
    _fitMode ??= config.layoutMode == ReaderLayoutMode.paginated
        ? PdfFitMode.page
        : PdfFitMode.width;
    final scale = _zoomFor(_fitMode!).clamp(.1, 8.0);
    final page = _controller.layout.pageLayouts[_pageIndex];
    final saved = _savedView;
    final Offset center;
    if (!_preferInitialLocator &&
        saved != null &&
        saved.pageIndex == _pageIndex &&
        (restoreLocation || _fitMode != PdfFitMode.page)) {
      center = Offset(
        page.left + page.width * saved.centerX,
        page.top + page.height * saved.centerY,
      );
    } else if (_fitMode == PdfFitMode.page) {
      center = _spread.center;
    } else {
      center = Offset(
        _spread.center.dx,
        page.top +
            page.height * _pageOffset +
            _controller.viewSize.height / (2 * scale),
      );
    }
    _applyingView = true;
    try {
      await _controller.goTo(
        _controller.calcMatrixFor(center, zoom: scale),
        duration: Duration.zero,
      );
    } finally {
      _applyingView = false;
      _preferInitialLocator = false;
    }
  }

  Future<void> _turnSpread(int direction) async {
    final config = _configuration;
    if (_disposed || _restoring || config == null || !_controller.isReady) {
      return;
    }
    final step = config.facingPages ? 2 : 1;
    final target = (_pageIndex ~/ step) * step + direction * step;
    if (target < 0 || target >= pageCount) return;
    await showPage(target, 0);
    if (_disposed) return;
    config.onPositionChanged?.call(target, 0);
    if (config.onPositionChanged == null) config.onPageChanged(target);
  }

  Widget _spreadPreview(BuildContext context, int index, Size size) {
    final document = _previewDocument;
    final layout = _previewLayout;
    if (document == null || layout == null) return const SizedBox.expand();
    final config = _configuration!;
    final step = config.facingPages ? 2 : 1;
    final spread = pdfSpreadRect(layout, index, config.facingPages);
    final scale = switch (_fitMode) {
      PdfFitMode.custom => _controller.currentZoom,
      PdfFitMode.width => size.width / spread.width,
      _ => min(size.width / spread.width, size.height / spread.height),
    };
    final params = buildPdfViewerParams(
      config,
      searchPainter: _searcher.pageTextMatchPaintCallback,
      highlights:
          ReaderInteractionScope.maybeOf(context)?.highlights ?? const [],
    );

    return ColoredBox(
      color: params.backgroundColor,
      child: Center(
        child: SizedBox(
          width: spread.width * scale,
          height: spread.height * scale,
          child: Stack(
            children: [
              for (
                var page = index;
                page < min(index + step, pageCount);
                page++
              )
                Positioned.fromRect(
                  rect: Rect.fromLTWH(
                    (layout.pageLayouts[page].left - spread.left) * scale,
                    (layout.pageLayouts[page].top - spread.top) * scale,
                    layout.pageLayouts[page].width * scale,
                    layout.pageLayouts[page].height * scale,
                  ),
                  child: PdfPageView(
                    document: document,
                    pageNumber: page + 1,
                    decorationBuilder: (context, size, page, image) =>
                        ColoredBox(
                          color: Colors.white,
                          child: CustomPaint(
                            foregroundPainter: _PdfPreviewPainter(
                              page,
                              params.pagePaintCallbacks ?? const [],
                            ),
                            child: image ?? const SizedBox.expand(),
                          ),
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveSelection(
    PdfTextSelectionDelegate delegate,
    ValueChanged<ReaderSelection> action,
  ) async {
    final ranges = await delegate.getSelectedTextRanges();

    if (_disposed || ranges.isEmpty) {
      return;
    }

    final rectangles = <ReaderSelectionRect>[];

    for (final range in ranges) {
      final page = _controller.document.pages[range.pageNumber - 1];

      for (final fragment in range.enumerateFragmentBoundingRects()) {
        final bounds = fragment.bounds.toRect(page: page);
        final rect = Rect.fromLTRB(
          (bounds.left / page.width).clamp(0, 1),
          (bounds.top / page.height).clamp(0, 1),
          (bounds.right / page.width).clamp(0, 1),
          (bounds.bottom / page.height).clamp(0, 1),
        );
        if (rect.isEmpty) continue;
        rectangles.add(
          ReaderSelectionRect(pageIndex: range.pageNumber - 1, rect: rect),
        );
      }
    }

    if (rectangles.isEmpty) return;

    PdfReaderLocator at(int page, double offset) => PdfReaderLocator(
      pageIndex: page,
      pageOffset: offset,
      totalProgression: pageCount <= 1 ? 0 : page / (pageCount - 1),
    );

    final selection = ReaderSelection(
      text: ranges.map((range) => range.text).join('\n'),
      start: at(ranges.first.pageNumber - 1, rectangles.first.rect.top),
      end: at(ranges.last.pageNumber - 1, rectangles.last.rect.bottom),
      rectangles: rectangles,
    );

    await delegate.clearTextSelection();

    if (_disposed) return;

    action(selection);
  }

  @override
  Widget buildViewport(PdfViewportConfiguration configuration) {
    if (_configuration != null &&
        _configuration!.layoutMode != configuration.layoutMode &&
        _fitMode != PdfFitMode.custom) {
      _fitMode = configuration.layoutMode == ReaderLayoutMode.paginated
          ? PdfFitMode.page
          : PdfFitMode.width;
    }
    _configuration = configuration;
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final key = (
            configuration.layoutMode,
            configuration.facingPages,
            size,
          );
          if (_viewKey != key) {
            _viewKey = key;
            _previewLayout = null;
            _viewerKey = GlobalKey();
            final previous = _pagesController;
            _pagesController =
                configuration.layoutMode == ReaderLayoutMode.paginated
                ? PageController(
                    initialPage: _pageIndex ~/ _spreadStep,
                    keepPage: false,
                  )
                : null;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => previous?.dispose(),
            );
            _viewerRevision++;
            _restoring = true;
            final revision = _viewerRevision;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_disposed && _restoring && revision == _viewerRevision) {
                _configuration?.onContentReadyChanged?.call(false);
              }
            });
          }
          final revision = _viewerRevision;
          _pagingEnabled =
              configuration.layoutMode == ReaderLayoutMode.paginated &&
              configuration.pageTurnAnimation &&
              !MediaQuery.disableAnimationsOf(context) &&
              !_restoring &&
              _atFit &&
              !_textSelected &&
              !_multiTouch;
          final viewer = Listener(
            onPointerSignal: (event) {
              if (configuration.layoutMode != ReaderLayoutMode.paginated ||
                  event is! PointerScrollEvent ||
                  _restoring ||
                  !_atFit ||
                  HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed) {
                return;
              }
              final delta =
                  event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
                  ? event.scrollDelta.dy
                  : event.scrollDelta.dx;
              if (delta.abs() < 10) return;
              final now = DateTime.now();
              if (_lastWheelTurn != null &&
                  now.difference(_lastWheelTurn!).inMilliseconds < 250) {
                return;
              }
              _lastWheelTurn = now;
              // Let pdfrx finish handling the wheel before snapping to the next row.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!_disposed && revision == _viewerRevision) {
                  final turn = ReaderInteractionScope.maybeOf(context)?.onTurn;
                  if (turn != null) {
                    turn(delta > 0 ? 1 : -1);
                  } else {
                    _turnSpread(delta > 0 ? 1 : -1);
                  }
                }
              });
              WidgetsBinding.instance.scheduleFrame();
            },
            onPointerDown: (event) {
              _swipe.start(event);
              _startLinkTap(event);
            },
            onPointerMove: (event) {
              _swipe.update(event);
              _moveLinkTap(event);
            },
            onPointerCancel: (event) {
              _swipe.cancel(event);
              _pageDrag?.cancel();
              _pageDrag = null;
              _pagesController?.jumpToPage(_pageIndex ~/ _spreadStep);
              _cancelLinkTap(event);
            },
            onPointerUp: (event) {
              _endLinkTap(event);
              final offset = _swipe.end(event);

              if (configuration.layoutMode == ReaderLayoutMode.paginated &&
                  (!configuration.pageTurnAnimation ||
                      MediaQuery.disableAnimationsOf(context)) &&
                  offset != null &&
                  !_restoring &&
                  _atFit &&
                  offset.dx.abs() > 70 &&
                  offset.dx.abs() > offset.dy.abs()) {
                final direction = offset.dx < 0 ? 1 : -1;
                final turn = ReaderInteractionScope.maybeOf(context)?.onTurn;

                if (turn != null) {
                  turn(direction);
                } else {
                  _turnSpread(direction);
                }
              }
            },
            child: ReaderHighlightInteraction(
              isSelecting: () => _textSelected,
              hitTest: (position) {
                if (!_controller.isReady) return null;
                final documentPosition = _controller.globalToDocument(position);
                if (documentPosition == null) return null;
                final target = pdfHighlightAt(
                  documentPosition,
                  _controller.layout.pageLayouts,
                  ReaderInteractionScope.maybeOf(context)?.highlights ??
                      const [],
                );
                if (target == null) return null;
                final visible = target.bounds.intersect(
                  _controller.visibleRect,
                );
                final topLeft = _controller.documentToGlobal(visible.topLeft);
                final bottomRight = _controller.documentToGlobal(
                  visible.bottomRight,
                );
                if (visible.isEmpty || topLeft == null || bottomRight == null) {
                  return null;
                }
                return (
                  highlight: target.highlight,
                  bounds: Rect.fromPoints(topLeft, bottomRight),
                );
              },
              child: PdfSelectionToolbar(
                controller: _controller,
                saveSelection: _saveSelection,
                child: PdfViewer(
                  _documentRef,
                  key: _viewerKey,
                  controller: _controller,
                  initialPageNumber: _pageIndex + 1,
                  params: buildPdfViewerParams(
                    configuration,
                    viewportSize: size,
                    onInteractionStart: _startPageDrag,
                    onInteractionUpdate: _updatePageDrag,
                    onInteractionEnd: _endPageDrag,
                    viewerController: _controller,
                    searchPainter: _searcher.pageTextMatchPaintCallback,
                    viewerOverlayBuilder: (_, _, handleLinkTap) {
                      _handleLinkTap = handleLinkTap;
                      return const [];
                    },
                    onGeneralTap: (_, _, _) {
                      final handled = _linkTapHandled;
                      _linkTapHandled = false;
                      return handled;
                    },
                    onLink: (link) {
                      // Consume the later classified tap after an immediate jump.
                      if (_linkTapHandled) {
                        _linkTapHandled = false;
                        return;
                      }

                      ReaderInteractionScope.maybeOf(context)?.suppressTap();
                      unawaited(
                        _openLink(link).catchError((Object error) {
                          if (context.mounted) {
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(
                                content: Text('Could not open this link.'),
                              ),
                            );
                          }
                        }),
                      );
                    },
                    customizeContextMenuItems: (params, items) {
                      if (!params.textSelectionDelegate.hasSelectedText ||
                          !params.textSelectionDelegate.isCopyAllowed) {
                        return;
                      }

                      final interactions = ReaderInteractionScope.maybeOf(
                        context,
                      );

                      for (final entry in [
                        ('Annotate', interactions?.onAnnotate),
                        ('Add note', interactions?.onNote),
                      ]) {
                        final action = entry.$2;

                        if (action != null) {
                          items.add(
                            ContextMenuButtonItem(
                              label: entry.$1,
                              onPressed: () {
                                params.dismissContextMenu();
                                _saveSelection(
                                  params.textSelectionDelegate,
                                  action,
                                );
                              },
                            ),
                          );
                        }
                      }
                    },
                    highlights:
                        ReaderInteractionScope.maybeOf(context)?.highlights ??
                        const [],
                    onTextSelectionChange: (selection) {
                      _textSelected = selection.hasSelectedText;
                      _swipe.selectionChanged(selection.hasSelectedText);
                      ReaderInteractionScope.maybeOf(
                        context,
                      )?.onSelectionChanged(selection.hasSelectedText);
                    },
                    currentPageIndex: () => _pageIndex,
                    onViewerReady: (_, _) async {
                      if (_disposed || revision != _viewerRevision) return;
                      _previewDocument = _controller.document;
                      _previewLayout = _controller.layout;
                      try {
                        await _restorePage();
                      } finally {
                        if (!_disposed && revision == _viewerRevision) {
                          _restoring = false;
                          _positionChanged();
                        }
                      }
                    },
                    onPageChanged: (_) => _positionChanged(),
                  ),
                ),
              ),
            ),
          );
          final pages = _pagesController;
          return applyPdfBrightness(
            preserveColors ? Brightness.light : configuration.brightness,
            pages == null
                ? viewer
                : Listener(
                    onPointerDown: _pagePointerDown,
                    onPointerUp: _pagePointerEnded,
                    onPointerCancel: _pagePointerEnded,
                    child: NotificationListener<ScrollEndNotification>(
                      onNotification: (notification) {
                        if (notification.depth == 0) {
                          scheduleMicrotask(_settlePage);
                        }
                        return false;
                      },
                      child: PageView.builder(
                        key: ValueKey(pages),
                        controller: pages,
                        allowImplicitScrolling: true,
                        physics: _pagingEnabled
                            ? const ClampingScrollPhysics()
                            : const NeverScrollableScrollPhysics(),
                        itemCount: (pageCount / _spreadStep).ceil(),
                        itemBuilder: (context, index) => SizedBox.expand(
                          key: ValueKey(('pdf-spread', index)),
                          child: index == _pageIndex ~/ _spreadStep
                              ? viewer
                              : _spreadPreview(
                                  context,
                                  index * _spreadStep,
                                  size,
                                ),
                        ),
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }

  void _pagePointerDown(PointerDownEvent event) {
    _pagePointers.add(event.pointer);
    if (_pagePointers.length > 1 && !_multiTouch) {
      _multiTouch = true;
      _pageDrag?.cancel();
      _pageDrag = null;
      _pagesController?.jumpToPage(_pageIndex ~/ _spreadStep);
      notifyListeners();
    }
  }

  void _pagePointerEnded(PointerEvent event) {
    _pagePointers.remove(event.pointer);
    if (_pagePointers.isEmpty && _multiTouch) {
      _multiTouch = false;
      notifyListeners();
    }
  }

  void _startPageDrag(ScaleStartDetails details) {
    final pages = _pagesController;
    if (!_pagingEnabled ||
        pages == null ||
        !pages.hasClients ||
        details.pointerCount != 1) {
      return;
    }
    _pageDrag = pages.position.drag(
      DragStartDetails(globalPosition: details.focalPoint),
      () => _pageDrag = null,
    );
  }

  void _updatePageDrag(ScaleUpdateDetails details) {
    final drag = _pageDrag;
    if (drag == null) return;
    if (details.pointerCount != 1 || (details.scale - 1).abs() > .001) {
      drag.cancel();
      _pageDrag = null;
      _pagesController?.jumpToPage(_pageIndex ~/ _spreadStep);
      return;
    }
    drag.update(
      DragUpdateDetails(
        globalPosition: details.focalPoint,
        delta: Offset(details.focalPointDelta.dx, 0),
        primaryDelta: details.focalPointDelta.dx,
      ),
    );
  }

  void _endPageDrag(ScaleEndDetails details) {
    final drag = _pageDrag;
    _pageDrag = null;
    drag?.end(
      DragEndDetails(
        velocity: Velocity(
          pixelsPerSecond: Offset(details.velocity.pixelsPerSecond.dx, 0),
        ),
        primaryVelocity: details.velocity.pixelsPerSecond.dx,
      ),
    );
  }

  void _settlePage() {
    final pages = _pagesController;
    if (_disposed ||
        _restoring ||
        pages == null ||
        !pages.hasClients ||
        pages.position.isScrollingNotifier.value) {
      return;
    }
    final target = pages.page!.round() * _spreadStep;
    if (target == (_pageIndex ~/ _spreadStep) * _spreadStep) return;
    unawaited(showPage(target, 0));
  }

  int _centerPageIndex() {
    final center = _controller.visibleRect.center;
    final pages = _controller.layout.pageLayouts;
    for (var index = 0; index < pages.length; index++) {
      if (pages[index].contains(center)) return index;
    }
    return ((_controller.pageNumber ?? 1) - 1).clamp(0, pageCount - 1);
  }

  void _positionChanged() {
    if (_disposed || _restoring || _scheduled || !_controller.isReady) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed || _restoring || !_controller.isReady) return;
      final config = _configuration;
      final index = config?.layoutMode == ReaderLayoutMode.paginated
          ? _pageIndex
          : _centerPageIndex();
      final page = _controller.layout.pageLayouts[index];
      final offset = config?.layoutMode == ReaderLayoutMode.paginated && _atFit
          ? 0.0
          : ((_controller.visibleRect.top - page.top) / page.height).clamp(
              0.0,
              1.0,
            );
      final visible = _controller.visibleRect;
      final exposure = pdfViewportExposure(
        _controller.layout.pageLayouts,
        visible,
      );
      config?.onVisiblePagesChanged?.call(exposure.pages);
      config?.onContentReadyChanged?.call(exposure.contentVisible);
      _pageIndex = index;
      _pageOffset = offset;
      if (!_applyingView &&
          _fitMode != null &&
          _fitMode != PdfFitMode.custom &&
          (zoom - _zoomFor(_fitMode!)).abs() > .01) {
        _fitMode = PdfFitMode.custom;
      }
      _savedView = _captureView();
      _saveTimer?.cancel();
      if (onViewChanged != null) {
        _saveTimer = Timer(const Duration(milliseconds: 250), () {
          if (!_disposed && _savedView != null) onViewChanged!(_savedView!);
        });
      }
      notifyListeners();
      if (config?.onPositionChanged != null) {
        config!.onPositionChanged!(index, offset);
      } else {
        config?.onPageChanged(index);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _saveTimer?.cancel();
    if (_savedView != null) onViewChanged?.call(_savedView!);
    _disposed = true;
    _pageDrag?.cancel();
    _pagesController?.dispose();
    _searcher.dispose();
    _controller.removeListener(_positionChanged);
    _releaseDocument?.call();
    _configuration = null;
    super.dispose();
  }
}

/// Visible content permits time tracking even when zoom prevents page qualification.
({bool contentVisible, List<int> pages}) pdfViewportExposure(
  List<Rect> pages,
  Rect viewport,
) {
  var contentVisible = false;
  final qualified = <int>[];
  for (var i = 0; i < pages.length; i++) {
    final rect = pages[i];
    if (!rect.overlaps(viewport)) continue;
    final intersection = rect.intersect(viewport);
    final area = intersection.width * intersection.height;
    if (area <= 0) continue;
    contentVisible = true;
    if (area >= rect.width * rect.height * .25) qualified.add(i);
  }
  return (contentVisible: contentVisible, pages: qualified);
}

ReaderHighlightTarget? pdfHighlightAt(
  Offset position,
  List<Rect> pages,
  List<ReaderHighlight> highlights,
) {
  for (final highlight in highlights.reversed) {
    for (final rectangle in highlight.selection.rectangles) {
      final pageIndex = rectangle.pageIndex;
      if (pageIndex < 0 || pageIndex >= pages.length) continue;
      final page = pages[pageIndex];
      final rect = rectangle.rect;
      final bounds = Rect.fromLTRB(
        page.left + rect.left * page.width,
        page.top + rect.top * page.height,
        page.left + rect.right * page.width,
        page.top + rect.bottom * page.height,
      );
      if (bounds.contains(position)) {
        return (highlight: highlight, bounds: bounds);
      }
    }
  }
  return null;
}

final class _PdfPreviewPainter extends CustomPainter {
  const _PdfPreviewPainter(this.page, this.painters);

  final PdfPage page;
  final List<PdfViewerPagePaintCallback> painters;

  @override
  void paint(Canvas canvas, Size size) {
    for (final painter in painters) {
      painter(canvas, Offset.zero & size, page);
    }
  }

  @override
  bool shouldRepaint(_PdfPreviewPainter oldDelegate) => true;
}

PdfViewerParams buildPdfViewerParams(
  PdfViewportConfiguration configuration, {
  PdfViewerController? viewerController,
  PdfViewerReadyCallback? onViewerReady,
  PdfViewerTextSelectionChangeCallback? onTextSelectionChange,
  ValueChanged<int>? onPageChanged,
  Size viewportSize = const Size(800, 600),
  int Function()? currentPageIndex,
  PdfViewerContextMenuUpdateMenuItemsFunction? customizeContextMenuItems,
  List<ReaderHighlight> highlights = const [],
  PdfViewerPagePaintCallback? searchPainter,
  ValueChanged<PdfLink>? onLink,
  PdfViewerOverlaysBuilder? viewerOverlayBuilder,
  PdfViewerGeneralTapHandler? onGeneralTap,
  GestureScaleStartCallback? onInteractionStart,
  GestureScaleUpdateCallback? onInteractionUpdate,
  GestureScaleEndCallback? onInteractionEnd,
}) {
  final paginated = configuration.layoutMode == ReaderLayoutMode.paginated;
  final handles = PdfSelectionHandles(viewerController);
  return PdfViewerParams(
    pageDropShadow: null,
    onInteractionStart: onInteractionStart,
    onInteractionUpdate: onInteractionUpdate,
    onInteractionEnd: onInteractionEnd,
    viewerOverlayBuilder: viewerOverlayBuilder,
    onGeneralTap: onGeneralTap,
    customizeContextMenuItems: customizeContextMenuItems,
    scaleByPointerScale: .5,
    scaleGestureSensitivity: 1,
    scaleInertiaMaxExcursion: .01,
    zoomStepsDelegateProvider: const PdfFineZoomSteps(),
    linkHandlerParams: onLink == null
        ? null
        : PdfLinkHandlerParams(
            onLinkTap: onLink,
            customPainter: (canvas, pageRect, page, links) {
              if (!configuration.highlightLinks) return;
              final regions = Path();

              for (final link in links) {
                for (final rect in link.rects) {
                  regions.addRect(
                    rect.toRectInDocument(page: page, pageRect: pageRect),
                  );
                }
              }

              // One non-zero fill keeps overlapping link regions equally tinted.
              canvas.drawPath(
                regions,
                Paint()..color = Colors.blue.withAlpha(50),
              );
            },
          ),
    pagePaintCallbacks: [
      (canvas, pageRect, page) => canvas.drawRect(
        pageRect,
        Paint()
          ..color = const Color(0xffbdbdbd)
          ..style = PaintingStyle.stroke
          // Hairline strokes stay one physical pixel wide at every zoom level.
          ..strokeWidth = 0,
      ),
      ?searchPainter,
      (canvas, pageRect, page) {
        for (final highlight in highlights) {
          for (final rectangle in highlight.selection.rectangles) {
            if (rectangle.pageIndex != page.pageNumber - 1) {
              continue;
            }

            final rect = rectangle.rect;
            canvas.drawRect(
              Rect.fromLTRB(
                pageRect.left + rect.left * pageRect.width,
                pageRect.top + rect.top * pageRect.height,
                pageRect.left + rect.right * pageRect.width,
                pageRect.top + rect.bottom * pageRect.height,
              ),
              Paint()..color = highlight.color.withValues(alpha: .35),
            );
          }
        }
      },
    ],
    textSelectionParams: PdfTextSelectionParams(
      buildSelectionHandle: handles.build,
      calcSelectionHandleOffset: handles.offset,
      onTextSelectionChange: onTextSelectionChange,
    ),
    backgroundColor: configuration.brightness == Brightness.dark
        ? Color.fromARGB(
            (configuration.backgroundColor.a * 255).round(),
            255 - (configuration.backgroundColor.r * 255).round(),
            255 - (configuration.backgroundColor.g * 255).round(),
            255 - (configuration.backgroundColor.b * 255).round(),
          )
        : configuration.backgroundColor,
    annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
    panAxis: PanAxis.free,
    // The layout's outer margin separates pages vertically, but must not add
    // horizontal travel beyond the document edges when fitting its width.
    boundaryMargin: const EdgeInsets.symmetric(horizontal: -8),
    layoutPages: paginated
        ? (pages, params) => buildPaginatedPdfLayout(
            [for (final page in pages) Size(page.width, page.height)],
            viewportSize: viewportSize,
            facingPages: configuration.facingPages,
            margin: params.margin,
          )
        : configuration.facingPages
        ? _facingLayout
        : null,
    // Scroll physics operate on the entire document. Paginated panning is
    // bounded to the active spread instead, with discrete wheel/touch turns.
    scrollPhysics: paginated ? null : const ClampingScrollPhysics(),
    sizeDelegateProvider: const PdfViewerSizeDelegateProviderLegacy(
      minScale: .1,
      useAlternativeFitScaleAsMinScale: false,
    ),
    normalizeMatrix: paginated
        ? (matrix, viewSize, layout, controller) {
            if (controller == null || !controller.isReady) return matrix;
            final rect = pdfSpreadRect(
              layout,
              currentPageIndex?.call() ?? configuration.pageIndex,
              configuration.facingPages,
            );
            final zoom = matrix.zoom.clamp(.1, 8.0).toDouble();
            final visible = matrix.calcVisibleRect(viewSize);
            double clampCenter(
              double center,
              double minEdge,
              double maxEdge,
              double half,
            ) => maxEdge - minEdge <= half * 2
                ? (minEdge + maxEdge) / 2
                : center.clamp(minEdge + half, maxEdge - half);
            return controller.calcMatrixFor(
              Offset(
                clampCenter(
                  visible.center.dx,
                  rect.left,
                  rect.right,
                  viewSize.width / (2 * zoom),
                ),
                clampCenter(
                  visible.center.dy,
                  rect.top,
                  rect.bottom,
                  viewSize.height / (2 * zoom),
                ),
              ),
              zoom: zoom,
              viewSize: viewSize,
            );
          }
        : null,
    // Navigation belongs to the reader shortcuts; retain pdfrx copy/zoom keys.
    onKey: (_, key, _) =>
        const [
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.pageUp,
          LogicalKeyboardKey.pageDown,
          LogicalKeyboardKey.space,
        ].contains(key)
        ? false
        : null,
    onViewerReady: onViewerReady,
    onPageChanged: (pageNumber) {
      if (pageNumber != null) {
        (onPageChanged ?? configuration.onPageChanged)(pageNumber - 1);
      }
    },
  );
}

Widget applyPdfBrightness(Brightness brightness, Widget child) {
  return ColorFiltered(
    colorFilter: brightness == Brightness.dark
        ? const ColorFilter.matrix([
            -1,
            0,
            0,
            0,
            255,
            0,
            -1,
            0,
            0,
            255,
            0,
            0,
            -1,
            0,
            255,
            0,
            0,
            0,
            1,
            0,
          ])
        : const ColorFilter.matrix([
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
    child: child,
  );
}

Rect pdfSpreadRect(PdfPageLayout layout, int index, bool facingPages) {
  final first = facingPages ? (index ~/ 2) * 2 : index;
  final rect = layout.pageLayouts[first];
  return facingPages && first + 1 < layout.pageLayouts.length
      ? rect.expandToInclude(layout.pageLayouts[first + 1])
      : rect;
}

/// Each spread gets a viewport-sized slot at fit scale, so spare space around
/// a short page cannot reveal the neighboring spread.
PdfPageLayout buildPaginatedPdfLayout(
  List<Size> pages, {
  required Size viewportSize,
  required bool facingPages,
  double margin = 8,
}) {
  final step = facingPages ? 2 : 1;
  final rows = <({int index, double width, double height})>[];
  var documentWidth = 0.0;
  for (var index = 0; index < pages.length; index += step) {
    final right = facingPages && index + 1 < pages.length
        ? pages[index + 1]
        : null;
    final width =
        pages[index].width + (right == null ? 0 : right.width + margin);
    final height = max(pages[index].height, right?.height ?? 0);
    rows.add((index: index, width: width, height: height));
    documentWidth = max(documentWidth, width + margin * 2);
  }
  final layouts = <Rect>[];
  var y = 0.0;
  for (final row in rows) {
    // Keep adjacent spreads outside the viewport even at the minimum zoom.
    final slotHeight = max(row.height + margin * 2, viewportSize.height / .1);
    final left = (documentWidth - row.width) / 2;
    final top = y + (slotHeight - row.height) / 2;
    layouts.add(
      Rect.fromLTWH(left, top, pages[row.index].width, pages[row.index].height),
    );
    if (facingPages && row.index + 1 < pages.length) {
      final right = pages[row.index + 1];
      layouts.add(
        Rect.fromLTWH(
          left + pages[row.index].width + margin,
          top,
          right.width,
          right.height,
        ),
      );
    }
    y += slotHeight;
  }
  return PdfPageLayout(
    pageLayouts: layouts,
    documentSize: Size(documentWidth, y),
  );
}

PdfPageLayout _facingLayout(List<PdfPage> pages, PdfViewerParams params) {
  final layouts = <Rect>[];
  var y = params.margin;
  var documentWidth = 0.0;

  for (var index = 0; index < pages.length; index += 2) {
    final left = pages[index];
    final right = index + 1 < pages.length ? pages[index + 1] : null;
    final rowHeight = max(left.height, right?.height ?? 0);
    final rowWidth =
        left.width +
        (right?.width ?? 0) +
        params.margin * (right == null ? 2 : 3);
    documentWidth = max(documentWidth, rowWidth);
    layouts.add(Rect.fromLTWH(params.margin, y, left.width, left.height));
    if (right != null) {
      layouts.add(
        Rect.fromLTWH(
          params.margin * 2 + left.width,
          y,
          right.width,
          right.height,
        ),
      );
    }
    y += rowHeight + params.margin;
  }

  return PdfPageLayout(
    pageLayouts: layouts,
    documentSize: Size(documentWidth, y),
  );
}

/// Five-percentage-point keyboard steps instead of doubling the document scale.
final class PdfFineZoomSteps extends PdfViewerZoomStepsDelegateProvider {
  const PdfFineZoomSteps();

  @override
  PdfViewerZoomStepsDelegate create() => _PdfFineZoomDelegate();
  @override
  bool operator ==(Object other) => other is PdfFineZoomSteps;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class _PdfFineZoomDelegate implements PdfViewerZoomStepsDelegate {
  @override
  void dispose() {}

  @override
  List<double> generateZoomStops(PdfViewerLayoutMetrics metrics) {
    final stops = <double>{
      metrics.minScale,
      metrics.maxScale,
      metrics.coverScale,
    };
    if (metrics.alternativeFitScale != null) {
      stops.add(metrics.alternativeFitScale!);
    }
    for (
      var percent = (metrics.minScale * 100 / 5).ceil() * 5;
      percent <= metrics.maxScale * 100;
      percent += 5
    ) {
      stops.add(percent / 100);
    }
    return stops
        .where(
          (scale) => scale >= metrics.minScale && scale <= metrics.maxScale,
        )
        .toList()
      ..sort();
  }
}
