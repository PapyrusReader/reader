import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

import '../../domain/reader_preferences.dart';
import '../../domain/reader_selection.dart';
import '../../domain/reader_locator.dart';
import '../../presentation/reader_interaction_scope.dart';

/// Converts worker blocks only when the page cursor reaches them. In particular,
/// a large spine item must not decode all of its illustrations on the UI thread.
final class EpubContentBlocks extends ListBase<EpubContentBlock> {
  EpubContentBlocks(this._blocks);
  final List<Object?> _blocks;

  @override
  int get length => _blocks.length;

  @override
  EpubContentBlock operator [](int index) =>
      EpubContentBlock(Map<String, Object?>.from(_blocks[index] as Map));

  @override
  set length(int value) => throw UnsupportedError('Read-only content');

  @override
  void operator []=(int index, EpubContentBlock value) =>
      throw UnsupportedError('Read-only content');
}

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

  TextSpan span(
    ReaderPreferences preferences, {
    int start = 0,
    int? end,
    List<ReaderHighlight> highlights = const [],
  }) {
    final children = <TextSpan>[];
    var position = 0;
    for (final run in runs) {
      final text = run['text'] as String;
      final from = math.max(0, start - position);
      final to = math.min(text.length, (end ?? length) - position);
      if (to > from) {
        final cuts = <int>{from, to};

        for (final highlight in highlights) {
          final first = highlight.selection.start;
          final last = highlight.selection.end;

          if (first is EpubReaderLocator &&
              last is EpubReaderLocator &&
              first.textOffset != null &&
              last.textOffset != null) {
            cuts.add((first.textOffset! - offset - position).clamp(from, to));
            cuts.add((last.textOffset! - offset - position).clamp(from, to));
          }
        }

        final boundaries = cuts.toList()..sort();

        for (var index = 0; index < boundaries.length - 1; index++) {
          final segmentStart = boundaries[index];
          Color? background;

          for (final highlight in highlights) {
            final first = highlight.selection.start;
            final last = highlight.selection.end;
            final absolute = offset + position + segmentStart;

            if (first is EpubReaderLocator &&
                last is EpubReaderLocator &&
                first.textOffset != null &&
                last.textOffset != null &&
                absolute >= first.textOffset! &&
                absolute < last.textOffset!) {
              background = highlight.color.withValues(alpha: .4);
            }
          }

          children.add(
            TextSpan(
              text: text.substring(segmentStart, boundaries[index + 1]),
              style: TextStyle(
                backgroundColor: background,
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

/// Collects a complete layout for export and layout verification.
Future<List<EpubRichPage>> layoutEpubChapter(
  List<EpubContentBlock> blocks, {
  required Size contentSize,
  required ReaderPreferences preferences,
  required TextScaler textScaler,
  required TextDirection direction,
  required bool Function() cancelled,
}) => paginateEpub(
  blocks,
  contentSize: contentSize,
  preferences: preferences,
  textScaler: textScaler,
  direction: direction,
  cancelled: cancelled,
).toList();

/// Measures each paragraph once and cuts at actual line boundaries. Long
/// paragraphs never trigger repeated binary-search layouts or surrogate splits.
Stream<EpubRichPage> paginateEpub(
  List<EpubContentBlock> blocks, {
  required Size contentSize,
  required ReaderPreferences preferences,
  required TextScaler textScaler,
  required TextDirection direction,
  required bool Function() cancelled,
  Future<void> Function()? yieldWork,
}) async* {
  final width = math.max(1.0, contentSize.width);
  final height = math.max(1.0, contentSize.height);
  var emitted = false;
  var fragments = <EpubPageFragment>[];
  var used = 0.0;
  final stopwatch = Stopwatch()..start();
  EpubRichPage finish() {
    emitted = true;
    final page = EpubRichPage(List.unmodifiable(fragments));
    fragments = [];
    used = 0;
    return page;
  }

  for (final block in blocks) {
    if (cancelled()) return;
    final spacing = block.paragraphEnd ? preferences.paragraphSpacing : 0.0;
    if (block.image != null) {
      final imageHeight = math.min(width / block.aspect, height * .65);
      if (used + imageHeight + spacing > height && fragments.isNotEmpty) {
        yield finish();
      }
      fragments.add(EpubPageFragment(block, 0, 1, imageHeight));
      used += imageHeight + spacing;
    } else {
      final span = block.span(preferences);
      final painter = TextPainter(
        text: span,
        textDirection: direction,
        textScaler: textScaler,
      )..layout(maxWidth: width);
      try {
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
            if (fragments.isNotEmpty) {
              yield finish();
              if (cancelled()) return;
            }
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
      } finally {
        painter.dispose();
      }
    }
    if (stopwatch.elapsedMilliseconds >= 4) {
      if (yieldWork == null) {
        await Future<void>.delayed(Duration.zero);
      } else {
        await yieldWork();
      }
      stopwatch.reset();
    }
  }
  if (fragments.isNotEmpty) {
    yield finish();
  } else if (!emitted) {
    yield const EpubRichPage([]);
  }
}

Widget buildEpubFragment(
  EpubPageFragment fragment,
  ReaderPreferences preferences, {
  List<ReaderHighlight> highlights = const [],
}) {
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
  final text = EpubSelectionFragment(
    key: ValueKey(fragment.offset),
    fragment: fragment,
    child: Text.rich(
      block.span(
        preferences,
        start: fragment.start,
        end: fragment.end,
        highlights: highlights,
      ),
    ),
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

final class EpubSelectionFragment extends StatefulWidget {
  const EpubSelectionFragment({
    required this.fragment,
    required this.child,
    super.key,
  });
  final EpubPageFragment fragment;
  final Widget child;

  @override
  State<EpubSelectionFragment> createState() => EpubSelectionFragmentState();
}

final class EpubSelectionFragmentState extends State<EpubSelectionFragment>
    implements SelectionRegistrar {
  final _selectables = <Selectable>{};
  SelectionRegistrar? _parent;

  SelectedContentRange? get range {
    for (final selectable in _selectables) {
      final selection = selectable.getSelection();
      if (selection != null) return selection;
    }
    return null;
  }

  List<Rect> rectangles(int start, int end) {
    RenderParagraph? paragraph;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        paragraph = object;
      } else {
        object.visitChildren(visit);
      }
    }

    final object = context.findRenderObject();
    if (object != null) visit(object);
    final text = paragraph;
    if (text == null || !text.attached) return const [];
    final length = widget.fragment.end - widget.fragment.start;
    final selection = TextSelection(
      baseOffset: start.clamp(0, length),
      extentOffset: end.clamp(0, length),
    );
    return [
      for (final box in text.getBoxesForSelection(selection))
        Rect.fromPoints(
          text.localToGlobal(box.toRect().topLeft),
          text.localToGlobal(box.toRect().bottomRight),
        ),
    ];
  }

  @override
  void add(Selectable selectable) {
    _selectables.add(selectable);
    _parent?.add(selectable);
  }

  @override
  void remove(Selectable selectable) {
    _selectables.remove(selectable);
    _parent?.remove(selectable);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = SelectionContainer.maybeOf(context);
    if (identical(parent, _parent)) return;
    for (final selectable in _selectables) {
      _parent?.remove(selectable);
      parent?.add(selectable);
    }
    _parent = parent;
  }

  @override
  Widget build(BuildContext context) =>
      SelectionRegistrarScope(registrar: this, child: widget.child);
}
