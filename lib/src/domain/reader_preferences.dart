import 'package:flutter/widgets.dart';

import 'reader_types.dart';

const Object _unsetFontFamily = Object();

final class ReaderPreferences {
  const ReaderPreferences({
    this.fontFamily,
    this.fontSize = 18,
    this.lineHeight = 1.5,
    this.letterSpacing = 0,
    this.paragraphSpacing = 8,
    this.pageMargins = const EdgeInsets.all(24),
    this.backgroundColor = const Color(0xffffffff),
    this.foregroundColor = const Color(0xff1b1b1b),
    this.brightness = Brightness.light,
    this.layoutMode = ReaderLayoutMode.paginated,
    this.columnMode = ReaderColumnMode.automatic,
  }) : assert(fontSize > 0),
       assert(lineHeight > 0),
       assert(paragraphSpacing >= 0);

  final String? fontFamily;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final EdgeInsets pageMargins;
  final Color backgroundColor;
  final Color foregroundColor;
  final Brightness brightness;
  final ReaderLayoutMode layoutMode;
  final ReaderColumnMode columnMode;

  ReaderPreferences copyWith({
    Object? fontFamily = _unsetFontFamily,
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? paragraphSpacing,
    EdgeInsets? pageMargins,
    Color? backgroundColor,
    Color? foregroundColor,
    Brightness? brightness,
    ReaderLayoutMode? layoutMode,
    ReaderColumnMode? columnMode,
  }) {
    return ReaderPreferences(
      fontFamily: identical(fontFamily, _unsetFontFamily)
          ? this.fontFamily
          : fontFamily as String?,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      pageMargins: pageMargins ?? this.pageMargins,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      foregroundColor: foregroundColor ?? this.foregroundColor,
      brightness: brightness ?? this.brightness,
      layoutMode: layoutMode ?? this.layoutMode,
      columnMode: columnMode ?? this.columnMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderPreferences &&
          fontFamily == other.fontFamily &&
          fontSize == other.fontSize &&
          lineHeight == other.lineHeight &&
          letterSpacing == other.letterSpacing &&
          paragraphSpacing == other.paragraphSpacing &&
          pageMargins == other.pageMargins &&
          backgroundColor == other.backgroundColor &&
          foregroundColor == other.foregroundColor &&
          brightness == other.brightness &&
          layoutMode == other.layoutMode &&
          columnMode == other.columnMode;

  @override
  int get hashCode => Object.hash(
    fontFamily,
    fontSize,
    lineHeight,
    letterSpacing,
    paragraphSpacing,
    pageMargins,
    backgroundColor,
    foregroundColor,
    brightness,
    layoutMode,
    columnMode,
  );
}
