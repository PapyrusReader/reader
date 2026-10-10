import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_processor.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

/// Deterministic transport for Flutter's fake clock. Production transports are
/// exercised independently so widget tests need no real isolate scheduling.
EpubReaderEngine testEpubEngine({EpubPaginator? paginator}) {
  final engine = EpubReaderEngine(
    paginator: paginator,
    workerFactory: () async => InProcessEpubWorker(),
  );
  addTearDown(engine.dispose);
  return engine;
}

final class InProcessEpubWorker implements EpubWorker {
  final EpubProcessor _processor = EpubProcessor();
  bool disposed = false;
  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    final response = await processEpubMessage(_processor, {
      'id': 1,
      'command': command,
      'argument': argument,
    });
    if (response['error'] != null) {
      throw ReaderException(
        response['error'] == 'unsupportedFixedLayout'
            ? ReaderErrorCode.unsupportedFixedLayout
            : ReaderErrorCode.invalidDocument,
        response['message'] as String,
      );
    }
    return Map<String, Object?>.from(response['result'] as Map);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

Future<void> pumpReaderCommand(
  WidgetTester tester,
  Future<void> command,
) async {
  var finished = false;
  Object? failure;
  command.then(
    (_) => finished = true,
    onError: (Object error) {
      failure = error;
      finished = true;
    },
  );
  for (var frame = 0; !finished && frame < 1000; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finished, isTrue, reason: 'Reader command did not complete');
  if (failure != null) {
    throw failure!;
  }
  await tester.pumpAndSettle();
}
