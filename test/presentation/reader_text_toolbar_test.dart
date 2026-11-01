import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/src/presentation/reader_text_toolbar.dart';

void main() {
  for (final width in [390.0, 1200.0]) {
    for (final atTop in [true, false]) {
      testWidgets(
        'toolbar stays near text and inside width $width, top $atTop',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 800);
          addTearDown(tester.view.reset);
          final bounds = Rect.fromLTWH(width - 100, atTop ? 4 : 700, 85, 24);
          await tester.pumpWidget(
            MaterialApp(
              home: Stack(
                children: [
                  ReaderTextToolbar(
                    bounds: bounds,
                    items: [
                      ContextMenuButtonItem(label: 'Edit', onPressed: () {}),
                      ContextMenuButtonItem(label: 'Remove', onPressed: () {}),
                      ContextMenuButtonItem(label: 'Copy', onPressed: () {}),
                    ],
                  ),
                ],
              ),
            ),
          );
          await tester.pumpAndSettle();
          final edit = tester.getRect(
            find.widgetWithText(TextSelectionToolbarTextButton, 'Edit'),
          );
          final copy = tester.getRect(
            find.widgetWithText(TextSelectionToolbarTextButton, 'Copy'),
          );
          final toolbar = edit.expandToInclude(copy);
          expect(toolbar.left, greaterThanOrEqualTo(0));
          expect(toolbar.right, lessThanOrEqualTo(width));
          if (atTop) {
            expect(toolbar.top, greaterThan(bounds.bottom));
            expect(toolbar.top - bounds.bottom, lessThan(30));
          } else {
            expect(toolbar.bottom, lessThan(bounds.top));
            expect(bounds.top - toolbar.bottom, lessThan(30));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
