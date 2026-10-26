import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/presentation/reader_text_toolbar.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'selecting text at a chapter boundary does not turn the page ($kind)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        final engine = testEpubEngine();
        ReaderSelection? saved;
        const words = 'Select these words without leaving this chapter.';
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              platform: kind == PointerDeviceKind.touch
                  ? TargetPlatform.android
                  : TargetPlatform.linux,
            ),
            home: PapyrusReader(
              onAnnotate: (selection) => saved = selection,
              document: ReaderDocument(
                id: 'selection',
                format: ReaderFormat.epub,
                loadBytes: () async =>
                    syntheticEpub(secondChapterBody: '<p>$words</p>'),
              ),
              registry: ReaderEngineRegistry([
                ReaderEngineRegistration(
                  formats: const {ReaderFormat.epub},
                  factory: () => engine,
                ),
              ]),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await pumpReaderCommand(tester, engine.goNext());
        final before = engine.locator;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byWidgetPredicate(
            (widget) =>
                widget is RichText && widget.text.toPlainText() == words,
          ),
        );
        final start = paragraph.localToGlobal(
          paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 1, extentOffset: 2),
              )
              .first
              .toRect()
              .center,
        );
        final gesture = await tester.startGesture(start, kind: kind);

        if (kind == PointerDeviceKind.touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 100),
          );
        }

        await gesture.moveTo(
          start + const Offset(160, 0),
          timeStamp: const Duration(milliseconds: 700),
        );
        await tester.pump();
        await gesture.up(timeStamp: const Duration(milliseconds: 750));
        await tester.pumpAndSettle();
        expect(
          paragraph.selections.any((selection) => !selection.isCollapsed),
          isTrue,
        );
        expect(engine.locator, before);
        if (find.text('Annotate').evaluate().isEmpty &&
            find.byType(TextSelectionToolbar).evaluate().isNotEmpty) {
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();
        }
        expect(find.text('Annotate'), findsOneWidget);
        await tester.tap(find.text('Annotate'));
        await tester.pumpAndSettle();
        expect(saved, isNotNull);
        final first = saved!.start as EpubReaderLocator;
        final last = saved!.end as EpubReaderLocator;
        expect(first.spineIndex, before.spineIndex);
        expect(
          words.substring(first.textOffset!, last.textOffset!),
          saved!.text,
        );
        expect(ReaderSelection.fromJson(saved!.toJson()).start, saved!.start);
        expect(find.byTooltip('Reading settings'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final (column, longParagraph, backwards) in [
    (0, true, false),
    (0, false, false),
    (1, true, false),
    (1, false, false),
    (1, true, true),
    (1, false, true),
  ]) {
    testWidgets(
      'mouse selection opens annotation actions in EPUB column $column, long paragraph $longParagraph, backwards $backwards',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 800);
        addTearDown(tester.view.reset);
        final engine = testEpubEngine();
        ReaderSelection? saved;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.linux),
            home: PapyrusReader(
              initialPreferences: const ReaderPreferences(
                columnMode: ReaderColumnMode.double,
              ),
              onAnnotate: (selection) => saved = selection,
              document: ReaderDocument(
                id: 'columns',
                format: ReaderFormat.epub,
                loadBytes: () async => syntheticEpub(
                  longChapter: !longParagraph,
                  firstChapterBody: longParagraph
                      ? '<p>${List.filled(1000, 'Paragraph words for selection across columns. ').join()}</p>'
                      : null,
                ),
              ),
              registry: ReaderEngineRegistry([
                ReaderEngineRegistration(
                  formats: const {ReaderFormat.epub},
                  factory: () => engine,
                ),
              ]),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = engine.locator;
        final candidates = find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('Paragraph'),
        );
        final paragraphs = tester.renderObjectList<RenderParagraph>(candidates);
        final visible = paragraphs.where((paragraph) {
          final point = paragraph.localToGlobal(Offset.zero);
          return point.dx >= column * 600 &&
              point.dx < (column + 1) * 600 &&
              point.dy < 600;
        });
        final paragraph = visible.first;
        Offset at(int offset) => paragraph.localToGlobal(
          paragraph
              .getBoxesForSelection(
                TextSelection(baseOffset: offset, extentOffset: offset + 1),
              )
              .first
              .toRect()
              .center,
        );
        Future<void> select() async {
          final drag = await tester.startGesture(
            at(backwards ? 10 : 1),
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveTo(at(backwards ? 1 : 10));
          await tester.pump();
          await drag.up();
          await tester.pumpAndSettle();
        }

        await select();
        expect(find.text('Annotate'), findsOneWidget);
        final bounds = tester
            .widget<ReaderTextToolbar>(find.byType(ReaderTextToolbar))
            .bounds;
        expect(
          bounds.center.dx,
          inInclusiveRange(column * 600.0, (column + 1) * 600.0),
        );
        expect(
          bounds.top,
          closeTo(
            at(1).dy -
                paragraph
                        .getBoxesForSelection(
                          const TextSelection(baseOffset: 1, extentOffset: 2),
                        )
                        .first
                        .toRect()
                        .height /
                    2,
            1,
          ),
        );
        await tester.tapAt(const Offset(1190, 790));
        await tester.pumpAndSettle();
        expect(find.text('Annotate'), findsNothing);
        await select();
        expect(
          paragraph.selections.any((selection) => !selection.isCollapsed),
          isTrue,
        );
        expect(engine.locator, before);
        expect(find.text('Annotate'), findsOneWidget);
        await tester.tap(find.text('Annotate'));
        await tester.pumpAndSettle();
        expect(find.text('Annotate'), findsNothing);
        expect(saved, isNotNull);
        expect(saved!.text, isNotEmpty);
        expect(
          (saved!.start as EpubReaderLocator).textOffset,
          greaterThanOrEqualTo(column == 1 ? 100 : 0),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'saved highlight offers edit and remove without toggling chrome ($kind)',
      (tester) async {
        final engine = testEpubEngine();
        const words = 'Select these words without leaving this chapter.';
        final start = EpubReaderLocator(
          spineIndex: 1,
          textOffset: 7,
          localProgression: .1,
          totalProgression: .5,
        );
        final end = EpubReaderLocator(
          spineIndex: 1,
          textOffset: 18,
          localProgression: .3,
          totalProgression: .5,
        );
        final highlight = ReaderHighlight(
          id: 'saved',
          selection: ReaderSelection(
            text: 'these words',
            start: start,
            end: end,
          ),
          color: Colors.green,
        );
        ReaderHighlight? edited;
        ReaderHighlight? removed;
        await tester.pumpWidget(
          MaterialApp(
            home: PapyrusReader(
              document: ReaderDocument(
                id: 'highlight',
                format: ReaderFormat.epub,
                loadBytes: () async =>
                    syntheticEpub(secondChapterBody: '<p>$words</p>'),
              ),
              registry: ReaderEngineRegistry([
                ReaderEngineRegistration(
                  formats: const {ReaderFormat.epub},
                  factory: () => engine,
                ),
              ]),
              highlights: [highlight],
              onEditHighlight: (highlight) => edited = highlight,
              onRemoveHighlight: (highlight) => removed = highlight,
              onAnnotate: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await pumpReaderCommand(tester, engine.goNext());
        final before = engine.locator;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byWidgetPredicate(
            (widget) =>
                widget is RichText && widget.text.toPlainText() == words,
          ),
        );
        final rect = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 9, extentOffset: 10),
            )
            .first
            .toRect()
            .shift(paragraph.localToGlobal(Offset.zero));
        await tester.tapAt(rect.center, kind: kind);
        await tester.pumpAndSettle();
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Remove'), findsOneWidget);
        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Annotate'), findsNothing);
        expect(find.byTooltip('Reading settings'), findsNothing);
        expect(engine.locator, before);
        final bounds = tester
            .widget<ReaderTextToolbar>(find.byType(ReaderTextToolbar))
            .bounds;
        expect(bounds.contains(rect.center), isTrue);
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        expect(edited?.id, 'saved');
        expect(find.text('Edit'), findsNothing);
        await tester.tapAt(rect.center, kind: kind);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expect(removed?.id, 'saved');
        final drag = await tester.startGesture(rect.center, kind: kind);
        if (kind == PointerDeviceKind.touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 100),
          );
        }
        await drag.moveBy(const Offset(120, 0));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Annotate'), findsOneWidget);
        expect(engine.locator, before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'an ordinary touch swipe still advances beyond the last page of a chapter',
    (tester) async {
      final engine = testEpubEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: PapyrusReader(
            document: ReaderDocument(
              id: 'swipe',
              format: ReaderFormat.epub,
              loadBytes: () async =>
                  syntheticEpub(firstChapterBody: '<p>A short chapter.</p>'),
            ),
            registry: ReaderEngineRegistry([
              ReaderEngineRegistration(
                formats: const {ReaderFormat.epub},
                factory: () => engine,
              ),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(500, 400), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(engine.locator.spineIndex, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
