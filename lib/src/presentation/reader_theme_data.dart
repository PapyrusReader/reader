import 'package:flutter/material.dart';

final class ReaderThemeData {
  const ReaderThemeData({
    required this.chromeColor,
    required this.surfaceColor,
    required this.panelColor,
    required this.accentColor,
    required this.progressColor,
    required this.handleColor,
    required this.errorColor,
    required this.onChromeColor,
    required this.dividerColor,
    this.compactBreakpoint = 720,
    this.sidePanelWidth = 320,
    this.compactToolbarHeight = 64,
    this.wideToolbarHeight = 72,
    this.minimumTargetSize = 48,
    this.panelPadding = 16,
  });

  factory ReaderThemeData.fromTheme(ThemeData theme) {
    final colors = theme.colorScheme;

    return ReaderThemeData(
      chromeColor: colors.surfaceContainer,
      surfaceColor: colors.surface,
      panelColor: colors.surfaceContainerLow,
      accentColor: colors.primary,
      progressColor: colors.primary,
      handleColor: colors.primary,
      errorColor: colors.error,
      onChromeColor: colors.onSurface,
      dividerColor: colors.outlineVariant,
    );
  }

  final Color chromeColor;
  final Color surfaceColor;
  final Color panelColor;
  final Color accentColor;
  final Color progressColor;
  final Color handleColor;
  final Color errorColor;
  final Color onChromeColor;
  final Color dividerColor;
  final double compactBreakpoint;
  final double sidePanelWidth;
  final double compactToolbarHeight;
  final double wideToolbarHeight;
  final double minimumTargetSize;
  final double panelPadding;

  ReaderThemeData copyWith({
    Color? chromeColor,
    Color? surfaceColor,
    Color? panelColor,
    Color? accentColor,
    Color? progressColor,
    Color? handleColor,
    Color? errorColor,
    Color? onChromeColor,
    Color? dividerColor,
    double? compactBreakpoint,
    double? sidePanelWidth,
    double? compactToolbarHeight,
    double? wideToolbarHeight,
    double? minimumTargetSize,
    double? panelPadding,
  }) {
    return ReaderThemeData(
      chromeColor: chromeColor ?? this.chromeColor,
      surfaceColor: surfaceColor ?? this.surfaceColor,
      panelColor: panelColor ?? this.panelColor,
      accentColor: accentColor ?? this.accentColor,
      progressColor: progressColor ?? this.progressColor,
      handleColor: handleColor ?? this.handleColor,
      errorColor: errorColor ?? this.errorColor,
      onChromeColor: onChromeColor ?? this.onChromeColor,
      dividerColor: dividerColor ?? this.dividerColor,
      compactBreakpoint: compactBreakpoint ?? this.compactBreakpoint,
      sidePanelWidth: sidePanelWidth ?? this.sidePanelWidth,
      compactToolbarHeight: compactToolbarHeight ?? this.compactToolbarHeight,
      wideToolbarHeight: wideToolbarHeight ?? this.wideToolbarHeight,
      minimumTargetSize: minimumTargetSize ?? this.minimumTargetSize,
      panelPadding: panelPadding ?? this.panelPadding,
    );
  }
}
