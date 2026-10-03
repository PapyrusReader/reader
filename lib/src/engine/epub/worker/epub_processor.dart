import 'dart:convert';
import 'dart:typed_data';

import 'package:epub_pro/epub_pro.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import 'epub_content.dart';

/// Pure Dart document session, shared by native isolates and browser workers.
final class EpubProcessor {
  EpubBookRef? _book;
  List<EpubChapterRef> _spine = const [];
  final Map<int, Map<String, Object?>> _chapters = {};

  Future<Map<String, Object?>> dispatch(
    String command,
    Object? argument,
  ) async {
    if (command == 'open') return _open(argument as Uint8List);
    if (command == 'chapter') return _chapter(argument as int);
    throw ArgumentError('Unknown EPUB worker command: $command');
  }

  Future<Map<String, Object?>> _open(Uint8List bytes) async {
    final book = await EpubReader.openBook(bytes);
    final metadata = book.schema?.package?.metadata;
    if (metadata?.metaItems.any(
          (item) =>
              (item.property == 'rendition:layout' ||
                  item.name == 'rendition:layout') &&
              (item.content == 'pre-paginated' ||
                  item.attributes['content'] == 'pre-paginated'),
        ) ??
        false) {
      throw const EpubProcessingException(
        'unsupportedFixedLayout',
        'Fixed-layout EPUB documents are not supported.',
      );
    }
    final chapters = book.getChapters();
    final package = book.schema?.package;
    final html = book.content?.html ?? {};
    final manifest = {
      for (final item in package?.manifest?.items ?? <EpubManifestItem>[])
        item.id: item,
    };
    final spine = <EpubChapterRef>[];
    for (final item in package?.spine?.items ?? <EpubSpineItemRef>[]) {
      if (!item.isLinear) continue;
      final path = manifest[item.idRef]?.href;
      if (path == null) continue;
      // Keep missing manifest resources in order: opening that chapter should
      // fail explicitly rather than silently skipping durable locator indices.
      final content = html[path];
      spine.add(
        EpubChapterRef(
          contentFileName: path,
          epubTextContentFileRef: content,
          title: path,
        ),
      );
    }
    if (spine.isEmpty) {
      final seen = <String>{};
      void visit(EpubChapterRef chapter) {
        final path = chapter.contentFileName?.split('#').first;
        if (path != null && seen.add(path)) spine.add(chapter);
        for (final child in chapter.subChapters) {
          visit(child);
        }
      }

      for (final chapter in chapters) {
        visit(chapter);
      }
    }
    if (spine.isEmpty) {
      throw const FormatException('The EPUB has no readable spine.');
    }
    Map<String, Object?> toc(EpubChapterRef chapter) {
      final path = chapter.contentFileName?.split('#').first;
      final index = spine.indexWhere((item) => item.contentFileName == path);
      return {
        'title': chapter.title ?? 'Chapter',
        'index': index < 0 ? 0 : index,
        'anchor': chapter.anchor,
        'children': chapter.subChapters.map(toc).toList(),
      };
    }

    List<Map<String, Object?>> navigation(List<EpubNavigationPoint> points) {
      final result = <Map<String, Object?>>[];
      for (final point in points) {
        final uri = Uri.tryParse(point.content?.source ?? '');
        if (uri == null || uri.hasScheme) continue;
        final path = Uri.decodeComponent(uri.path);
        final index = spine.indexWhere((item) => item.contentFileName == path);
        final children = navigation(point.childNavigationPoints);
        if (index < 0) {
          result.addAll(children);
          continue;
        }
        final title = point.navigationLabels
            .map((label) => label.text?.trim() ?? '')
            .firstWhere((title) => title.isNotEmpty, orElse: () => 'Chapter');
        result.add({
          'title': title,
          'index': index,
          'anchor': uri.hasFragment ? Uri.decodeComponent(uri.fragment) : null,
          'children': children,
        });
      }
      return result;
    }

    final points = book.schema?.navigation?.navMap?.points;
    final tableOfContents = points == null || points.isEmpty
        ? chapters.map(toc).toList()
        : navigation(points);
    _book = book;
    _spine = spine;
    _chapters.clear();
    return {'count': spine.length, 'toc': tableOfContents};
  }

  Future<Map<String, Object?>> _chapter(int index) async {
    final cached = _chapters.remove(index);
    if (cached != null) {
      _chapters[index] = cached;
      return cached;
    }
    if (_book == null || index < 0 || index >= _spine.length) {
      throw const FormatException('Chapter is outside the EPUB spine.');
    }
    final chapter = _spine[index];
    final raw = await chapter.readHtmlContent();
    final sanitized = await _sanitize(raw, chapter, _book!);
    final content = collectEpubContent(sanitized);
    final result = <String, Object?>{'html': sanitized, ...content};
    _chapters[index] = result;
    // Bound by both count and encoded chapter size; a large chapter is returned
    // but not retained in addition to its engine copy.
    var size = _chapters.values.fold<int>(
      0,
      (sum, value) => sum + (value['html'] as String).length,
    );
    while (_chapters.length > 3 || size > 4 * 1024 * 1024) {
      final removed = _chapters.remove(_chapters.keys.first)!;
      size -= (removed['html'] as String).length;
    }
    return result;
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
}

final class EpubProcessingException implements Exception {
  const EpubProcessingException(this.code, this.message);
  final String code;
  final String message;
}

Future<Map<String, Object?>> processEpubMessage(
  EpubProcessor processor,
  Map<String, Object?> message,
) async {
  try {
    return {
      'id': message['id'],
      'result': await processor.dispatch(
        message['command'] as String,
        message['argument'],
      ),
    };
  } on EpubProcessingException catch (error) {
    return {'id': message['id'], 'error': error.code, 'message': error.message};
  } catch (_) {
    return {
      'id': message['id'],
      'error': 'invalidDocument',
      'message': 'The EPUB document or chapter is invalid or malformed.',
    };
  }
}
