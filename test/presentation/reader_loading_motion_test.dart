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
    final toggle = find.widgetWithText(SwitchListTile, 'Page turn animation');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(engine.preferences.pageTurnAnimation, isFalse);
    expect(changes.last.pageTurnAnimation, isFalse);
    expect(engine.locator, location);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(engine.preferences.pageTurnAnimation, isTrue);
    expect(tester.takeException(), isNull);
  });
}
