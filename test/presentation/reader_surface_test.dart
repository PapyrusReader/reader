import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/epub_rich_layout.dart';
import 'package:papyrus_reader/src/presentation/reader_interaction_scope.dart';
import 'package:papyrus_reader/src/presentation/reader_surface.dart';

void main() {
  testWidgets(
    'selectable text toggles while only the actual link excludes taps',
    (tester) async {
      var toggles = 0;
      final block = EpubContentBlock({
        'kind': 'p',
        'offset': 0,
        'length': 32,
        'runs': [
          {'text': 'Ordinary words '},
          {'text': 'a link', 'link': true, 'underline': true},
          {'text': ' more text.'},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderSurface(
            enabled: true,
            onToggle: () => toggles++,
            onTurn: (_) {},
            child: Center(
              child: SizedBox(
                width: 500,
                child: Builder(
                  builder: (context) => SelectionArea(
                    onSelectionChanged: (selection) =>
                        ReaderInteractionScope.maybeOf(
                          context,
                        )!.onSelectionChanged(
                          selection?.plainText.isNotEmpty ?? false,
                        ),
                    child: buildEpubFragment(
                      EpubPageFragment(block, 0, 32, 40),
                      const ReaderPreferences(fontSize: 24),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText() == 'Ordinary words a link more text.',
        ),
      );
      Offset character(int index) => paragraph.localToGlobal(
        paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: index, extentOffset: index + 1),
            )
            .single
            .toRect()
            .center,
      );
      await tester.tapAt(character(2));
      await tester.pump(const Duration(milliseconds: 350));
      expect(toggles, 1);
      await tester.tapAt(character(16));
      await tester.pump(const Duration(milliseconds: 350));
      expect(toggles, 1);
      await tester.tapAt(character(25));
      await tester.pump(const Duration(milliseconds: 350));
      expect(toggles, 2);
    },
  );

  testWidgets('plain page taps toggle while gestures and selections do not', (
    tester,
  ) async {
    var toggles = 0;
    late ReaderInteractionScope interactions;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: ReaderSurface(
            enabled: true,
            onToggle: () => toggles++,
            onTurn: (_) {},
            child: Builder(
              builder: (context) {
                interactions = ReaderInteractionScope.maybeOf(context)!;
                return const ColoredBox(color: Colors.white);
              },
            ),
          ),
        ),
      ),
    );
    const center = Offset(400, 300);
    Future<void> settleTap() => tester.pump(const Duration(milliseconds: 350));

    await tester.tapAt(center);
    await settleTap();
    expect(toggles, 1);
    await tester.longPressAt(center);
    await settleTap();
    await tester.dragFrom(center, const Offset(-120, 0));
    await settleTap();
    expect(toggles, 1);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await settleTap();
    expect(toggles, 1);
    final first = await tester.startGesture(center, pointer: 1);
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );
    await second.up();
    await first.up();
    await settleTap();
    expect(toggles, 1);
    interactions.onSelectionChanged(true);
    await tester.tapAt(center);
    await settleTap();
    expect(toggles, 1);
    interactions.onSelectionChanged(false);
    final linkTap = await tester.startGesture(center);
    interactions.suppressTap();
    await linkTap.up();
    await settleTap();
    expect(toggles, 1);
    await tester.tapAt(center);
    await settleTap();
    expect(toggles, 2);
    final plainTap = await tester.startGesture(const Offset(50, 300));
    interactions.onSelectionChanged(false);
    await plainTap.up();
    await settleTap();
    expect(toggles, 3);
  });
}
