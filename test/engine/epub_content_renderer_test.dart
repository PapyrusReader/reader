import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  testWidgets('progress seeks restore the custom renderer within a chapter', (
    tester,
  ) async {
    final renderer = _TrackingRenderer();
    final engine = EpubReaderEngine(
      renderer: renderer,
      workerFactory: () async => InProcessEpubWorker(),
    );
    addTearDown(engine.dispose);
    await engine.load(
      ReaderDocument(
        id: 'custom-scroll',
        format: ReaderFormat.epub,
        loadBytes: () async => syntheticEpub(
          singleSpine: true,
          firstChapterBody:
              '<p>${List.filled(200, "Scrollable text").join(" ")}</p>',
        ),
      ),
      preferences: const ReaderPreferences(layoutMode: ReaderLayoutMode.scroll),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: engine,
          builder: (context, _) => engine.buildViewport(context),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final progress in [.25, .75, 1.0]) {
      await pumpReaderCommand(tester, engine.goToProgress(progress));
      expect(
        renderer.controller.offset /
            renderer.controller.position.maxScrollExtent,
        closeTo(progress, .01),
      );
      expect(engine.locator.totalProgression, closeTo(progress, .01));
    }
  });

  for (final initiallyPaginated in [false, true]) {
    testWidgets(
      'custom EPUB renderer crosses chapter edges with touch, initially paginated $initiallyPaginated',
      (tester) async {
        final renderer = _TrackingRenderer();
        final engine = EpubReaderEngine(
          renderer: renderer,
          workerFactory: () async => InProcessEpubWorker(),
        );
        addTearDown(engine.dispose);
        await engine.load(
          ReaderDocument(
            id: 'custom-touch',
            format: ReaderFormat.epub,
            loadBytes: () async => syntheticEpub(),
          ),
          preferences: ReaderPreferences(
            layoutMode: initiallyPaginated
                ? ReaderLayoutMode.paginated
                : ReaderLayoutMode.scroll,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(home: Builder(builder: engine.buildViewport)),
        );
        await tester.pumpAndSettle();
        if (initiallyPaginated) {
          await engine.updatePreferences(
            engine.preferences.copyWith(layoutMode: ReaderLayoutMode.scroll),
          );
          await tester.pumpAndSettle();
        }
        for (final direction in [1, -1]) {
          final position = renderer.controller.position;
          renderer.controller.jumpTo(
            direction > 0 ? position.maxScrollExtent - 40 : 40,
          );
          await tester.pumpAndSettle();
          final before = engine.locator.spineIndex;
          await tester.dragFrom(
            const Offset(400, 300),
            Offset(0, -250.0 * direction),
          );
          await tester.pumpAndSettle();
          expect(engine.locator.spineIndex, before + direction);
          expect(
            renderer.controller.offset,
            closeTo(
              direction > 0 ? 0 : renderer.controller.position.maxScrollExtent,
              1,
            ),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('programmatic restoration does not publish progress', (
    tester,
  ) async {
    final renderer = _TrackingRenderer();
    final progressions = <double>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 300,
          height: 300,
          child: EpubScrollViewport(
            xhtml: '<p>Chapter</p>',
            preferences: const ReaderPreferences(),
            localProgression: 0.5,
            restorationRevision: 1,
            renderer: renderer,
            onProgressChanged: progressions.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      renderer.controller.offset,
      renderer.controller.position.maxScrollExtent * 0.5,
    );
    expect(progressions, isEmpty);
  });

  testWidgets(
    'scroll-originated progression rebuild does not restore the viewport',
    (tester) async {
      final renderer = _TrackingRenderer();

      Widget viewport(double localProgression) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 300,
            child: EpubScrollViewport(
              xhtml: '<p>Chapter</p>',
              preferences: const ReaderPreferences(),
              localProgression: localProgression,
              restorationRevision: 1,
              renderer: renderer,
              onProgressChanged: (_) {},
            ),
          ),
        );
      }

      await tester.pumpWidget(viewport(0.2));
      await tester.pumpAndSettle();

      renderer.controller.jumpTo(300);
      await tester.pump();
      expect(renderer.controller.offset, 300);

      await tester.pumpWidget(viewport(0.8));
      await tester.pumpAndSettle();

      expect(renderer.controller.offset, 300);
    },
  );
}

final class _TrackingRenderer implements EpubContentRenderer {
  late ScrollController controller;

  @override
  Widget render({
    required String xhtml,
    required ReaderPreferences preferences,
    required ScrollController controller,
  }) {
    this.controller = controller;

    return SingleChildScrollView(
      controller: controller,
      child: const SizedBox(height: 2000),
    );
  }
}
