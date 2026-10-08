import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/reader_types.dart';

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
    this.onPositionChanged,
    this.onVisiblePagesChanged,
    this.onContentReadyChanged,
  });

  final int pageIndex;
  final bool facingPages;
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

final class _PdfrxFacade implements PdfFacade, DisposablePdfFacade {
  _PdfrxFacade({
    required PdfDocumentRef documentRef,
    required this.pageCount,
    required this.outline,
    VoidCallback? releaseDocument,
  }) : _documentRef = documentRef,
       _releaseDocument = releaseDocument {
    _controller.addListener(_positionChanged);
  }

  final PdfDocumentRef _documentRef;
  final PdfViewerController _controller = PdfViewerController();
  int _pageIndex = 0;
  double _pageOffset = 0;
  final VoidCallback? _releaseDocument;
  PdfViewportConfiguration? _configuration;
  bool _restoring = false;
  bool _scheduled = false;
  bool _disposed = false;
  Object? _viewKey;
  int _viewerRevision = 0;
  DateTime? _lastWheelTurn;
  Offset? _touchStart;
  int _touchPointers = 0;

  @override
  final int pageCount;

  @override
  final List<PdfFacadeOutlineEntry> outline;

  @override
  Future<void> showPage(int pageIndex, double pageOffset) async {
    _pageIndex = pageIndex;
    _pageOffset = pageOffset;
    if (_controller.isReady && !_restoring) {
      _restoring = true;
      try {
        await _restorePage();
      } finally {
        _restoring = false;
      }
    }
  }

  Rect get _spread => pdfSpreadRect(
    _controller.layout,
    _pageIndex,
    _configuration!.facingPages,
  );

  double get _fitZoom => min(
    (_controller.viewSize.width - 16) / _spread.width,
    (_controller.viewSize.height - 16) / _spread.height,
  );

  bool get _atFit =>
      _controller.isReady && _controller.currentZoom <= _fitZoom * 1.02;

  Future<void> _restorePage() {
    final config = _configuration;
    if (config == null) return Future<void>.value();
    final rect = _spread;
    if (config.layoutMode == ReaderLayoutMode.paginated) {
      return _controller.goTo(
        _controller.calcMatrixForRect(rect, margin: 8),
        duration: Duration.zero,
      );
    }
    // Include pdfrx's document margins in the width fit. Fitting only the page
    // makes scaled margins wider than the viewport and permits horizontal pan.
    // Keep the page-local offset while refitting columns or available space.
    final documentWidth = _controller.layout.documentSize.width;
    final zoom = (_controller.viewSize.width / documentWidth).clamp(.1, 8.0);
    final page = _controller.layout.pageLayouts[_pageIndex];
    return _controller.goTo(
      _controller.calcMatrixFor(
        Offset(
          documentWidth / 2,
          page.top +
              page.height * _pageOffset +
              _controller.viewSize.height / (2 * zoom),
        ),
        zoom: zoom,
      ),
      duration: Duration.zero,
    );
  }

  void _turnSpread(int direction) {
    final config = _configuration;
    if (_disposed || _restoring || config == null || !_controller.isReady) {
      return;
    }
    final step = config.facingPages ? 2 : 1;
    final target = (_pageIndex ~/ step) * step + direction * step;
    if (target < 0 || target >= pageCount) return;
    unawaited(
      showPage(target, 0).then((_) {
        if (_disposed) return;
        config.onPositionChanged?.call(target, 0);
        if (config.onPositionChanged == null) config.onPageChanged(target);
      }),
    );
  }

  @override
  Widget buildViewport(PdfViewportConfiguration configuration) {
    _configuration = configuration;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final key = (configuration.layoutMode, configuration.facingPages, size);
        if (_viewKey != key) {
          _viewKey = key;
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
        return applyPdfBrightness(
          configuration.brightness,
          Listener(
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
                  _turnSpread(delta > 0 ? 1 : -1);
                }
              });
              WidgetsBinding.instance.scheduleFrame();
            },
            onPointerDown: (event) {
              if (event.kind != PointerDeviceKind.touch) return;
              _touchPointers++;
              _touchStart = _touchPointers == 1 ? event.position : null;
            },
            onPointerUp: (event) {
              if (event.kind != PointerDeviceKind.touch) return;
              final start = _touchStart;
              _touchPointers = max(0, _touchPointers - 1);
              _touchStart = null;
              if (configuration.layoutMode == ReaderLayoutMode.paginated &&
                  start != null &&
                  !_restoring &&
                  _atFit &&
                  (event.position.dx - start.dx).abs() > 70) {
                _turnSpread(event.position.dx < start.dx ? 1 : -1);
              }
            },
            onPointerCancel: (_) {
              _touchPointers = 0;
              _touchStart = null;
            },
            child: PdfViewer(
              _documentRef,
              key: ValueKey(key),
              controller: _controller,
              initialPageNumber: _pageIndex + 1,
              params: buildPdfViewerParams(
                configuration,
                viewportSize: size,
                currentPageIndex: () => _pageIndex,
                onViewerReady: (_, _) async {
                  if (_disposed || revision != _viewerRevision) return;
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
        );
      },
    );
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
          : ((_controller.pageNumber ?? 1) - 1).clamp(0, pageCount - 1);
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
    _disposed = true;
    _controller.removeListener(_positionChanged);
    _releaseDocument?.call();
    _configuration = null;
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

PdfViewerParams buildPdfViewerParams(
  PdfViewportConfiguration configuration, {
  PdfViewerReadyCallback? onViewerReady,
  ValueChanged<int>? onPageChanged,
  Size viewportSize = const Size(800, 600),
  int Function()? currentPageIndex,
}) {
  final paginated = configuration.layoutMode == ReaderLayoutMode.paginated;
  return PdfViewerParams(
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
            final fit = min(
              (viewSize.width - 16) / rect.width,
              (viewSize.height - 16) / rect.height,
            );
            final zoom = matrix.zoom.clamp(fit.clamp(.1, 8.0), 8.0).toDouble();
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
                  rect.left - 8,
                  rect.right + 8,
                  viewSize.width / (2 * zoom),
                ),
                clampCenter(
                  visible.center.dy,
                  rect.top - 8,
                  rect.bottom + 8,
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
    final zoom = min(
      max(1, viewportSize.width - margin * 2) / row.width,
      max(1, viewportSize.height - margin * 2) / row.height,
    );
    final slotHeight = max(row.height + margin * 2, viewportSize.height / zoom);
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
