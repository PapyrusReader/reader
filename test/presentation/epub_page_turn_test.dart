import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets(
      'boundary turns preserve the committed location until visible, reduced motion $reducedMotion',
      (tester) async {
        final engine = testEpubEngine();
        await engine.load(
          ReaderDocument(
            id: 'boundaries',
            format: ReaderFormat.epub,
            loadBytes: () async =>
                syntheticEpub(firstChapterBody: '<p>First page.</p>'),
          ),
          preferences: const ReaderPreferences(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: Builder(builder: engine.buildViewport),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final turn = engine.goNext();
        await tester.pump();
        await tester.pump();
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        if (!reducedMotion) {
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          expect(controller.page, greaterThan(0));
          expect(controller.page, lessThan(1));
          expect((engine.snapshot.locator as EpubReaderLocator).spineIndex, 0);
        }

        await pumpReaderCommand(tester, turn);
        expect((engine.snapshot.locator as EpubReaderLocator).spineIndex, 1);
        expect(engine.snapshot.contentReady, isTrue);
        final previous = engine.goPrevious();
        await tester.pump();
        await tester.pump();
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        if (!reducedMotion) {
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          expect(controller.page, greaterThan(0));
          expect(controller.page, lessThan(1));
          expect((engine.snapshot.locator as EpubReaderLocator).spineIndex, 1);
        }

        await pumpReaderCommand(tester, previous);
        expect((engine.snapshot.locator as EpubReaderLocator).spineIndex, 0);
        await pumpReaderCommand(
          tester,
          Future.wait([engine.goNext(), engine.goNext(), engine.goPrevious()]),
        );
        expect((engine.snapshot.locator as EpubReaderLocator).spineIndex, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('queued turns continue visually into a multipage destination', (
    tester,
  ) async {
    final engine = testEpubEngine();
    await engine.load(
      ReaderDocument(
        id: 'queued',
        format: ReaderFormat.epub,
        loadBytes: () async => syntheticEpub(
          firstChapterBody: '<p>Start.</p>',
          secondChapterBody: List.filled(
            100,
            '<p>A longer passage fills the following pages with continuous text.</p>',
          ).join(),
        ),
      ),
      preferences: const ReaderPreferences(),
    );
    await tester.pumpWidget(
      MaterialApp(home: Builder(builder: engine.buildViewport)),
    );
    await tester.pumpAndSettle();
    await pumpReaderCommand(
      tester,
      Future.wait([engine.goNext(), engine.goNext(), engine.goNext()]),
    );
    expect(engine.locator.spineIndex, 1);
    expect(engine.locator.textOffset, greaterThan(0));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page counts stay present and settle without moving the reader', (
    tester,
  ) async {
    final engine = testEpubEngine();
    final labels = <String>[];
    engine.addListener(() {
      if (engine.snapshot.contentReady &&
          engine.snapshot.locationLabel != null) {
        labels.add(engine.snapshot.locationLabel!);
      }
    });
    await engine.load(
      ReaderDocument(
        id: 'page-counts',
        format: ReaderFormat.epub,
        loadBytes: () async => syntheticEpub(longChapter: true),
      ),
      preferences: const ReaderPreferences(),
    );
    await tester.pumpWidget(
      MaterialApp(home: Builder(builder: engine.buildViewport)),
    );
    await tester.pumpAndSettle();
    final location = engine.locator;
    for (
      var frame = 0;
      frame < 100 && engine.snapshot.locationLabel!.contains('≈');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      engine.snapshot.locationLabel,
      matches(r'Chapter 1 of 3 · Page 1 of [0-9]+$'),
    );
    expect(engine.locator, location);
    expect(labels, isNotEmpty);
    expect(
      labels.every(
        (label) => RegExp(r' · Page [0-9]+ of ≈?[0-9]+$').hasMatch(label),
      ),
      isTrue,
    );
    await pumpReaderCommand(
      tester,
      engine.goTo(
        EpubReaderLocator(
          spineIndex: 1,
          localProgression: 0,
          totalProgression: 0,
        ),
      ),
    );
    expect(
      engine.snapshot.locationLabel,
      matches(r'Chapter 2 of 3 · Page 1 of ≈?[0-9]+$'),
    );
    await engine.updatePreferences(const ReaderPreferences(fontSize: 28));
    await tester.pumpAndSettle();
    expect(
      engine.snapshot.locationLabel,
      matches(r'Chapter 2 of 3 · Page 1 of ≈?[0-9]+$'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a single long spine item reads ahead by pages and restores distant offsets',
    (tester) async {
      final engine = testEpubEngine();
      await engine.load(
        ReaderDocument(
          id: 'unchaptered',
          format: ReaderFormat.epub,
          loadBytes: () async => syntheticEpub(
            singleSpine: true,
            firstChapterBody: List.generate(
              2000,
              (index) =>
                  '<p>Passage $index. A continuous book with no chapter divisions keeps turning smoothly.</p>',
            ).join(),
          ),
        ),
        preferences: const ReaderPreferences(),
      );
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: engine.buildViewport)),
      );
      await tester.pumpAndSettle();
      expect(engine.chapterCount, 1);
      expect(engine.snapshot.contentReady, isTrue);
      expect(engine.snapshot.atEnd, isFalse);
      expect(
        tester
            .widget<PageView>(find.byType(PageView))
            .childrenDelegate
            .estimatedChildCount,
        lessThanOrEqualTo(5),
      );

      for (var i = 0; i < 8; i++) {
        await pumpReaderCommand(tester, engine.goNext());
      }

      expect(engine.locator.spineIndex, 0);
      expect(engine.locator.textOffset, greaterThan(0));
      expect(engine.snapshot.atEnd, isFalse);
      await pumpReaderCommand(
        tester,
        engine.goTo(
          EpubReaderLocator(
            spineIndex: 0,
            textOffset: 60000,
            localProgression: 0,
            totalProgression: 0,
          ),
        ),
      );
      expect(engine.locator.textOffset, 60000);
      final page = tester
          .widget<PageView>(find.byType(PageView))
          .controller!
          .page!;
      expect(page, greaterThan(8));
      await engine.updatePreferences(const ReaderPreferences(fontSize: 22));
      await tester.pumpAndSettle();
      expect(engine.locator.textOffset, 60000);
      await pumpReaderCommand(tester, engine.goToProgress(1));
      expect(engine.snapshot.atEnd, isTrue);
      await pumpReaderCommand(tester, engine.goPrevious());
      expect(engine.snapshot.atEnd, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
