import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  testWidgets('hiding chrome keeps a long EPUB on its current content offset', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 850);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = testEpubEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: PapyrusReader(
          registry: ReaderEngineRegistry([
            ReaderEngineRegistration(
              formats: const {ReaderFormat.epub},
              factory: () => engine,
            ),
          ]),
          document: ReaderDocument(
            id: 'focus',
            format: ReaderFormat.epub,
            loadBytes: () async => syntheticEpub(longChapter: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await engine.goNext();
    await tester.pumpAndSettle();
    await engine.goNext();
    await tester.pumpAndSettle();
    final before = await engine.currentLocator() as EpubReaderLocator;
    expect(before.textOffset, greaterThan(0));
    await tester.tap(find.byTooltip('Hide controls'));
    await tester.pumpAndSettle();
    expect(
      (await engine.currentLocator() as EpubReaderLocator).textOffset,
      before.textOffset,
    );
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      greaterThan(0),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide controls'), findsOneWidget);
    expect(
      (await engine.currentLocator() as EpubReaderLocator).textOffset,
      before.textOffset,
    );
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      greaterThan(0),
    );
    semantics.dispose();
  });

  testWidgets('arrow navigation stays focused across consecutive chapters', (
    tester,
  ) async {
    final engine = testEpubEngine();
    final registry = ReaderEngineRegistry([
      ReaderEngineRegistration(
        formats: const {ReaderFormat.epub},
        factory: () => engine,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: PapyrusReader(
          registry: registry,
          document: ReaderDocument(
            id: 'keyboard',
            format: ReaderFormat.epub,
            loadBytes: () async => syntheticEpub(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect((await engine.currentLocator() as EpubReaderLocator).spineIndex, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect((await engine.currentLocator() as EpubReaderLocator).spineIndex, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect((await engine.currentLocator() as EpubReaderLocator).spineIndex, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect((await engine.currentLocator() as EpubReaderLocator).spineIndex, 0);
  });

  testWidgets(
    'page controls, reflow and chapter boundaries preserve the reading position',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = testEpubEngine();
      await engine.load(
        ReaderDocument(
          id: 'long',
          format: ReaderFormat.epub,
          loadBytes: () async => syntheticEpub(longChapter: true),
        ),
        preferences: const ReaderPreferences(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Builder(builder: engine.buildViewport)),
        ),
      );
      await tester.pumpAndSettle();

      await engine.goNext();
      await tester.pumpAndSettle();
      final secondPage = await engine.currentLocator() as EpubReaderLocator;
      expect(
        secondPage.spineIndex,
        0,
        reason: 'Next turns a page instead of skipping a chapter',
      );
      expect(secondPage.textOffset, greaterThan(0));
      await engine.updatePreferences(const ReaderPreferences(fontSize: 25));
      await tester.pumpAndSettle();
      expect(
        (await engine.currentLocator() as EpubReaderLocator).textOffset,
        secondPage.textOffset,
      );

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(
        (await engine.currentLocator() as EpubReaderLocator).textOffset,
        secondPage.textOffset,
      );
      expect(tester.takeException(), isNull);
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.pumpAndSettle();
      expect(
        (await engine.currentLocator() as EpubReaderLocator).textOffset,
        secondPage.textOffset,
        reason: 'Late font loading must remeasure without losing position',
      );
      await engine.goToProgress(1 / 3);
      await tester.pumpAndSettle();
      await engine.goPrevious();
      await tester.pumpAndSettle();
      final previousChapterEnd =
          await engine.currentLocator() as EpubReaderLocator;
      expect(previousChapterEnd.spineIndex, 0);
      expect(previousChapterEnd.localProgression, 1);
      await engine.goNext();
      await tester.pumpAndSettle();
      expect(
        (await engine.currentLocator() as EpubReaderLocator).spineIndex,
        1,
      );
    },
  );

  testWidgets(
    'single column stays readable beside a desktop panel and at large text sizes',
    (tester) async {
      final engine = testEpubEngine();
      await engine.load(
        ReaderDocument(
          id: 'long',
          format: ReaderFormat.epub,
          loadBytes: () async => syntheticEpub(longChapter: true),
        ),
        preferences: const ReaderPreferences(),
      );
      for (final size in [
        const Size(320, 480),
        const Size(700, 360),
        const Size(1200, 800),
      ]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(child: Builder(builder: engine.buildViewport)),
                  if (size.width > 1000) const SizedBox(width: 320),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
