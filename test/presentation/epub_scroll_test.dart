import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_processor.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  testWidgets('continuous EPUB scrolls in margins and crosses chapter edges', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final engine = testEpubEngine();
    addTearDown(engine.dispose);
    await engine.load(
      ReaderDocument(
        id: 'continuous-chapters',
        format: ReaderFormat.epub,
        loadBytes: () async => syntheticEpub(longChapter: true),
      ),
      preferences: const ReaderPreferences(layoutMode: ReaderLayoutMode.scroll),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Builder(builder: engine.buildViewport),
      ),
    );
    await tester.pumpAndSettle();
    ScrollController controller() =>
        tester.widget<ListView>(find.byType(ListView)).controller!;
    Future<void> wheel(double delta, {double x = 20}) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: Offset(x, 450),
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(tester.getSize(find.byType(ListView)).width, 1440);
    expect(tester.getSize(find.byType(Scrollbar)).width, 1440);
    await wheel(-1);
    expect(engine.locator.spineIndex, 0);
    await wheel(80);
    expect(controller().offset, greaterThan(0));
    final before = controller().offset;
    await wheel(80, x: 1420);
    expect(controller().offset, greaterThan(before));
    expect(engine.locator.spineIndex, 0);
    for (var chapter = 1; chapter < 3; chapter++) {
      controller().jumpTo(controller().position.maxScrollExtent);
      await tester.pumpAndSettle();
      await wheel(1, x: 1420);
      expect(engine.locator.spineIndex, chapter);
      expect(controller().offset, closeTo(0, 1));
    }
    controller().jumpTo(controller().position.maxScrollExtent);
    await tester.pumpAndSettle();
    await wheel(1);
    expect(engine.locator.spineIndex, 2);
    for (var chapter = 1; chapter >= 0; chapter--) {
      controller().jumpTo(0);
      await tester.pumpAndSettle();
      await wheel(-1);
      expect(engine.locator.spineIndex, chapter);
      expect(
        controller().offset,
        closeTo(controller().position.maxScrollExtent, 1),
      );
    }
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final short in [false, true]) {
      testWidgets(
        'continuous EPUB touch crosses edges on $platform, short $short',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final engine = testEpubEngine();
          addTearDown(engine.dispose);
          await engine.load(
            ReaderDocument(
              id: 'touch-chapters',
              format: ReaderFormat.epub,
              loadBytes: () async => syntheticEpub(
                longChapter: !short,
                firstChapterBody: short ? '<p>Short first chapter.</p>' : null,
                secondChapterBody: short
                    ? '<p>Short second chapter.</p>'
                    : null,
              ),
            ),
            preferences: const ReaderPreferences(
              layoutMode: ReaderLayoutMode.scroll,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Builder(builder: engine.buildViewport),
            ),
          );
          await tester.pumpAndSettle();
          ScrollController controller() =>
              tester.widget<ListView>(find.byType(ListView)).controller!;
          Future<void> swipe(int direction, {bool cancel = false}) async {
            final before = engine.locator.spineIndex;
            final gesture = await tester.startGesture(
              Offset(195, direction > 0 ? 600 : 250),
            );
            for (final distance in [30.0, 100.0, 180.0]) {
              await gesture.moveBy(Offset(0, -distance * direction));
              await tester.pump(const Duration(milliseconds: 40));
            }
            expect(
              engine.locator.spineIndex,
              before,
              reason: 'Only a completed gesture changes chapter',
            );
            if (cancel) {
              await gesture.cancel();
            } else {
              await gesture.up();
            }
            await tester.pumpAndSettle();
          }

          final maximum = controller().position.maxScrollExtent;
          if (!short) {
            controller().jumpTo(maximum - 300);
            await tester.pumpAndSettle();
            await tester.fling(
              find.byType(ListView),
              const Offset(0, -100),
              2500,
            );
            await tester.pumpAndSettle();
            expect(
              engine.locator.spineIndex,
              0,
              reason: 'Inertia alone must not skip a chapter',
            );
          }
          controller().jumpTo(short ? 0 : maximum - 80);
          await tester.pumpAndSettle();
          await swipe(1);
          expect(engine.locator.spineIndex, 1);
          expect(controller().offset, closeTo(0, 1));
          controller().jumpTo(short ? 0 : 80);
          await tester.pumpAndSettle();
          await swipe(-1);
          expect(engine.locator.spineIndex, 0);
          expect(
            controller().offset,
            closeTo(controller().position.maxScrollExtent, 1),
          );
          await swipe(1, cancel: true);
          expect(engine.locator.spineIndex, 0);
          controller().jumpTo(0);
          await tester.pumpAndSettle();
          await swipe(-1);
          expect(
            engine.locator.spineIndex,
            0,
            reason: 'The beginning of the book stays in place',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final scale in [1.0, 1.6]) {
    testWidgets(
      'continuous line-break paragraphs do not overflow at scale $scale',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final engine = testEpubEngine();
        addTearDown(engine.dispose);
        final lines = List.generate(
          100,
          (index) =>
              'Line $index with <em>italic text</em> and more words.<br/>',
        ).join();
        await engine.load(
          ReaderDocument(
            id: 'continuous-line-breaks',
            format: ReaderFormat.epub,
            loadBytes: () async =>
                syntheticEpub(firstChapterBody: '<p>$lines</p>'),
          ),
          preferences: const ReaderPreferences(
            layoutMode: ReaderLayoutMode.scroll,
            fontSize: 24,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Builder(builder: engine.buildViewport),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        for (
          var offset = 0.0;
          offset < controller.position.maxScrollExtent;
          offset += 400
        ) {
          controller.jumpTo(offset);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'Alice arithmetic and poem remain readable in continuous scroll',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bytes = File(
        'test/fixtures/gutenberg/alice.epub',
      ).readAsBytesSync();
      final processor = EpubProcessor();
      final metadata = await processor.dispatch('open', bytes);
      int? chapter;
      for (var index = 0; index < (metadata['count'] as int); index++) {
        final content = await processor.dispatch('chapter', index);
        if (content.toString().contains('four times five')) {
          chapter = index;
          break;
        }
      }
      expect(chapter, isNotNull);
      final engine = testEpubEngine();
      addTearDown(engine.dispose);
      await engine.load(
        ReaderDocument(
          id: 'alice-scroll',
          format: ReaderFormat.epub,
          loadBytes: () async => bytes,
        ),
        initialLocator: EpubReaderLocator(
          spineIndex: chapter!,
          localProgression: 0,
          totalProgression: 0,
        ),
        preferences: const ReaderPreferences(
          layoutMode: ReaderLayoutMode.scroll,
          fontSize: 24,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: engine.buildViewport)),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      for (
        var offset = 0.0;
        offset < controller.position.maxScrollExtent;
        offset += 450
      ) {
        controller.jumpTo(offset);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );
}
