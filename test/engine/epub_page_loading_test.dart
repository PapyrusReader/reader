import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

import '../support/in_process_epub_worker.dart';
import '../support/synthetic_epub.dart';

void main() {
  test(
    'navigation shares an in-flight prefetch and reuses the initial content',
    () async {
      final worker = _GatedWorker();
      final engine = EpubReaderEngine(workerFactory: () async => worker);
      addTearDown(engine.dispose);
      await engine.load(
        ReaderDocument(
          id: 'shared',
          format: ReaderFormat.epub,
          loadBytes: () async => syntheticEpub(),
        ),
        preferences: const ReaderPreferences(),
      );
      await engine.chapterContent(0);
      expect(worker.reads[0], 1);

      final prefetch = engine.chapterContent(1);
      final turn = engine.goNext();
      await Future<void>.delayed(Duration.zero);
      expect(worker.reads[1], 1);
      expect(engine.locator.spineIndex, 0);
      worker.gate.complete();
      await Future.wait([prefetch, turn]);
      expect(engine.locator.spineIndex, 1);
      expect(worker.reads[1], 1);
    },
  );
}

final class _GatedWorker implements EpubWorker {
  final delegate = InProcessEpubWorker();
  final gate = Completer<void>();
  final reads = <int, int>{};

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    if (command == 'chapter') {
      final index = argument as int;
      reads.update(index, (count) => count + 1, ifAbsent: () => 1);
      if (index == 1) await gate.future;
    }
    return delegate.request(command, argument);
  }

  @override
  void dispose() => delegate.dispose();
}
