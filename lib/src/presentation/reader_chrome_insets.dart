import 'package:flutter/widgets.dart';

/// Space obscured by reader controls, for feedback that overlays the viewport.
/// Reading content keeps its full size when the controls appear.
final class ReaderChromeInsets extends InheritedWidget {
  const ReaderChromeInsets({
    required this.insets,
    required super.child,
    super.key,
  });

  final EdgeInsets insets;

  static EdgeInsets of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderChromeInsets>()
          ?.insets ??
      EdgeInsets.zero;

  @override
  bool updateShouldNotify(ReaderChromeInsets oldWidget) =>
      insets != oldWidget.insets;
}
