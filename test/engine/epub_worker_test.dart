import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_content.dart';

import '../support/synthetic_epub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('named XHTML anchors do not underline the surrounding book text', () {
    final content = collectEpubContent('<a id="chapter"/><p>Book text</p>');
    final block = (content['blocks'] as List).single as Map;
    expect((block['runs'] as List).single['underline'], isNot(true));
    expect((content['anchors'] as Map)['chapter'], 0);
    final link = collectEpubContent('<p><a href="#chapter">A link</a></p>');
    expect(
      ((link['blocks'] as List).single['runs'] as List).single['underline'],
      isTrue,
    );
  });
  Future<List<String>> listText(String html) async {
    final worker = await createEpubWorker();
    addTearDown(worker.dispose);
    await worker.open(syntheticEpub(firstChapterBody: html));
    final chapter = await worker.chapter(0);
    return (chapter['blocks'] as List)
        .map(
          (block) => (block['runs'] as List)
              .map((run) => run['text'] as String)
              .join(),
        )
        .toList();
  }

  test('native worker preserves ordered list start and item values', () async {
    expect(
      await listText('''
<ol start="3"><li>Alpha</li><li value="8"><strong>Beta</strong></li><li>Gamma</li></ol>
<ul><li value="4">Unordered</li><li>Another bullet</li></ul>
'''),
      ['3. Alpha', '8. Beta', '9. Gamma', '• Unordered', '• Another bullet'],
    );
  });

  test(
    'native worker keeps nested and separate list counters independent',
    () async {
      expect(
        await listText('''
<ol start="7"><li>Outer<ul><li>Bullet<ol><li>Inner</li><li>Inner next</li></ol></li></ul></li><li>Outer next</li></ol>
<ol><li>New list</li></ol>
'''),
        [
          '7. Outer',
          '• Bullet',
          '1. Inner',
          '2. Inner next',
          '8. Outer next',
          '1. New list',
        ],
      );
    },
  );

  test('native worker preserves reversed and invalid list numbering', () async {
    expect(
      await listText('''
<ol reversed><li>First</li><li value="5">Reset</li><li>Last</li></ol>
<ol reversed start="-1"><li>Negative</li><li>Negative next</li></ol>
<ol start="invalid"><li value="invalid">Fallback</li><li>Fallback next</li></ol>
'''),
      [
        '3. First',
        '5. Reset',
        '4. Last',
        '-1. Negative',
        '-2. Negative next',
        '1. Fallback',
        '2. Fallback next',
      ],
    );
  });

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
