import 'package:flutter/widgets.dart';

import '../../domain/reader_capabilities.dart';
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

    try {
      final bytes = await document.loadBytes();
      final factory =
          _facadeFactory ??
          (bytes) => createPdfrxFacade(bytes, sourceName: document.id);
      final facade = await factory(bytes);
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

      _facade = facade;
      _document = document;
      _preferences = preferences;
      _locator = restored ?? _locatorFor(0);
      _toc = facade.outline.map(_tocEntry).toList();
      await facade.showPage(_locator!.pageIndex, _locator!.pageOffset);
      _publish();
    } on ReaderException {
      rethrow;
    } on PdfFacadeException catch (error) {
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
      throw ReaderException(
        ReaderErrorCode.invalidDocument,
        'The PDF document is invalid or malformed.',
        cause: error,
      );
    }
  }

  ReaderTocEntry _tocEntry(PdfFacadeOutlineEntry entry) {
    final index = entry.pageIndex.clamp(0, _facade!.pageCount - 1);
    return ReaderTocEntry(
      title: entry.title,
      locator: _locatorFor(index),
      children: entry.children.map(_tocEntry).toList(),
    );
  }

  PdfReaderLocator _locatorFor(int pageIndex, {double pageOffset = 0}) {
    final last = (_facade?.pageCount ?? 1) - 1;
    return PdfReaderLocator(
      pageIndex: pageIndex,
      pageOffset: pageOffset,
      totalProgression: last <= 0
          ? 0
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
    _locator = locator;
    await facade.showPage(locator.pageIndex, locator.pageOffset);
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
    final page = locator.pageIndex + delta;
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
    final facade = _facade;
    if (facade == null || pageIndex < 0 || pageIndex >= facade.pageCount) {
      return;
    }
    final next = _locatorFor(pageIndex);
    if (next == _locator) {
      return;
    }
    _locator = next;
    _publish();
  }

  void _publish() {
    snapshot = ReaderReadySnapshot(
      document: _document!,
      preferences: _preferences,
      capabilities: capabilities,
      locator: _locator,
      toc: _toc,
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
    final facingPages = switch (_preferences.columnMode) {
      ReaderColumnMode.double => true,
      ReaderColumnMode.single => false,
      ReaderColumnMode.automatic =>
        MediaQuery.maybeSizeOf(context)?.width.compareTo(900) == 1,
    };
    return facade.buildViewport(
      PdfViewportConfiguration(
        pageIndex: locator.pageIndex,
        facingPages: facingPages,
        backgroundColor: _preferences.backgroundColor,
        brightness: _preferences.brightness,
        layoutMode: _preferences.layoutMode,
        onPageChanged: _visiblePageChanged,
      ),
    );
  }
}
