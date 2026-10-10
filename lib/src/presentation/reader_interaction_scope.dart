import 'package:flutter/widgets.dart';

/// Routes viewport boundary gestures through the shell's command queue.
final class ReaderInteractionScope extends InheritedWidget {
  const ReaderInteractionScope({
    required this.onTurn,
    required this.onSelectionChanged,
    required this.suppressTap,
    required super.child,
    super.key,
  });

  final ValueChanged<int> onTurn;
  final ValueChanged<bool> onSelectionChanged;
  final VoidCallback suppressTap;

  static ReaderInteractionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderInteractionScope>();

  @override
  bool updateShouldNotify(ReaderInteractionScope oldWidget) =>
      onTurn != oldWidget.onTurn;
}
