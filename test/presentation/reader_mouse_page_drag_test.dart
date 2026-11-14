import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/src/presentation/reader_mouse_page_drag.dart';

void main() {
  for (final direction in [-1, 1]) {
    testWidgets('decelerating mouse drag cannot fling backwards, $direction', (
      tester,
    ) async {
      final pages = PageController(initialPage: 1);
      addTearDown(pages.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderMousePageDrag(
            controller: pages,
            animate: true,
            canStart: (_) => true,
            onTurn: (_) {},
            child: PageView(
              controller: pages,
              children: const [
                SizedBox.expand(),
                SizedBox.expand(),
                SizedBox.expand(),
              ],
            ),
          ),
        ),
      );
      final start = Offset(direction > 0 ? 50 : 750, 300);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      for (final sample in [
        (10, 100),
        (20, 300),
        (30, 500),
        (60, 600),
        (80, 601),
        (100, 602),
      ]) {
        await gesture.moveTo(
          start + Offset(sample.$2 * direction.toDouble(), 0),
          timeStamp: Duration(milliseconds: sample.$1),
        );
        await tester.pump();
      }
      expect(pages.page, closeTo(1 - direction * 602 / 800, .001));
      await gesture.up(timeStamp: const Duration(milliseconds: 101));
      await tester.pumpAndSettle();
      expect(pages.page, 1 - direction);

      // A real reversal at release must still fling back to the starting page.
      pages.jumpToPage(1);
      await tester.pumpAndSettle();
      final reverse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      for (final sample in [(10, 30), (20, 600), (50, 550), (60, 500)]) {
        await reverse.moveTo(
          start + Offset(sample.$2 * direction.toDouble(), 0),
          timeStamp: Duration(milliseconds: sample.$1),
        );
        await tester.pump();
      }
      await reverse.up(timeStamp: const Duration(milliseconds: 61));
      await tester.pumpAndSettle();
      expect(pages.page, 1);
    });
  }
}
