import 'dart:convert';
import 'dart:typed_data';

import 'package:epub_pro/epub_pro.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

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

final class EpubReaderEngine extends ReaderEngine {
  EpubReaderEngine({
    EpubContentRenderer renderer = const FlutterHtmlEpubContentRenderer(),
    EpubPaginator? paginator,
  }) : _renderer = renderer,
       _paginator = paginator ?? EpubPaginator();

  final EpubContentRenderer _renderer;
  final EpubPaginator _paginator;

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

  EpubBookRef? _book;
  List<EpubChapterRef> _spine = const [];
  ReaderDocument? _document;
  ReaderPreferences _preferences = const ReaderPreferences();
  EpubReaderLocator? _locator;
  String _currentChapterHtml = '';
  List<ReaderTocEntry> _toc = const [];
  int _restorationRevision = 0;

  String get currentChapterHtml => _currentChapterHtml;

  @override
  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    required ReaderPreferences preferences,
  }) async {
    if (document.format != ReaderFormat.epub) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The EPUB engine can only load EPUB documents.',
      );
    }
    if (initialLocator != null && initialLocator is! EpubReaderLocator) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The initial locator is not an EPUB locator.',
      );
    }

    try {
      final Uint8List bytes = await document.loadBytes();
      final book = await EpubReader.openBook(bytes);
      _rejectFixedLayout(book);
      final chapters = book.getChapters();
      final spine = _flattenSpine(chapters);
      if (spine.isEmpty) {
        throw const FormatException('The EPUB has no readable spine items.');
      }

      final restored = initialLocator as EpubReaderLocator?;
      if (restored != null && restored.spineIndex >= spine.length) {
        throw const ReaderException(
          ReaderErrorCode.invalidDocument,
          'The EPUB locator is outside the document spine.',
        );
      }

      final locator = restored ?? _locatorFor(0, spine);
      final toc = _buildToc(chapters, spine);
      final chapterHtml = await _readChapterFrom(
        book,
        spine[locator.spineIndex],
      );

      _book = book;
      _spine = spine;
      _document = document;
      _preferences = preferences;
      _locator = locator;
      _toc = toc;
      _currentChapterHtml = chapterHtml;
      _paginator.clear();
      _restorationRevision++;
      _publish();
    } on ReaderException {
      rethrow;
    } catch (error) {
      throw ReaderException(
        ReaderErrorCode.invalidDocument,
        'The EPUB document is invalid or malformed.',
        cause: error,
      );
    }
  }

  void _rejectFixedLayout(EpubBookRef book) {
    final metadata = book.schema?.package?.metadata;
    final fixed = metadata?.metaItems.any(
      (item) =>
          (item.property == 'rendition:layout' ||
              item.name == 'rendition:layout') &&
          (item.content == 'pre-paginated' ||
              item.attributes['content'] == 'pre-paginated'),
    );
    if (fixed ?? false) {
      throw const ReaderException(
        ReaderErrorCode.unsupportedFixedLayout,
        'Fixed-layout EPUB documents are not supported.',
      );
    }
  }

  List<EpubChapterRef> _flattenSpine(List<EpubChapterRef> chapters) {
    final result = <EpubChapterRef>[];
    final paths = <String>{};

    void visit(EpubChapterRef chapter) {
      final path = chapter.contentFileName?.split('#').first;
      if (path != null && paths.add(path)) {
        result.add(chapter);
      }
      for (final child in chapter.subChapters) {
        visit(child);
      }
    }

    for (final chapter in chapters) {
      visit(chapter);
    }
    return result;
  }

  List<ReaderTocEntry> _buildToc(
    List<EpubChapterRef> chapters,
    List<EpubChapterRef> spine,
  ) {
    ReaderTocEntry convert(EpubChapterRef chapter) {
      final target = chapter.contentFileName?.split('#').first;
      final index = spine.indexWhere(
        (item) => item.contentFileName?.split('#').first == target,
      );
      return ReaderTocEntry(
        title: chapter.title?.trim().isNotEmpty == true
            ? chapter.title!.trim()
            : 'Chapter',
        locator: _locatorFor(index < 0 ? 0 : index, spine),
        children: chapter.subChapters.map(convert).toList(),
      );
    }

    return chapters.map(convert).toList();
  }

  Future<String> _readChapter(int index) async {
    return _readChapterFrom(_book!, _spine[index]);
  }

  Future<String> _readChapterFrom(
    EpubBookRef book,
    EpubChapterRef chapter,
  ) async {
    final raw = await chapter.readHtmlContent();

    return _sanitize(raw, chapter, book);
  }

  Future<String> _sanitize(
    String raw,
    EpubChapterRef chapter,
    EpubBookRef book,
  ) async {
    final document = html_parser.parse(raw);
    const blockedTags = {
      'script',
      'form',
      'iframe',
      'object',
      'embed',
      'input',
      'button',
      'link',
      'style',
      'video',
      'audio',
      'source',
      'track',
      'use',
    };
    for (final tag in blockedTags) {
      for (final element in document.querySelectorAll(tag).toList()) {
        element.remove();
      }
    }

    for (final element in document.querySelectorAll('*').toList()) {
      _sanitizeAttributes(element);
      if (element.localName != 'img') {
        continue;
      }

      final source = element.attributes['src']?.trim();
      final uri = source == null ? null : Uri.tryParse(source);
      if (source == null ||
          source.isEmpty ||
          source.startsWith('//') ||
          uri == null ||
          uri.hasScheme) {
        element.remove();
        continue;
      }

      final resolved = _resolvePath(
        chapter.contentFileName ?? '',
        Uri.decodeComponent(uri.path),
      );
      final image = book.content?.images.entries
          .where((entry) => _normalized(entry.key) == _normalized(resolved))
          .map((entry) => entry.value)
          .firstOrNull;
      if (image == null) {
        element.remove();
        continue;
      }

      final bytes = await image.readContent();
      final mime = image.contentMimeType ?? 'application/octet-stream';
      if (!mime.toLowerCase().startsWith('image/')) {
        element.remove();
        continue;
      }
      element.attributes['src'] = 'data:$mime;base64,${base64Encode(bytes)}';
    }
    return document.outerHtml;
  }

  void _sanitizeAttributes(html_dom.Element element) {
    for (final name in element.attributes.keys.toList()) {
      final normalizedName = name.toString().toLowerCase();
      if (normalizedName.startsWith('on') || normalizedName == 'srcset') {
        element.attributes.remove(name);
      }
    }

    final style = element.attributes['style'];
    if (style != null) {
      final declarations = style
          .split(';')
          .map((declaration) => declaration.trim())
          .where(
            (declaration) =>
                declaration.isNotEmpty &&
                !RegExp(
                  r'(?:url\s*\(|@import|expression\s*\()',
                  caseSensitive: false,
                ).hasMatch(declaration),
          )
          .toList();
      if (declarations.isEmpty) {
        element.attributes.remove('style');
      } else {
        element.attributes['style'] = declarations.join('; ');
      }
    }

    for (final attribute in const ['poster', 'background']) {
      element.attributes.remove(attribute);
    }
    if (element.localName != 'img') {
      element.attributes.remove('src');
    }

    final href = element.attributes['href'];
    if (href == null) {
      return;
    }
    if (element.localName != 'a' || !_isSafeLink(href)) {
      element.attributes.remove('href');
    }
  }

  bool _isSafeLink(String href) {
    final normalized = href
        .replaceAll(RegExp(r'[\u0000-\u0020]+'), '')
        .toLowerCase();
    return !normalized.startsWith('javascript:') &&
        !normalized.startsWith('data:') &&
        !normalized.startsWith('vbscript:') &&
        !normalized.startsWith('file:');
  }

  String _resolvePath(String chapterPath, String relative) {
    final parts = chapterPath.split('/')..removeLast();
    for (final part in relative.split('/')) {
      if (part == '..') {
        if (parts.isNotEmpty) {
          parts.removeLast();
        }
      } else if (part != '.' && part.isNotEmpty) {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  String _normalized(String path) =>
      path.replaceFirst(RegExp(r'^OEBPS/'), '').replaceFirst(RegExp(r'^/'), '');

  EpubReaderLocator _locatorFor(
    int index, [
    List<EpubChapterRef>? candidateSpine,
  ]) {
    final spine = candidateSpine ?? _spine;

    return EpubReaderLocator(
      cfi: 'epubcfi(/6/${(index + 1) * 2}!/4/1:0)',
      spineIndex: index,
      localProgression: 0,
      totalProgression: _totalProgression(index, 0, spineCount: spine.length),
    );
  }

  double _totalProgression(
    int spineIndex,
    double localProgression, {
    int? spineCount,
  }) {
    final count = spineCount ?? _spine.length;
    if (count == 0) {
      return 0;
    }

    return ((spineIndex + localProgression) / count).clamp(0, 1);
  }

  @override
  Future<void> goTo(ReaderLocator locator) async {
    if (locator is! EpubReaderLocator ||
        locator.spineIndex >= _spine.length ||
        _document == null) {
      throw const ReaderException(
        ReaderErrorCode.invalidDocument,
        'The locator is not valid for the current EPUB.',
      );
    }
    final chapterHtml = await _readChapter(locator.spineIndex);

    _locator = locator;
    _currentChapterHtml = chapterHtml;
    _paginator.clear();
    _restorationRevision++;
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
    if (_document == null || _spine.isEmpty) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No EPUB document is loaded.',
      );
    }

    final scaledProgress = progress * _spine.length;
    final spineIndex = progress == 1
        ? _spine.length - 1
        : scaledProgress.floor();
    final localProgression = progress == 1 ? 1.0 : scaledProgress - spineIndex;
    final locator = EpubReaderLocator(
      cfi:
          'epubcfi(/6/${(spineIndex + 1) * 2}!/4/1:${(localProgression * 1000000).round()})',
      spineIndex: spineIndex,
      localProgression: localProgression,
      totalProgression: progress,
    );

    await goTo(locator);
  }

  @override
  Future<void> goNext() => _move(1);

  @override
  Future<void> goPrevious() => _move(-1);

  Future<void> _move(int delta) async {
    final current = _locator;
    if (current == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No EPUB document is loaded.',
      );
    }
    final next = current.spineIndex + delta;
    if (next < 0 || next >= _spine.length) {
      throw const ReaderException(
        ReaderErrorCode.navigationBoundary,
        'There is no chapter in that direction.',
      );
    }
    await goTo(_locatorFor(next));
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
    _preferences = preferences;
    _restorationRevision++;
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
    if (_document == null) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The EPUB viewport is not ready.',
      );
    }
    if (_preferences.layoutMode == ReaderLayoutMode.scroll) {
      return EpubScrollViewport(
        xhtml: _currentChapterHtml,
        preferences: _preferences,
        localProgression: _locator!.localProgression,
        restorationRevision: _restorationRevision,
        renderer: _renderer,
        onProgressChanged: _scrollProgressChanged,
      );
    }

    final blocks = _textBlocks(_currentChapterHtml);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 600,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 800,
        );
        final pages = _paginator.paginate(
          blocks,
          viewport: viewport,
          preferences: _preferences,
        );
        return _PaginatedEpubViewport(
          pages: pages,
          preferences: _preferences,
          locator: _locator!,
          onPageChanged: (pageIndex) {
            _paginatedPageChanged(pageIndex, pages.length);
          },
        );
      },
    );
  }

  void _scrollProgressChanged(double localProgression) {
    final current = _locator;
    if (current == null) {
      return;
    }
    _locator = EpubReaderLocator(
      cfi:
          'epubcfi(/6/${(current.spineIndex + 1) * 2}!/4/1:${(localProgression * 1000000).round()})',
      spineIndex: current.spineIndex,
      localProgression: localProgression,
      totalProgression: _totalProgression(current.spineIndex, localProgression),
    );
    _publish();
  }

  void _paginatedPageChanged(int pageIndex, int pageCount) {
    final current = _locator;
    if (current == null || pageCount <= 1) {
      return;
    }
    final localProgression = pageIndex / (pageCount - 1);
    _locator = EpubReaderLocator(
      cfi: 'epubcfi(/6/${(current.spineIndex + 1) * 2}!/4/1:$pageIndex)',
      spineIndex: current.spineIndex,
      localProgression: localProgression,
      totalProgression: _totalProgression(current.spineIndex, localProgression),
    );
    _publish();
  }

  List<String> _textBlocks(String html) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) {
      return const [];
    }

    return _EpubTextBlockCollector().collect(body);
  }
}

final class _EpubTextBlockCollector {
  static const _lineBreak = '\u0000';
  static const _blockTags = {
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'p',
    'li',
    'blockquote',
    'pre',
    'div',
    'td',
    'th',
  };

  final List<String> _blocks = [];

  List<String> collect(html_dom.Element root) {
    final buffer = StringBuffer();
    _visitChildren(root, buffer);
    _flush(buffer);

    return List.unmodifiable(_blocks);
  }

  void _visitChildren(html_dom.Node parent, StringBuffer buffer) {
    for (final node in parent.nodes) {
      if (node is html_dom.Text) {
        buffer.write(node.data);
        continue;
      }
      if (node is! html_dom.Element) {
        continue;
      }

      final tag = node.localName;
      if (tag == 'br') {
        buffer.write(_lineBreak);
      } else if (_blockTags.contains(tag)) {
        _flush(buffer);
        _visitBlock(node);
      } else {
        _visitChildren(node, buffer);
      }
    }
  }

  void _visitBlock(html_dom.Element element) {
    if (element.localName == 'pre') {
      final buffer = StringBuffer();
      _visitPreformatted(element, buffer);
      _add(_normalizePreformatted(buffer.toString()));
      return;
    }

    final buffer = StringBuffer();
    _visitChildren(element, buffer);
    _flush(buffer);
  }

  void _visitPreformatted(html_dom.Node parent, StringBuffer buffer) {
    for (final node in parent.nodes) {
      if (node is html_dom.Text) {
        buffer.write(node.data);
      } else if (node is html_dom.Element && node.localName == 'br') {
        buffer.write('\n');
      } else if (node is html_dom.Element) {
        _visitPreformatted(node, buffer);
      }
    }
  }

  void _flush(StringBuffer buffer) {
    _add(_normalize(buffer.toString()));
    buffer.clear();
  }

  void _add(String value) {
    if (value.isNotEmpty) {
      _blocks.add(value);
    }
  }

  String _normalize(String value) {
    final lines = value
        .split(_lineBreak)
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }

    return lines.join('\n');
  }

  String _normalizePreformatted(String value) {
    return value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  }
}

final class _PaginatedEpubViewport extends StatefulWidget {
  const _PaginatedEpubViewport({
    required this.pages,
    required this.preferences,
    required this.locator,
    required this.onPageChanged,
  });

  final List<List<String>> pages;
  final ReaderPreferences preferences;
  final EpubReaderLocator locator;
  final ValueChanged<int> onPageChanged;

  @override
  State<_PaginatedEpubViewport> createState() => _PaginatedEpubViewportState();
}

final class _PaginatedEpubViewportState extends State<_PaginatedEpubViewport> {
  late PageController _controller;

  int get _targetPage =>
      ((widget.pages.length - 1) * widget.locator.localProgression)
          .round()
          .clamp(0, widget.pages.length - 1);

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _targetPage);
  }

  @override
  void didUpdateWidget(covariant _PaginatedEpubViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldTarget =
        ((oldWidget.pages.length - 1) * oldWidget.locator.localProgression)
            .round()
            .clamp(0, oldWidget.pages.length - 1);
    if (oldTarget == _targetPage &&
        oldWidget.locator.spineIndex == widget.locator.spineIndex &&
        oldWidget.preferences == widget.preferences) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.hasClients) {
        _controller.jumpToPage(_targetPage);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.preferences.backgroundColor,
      child: PageView(
        controller: _controller,
        onPageChanged: widget.onPageChanged,
        children: [
          for (final page in widget.pages)
            Padding(
              padding: widget.preferences.pageMargins,
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final block in page)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: widget.preferences.paragraphSpacing,
                      ),
                      child: Text(
                        block,
                        style: TextStyle(
                          color: widget.preferences.foregroundColor,
                          fontFamily: widget.preferences.fontFamily,
                          fontSize: widget.preferences.fontSize,
                          height: widget.preferences.lineHeight,
                          letterSpacing: widget.preferences.letterSpacing,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
