import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:archive/archive.dart' show ZLibEncoder;
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializePdfiumForTest);

  test('KF8 HTML containing an SVG cover stays the primary HTML flow', () {
    for (final html in [
      '<html><body><svg xmlns="http://www.w3.org/2000/svg"></svg></body></html>',
      '<?xml version="1.0"?><html><body><svg/></body></html>',
      '<body><svg/></body>',
    ]) {
      final bytes = Uint8List.fromList(utf8.encode(html));
      final flows = BookFlows.split(
        bytes,
        FdstTable(entries: [FdstEntry(start: 0, end: bytes.length)]),
      );
      expect(flows.primaryHtml?.bytes, bytes);
    }

    final svg = Uint8List.fromList(utf8.encode('<?xml version="1.0"?><svg/>'));
    final flows = BookFlows.split(
      svg,
      FdstTable(entries: [FdstEntry(start: 0, end: svg.length)]),
    );
    expect(flows.flows.single.kind, FlowKind.svg);
  });

  for (final format in [
    ReaderFormat.txt,
    ReaderFormat.mobi,
    ReaderFormat.azw3,
  ]) {
    test(
      '$format opens real text, navigates and restores a serialized position',
      () async {
        final bytes = format == ReaderFormat.txt
            ? utf8.encode(
                List.filled(
                  3000,
                  'Alice read the book. Ελληνικά 日本語 🐇\n\n',
                ).join(),
              )
            : await File(
                'test/fixtures/gutenberg/alice.${format.name}',
              ).readAsBytes();
        final document = ReaderDocument(
          id: format.name,
          format: format,
          loadBytes: () async => bytes,
        );
        final engine =
            ReaderEngineRegistry.defaults().resolve(format) as EpubReaderEngine;
        addTearDown(engine.dispose);
        var ticks = 0;
        final heartbeat = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => ticks++,
        );
        await engine.load(document, preferences: const ReaderPreferences());
        heartbeat.cancel();
        expect(
          ticks,
          greaterThan(0),
          reason: 'Opening must allow the host event loop to advance',
        );
        expect(engine.contentLength, greaterThan(0));
        await engine.goToProgress(.5);
        expect(engine.currentChapterHtml, contains('Alice'));
        final locator = ReaderLocator.fromJson(
          (await engine.currentLocator())!.toJson(),
        );
        final reopened =
            ReaderEngineRegistry.defaults().resolve(format) as EpubReaderEngine;
        addTearDown(reopened.dispose);
        await reopened.load(
          document,
          initialLocator: locator,
          preferences: const ReaderPreferences(),
        );
        expect(await reopened.currentLocator(), locator);
        expect(reopened.currentChapterHtml, engine.currentChapterHtml);
        await reopened.goToProgress(1);
        expect(reopened.contentLength, greaterThan(0));
      },
    );
  }

  for (final fixture in [
    'pages.cbz',
    'pages-rar4.cbr',
    'pages-rar4-compressed.cbr',
    'pages-rar5.cbr',
  ]) {
    test(
      '$fixture decodes real pages in natural order and opens in PDFium',
      () async {
        final worker = await createEpubWorker();
        addTearDown(worker.dispose);
        final bytes = await File('test/fixtures/comics/$fixture').readAsBytes();
        var ticks = 0;
        final heartbeat = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => ticks++,
        );
        final converted = await worker.request(
          fixture.endsWith('cbz') ? 'prepare_cbz' : 'prepare_cbr',
          bytes,
        );
        heartbeat.cancel();
        expect(ticks, greaterThan(0));
        final pdf = await PdfDocument.openData(converted['bytes'] as Uint8List);
        addTearDown(pdf.dispose);
        expect(pdf.pages, hasLength(3));

        for (var index = 0; index < 3; index++) {
          final page = pdf.pages[index];
          expect(page.width, 320);
          expect(page.height, 480);
          final rendered = await page.render(width: 32, height: 48);
          expect(rendered, isNotNull);
          final pixel = rendered!.pixels.sublist(0, 4);
          // PDFium pixels are BGRA: red, green, blue prove natural page order.
          expect(pixel[2 - index], greaterThan(150));
          expect(pixel[2 - ((index + 1) % 3)], lessThan(30));
          rendered.dispose();
        }

        final engine = ReaderEngineRegistry.defaults().resolve(
          fixture.endsWith('cbz') ? ReaderFormat.cbz : ReaderFormat.cbr,
        );
        addTearDown(engine.dispose);
        final location = PdfReaderLocator(
          pageIndex: 1,
          pageOffset: .2,
          totalProgression: .5,
        );
        await engine.load(
          ReaderDocument(
            id: fixture,
            format: fixture.endsWith('cbz')
                ? ReaderFormat.cbz
                : ReaderFormat.cbr,
            loadBytes: () async => bytes,
          ),
          initialLocator: ReaderLocator.fromJson(location.toJson()),
          preferences: const ReaderPreferences(),
        );
        expect(await engine.currentLocator(), location);
        await engine.goNext();
        expect(
          (await engine.currentLocator() as PdfReaderLocator).pageIndex,
          2,
        );
        await engine.goPrevious();
        expect(
          (await engine.currentLocator() as PdfReaderLocator).pageIndex,
          1,
        );
      },
    );
  }

  test(
    'text decoding preserves UTF-16 and Windows-1252 without interpreting markup',
    () async {
      final worker = await createEpubWorker();
      addTearDown(worker.dispose);
      const text = '日本語 🐇 <script>literal text</script>';
      final bytes = ByteData(2 + text.length * 2)
        ..setUint16(0, 0xfeff, Endian.little);

      for (var index = 0; index < text.length; index++) {
        bytes.setUint16(2 + index * 2, text.codeUnitAt(index), Endian.little);
      }

      await worker.request('open_txt', bytes.buffer.asUint8List());
      var chapter = await worker.chapter(0);
      expect(
        chapter['html'],
        contains('&lt;script&gt;literal text&lt;/script&gt;'),
      );
      expect(chapter['html'], contains('日本語 🐇'));
      await worker.request(
        'open_txt',
        Uint8List.fromList([0x93, 0x41, 0x94, 0x20, 0x80]),
      );
      chapter = await worker.chapter(0);
      expect(chapter['html'], contains('“A” €'));
    },
  );

  test('Kindle embedded font inflation uses the portable decoder', () {
    final font = Uint8List.fromList([0, 1, 0, 0, ...List.filled(128, 42)]);
    final compressed = ZLibEncoder().encodeBytes(font);
    final record = Uint8List(24 + compressed.length);
    record.setRange(0, 4, 'FONT'.codeUnits);
    final header = ByteData.sublistView(record);
    header.setUint32(4, font.length);
    header.setUint32(8, 1);
    header.setUint32(12, 24);
    record.setRange(24, record.length, compressed);
    expect(FontResource.parse(record).payload, font);
  });

  for (final pointsAtSentinel in [true, false]) {
    test(
      'dual MOBI/KF8 uses relative section records, sentinel=$pointsAtSentinel',
      () async {
        final legacy = await File(
          'test/fixtures/gutenberg/alice.mobi',
        ).readAsBytes();
        final modern = await File(
          'test/fixtures/gutenberg/alice.azw3',
        ).readAsBytes();
        final bytes = _dualKindle(
          legacy,
          modern,
          pointsAtSentinel: pointsAtSentinel,
        );
        final book = KindleBook.fromBytes(bytes);
        expect(book.format, KindleFormat.combo);
        expect(book.parts.length, greaterThan(10));
        expect(utf8.decode(book.rawML), contains('Alice'));
        final worker = await createEpubWorker();
        addTearDown(worker.dispose);
        final metadata = await worker.request('open_mobi', bytes);
        expect(metadata['count'], 19);
        final cover = await worker.chapter(0);
        expect(
          (cover['blocks'] as List).where((block) => block['kind'] == 'image'),
          isNotEmpty,
        );
      },
    );
  }

  test('encrypted Kindle files report a specific error', () async {
    final bytes = await File(
      'test/fixtures/gutenberg/alice.mobi',
    ).readAsBytes();
    final header = ByteData.sublistView(bytes);
    header.setUint16(header.getUint32(78) + 12, 2);
    final worker = await createEpubWorker();
    addTearDown(worker.dispose);
    await expectLater(
      worker.request('open_mobi', bytes),
      throwsA(
        isA<ReaderException>().having(
          (error) => error.code,
          'code',
          ReaderErrorCode.encryptedDocument,
        ),
      ),
    );
  });

  test('PDF opening leaves the host event loop running', () async {
    final engine = PdfReaderEngine();
    addTearDown(engine.dispose);
    final bytes = await File('example/assets/a_tiny_pdf.pdf').readAsBytes();
    var ticks = 0;
    final heartbeat = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    await engine.load(
      ReaderDocument(
        id: 'pdf',
        format: ReaderFormat.pdf,
        loadBytes: () async => bytes,
      ),
      preferences: const ReaderPreferences(),
    );
    heartbeat.cancel();
    expect(ticks, greaterThan(0));
    expect(engine.snapshot.status, ReaderStatus.ready);
  });

  test(
    'worker rejects empty comics, malformed Kindle books and empty text',
    () async {
      for (final command in [
        'prepare_cbz',
        'prepare_cbr',
        'open_mobi',
        'open_azw3',
        'open_txt',
      ]) {
        final worker = await createEpubWorker();
        addTearDown(worker.dispose);
        await expectLater(
          worker.request(command, Uint8List(0)),
          throwsA(isA<ReaderException>()),
        );
      }
    },
  );

  test('closing the worker cancels in-flight format decoding', () async {
    final worker = await createEpubWorker();
    final opening = worker.request(
      'open_txt',
      utf8.encode(List.filled(100000, 'Long text\n\n').join()),
    );
    final expectation = expectLater(opening, throwsA(isA<ReaderException>()));
    worker.dispose();
    await expectation;
  });
}

// Combine the independent real editions without changing their text records.
// This deliberately tests section-relative record indices and shared images.
Uint8List _dualKindle(
  Uint8List legacy,
  Uint8List modern, {
  required bool pointsAtSentinel,
}) {
  final first = PdbFile.parse(legacy);
  final second = PdbFile.parse(modern);
  final original = first.records.first.data;
  final originalHeader = ByteData.sublistView(original);
  final exth = 16 + originalHeader.getUint32(20);
  final count = originalHeader.getUint32(exth + 8);
  var insertAt = exth + 12;

  for (var index = 0; index < count; index++) {
    insertAt += originalHeader.getUint32(insertAt + 4);
  }

  final record = Uint8List(original.length + 12);
  record.setRange(0, insertAt, original);
  record.setRange(insertAt + 12, record.length, original, insertAt);
  final header = ByteData.sublistView(record);
  header.setUint32(insertAt, 121);
  header.setUint32(insertAt + 4, 12);
  header.setUint32(
    insertAt + 8,
    first.records.length + (pointsAtSentinel ? 0 : 1),
  );
  header.setUint32(exth + 4, originalHeader.getUint32(exth + 4) + 12);
  header.setUint32(exth + 8, count + 1);
  header.setUint32(84, originalHeader.getUint32(84) + 12);
  final records = [
    record,
    ...first.records.skip(1).map((record) => record.data),
    utf8.encode('BOUNDARY'),
    ...second.records.map((record) => record.data),
  ];
  final table = Uint8List(78 + records.length * 8 + 2)..setRange(0, 78, legacy);
  final offsets = ByteData.sublistView(table)..setUint16(76, records.length);
  var offset = table.length;

  for (var index = 0; index < records.length; index++) {
    offsets.setUint32(78 + index * 8, offset);
    offset += records[index].length;
  }

  return (BytesBuilder(copy: false)
        ..add(table)
        ..add(records.expand((record) => record).toList()))
      .takeBytes();
}
