import 'package:flutter/material.dart';

/// Keeps engine preparation visually consistent with the host's opening state.
final class ReaderLoadingScope extends InheritedWidget {
  const ReaderLoadingScope({
    required this.builder,
    required this.backgroundColor,
    required super.child,
    super.key,
  });

  final WidgetBuilder builder;
  final Color backgroundColor;

  static ReaderLoadingScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderLoadingScope>();

  @override
  bool updateShouldNotify(ReaderLoadingScope oldWidget) =>
      builder != oldWidget.builder ||
      backgroundColor != oldWidget.backgroundColor;
}

final class ReaderLoading extends StatelessWidget {
  const ReaderLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ReaderLoadingScope>();
    return scope?.builder(context) ??
        const Center(
          child: CircularProgressIndicator(semanticsLabel: 'Opening document'),
        );
  }
}
