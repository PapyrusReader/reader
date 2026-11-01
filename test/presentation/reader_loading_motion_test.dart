import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  testWidgets(
    'host loader stays consistent through opening and initial pagination',
    (tester) async {
      final gate = Completer<void>();
      final engine = testEpubEngine();
      final phases = <ReaderStatus>{};
      const loaderKey = ValueKey('host-loader');
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
              id: 'loading',
              format: ReaderFormat.epub,
              loadBytes: () async {
                await gate.future;
                return syntheticEpub(longChapter: true);
              },
            ),
            initialPreferences: const ReaderPreferences(
              brightness: Brightness.dark,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            builders: ReaderUiBuilders(
              loading: (context, state) {
                phases.add(state.snapshot.status);
                expect(Theme.of(context).brightness, Brightness.light);
                return const Center(
                  child: CircularProgressIndicator(key: loaderKey),
                );
              },
            ),
          ),
        ),
      );
      expect(find.byKey(loaderKey), findsOneWidget);
      final center = tester.getCenter(find.byKey(loaderKey));
      gate.complete();

      for (
        var frame = 0;
        frame < 100 && !engine.snapshot.contentReady;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('Preparing pages…'), findsNothing);
        if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.byKey(loaderKey), findsOneWidget);
          expect(tester.getCenter(find.byKey(loaderKey)), center);
        }
      }

      await tester.pumpAndSettle();
      expect(phases, containsAll([ReaderStatus.loading, ReaderStatus.ready]));
      expect(engine.snapshot.contentReady, isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('safe-area color stays with readable pages until a new load', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
    addTearDown(tester.view.resetPadding);
    final engines = <EpubReaderEngine>[];
    final controller = ReaderController(
      initialPreferences: const ReaderPreferences(
        brightness: Brightness.dark,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      registry: ReaderEngineRegistry([
        ReaderEngineRegistration(
          formats: const {ReaderFormat.epub},
          factory: () {
            final engine = testEpubEngine();
            engines.add(engine);
            return engine;
          },
        ),
      ]),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PapyrusReader(
          controller: controller,
          document: ReaderDocument(
            id: 'insets',
            format: ReaderFormat.epub,
            loadBytes: () async => syntheticEpub(longChapter: true),
          ),
        ),
      ),
    );

    Color? insetColor() => tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(PapyrusReader),
                matching: find.byType(Material),
              )
              .first,
        )
        .color;

    final hostColor = Theme.of(
      tester.element(find.byType(PapyrusReader)),
    ).colorScheme.surface;
    expect(insetColor(), hostColor);
    await tester.pumpAndSettle();
    final engine = engines.single;
    expect(engine.snapshot.contentReady, isTrue);
    expect(insetColor(), Colors.black);

    engine.viewportPreparing();
    expect(engine.snapshot.contentReady, isFalse);
    await tester.pump();
    expect(insetColor(), Colors.black);
    await tester.pumpAndSettle();

    await controller.updatePreferences(
      controller.preferences.copyWith(fontSize: 28),
    );
    expect(controller.snapshot.contentReady, isFalse);
    await tester.pump();
    expect(insetColor(), Colors.black);
    await tester.pumpAndSettle();

    var finished = false;
    final turn = controller
        .goTo(
          EpubReaderLocator(
            spineIndex: 1,
            localProgression: 0,
            totalProgression: .9,
          ),
        )
        .whenComplete(() => finished = true);
    for (var frame = 0; frame < 100 && !finished; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(insetColor(), Colors.black);
    }
    expect(finished, isTrue);
    await turn;
    await tester.pumpAndSettle();
    expect(engine.locator.spineIndex, 1);

    final gate = Completer<void>();
    final load = controller.load(
      ReaderDocument(
        id: 'replacement',
        format: ReaderFormat.epub,
        loadBytes: () async {
          await gate.future;
          return syntheticEpub(longChapter: true);
        },
      ),
    );
    await tester.pump();
    expect(insetColor(), hostColor);
    gate.complete();
    for (
      var frame = 0;
      frame < 100 && !controller.snapshot.contentReady;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
      if (!controller.snapshot.contentReady) {
        expect(insetColor(), hostColor);
      }
    }
    await load;
    await tester.pumpAndSettle();
    expect(controller.snapshot.contentReady, isTrue);
    expect(insetColor(), Colors.black);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading settings update animation without moving the page', (
    tester,
  ) async {
    final engine = testEpubEngine();
    final changes = <ReaderPreferences>[];
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
            id: 'settings',
            format: ReaderFormat.epub,
            loadBytes: () async => syntheticEpub(longChapter: true),
          ),
          onPreferencesChanged: changes.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await pumpReaderCommand(tester, engine.goNext());
    final location = engine.locator;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
    final animation = find.byType(DropdownButtonFormField<bool>);
    await tester.ensureVisible(animation);
    await tester.tap(animation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();
    expect(engine.preferences.pageTurnAnimation, isFalse);
    expect(changes.last.pageTurnAnimation, isFalse);
    expect(engine.locator, location);
    await tester.tap(animation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slide').last);
    await tester.pumpAndSettle();
    expect(engine.preferences.pageTurnAnimation, isTrue);
    expect(tester.takeException(), isNull);
  });
}
