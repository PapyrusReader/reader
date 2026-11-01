import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  for (final lateError in [false, true]) {
    test(
      'latest seek does not wait for an obsolete chapter read, late error $lateError',
      () async {
        final worker = _SeekWorker();
        final engine = EpubReaderEngine(workerFactory: () async => worker);
        addTearDown(engine.dispose);
        await engine.load(_document(), preferences: const ReaderPreferences());
        final visited = <int>[];
        engine.addListener(() => visited.add(engine.locator.spineIndex));
        final old = engine.goToProgress(.7);
        await worker.started.future;
        final latest = engine.goToProgress(1);
        await Future.wait([old, latest]).timeout(const Duration(seconds: 2));
        expect(engine.locator.spineIndex, 2);
        expect(visited, isNot(contains(1)));
        if (lateError) {
          worker.gate.completeError(StateError('Obsolete chapter read failed'));
        } else {
          worker.gate.complete();
        }
        await Future<void>.delayed(Duration.zero);
        expect(engine.locator.spineIndex, 2);
        expect(visited, isNot(contains(1)));
      },
    );
  }

  test(
    'superseding a seek cancels its layout demand without waiting for it',
    () async {
      final engine = EpubReaderEngine(
        workerFactory: () async => InProcessEpubWorker(),
      );
      addTearDown(engine.dispose);
      await engine.load(_document(), preferences: const ReaderPreferences());
      final started = Completer<void>();
      final gate = Completer<void>();
      late bool Function() cancelled;
      engine.prepareLocation = (target, blocks, isCancelled) async {
        if (target.spineIndex == 1) {
          cancelled = isCancelled;
          started.complete();
          await gate.future;
        }
      };
      final old = engine.goToProgress(.7);
      await started.future;
      final latest = engine.goToProgress(1);
      await Future.wait([old, latest]).timeout(const Duration(seconds: 2));
      expect(cancelled(), isTrue);
      expect(engine.locator.spineIndex, 2);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(engine.locator.spineIndex, 2);
    },
  );
}

ReaderDocument _document() => ReaderDocument(
  id: 'seeking',
  format: ReaderFormat.epub,
  loadBytes: () async => syntheticEpub(
    firstChapterBody: '<p>${List.filled(300, 'First').join(' ')}</p>',
    secondChapterBody: '<p>${List.filled(300, 'Later').join(' ')}</p>',
  ),
);

final class _SeekWorker implements EpubWorker {
  final delegate = InProcessEpubWorker();
  final started = Completer<void>();
  final gate = Completer<void>();

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    if (command == 'chapter' && argument == 1) {
      if (!started.isCompleted) started.complete();
      await gate.future;
    }
    return delegate.request(command, argument);
  }

  @override
  void dispose() => delegate.dispose();
}
