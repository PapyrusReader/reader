import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_processor.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

import '../support/in_process_epub_worker.dart';

void main() {
  for (final name in ['alice', 'pride-and-prejudice']) {
    test(
      '$name indexes the full book and renders its SVG-wrapped cover',
      () async {
        final processor = EpubProcessor();
        final bytes = File(
          'test/fixtures/gutenberg/$name.epub',
        ).readAsBytesSync();
        final metadata = await processor.dispatch('open', bytes);
        final lengths = (metadata['lengths'] as List).cast<int>();
        expect(lengths.length, metadata['count']);
        expect(lengths.first, greaterThan(0));
        expect(lengths.first / lengths.reduce((a, b) => a + b), lessThan(.01));
        final cover = await processor.dispatch('chapter', 0);
        final blocks = cover['blocks'] as List;
        expect(blocks.single['kind'], 'image');
        expect(blocks.single['src'], startsWith('data:image/'));
        if (name == 'alice') {
          expect(blocks.single['aspect'], closeTo(800 / 1104, .001));
        }
        expect(cover['length'], lengths.first);
        for (final index in [1, lengths.length ~/ 2, lengths.length - 1]) {
          final chapter = await processor.dispatch('chapter', index);
          expect(chapter['length'], lengths[index]);
        }
      },
    );
  }

  test('native worker preserves content offsets across restart', () async {
    for (final name in ['alice', 'pride-and-prejudice']) {
      final bytes = File(
        'test/fixtures/gutenberg/$name.epub',
      ).readAsBytesSync();
      final document = ReaderDocument(
        id: name,
        format: ReaderFormat.epub,
        loadBytes: () async => bytes,
      );
      final engine = EpubReaderEngine();
      await engine.load(document, preferences: const ReaderPreferences());
      await engine.goToProgress(.55);
      final position = engine.locator;
      expect(position.totalProgression, closeTo(.55, .0001));
      engine.dispose();
      final reopened = EpubReaderEngine();
      await reopened.load(
        document,
        initialLocator: position,
        preferences: const ReaderPreferences(fontSize: 30),
      );
      expect(reopened.locator.textOffset, position.textOffset);
      expect(reopened.locator.totalProgression, position.totalProgression);
      reopened.dispose();
    }
  });

  testWidgets(
    'slow and failed chapter preparation retain the committed page and progress',
    (tester) async {
      final worker = _GatedWorker();
      final engine = EpubReaderEngine(workerFactory: () async => worker);
      final bytes = File(
        'test/fixtures/gutenberg/alice.epub',
      ).readAsBytesSync();
      await tester.pumpWidget(
        MaterialApp(
          home: PapyrusReader(
            document: ReaderDocument(
              id: 'slow-alice',
              format: ReaderFormat.epub,
              loadBytes: () async => bytes,
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
      final bounds = tester.getRect(
        find.byKey(const ValueKey('reader-content')),
      );
      final original = engine.snapshot.locator;
      await tester.tap(find.byTooltip('Next'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Preparing pages…'), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      expect(engine.snapshot.locator, original);
      worker.fail = true;
      worker.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      expect(engine.snapshot.locator, original);
      expect(
        tester.getRect(find.byKey(const ValueKey('reader-content'))),
        bounds,
      );
      worker.fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(engine.locator.spineIndex, 1);
      expect(find.text('Try again'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final name in ['alice', 'pride-and-prejudice']) {
    for (final size in [const Size(390, 844), const Size(1280, 850)]) {
      testWidgets('$name navigation and chrome remain stable at $size', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final engine = testEpubEngine();
        final bytes = File(
          Platform.environment['PAPYRUS_SQL_EPUB'] ??
              'test/fixtures/gutenberg/$name.epub',
        ).readAsBytesSync();
        await tester.pumpWidget(
          MaterialApp(
            home: PapyrusReader(
              document: ReaderDocument(
                id: 'alice',
                format: ReaderFormat.epub,
                loadBytes: () async => bytes,
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
        expect(engine.blocks.single.image, isNotNull);
        expect(engine.locator.totalProgression, 0);
        final content = find.byKey(const ValueKey('reader-content'));
        final bounds = tester.getRect(content);
        final label = tester.getRect(find.text(engine.snapshot.locationLabel!));
        final slider = tester.getRect(find.byType(Slider));
        expect(slider.center.dy - label.bottom, 11);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('reader-progress-controls')))
              .width,
          size.width > 1000 ? 1000 : size.width,
        );
        await tester.tap(find.byTooltip('Next'));
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.text('Preparing pages…'), findsNothing);
          expect(find.byType(PageView), findsOneWidget);
        }
        await tester.pumpAndSettle();
        expect(engine.locator.spineIndex, 1);
        expect(engine.locator.totalProgression, lessThan(.01));
        await tester.tap(find.byTooltip('Previous'));
        await tester.pumpAndSettle();
        expect(engine.locator.spineIndex, 0);
        expect(engine.locator.localProgression, 0);
        expect(engine.locator.totalProgression, 0);
        expect(find.text('0%'), findsOneWidget);
        await tester.tapAt(bounds.center);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(tester.getRect(content), bounds);
        expect(find.byTooltip('Show controls'), findsNothing);
        expect(find.byTooltip('Reading settings'), findsNothing);
        await tester.tapAt(bounds.center);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Table of contents'));
        await tester.pumpAndSettle();
        expect(tester.getRect(content), bounds);
        expect(find.text('Preparing pages…'), findsNothing);
        if (size.width > 900) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        }
        await tester.pumpAndSettle();
        expect(engine.locator.totalProgression, 0);
        if (size.width < 900) {
          await tester.tapAt(bounds.center);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Reading settings'), findsNothing);
          await tester.tapAt(bounds.center);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Reading settings'), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Next'));
        await tester.tap(find.byTooltip('Next'));
        await tester.tap(find.byTooltip('Previous'));
        await tester.pumpAndSettle();
        expect(engine.locator.spineIndex, 1);
        await pumpReaderCommand(tester, engine.goToProgress(1));
        expect(engine.locator.totalProgression, 1);
        await pumpReaderCommand(tester, engine.goToProgress(.55));
        final position = engine.locator;
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller;
        await engine.updatePreferences(
          engine.preferences.copyWith(backgroundColor: Colors.black),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<PageView>(find.byType(PageView)).controller,
          same(controller),
        );
        expect(engine.snapshot.contentReady, isTrue);
        expect(engine.locator.textOffset, position.textOffset);
        await pumpReaderCommand(
          tester,
          engine.updatePreferences(engine.preferences.copyWith(fontSize: 24)),
        );
        expect(engine.locator.textOffset, position.textOffset);
        tester.view.physicalSize = Size(size.height, size.width);
        await tester.pumpAndSettle();
        expect(engine.locator.textOffset, position.textOffset);
        await pumpReaderCommand(
          tester,
          engine.updatePreferences(
            engine.preferences.copyWith(layoutMode: ReaderLayoutMode.scroll),
          ),
        );
        final scroll = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        expect(scroll.initialScrollOffset, closeTo(scroll.offset, 1));
        await pumpReaderCommand(tester, engine.goToProgress(.8));
        final sought = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        expect(sought.initialScrollOffset, closeTo(sought.offset, 1));
        await pumpReaderCommand(tester, engine.goToProgress(0));
        expect(engine.locator.totalProgression, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

final class _GatedWorker implements EpubWorker {
  final delegate = InProcessEpubWorker();
  final gate = Completer<void>();
  bool fail = false;

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    if (command == 'chapter' && argument == 1) {
      await gate.future;
      if (fail) {
        throw const ReaderException(
          ReaderErrorCode.invalidDocument,
          'Chapter unavailable',
        );
      }
    }
    return delegate.request(command, argument);
  }

  @override
  void dispose() => delegate.dispose();
}
