import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  for (final blocked in [0, 2]) {
    testWidgets(
      'a slow neighbor $blocked does not block preloading the other direction',
      (tester) async {
        final worker = _GatedNeighbor(blocked);
        final engine = EpubReaderEngine(workerFactory: () async => worker);
        addTearDown(engine.dispose);
        await engine.load(
          ReaderDocument(
            id: 'neighbors',
            format: ReaderFormat.epub,
            loadBytes: () async => syntheticEpub(),
          ),
          initialLocator: EpubReaderLocator(
            spineIndex: 1,
            localProgression: 0,
            totalProgression: .5,
          ),
          preferences: const ReaderPreferences(pageTurnAnimation: false),
        );
        await tester.pumpWidget(
          MaterialApp(home: Builder(builder: engine.buildViewport)),
        );
        await tester.pumpAndSettle();
        expect(worker.reads[0], 1);
        expect(worker.reads[2], 1);
        expect(engine.locator.spineIndex, 1);
        final destination = blocked == 0 ? 2 : 0;
        await pumpReaderCommand(
          tester,
          blocked == 0 ? engine.goNext() : engine.goPrevious(),
        );
        expect(engine.locator.spineIndex, destination);
        expect(
          worker.reads[destination],
          1,
          reason: 'Use the already prepared neighbor',
        );
        worker.gate.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'keeps five forward turns ready and retains pages for reversing direction',
    (tester) async {
      final engine = testEpubEngine();
      await engine.load(
        ReaderDocument(
          id: 'buffered',
          format: ReaderFormat.epub,
          loadBytes: () async => syntheticEpub(
            singleSpine: true,
            firstChapterBody: List.filled(
              1000,
              '<p>A long uninterrupted book keeps nearby pages ready.</p>',
            ).join(),
          ),
        ),
        preferences: const ReaderPreferences(pageTurnAnimation: false),
      );
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: engine.buildViewport)),
      );
      await tester.pumpAndSettle();
      final view = tester.widget<PageView>(find.byType(PageView));
      expect(
        view.childrenDelegate.estimatedChildCount,
        greaterThanOrEqualTo(6),
      );
      expect(
        view.childrenDelegate.estimatedChildCount,
        lessThan(12),
        reason: 'Do not paginate the whole book to turn',
      );
      final start = engine.locator.textOffset;
      for (var page = 1; page <= 5; page++) {
        final turn = engine.goNext();
        await tester.pump();
        expect(view.controller!.page, page);
        await turn;
      }
      for (var page = 4; page >= 0; page--) {
        final turn = engine.goPrevious();
        await tester.pump();
        expect(view.controller!.page, page);
        await turn;
      }
      expect(engine.locator.textOffset, start);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

final class _GatedNeighbor implements EpubWorker {
  _GatedNeighbor(this.blocked);
  final int blocked;
  final delegate = InProcessEpubWorker();
  final gate = Completer<void>();
  final reads = <int, int>{};

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    if (command == 'chapter') {
      final index = argument as int;
      reads.update(index, (count) => count + 1, ifAbsent: () => 1);
      if (index == blocked) await gate.future;
    }
    return delegate.request(command, argument);
  }

  @override
  void dispose() => delegate.dispose();
}
