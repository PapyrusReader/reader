import 'dart:math';
import 'dart:typed_data';

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
  });

  final int pageIndex;
  final bool facingPages;
  final Color backgroundColor;
  final Brightness brightness;
  final ReaderLayoutMode layoutMode;
  final ValueChanged<int> onPageChanged;
}

abstract interface class PdfFacade {
  int get pageCount;

  List<PdfFacadeOutlineEntry> get outline;

  Future<void> showPage(int pageIndex, double pageOffset);

  Widget buildViewport(PdfViewportConfiguration configuration);
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

  try {
    metadataDocument =
        await metadataDocumentLoader?.call() ??
        _PdfrxMetadataDocument(
          await reference.loadDocument((int current, [int? total]) {}),
        );
    final outline = await metadataDocument.loadOutline();

    return _PdfrxFacade(
      documentRef: reference,
      pageCount: metadataDocument.pageCount,
      pageSizes: List.unmodifiable(metadataDocument.pageSizes),
      outline: List.unmodifiable(outline),
    );
  } on PdfPasswordException catch (error) {
    throw PdfFacadeException(PdfFacadeError.encrypted, error);
  } on PdfFacadeException {
    rethrow;
  } on Object catch (error) {
    throw PdfFacadeException(PdfFacadeError.invalid, error);
  } finally {
    await metadataDocument?.dispose();
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

final class _PdfrxFacade implements PdfFacade {
  _PdfrxFacade({
    required PdfDocumentRef documentRef,
    required this.pageCount,
    required List<Size> pageSizes,
    required this.outline,
  }) : _documentRef = documentRef,
       _pageSizes = pageSizes;

  final PdfDocumentRef _documentRef;
  final List<Size> _pageSizes;
  final PdfViewerController _controller = PdfViewerController();
  int _pageIndex = 0;
  double _pageOffset = 0;

  @override
  final int pageCount;

  @override
  final List<PdfFacadeOutlineEntry> outline;

  @override
  Future<void> showPage(int pageIndex, double pageOffset) async {
    _pageIndex = pageIndex;
    _pageOffset = pageOffset;
    if (_controller.isReady) {
      await _restorePage();
    }
  }

  Future<void> _restorePage() {
    if (_pageOffset == 0) {
      return _controller.goToPage(
        pageNumber: _pageIndex + 1,
        duration: Duration.zero,
      );
    }

    final pageSize = _pageSizes[_pageIndex];
    final top = pageSize.height * (1 - _pageOffset);
    return _controller.goToRectInsidePage(
      pageNumber: _pageIndex + 1,
      rect: PdfRect(0, max(1, top), pageSize.width, max(0, top - 1)),
      anchor: PdfPageAnchor.top,
      duration: Duration.zero,
    );
  }

  @override
  Widget buildViewport(PdfViewportConfiguration configuration) {
    _pageIndex = configuration.pageIndex;

    return applyPdfBrightness(
      configuration.brightness,
      PdfViewer(
        _documentRef,
        controller: _controller,
        initialPageNumber: _pageIndex + 1,
        params: buildPdfViewerParams(
          configuration,
          onViewerReady: (_, _) {
            _restorePage();
          },
          onPageChanged: (pageIndex) {
            _pageIndex = pageIndex;
            _pageOffset = 0;
            configuration.onPageChanged(_pageIndex);
          },
        ),
      ),
    );
  }
}

PdfViewerParams buildPdfViewerParams(
  PdfViewportConfiguration configuration, {
  PdfViewerReadyCallback? onViewerReady,
  ValueChanged<int>? onPageChanged,
}) {
  final paginated = configuration.layoutMode == ReaderLayoutMode.paginated;
  return PdfViewerParams(
    backgroundColor: configuration.backgroundColor,
    annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
    panAxis: PanAxis.vertical,
    layoutPages: configuration.facingPages
        ? _facingLayout
        : paginated
        ? _paginatedLayout
        : null,
    scrollPhysics: paginated
        ? const PageScrollPhysics()
        : const ClampingScrollPhysics(),
    onViewerReady: onViewerReady,
    onPageChanged: (pageNumber) {
      if (pageNumber != null) {
        (onPageChanged ?? configuration.onPageChanged)(pageNumber - 1);
      }
    },
  );
}

Widget applyPdfBrightness(Brightness brightness, Widget child) {
  if (brightness != Brightness.dark) {
    return child;
  }
  return ColorFiltered(
    colorFilter: const ColorFilter.matrix([
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
    ]),
    child: child,
  );
}

PdfPageLayout _paginatedLayout(List<PdfPage> pages, PdfViewerParams params) {
  final layouts = <Rect>[];
  var y = params.margin;
  var documentWidth = 0.0;

  for (final page in pages) {
    layouts.add(Rect.fromLTWH(params.margin, y, page.width, page.height));
    documentWidth = max(documentWidth, page.width + params.margin * 2);
    y += page.height + params.margin;
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
