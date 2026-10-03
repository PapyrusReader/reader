import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

import '../support/synthetic_epub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native document worker opens and prepares chapters independently',
    () async {
      final worker = await createEpubWorker();
      addTearDown(worker.dispose);
      final metadata = await worker.open(syntheticEpub());
      expect(metadata['count'], 3);
      final first = await worker.chapter(0);
      expect(first['html'], contains('Chapter One'));
      expect(first['blocks'], isNotEmpty);
      final second = await worker.chapter(1);
      expect(second['html'], contains('Chapter Two'));
      expect(await worker.chapter(0), first);
    },
  );

  test(
    'native worker errors stay typed and disposal rejects requests',
    () async {
      final worker = await createEpubWorker();
      await expectLater(
        worker.open(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<ReaderException>().having(
            (e) => e.code,
            'code',
            ReaderErrorCode.invalidDocument,
          ),
        ),
      );
      await expectLater(
        worker.open(syntheticEpub(fixedLayout: true)),
        throwsA(
          isA<ReaderException>().having(
            (e) => e.code,
            'code',
            ReaderErrorCode.unsupportedFixedLayout,
          ),
        ),
      );
      worker.dispose();
      await expectLater(worker.chapter(0), throwsA(isA<ReaderException>()));
    },
  );
}
