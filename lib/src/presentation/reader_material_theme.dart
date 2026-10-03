import 'package:flutter/material.dart';

/// Reader colors must not retain the host's resolved canvas/component colors.
/// Keep typography, control geometry and motion policy, but construct Material
/// defaults again from the selected reading appearance.
ThemeData buildReaderMaterialTheme(ThemeData host, Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: host.colorScheme.primary,
    brightness: brightness,
  );
  final input = host.inputDecorationTheme;
  InputBorder? border(InputBorder? value, Color color) =>
      value?.copyWith(borderSide: value.borderSide.copyWith(color: color));
  TextStyle text(TextStyle? value, Color color) =>
      (value ?? const TextStyle()).copyWith(color: color);
  final labels = WidgetStateTextStyle.resolveWith(
    (states) => text(
      input.floatingLabelStyle ?? input.labelStyle,
      states.contains(WidgetState.error)
          ? colors.error
          : states.contains(WidgetState.disabled)
          ? colors.onSurface.withValues(alpha: .38)
          : states.contains(WidgetState.focused)
          ? colors.primary
          : colors.onSurfaceVariant,
    ),
  );
  return ThemeData(
    useMaterial3: host.useMaterial3,
    colorScheme: colors,
    canvasColor: colors.surface,
    scaffoldBackgroundColor: colors.surface,
    cardColor: colors.surfaceContainerLow,
    hintColor: colors.onSurfaceVariant,
    disabledColor: colors.onSurface.withValues(alpha: .38),
    iconTheme: host.iconTheme.copyWith(color: colors.onSurface),
    primaryIconTheme: host.primaryIconTheme.copyWith(color: colors.onPrimary),
    platform: host.platform,
    visualDensity: host.visualDensity,
    materialTapTargetSize: host.materialTapTargetSize,
    typography: host.typography,
    textTheme: host.textTheme.apply(
      bodyColor: colors.onSurface,
      displayColor: colors.onSurface,
    ),
    primaryTextTheme: host.primaryTextTheme.apply(
      bodyColor: colors.onPrimary,
      displayColor: colors.onPrimary,
    ),
    extensions: host.extensions.values,
    pageTransitionsTheme: host.pageTransitionsTheme,
    splashFactory: host.splashFactory,
    // Retain the e-ink host's transparent ink effects.
    highlightColor: host.highlightColor.a == 0 ? host.highlightColor : null,
    splashColor: host.splashColor.a == 0 ? host.splashColor : null,
    inputDecorationTheme: input.copyWith(
      labelStyle: text(input.labelStyle, colors.onSurfaceVariant),
      floatingLabelStyle: labels,
      hintStyle: text(input.hintStyle, colors.onSurfaceVariant),
      helperStyle: text(input.helperStyle, colors.onSurfaceVariant),
      errorStyle: text(input.errorStyle, colors.error),
      fillColor: colors.surfaceContainerHighest,
      iconColor: colors.onSurfaceVariant,
      prefixIconColor: colors.onSurfaceVariant,
      suffixIconColor: colors.onSurfaceVariant,
      border: border(input.border, colors.outline),
      enabledBorder: border(input.enabledBorder, colors.outline),
      focusedBorder: border(input.focusedBorder, colors.primary),
      disabledBorder: border(
        input.disabledBorder,
        colors.onSurface.withValues(alpha: .12),
      ),
      errorBorder: border(input.errorBorder, colors.error),
      focusedErrorBorder: border(input.focusedErrorBorder, colors.error),
      focusColor: colors.primary.withValues(alpha: .12),
      hoverColor: host.hoverColor.a == 0
          ? host.hoverColor
          : colors.onSurface.withValues(alpha: .08),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: _geometry(host.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: _geometry(host.elevatedButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _geometry(host.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: _geometry(host.textButtonTheme.style),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: _geometry(host.iconButtonTheme.style),
    ),
    dividerTheme: host.dividerTheme.copyWith(color: colors.outlineVariant),
  );
}

ButtonStyle? _geometry(ButtonStyle? style) => style == null
    ? null
    : ButtonStyle(
        animationDuration: style.animationDuration,
        padding: style.padding,
        shape: style.shape,
        minimumSize: style.minimumSize,
        maximumSize: style.maximumSize,
        fixedSize: style.fixedSize,
        elevation: style.elevation,
        visualDensity: style.visualDensity,
        enableFeedback: style.enableFeedback,
        tapTargetSize: style.tapTargetSize,
      );
