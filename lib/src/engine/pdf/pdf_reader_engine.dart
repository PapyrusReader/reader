import 'package:flutter/widgets.dart';

import '../../domain/reader_capabilities.dart';
import '../../domain/reader_activity.dart';
import '../../domain/reader_document.dart';
import '../../domain/reader_exception.dart';
import '../../domain/reader_locator.dart';
import '../../domain/reader_preferences.dart';
import '../../domain/reader_snapshot.dart';
import '../../domain/reader_toc_entry.dart';
import '../../domain/reader_types.dart';
import '../reader_engine.dart';
import 'pdf_facade.dart';

final class PdfReaderEngine extends ReaderEngine {
  PdfReaderEngine({PdfFacadeFactory? facadeFactory})
    : _facadeFactory = facadeFactory;

  final PdfFacadeFactory? _facadeFactory;

  @override
  Set<ReaderFormat> get supportedFormats => const {ReaderFormat.pdf};

  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    supportsPagination: true,
    supportsScrolling: true,
    supportsTextCustomization: false,
    supportsColumnMode: true,
  );

  @override
  ReaderSnapshot snapshot = const ReaderIdleSnapshot();

  PdfFacade? _facade;
  ReaderDocument? _document;
  ReaderPreferences _preferences = const ReaderPreferences();
  PdfReaderLocator? _locator;
  List<ReaderTocEntry> _toc = const [];
  bool _disposed = false;
  bool _facingPages = false;

  @override
  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    required ReaderPreferences preferences,
  }) async {
    if (document.format != ReaderFormat.pdf) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The PDF engine can only load PDF documents.',
      );
    }
    if (initialLocator != null && initialLocator is! PdfReaderLocator) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The initial locator is not a PDF locator.',
      );
    }

    _exposedPages = const [];
    _viewportReady = null;
    PdfFacade? candidate;
    try {
      final bytes = await document.loadBytes();
      if (_disposed) {
        throw const ReaderException(
          ReaderErrorCode.engineUnavailable,
          'The document was closed.',
        );
      }
      final factory =
          _facadeFactory ??
          (bytes) => createPdfrxFacade(bytes, sourceName: document.id);
      final facade = await factory(bytes);
      candidate = facade;
      if (_disposed) {
        throw const ReaderException(
          ReaderErrorCode.engineUnavailable,
          'The document was closed.',
        );
      }
      if (facade.pageCount <= 0) {
        throw const PdfFacadeException(PdfFacadeError.invalid);
      }

      final restored = initialLocator as PdfReaderLocator?;
      if (restored != null && restored.pageIndex >= facade.pageCount) {
        throw const ReaderException(
          ReaderErrorCode.invalidDocument,
          'The PDF locator is outside the document.',
        );
      }

      final target = restored ?? _locatorFor(0, pageCount: facade.pageCount);
      final toc = facade.outline
          .map((entry) => _tocEntry(entry, facade.pageCount))
          .toList();
      await facade.showPage(target.pageIndex, target.pageOffset);
      if (_disposed) {
        throw const ReaderException(
          ReaderErrorCode.engineUnavailable,
          'The document was closed.',
        );
      }
      final previous = _facade;
      _facade = facade;
      if (previous != null && !identical(previous, facade)) _release(previous);
      _document = document;
      _preferences = preferences;
      _locator = target;
      _toc = toc;
      _publish();
    } on ReaderException {
      if (candidate != null && !identical(candidate, _facade)) {
        _release(candidate);
      }
      rethrow;
    } on PdfFacadeException catch (error) {
      if (candidate != null && !identical(candidate, _facade)) {
        _release(candidate);
      }
      throw ReaderException(
        error.error == PdfFacadeError.encrypted
            ? ReaderErrorCode.encryptedDocument
            : ReaderErrorCode.invalidDocument,
        error.error == PdfFacadeError.encrypted
            ? 'The PDF document is encrypted.'
            : 'The PDF document is invalid or malformed.',
        cause: error.cause,
      );
    } catch (error) {
      if (candidate != null && !identical(candidate, _facade)) {
        _release(candidate);
      }
      throw ReaderException(
        ReaderErrorCode.invalidDocument,
        'The PDF document is invalid or malformed.',
        cause: error,
      );
    }
  }

  ReaderTocEntry _tocEntry(PdfFacadeOutlineEntry entry, int pageCount) {
    final index = entry.pageIndex.clamp(0, pageCount - 1);
    return ReaderTocEntry(
      title: entry.title,
      locator: _locatorFor(index, pageCount: pageCount),
      children: entry.children
          .map((child) => _tocEntry(child, pageCount))
          .toList(),
    );
  }

  PdfReaderLocator _locatorFor(
    int pageIndex, {
    double pageOffset = 0,
    int? pageCount,
  }) {
    final last = (pageCount ?? _facade?.pageCount ?? 1) - 1;
    return PdfReaderLocator(
      pageIndex: pageIndex,
      pageOffset: pageOffset,
      totalProgression: last <= 0
          ? pageOffset
          : ((pageIndex + pageOffset) / last).clamp(0, 1),
    );
  }

  @override
  Future<void> goTo(ReaderLocator locator) async {
    final facade = _facade;
    if (facade == null ||
        locator is! PdfReaderLocator ||
        locator.pageIndex >= facade.pageCount) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The locator is not valid for the current PDF.',
      );
    }
    _exposedPages = const [];
    _viewportReady = null;
    _publish();
    await facade.showPage(locator.pageIndex, locator.pageOffset);
    _locator = locator;
    _publish();
  }

  @override
  Future<void> goToProgress(double progress) async {
    if (!progress.isFinite || progress < 0 || progress > 1) {
      throw ArgumentError.value(
        progress,
        'progress',
        'must be between 0 and 1',
      );
    }

    final facade = _facade;
    if (facade == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No PDF document is loaded.',
      );
    }

    final lastPageIndex = facade.pageCount - 1;
    if (lastPageIndex == 0) {
      await goTo(_locatorFor(0, pageOffset: progress));
      return;
    }
    final scaledProgress = progress * lastPageIndex;
    final pageIndex = scaledProgress.floor();
    final pageOffset = pageIndex == lastPageIndex
        ? 0.0
        : scaledProgress - pageIndex;

    await goTo(_locatorFor(pageIndex, pageOffset: pageOffset));
  }

  @override
  Future<void> goNext() => _move(1);

  @override
  Future<void> goPrevious() => _move(-1);

  Future<void> _move(int delta) async {
    final locator = _locator;
    final facade = _facade;
    if (locator == null || facade == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No PDF document is loaded.',
      );
    }
    final step =
        _preferences.layoutMode == ReaderLayoutMode.paginated && _facingPages
        ? 2
        : 1;
    final page = (locator.pageIndex ~/ step) * step + delta * step;
    if (page < 0 || page >= facade.pageCount) {
      throw const ReaderException(
        ReaderErrorCode.navigationBoundary,
        'There is no PDF page in that direction.',
      );
    }
    await goTo(_locatorFor(page));
  }

  @override
  Future<ReaderLocator?> currentLocator() async => _locator;

  @override
  Future<void> updatePreferences(ReaderPreferences preferences) async {
    if (_document == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No PDF document is loaded.',
      );
    }
    _preferences = preferences;
    _publish();
  }

  void _visiblePageChanged(int pageIndex) {
    _visiblePositionChanged(pageIndex, 0);
  }

  void _visiblePositionChanged(int pageIndex, double pageOffset) {
    final facade = _facade;
    if (_disposed ||
        facade == null ||
        pageIndex < 0 ||
        pageIndex >= facade.pageCount) {
      return;
    }
    final next = _locatorFor(
      pageIndex,
      pageOffset: (pageOffset.clamp(0, 1) * 10000).round() / 10000,
    );
    if (next == _locator) {
      return;
    }
    _locator = next;
    _publish();
  }

  List<int> _exposedPages = const [];
  bool? _viewportReady;
  void _contentReadyChanged(bool ready) {
    if (_disposed || _viewportReady == ready) return;
    _viewportReady = ready;
    _publish();
  }

  void _visiblePagesChanged(List<int> pages) {
    if (_disposed) return;
    if (pages.length == _exposedPages.length &&
        List.generate(
          pages.length,
          (i) => pages[i] == _exposedPages[i],
        ).every((same) => same)) {
      return;
    }
    _exposedPages = List.unmodifiable(pages);
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    snapshot = ReaderReadySnapshot(
      document: _document!,
      contentReady: _viewportReady ?? _exposedPages.isNotEmpty,
      coverage: [
        for (final page in _exposedPages)
          ReaderContentCoverage(
            key: 'pdf:$page',
            start: 0,
            end: 1,
            pdfPageIndex: page,
          ),
      ],
      atEnd: _exposedPages.contains(_facade!.pageCount - 1),
      preferences: _preferences,
      capabilities: capabilities,
      locator: _locator,
      toc: _toc,
      locationLabel: 'Page ${_locator!.pageIndex + 1} of ${_facade!.pageCount}',
    );
    notifyListeners();
  }

  @override
  Widget buildViewport(BuildContext context) {
    final facade = _facade;
    final locator = _locator;
    if (facade == null || locator == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The PDF viewport is not ready.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final facingPages = switch (_preferences.columnMode) {
          ReaderColumnMode.double => constraints.maxWidth >= 600,
          ReaderColumnMode.single => false,
          ReaderColumnMode.automatic => constraints.maxWidth >= 1000,
        };
        _facingPages = facingPages;
        if (_facadeFactory != null && _viewportReady == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_disposed ||
                !identical(_facade, facade) ||
                _viewportReady != null) {
              return;
            }
            _viewportReady = true;
            _publish();
          });
        }
        return facade.buildViewport(
          PdfViewportConfiguration(
            pageIndex: locator.pageIndex,
            facingPages: facingPages,
            backgroundColor: _preferences.backgroundColor,
            brightness: _preferences.brightness,
            layoutMode: _preferences.layoutMode,
            onPageChanged: _visiblePageChanged,
            onPositionChanged: _visiblePositionChanged,
            onVisiblePagesChanged: _visiblePagesChanged,
            onContentReadyChanged: _contentReadyChanged,
          ),
        );
      },
    );
  }

  static void _release(PdfFacade facade) {
    if (facade is DisposablePdfFacade) {
      (facade as DisposablePdfFacade).dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final facade = _facade;
    _facade = null;
    if (facade != null) _release(facade);
    super.dispose();
  }
}
