import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  testWidgets(
    'rapid scrubbing displays and persists only the latest prepared destination',
    (tester) async {
      final worker = _SlowChapterWorker();
      final engine = EpubReaderEngine(workerFactory: () async => worker);
      final controller = ReaderController(
        registry: ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub},
            factory: () => engine,
          ),
        ]),
      );
      addTearDown(controller.dispose);
      final saved = <EpubReaderLocator>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PapyrusReader(
            controller: controller,
            document: ReaderDocument(
              id: 'scrub',
              format: ReaderFormat.epub,
              loadBytes: () async => syntheticEpub(
                firstChapterBody:
                    '<p>${List.filled(300, 'First').join(' ')}</p>',
                secondChapterBody:
                    '<p>${List.filled(300, 'Later').join(' ')}</p>',
              ),
            ),
            initialPreferences: const ReaderPreferences(
              pageTurnAnimation: false,
            ),
            onLocatorChanged: (locator) =>
                saved.add(locator as EpubReaderLocator),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      saved.clear();
      Slider slider() => tester.widget<Slider>(find.byType(Slider).first);
      slider().onChangeEnd!(.7);
      await tester.pump();
      expect(worker.blocked, isTrue);

      slider().onChangeStart!(.7);
      slider().onChanged!(.3);
      await tester.pumpAndSettle();
      expect(slider().value, .3);
      expect(engine.locator.spineIndex, 0);
      expect(saved, isEmpty);

      slider().onChangeEnd!(.3);
      slider().onChangeEnd!(1);
      await tester.pumpAndSettle();
      expect(worker.gate.isCompleted, isFalse);
      expect(controller.snapshot.contentReady, isTrue);
      expect(engine.locator.spineIndex, 2);
      expect(find.text('Chapter Three'), findsOneWidget);
      expect(saved, isNotEmpty);
      expect(saved.every((locator) => locator.spineIndex == 2), isTrue);
      final position = engine.locator;
      worker.gate.complete();
      await tester.pumpAndSettle();
      expect(engine.locator, position);
      expect(saved.every((locator) => locator.spineIndex == 2), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _SlowChapterWorker implements EpubWorker {
  final delegate = InProcessEpubWorker();
  final gate = Completer<void>();
  bool blocked = false;

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    if (command == 'chapter' && argument == 1) {
      blocked = true;
      await gate.future;
    }
    return delegate.request(command, argument);
  }

  @override
  void dispose() => delegate.dispose();
}
