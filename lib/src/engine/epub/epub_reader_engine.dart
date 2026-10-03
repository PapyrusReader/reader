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
import 'epub_content_renderer.dart';
import 'epub_paginator.dart';
import 'epub_rich_layout.dart';
import 'epub_viewport.dart';
import 'worker/epub_worker.dart';

typedef EpubWorkerFactory = Future<EpubWorker> Function();

final class EpubReaderEngine extends ReaderEngine {
  EpubReaderEngine({
    this.renderer,
    EpubPaginator? paginator,
    EpubWorkerFactory workerFactory = createEpubWorker,
  }) : _paginator = paginator ?? EpubPaginator(),
       _workerFactory = workerFactory;

  final EpubContentRenderer? renderer;
  final EpubPaginator _paginator;
  final EpubWorkerFactory _workerFactory;
  EpubWorker? _worker;
  EpubWorker? _openingWorker;
  ReaderDocument? _document;
  ReaderPreferences _preferences = const ReaderPreferences();
  EpubReaderLocator? _locator;
  String _currentChapterHtml = '';
  List<ReaderTocEntry> _toc = const [];
  List<EpubContentBlock> _blocks = const [];
  Map<String, int> _anchors = const {};
  int _chapterCount = 0;
  int _contentLength = 0;
  int _restorationRevision = 0;
  int _contentRevision = 0;
  int _navigationGeneration = 0;
  bool _disposed = false;
  int _visiblePage = 1;
  int _pageCount = 0;

  /// The mounted viewport handles local page/scroll turns. The engine crosses
  /// the spine only when that viewport reports a boundary.
  Future<bool> Function(int direction)? moveWithinChapter;

  String get currentChapterHtml => _currentChapterHtml;
  List<EpubContentBlock> get blocks => _blocks;
  int get restorationRevision => _restorationRevision;
  int get contentRevision => _contentRevision;
  int get contentLength => _contentLength;
  EpubReaderLocator get locator => _locator!;
  ReaderPreferences get preferences => _preferences;

  @override
  Set<ReaderFormat> get supportedFormats => const {ReaderFormat.epub};
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    supportsPagination: true,
    supportsScrolling: true,
    supportsTextCustomization: true,
    supportsColumnMode: true,
  );
  @override
  ReaderSnapshot snapshot = const ReaderIdleSnapshot();

  @override
  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    required ReaderPreferences preferences,
  }) async {
    if (document.format != ReaderFormat.epub ||
        (initialLocator != null && initialLocator is! EpubReaderLocator)) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The EPUB document or initial locator has the wrong format.',
      );
    }
    final generation = ++_navigationGeneration;
    EpubWorker? candidate;
    try {
      final bytes = await document.loadBytes();
      _requireCurrent(generation);
      candidate = await _workerFactory();
      _requireCurrent(generation);
      _openingWorker = candidate;
      final metadata = await candidate.open(bytes);
      _requireCurrent(generation);
      final count = metadata['count'] as int;
      final restored = initialLocator as EpubReaderLocator?;
      if (restored != null && restored.spineIndex >= count) {
        throw const ReaderException(
          ReaderErrorCode.invalidDocument,
          'The EPUB locator is outside the document spine.',
        );
      }
      final target = restored ?? _locatorFor(0, count: count);
      final chapter = await candidate.chapter(target.spineIndex);
      _requireCurrent(generation);
      final old = _worker;
      _worker = candidate;
      _openingWorker = null;
      old?.dispose();
      _document = document;
      _preferences = preferences;
      _chapterCount = count;
      _toc = [
        for (final entry in metadata['toc'] as List)
          _tocEntry(Map<String, Object?>.from(entry as Map), count),
      ];
      _setChapter(chapter, target);
      _publish();
    } on ReaderException {
      if (!identical(candidate, _worker)) candidate?.dispose();
      rethrow;
    } catch (error) {
      if (!identical(candidate, _worker)) candidate?.dispose();
      throw ReaderException(
        ReaderErrorCode.invalidDocument,
        'The EPUB document is invalid or malformed.',
        cause: error,
      );
    } finally {
      if (identical(candidate, _openingWorker)) _openingWorker = null;
    }
  }

  ReaderTocEntry _tocEntry(Map<String, Object?> entry, int count) {
    final index = entry['index'] as int;
    return ReaderTocEntry(
      title: entry['title'] as String,
      locator: _locatorFor(
        index,
        count: count,
        anchor: entry['anchor'] as String?,
      ),
      children: [
        for (final child in entry['children'] as List)
          _tocEntry(Map<String, Object?>.from(child as Map), count),
      ],
    );
  }

  EpubReaderLocator _locatorFor(
    int index, {
    int? count,
    double local = 0,
    int? textOffset,
    String? anchor,
  }) {
    return EpubReaderLocator(
      cfi: 'epubcfi(/6/${(index + 1) * 2}!/4/1:${textOffset ?? 0})',
      spineIndex: index,
      localProgression: local,
      totalProgression: ((index + local) / (count ?? _chapterCount)).clamp(
        0,
        1,
      ),
      textOffset: textOffset,
      anchor: anchor,
    );
  }

  void _setChapter(Map<String, Object?> chapter, EpubReaderLocator target) {
    _currentChapterHtml = chapter['html'] as String;
    _blocks = [
      for (final block in chapter['blocks'] as List)
        EpubContentBlock(Map<String, Object?>.from(block as Map)),
    ];
    _anchors = (chapter['anchors'] as Map).cast<String, int>();
    _contentLength = chapter['length'] as int;
    final offset = target.anchor == null
        ? target.textOffset
        : _anchors[target.anchor] ?? target.textOffset;
    _locator = offset == null
        ? target
        : _locatorFor(
            target.spineIndex,
            local: target.localProgression,
            textOffset: offset.clamp(0, _contentLength),
          );
    _paginator.clear();
    _contentRevision++;
    _pageCount = 0;
    _restorationRevision++;
  }

  void _requireCurrent(int generation) {
    if (_disposed || generation != _navigationGeneration) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The document was closed or replaced.',
      );
    }
  }

  @override
  Future<void> goTo(ReaderLocator locator) async {
    if (locator is! EpubReaderLocator ||
        locator.spineIndex >= _chapterCount ||
        _worker == null) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The locator is not valid for the current EPUB.',
      );
    }
    final generation = ++_navigationGeneration;
    if (locator.spineIndex == _locator?.spineIndex) {
      final offset = locator.anchor == null
          ? locator.textOffset
          : _anchors[locator.anchor] ?? locator.textOffset;
      _locator = offset == null
          ? locator
          : _locatorFor(
              locator.spineIndex,
              local: locator.localProgression,
              textOffset: offset.clamp(0, _contentLength),
            );
      _restorationRevision++;
    } else {
      final chapter = await _worker!.chapter(locator.spineIndex);
      _requireCurrent(generation);
      _setChapter(chapter, locator);
    }
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
    if (_worker == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No EPUB document is loaded.',
      );
    }
    final scaled = progress * _chapterCount;
    final index = progress == 1 ? _chapterCount - 1 : scaled.floor();
    await goTo(_locatorFor(index, local: progress == 1 ? 1 : scaled - index));
  }

  @override
  Future<void> goNext() => _move(1);
  @override
  Future<void> goPrevious() => _move(-1);
  Future<void> _move(int direction) async {
    if (_locator == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No EPUB document is loaded.',
      );
    }
    if (await moveWithinChapter?.call(direction) ?? false) return;
    final index = _locator!.spineIndex + direction;
    if (index < 0 || index >= _chapterCount) {
      throw const ReaderException(
        ReaderErrorCode.navigationBoundary,
        'There is no page in that direction.',
      );
    }
    await goTo(_locatorFor(index, local: direction < 0 ? 1 : 0));
  }

  void viewportPositionChanged(
    double local, {
    int? textOffset,
    int? pageNumber,
  }) {
    if (_disposed || _locator == null) return;
    final next = _locatorFor(
      _locator!.spineIndex,
      local: local.clamp(0, 1),
      textOffset: textOffset,
    );
    if (pageNumber != null) _visiblePage = pageNumber;
    if (next == _locator) return;
    _locator = next;
    _publish();
  }

  void viewportPaginationChanged(int count, int visiblePage) {
    if (_disposed || (_pageCount == count && _visiblePage == visiblePage)) {
      return;
    }
    _pageCount = count;
    _visiblePage = visiblePage;
    _publish();
  }

  @override
  Future<ReaderLocator?> currentLocator() async => _locator;
  @override
  Future<void> updatePreferences(ReaderPreferences preferences) async {
    if (_document == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No EPUB document is loaded.',
      );
    }
    if (_preferences == preferences) return;
    _preferences = preferences;
    _restorationRevision++;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    snapshot = ReaderReadySnapshot(
      document: _document!,
      preferences: _preferences,
      capabilities: capabilities,
      locator: _locator,
      toc: _toc,
      locationLabel:
          'Chapter ${_locator!.spineIndex + 1} of $_chapterCount'
          '${_pageCount > 0 ? ' · Page $_visiblePage of $_pageCount' : ''}',
    );
    notifyListeners();
  }

  @override
  Widget buildViewport(BuildContext context) {
    if (_document == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The EPUB viewport is not ready.',
      );
    }
    return EpubViewport(engine: this);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _navigationGeneration++;
    _openingWorker?.dispose();
    _worker?.dispose();
    _worker = null;
    _openingWorker = null;
    moveWithinChapter = null;
    super.dispose();
  }
}
