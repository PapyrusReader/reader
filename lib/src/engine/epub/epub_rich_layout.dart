import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../domain/reader_preferences.dart';
import '../../presentation/reader_interaction_scope.dart';

final class EpubContentBlock {
  EpubContentBlock(Map<String, Object?> json)
    : kind = json['kind'] as String,
      offset = json['offset'] as int,
      length = json['length'] as int,
      paragraphEnd = json['paragraphEnd'] as bool? ?? true,
      runs = [
        for (final run in json['runs'] as List? ?? const [])
          Map<String, Object?>.from(run as Map),
      ],
      image = json['src'] == null
          ? null
          : UriData.parse(json['src'] as String).contentAsBytes(),
      imageLabel = json['alt'] as String? ?? 'Illustration',
      aspect = (json['aspect'] as num?)?.toDouble() ?? 1.5;

  final String kind;
  final int offset;
  final int length;
  final bool paragraphEnd;
  final List<Map<String, Object?>> runs;
  final Uint8List? image;
  final String imageLabel;
  final double aspect;

  TextStyle style(ReaderPreferences preferences) {
    final heading = kind.startsWith('h')
        ? int.tryParse(kind.substring(1))
        : null;
    return TextStyle(
      inherit: false,
      color: preferences.foregroundColor,
      fontFamily: kind == 'pre' ? 'monospace' : preferences.fontFamily,
      fontSize:
          preferences.fontSize *
          (heading == null ? 1 : math.max(1.1, 1.8 - heading * .12)),
      fontWeight: heading == null ? FontWeight.normal : FontWeight.w600,
      fontStyle: kind == 'blockquote' ? FontStyle.italic : FontStyle.normal,
      height: preferences.lineHeight,
      letterSpacing: preferences.letterSpacing,
    );
  }

  TextSpan span(ReaderPreferences preferences, {int start = 0, int? end}) {
    final children = <TextSpan>[];
    var position = 0;
    for (final run in runs) {
      final text = run['text'] as String;
      final from = math.max(0, start - position);
      final to = math.min(text.length, (end ?? length) - position);
      if (to > from) {
        children.add(
          TextSpan(
            text: text.substring(from, to),
            style: TextStyle(
              fontWeight: run['bold'] == true ? FontWeight.bold : null,
              fontStyle: run['italic'] == true ? FontStyle.italic : null,
              fontFamily: run['code'] == true ? 'monospace' : null,
              decoration: TextDecoration.combine([
                if (run['underline'] == true) TextDecoration.underline,
                if (run['strike'] == true) TextDecoration.lineThrough,
              ]),
            ),
          ),
        );
      }
      position += text.length;
    }
    return TextSpan(style: style(preferences), children: children);
  }
}

final class EpubPageFragment {
  const EpubPageFragment(this.block, this.start, this.end, this.height);
  final EpubContentBlock block;
  final int start;
  final int end;
  final double height;
  int get offset => block.offset + start;
  double spacing(ReaderPreferences preferences) =>
      block.paragraphEnd && end == block.length
      ? preferences.paragraphSpacing
      : 0;
}

final class EpubRichPage {
  const EpubRichPage(this.fragments);
  final List<EpubPageFragment> fragments;
  int get offset => fragments.isEmpty ? 0 : fragments.first.offset;
}

/// Measures each paragraph once and cuts at actual line boundaries. Long
/// paragraphs never trigger repeated binary-search layouts or surrogate splits.
Future<List<EpubRichPage>> layoutEpubChapter(
  List<EpubContentBlock> blocks, {
  required Size contentSize,
  required ReaderPreferences preferences,
  required TextScaler textScaler,
  required TextDirection direction,
  required bool Function() cancelled,
}) async {
  final width = math.max(1.0, contentSize.width);
  final height = math.max(1.0, contentSize.height);
  final pages = <EpubRichPage>[];
  var fragments = <EpubPageFragment>[];
  var used = 0.0;
  final stopwatch = Stopwatch()..start();
  void finish() {
    if (fragments.isEmpty) return;
    pages.add(EpubRichPage(List.unmodifiable(fragments)));
    fragments = [];
    used = 0;
  }

  for (final block in blocks) {
    if (cancelled()) return const [];
    final spacing = block.paragraphEnd ? preferences.paragraphSpacing : 0.0;
    if (block.image != null) {
      final imageHeight = math.min(width / block.aspect, height * .65);
      if (used + imageHeight + spacing > height) finish();
      fragments.add(EpubPageFragment(block, 0, 1, imageHeight));
      used += imageHeight + spacing;
    } else {
      final span = block.span(preferences);
      final painter = TextPainter(
        text: span,
        textDirection: direction,
        textScaler: textScaler,
      )..layout(maxWidth: width);
      final lines = painter.computeLineMetrics();
      final text = span.toPlainText();
      var start = 0;
      var segmentHeight = 0.0;
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        final line = lines[lineIndex];
        final top = line.baseline - line.ascent;
        final bottom = line.baseline + line.descent;
        // Ascent/descent exclude part of the line-height leading on Skia fonts.
        // Count the complete line box so several paragraphs cannot overfill a
        // page even when the glyph bounds are shorter than their line boxes.
        final lineHeight = line.height;
        if (used + segmentHeight + lineHeight + spacing > height &&
            (used > 0 || segmentHeight > 0)) {
          final position = painter.getPositionForOffset(
            Offset(line.left + line.width / 2, (top + bottom) / 2),
          );
          // Query inside the line: x=0 can resolve to the previous line's end
          // on Skia, even when the y coordinate belongs to the following line.
          final boundary = painter
              .getLineBoundary(
                TextPosition(
                  offset: position.offset,
                  affinity: TextAffinity.downstream,
                ),
              )
              .start;
          if (boundary > start) {
            fragments.add(
              EpubPageFragment(block, start, boundary, segmentHeight),
            );
            start = boundary;
          }
          finish();
          segmentHeight = 0;
        }
        segmentHeight += lineHeight;
      }
      if (start < text.length) {
        fragments.add(
          EpubPageFragment(block, start, text.length, segmentHeight),
        );
        used += segmentHeight + spacing;
      }
      painter.dispose();
    }
    if (stopwatch.elapsedMilliseconds >= 4) {
      await Future<void>.delayed(Duration.zero);
      stopwatch.reset();
    }
  }
  finish();
  if (pages.isEmpty) pages.add(const EpubRichPage([]));
  return List.unmodifiable(pages);
}

Widget buildEpubFragment(
  EpubPageFragment fragment,
  ReaderPreferences preferences,
) {
  final block = fragment.block;
  if (block.image != null) {
    return SizedBox(
      height: fragment.height,
      child: Image.memory(
        block.image!,
        fit: BoxFit.contain,
        semanticLabel: block.imageLabel,
        errorBuilder: (_, _, _) => Center(
          child: Text(
            block.imageLabel,
            style: TextStyle(color: preferences.foregroundColor),
          ),
        ),
      ),
    );
  }
  final text = Text.rich(
    block.span(preferences, start: fragment.start, end: fragment.end),
  );
  if (!block.runs.any((run) => run['link'] == true)) {
    return text;
  }
  return LayoutBuilder(
    builder: (context, constraints) => Listener(
      onPointerDown: (event) {
        final painter = TextPainter(
          text: block.span(
            preferences,
            start: fragment.start,
            end: fragment.end,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        var position = 0;
        for (final run in block.runs) {
          final end = position + (run['text'] as String).length;
          final start = math.max(position, fragment.start) - fragment.start;
          final stop = math.min(end, fragment.end) - fragment.start;
          if (run['link'] == true && stop > start) {
            final boxes = painter.getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: stop),
            );
            if (boxes.any(
              (box) => box.toRect().contains(event.localPosition),
            )) {
              ReaderInteractionScope.maybeOf(context)?.suppressTap();
              break;
            }
          }
          position = end;
        }
        painter.dispose();
      },
      child: text,
    ),
  );
}
