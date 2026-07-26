import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  group('ReaderPreferences', () {
    test('provides readable defaults', () {
      const preferences = ReaderPreferences();

      expect(preferences.fontSize, 18);
      expect(preferences.lineHeight, 1.5);
      expect(preferences.pageMargins, const EdgeInsets.all(24));
      expect(preferences.brightness, Brightness.light);
      expect(preferences.layoutMode, ReaderLayoutMode.paginated);
      expect(preferences.columnMode, ReaderColumnMode.automatic);
    });

    test('copyWith changes selected values and preserves the rest', () {
      const original = ReaderPreferences(
        fontFamily: 'Literata',
        foregroundColor: Color(0xff222222),
      );

      final changed = original.copyWith(
        fontSize: 21,
        layoutMode: ReaderLayoutMode.scroll,
      );

      expect(changed.fontFamily, 'Literata');
      expect(changed.foregroundColor, const Color(0xff222222));
      expect(changed.fontSize, 21);
      expect(changed.layoutMode, ReaderLayoutMode.scroll);
      expect(changed, isNot(original));
      expect(changed.copyWith(), changed);
    });

    test('supports setting and clearing an optional font family', () {
      const preferences = ReaderPreferences(fontFamily: 'Atkinson');

      expect(preferences.copyWith(fontFamily: null).fontFamily, isNull);
    });
  });
}
