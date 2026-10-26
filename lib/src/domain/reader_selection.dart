import 'package:flutter/painting.dart';

import 'reader_locator.dart';

/// Durable text anchors. EPUB uses chapter-local UTF-16 offsets, PDF uses page rectangles.
final class ReaderSelection {
  const ReaderSelection({
    required this.text,
    required this.start,
    required this.end,
    this.rectangles = const [],
  });

  final String text;
  final ReaderLocator start;
  final ReaderLocator end;
  final List<ReaderSelectionRect> rectangles;

  Map<String, Object?> toJson() => {
    'text': text,
    'start': start.toJson(),
    'end': end.toJson(),
    'rectangles': [for (final rectangle in rectangles) rectangle.toJson()],
  };

  factory ReaderSelection.fromJson(Map<String, Object?> json) =>
      ReaderSelection(
        text: json['text'] as String,
        start: ReaderLocator.fromJson(
          Map<String, Object?>.from(json['start'] as Map),
        ),
        end: ReaderLocator.fromJson(
          Map<String, Object?>.from(json['end'] as Map),
        ),
        rectangles: [
          for (final rectangle in json['rectangles'] as List? ?? const [])
            ReaderSelectionRect.fromJson(
              Map<String, Object?>.from(rectangle as Map),
            ),
        ],
      );
}

final class ReaderSelectionRect {
  const ReaderSelectionRect({required this.pageIndex, required this.rect});

  final int pageIndex;

  /// Coordinates relative to page width and height, with a top-left origin.
  final Rect rect;

  Map<String, Object?> toJson() => {
    'pageIndex': pageIndex,
    'left': rect.left,
    'top': rect.top,
    'right': rect.right,
    'bottom': rect.bottom,
  };

  factory ReaderSelectionRect.fromJson(Map<String, Object?> json) =>
      ReaderSelectionRect(
        pageIndex: json['pageIndex'] as int,
        rect: Rect.fromLTRB(
          (json['left'] as num).toDouble(),
          (json['top'] as num).toDouble(),
          (json['right'] as num).toDouble(),
          (json['bottom'] as num).toDouble(),
        ),
      );
}

final class ReaderHighlight {
  const ReaderHighlight({
    required this.id,
    required this.selection,
    required this.color,
  });

  final String id;
  final ReaderSelection selection;
  final Color color;
}
