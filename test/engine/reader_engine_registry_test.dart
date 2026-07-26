import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/fake_reader_engine.dart';

void main() {
  group('ReaderEngineRegistry', () {
    test('resolves the engine registered for a format', () {
      final epubEngine = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );
      final pdfEngine = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.pdf},
      );
      final registry = ReaderEngineRegistry([
        ReaderEngineRegistration(
          formats: const {ReaderFormat.epub},
          factory: () => epubEngine,
        ),
        ReaderEngineRegistration(
          formats: const {ReaderFormat.pdf},
          factory: () => pdfEngine,
        ),
      ]);

      expect(registry.resolve(ReaderFormat.epub), same(epubEngine));
      expect(registry.resolve(ReaderFormat.pdf), same(pdfEngine));
    });

    test('rejects duplicate format registrations', () {
      final first = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );
      final second = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );

      expect(
        () => ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub},
            factory: () => first,
          ),
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub},
            factory: () => second,
          ),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('epub'),
          ),
        ),
      );
    });

    test('reports a stable error when no engine supports a format', () {
      final registry = ReaderEngineRegistry(const []);

      expect(
        () => registry.resolve(ReaderFormat.pdf),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.engineUnavailable,
          ),
        ),
      );
    });

    test('default registry provides EPUB and PDF engines', () {
      final registry = ReaderEngineRegistry.defaults();

      expect(registry.resolve(ReaderFormat.epub), isA<EpubReaderEngine>());
      expect(registry.resolve(ReaderFormat.pdf), isA<PdfReaderEngine>());
    });

    test('each resolution creates an independent engine', () {
      final registry = ReaderEngineRegistry.defaults();

      final first = registry.resolve(ReaderFormat.epub);
      final second = registry.resolve(ReaderFormat.epub);

      expect(second, isNot(same(first)));
    });
  });
}
