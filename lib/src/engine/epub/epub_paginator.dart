import 'package:flutter/painting.dart';

import '../../domain/reader_preferences.dart';

class EpubPaginator {
  _PaginationCacheEntry? _cache;

  List<List<String>> paginate(
    List<String> blocks, {
    required Size viewport,
    required ReaderPreferences preferences,
  }) {
    final cached = _cache;
    if (cached != null &&
        cached.matches(blocks, viewport: viewport, preferences: preferences)) {
      return cached.pages;
    }

    final content = List<String>.unmodifiable(blocks);
    final pages = _layout(content, viewport, preferences);
    _cache = _PaginationCacheEntry(
      blocks: content,
      viewport: viewport,
      preferences: preferences,
      pages: pages,
    );

    return pages;
  }

  void clear() => _cache = null;

  List<List<String>> _layout(
    List<String> blocks,
    Size viewport,
    ReaderPreferences preferences,
  ) {
    final width = (viewport.width - preferences.pageMargins.horizontal)
        .clamp(1, double.infinity)
        .toDouble();
    final height = (viewport.height - preferences.pageMargins.vertical)
        .clamp(1, double.infinity)
        .toDouble();
    final pages = <List<String>>[];
    var page = <String>[];
    var usedHeight = 0.0;
    final style = TextStyle(
      color: preferences.foregroundColor,
      fontFamily: preferences.fontFamily,
      fontSize: preferences.fontSize,
      height: preferences.lineHeight,
      letterSpacing: preferences.letterSpacing,
    );

    for (final block in blocks) {
      var remaining = block.trim();
      while (remaining.isNotEmpty) {
        final availableHeight = height - usedHeight;
        final remainingHeight =
            _measure(remaining, width, style) + preferences.paragraphSpacing;
        if (remainingHeight <= availableHeight) {
          page.add(remaining);
          usedHeight += remainingHeight;
          break;
        }

        final fragment = _largestFittingPrefix(
          remaining,
          width: width,
          maxHeight: availableHeight - preferences.paragraphSpacing,
          style: style,
        );
        if (fragment.isEmpty) {
          if (page.isNotEmpty) {
            pages.add(List.unmodifiable(page));
            page = <String>[];
            usedHeight = 0;
            continue;
          }
          page.add(remaining);
          usedHeight = remainingHeight;
          break;
        }

        page.add(fragment);
        usedHeight +=
            _measure(fragment, width, style) + preferences.paragraphSpacing;
        remaining = remaining.substring(fragment.length).trimLeft();
        if (remaining.isNotEmpty) {
          pages.add(List.unmodifiable(page));
          page = <String>[];
          usedHeight = 0;
        }
      }
    }

    if (page.isNotEmpty || pages.isEmpty) {
      pages.add(List.unmodifiable(page));
    }

    return List.unmodifiable(pages);
  }

  double _measure(String text, double width, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    return painter.height;
  }

  String _largestFittingPrefix(
    String text, {
    required double width,
    required double maxHeight,
    required TextStyle style,
  }) {
    if (maxHeight <= 0) {
      return '';
    }

    var lower = 0;
    var upper = text.length;
    while (lower < upper) {
      final middle = (lower + upper + 1) ~/ 2;
      if (_measure(text.substring(0, middle), width, style) <= maxHeight) {
        lower = middle;
      } else {
        upper = middle - 1;
      }
    }
    if (lower == 0) {
      return '';
    }
    if (lower == text.length) {
      return text;
    }

    final whitespace = text.substring(0, lower).lastIndexOf(RegExp(r'\s'));
    final boundary = whitespace > 0 ? whitespace : lower;
    return text.substring(0, boundary).trimRight();
  }
}

final class _PaginationCacheEntry {
  const _PaginationCacheEntry({
    required this.blocks,
    required this.viewport,
    required this.preferences,
    required this.pages,
  });

  final List<String> blocks;
  final Size viewport;
  final ReaderPreferences preferences;
  final List<List<String>> pages;

  bool matches(
    List<String> otherBlocks, {
    required Size viewport,
    required ReaderPreferences preferences,
  }) {
    if (this.viewport != viewport ||
        this.preferences != preferences ||
        blocks.length != otherBlocks.length) {
      return false;
    }
    for (var index = 0; index < blocks.length; index++) {
      if (blocks[index] != otherBlocks[index]) {
        return false;
      }
    }

    return true;
  }
}
