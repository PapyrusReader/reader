import 'package:flutter/widgets.dart';
import '../domain/reader_selection.dart';

/// Routes viewport boundary gestures through the shell's command queue.
final class ReaderInteractionScope extends InheritedWidget {
  const ReaderInteractionScope({
    required this.onTurn,
    required this.onSelectionChanged,
    required this.suppressTap,
    this.onAnnotate,
    this.onNote,
    this.onEditHighlight,
    this.onRemoveHighlight,
    this.highlights = const [],
    required super.child,
    super.key,
  });

  final ValueChanged<int> onTurn;
  final ValueChanged<bool> onSelectionChanged;
  final VoidCallback suppressTap;
  final ValueChanged<ReaderSelection>? onAnnotate;
  final ValueChanged<ReaderSelection>? onNote;
  final ValueChanged<ReaderHighlight>? onEditHighlight;
  final ValueChanged<ReaderHighlight>? onRemoveHighlight;
  final List<ReaderHighlight> highlights;

  static ReaderInteractionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderInteractionScope>();

  @override
  bool updateShouldNotify(ReaderInteractionScope oldWidget) =>
      onTurn != oldWidget.onTurn ||
      highlights != oldWidget.highlights ||
      onAnnotate != oldWidget.onAnnotate ||
      onNote != oldWidget.onNote ||
      onEditHighlight != oldWidget.onEditHighlight ||
      onRemoveHighlight != oldWidget.onRemoveHighlight;
}
