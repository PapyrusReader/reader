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
