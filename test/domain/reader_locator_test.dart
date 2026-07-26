import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  group('ReaderLocator', () {
    test('round trips an EPUB locator through versioned JSON', () {
      final locator = EpubReaderLocator(
        cfi: 'epubcfi(/6/4!/4/2/1:0)',
        spineIndex: 1,
        localProgression: 0.25,
        totalProgression: 0.4,
      );

      final decoded = ReaderLocator.fromJson(locator.toJson());

      expect(decoded, locator);
      expect(decoded.toJson(), {
        'version': 1,
        'type': 'epub',
        'cfi': 'epubcfi(/6/4!/4/2/1:0)',
        'spineIndex': 1,
        'localProgression': 0.25,
        'totalProgression': 0.4,
      });
    });

    test('round trips a PDF locator through versioned JSON', () {
      final locator = PdfReaderLocator(
        pageIndex: 7,
        pageOffset: 0.2,
        totalProgression: 0.75,
      );

      final decoded = ReaderLocator.fromJson(locator.toJson());

      expect(decoded, locator);
      expect(decoded.toJson(), {
        'version': 1,
        'type': 'pdf',
        'pageIndex': 7,
        'pageOffset': 0.2,
        'totalProgression': 0.75,
      });
    });

    test('rejects unsupported locator versions', () {
      expect(
        () => ReaderLocator.fromJson({
          'version': 2,
          'type': 'pdf',
          'pageIndex': 0,
          'pageOffset': 0.0,
          'totalProgression': 0.0,
        }),
        throwsFormatException,
      );
    });

    test('rejects unsupported locator types', () {
      expect(
        () => ReaderLocator.fromJson({'version': 1, 'type': 'audio'}),
        throwsFormatException,
      );
    });
  });

  group('EpubReaderLocator construction', () {
    test('rejects an empty CFI', () {
      expect(
        () => EpubReaderLocator(
          cfi: '',
          spineIndex: 0,
          localProgression: 0,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a negative spine index', () {
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: -1,
          localProgression: 0,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects non-finite local progression', () {
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: double.nan,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects local progression outside zero and one', () {
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: -0.01,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: 1.01,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects non-finite total progression', () {
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: 0,
          totalProgression: double.infinity,
        ),
        throwsArgumentError,
      );
    });

    test('rejects total progression outside zero and one', () {
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: 0,
          totalProgression: -0.01,
        ),
        throwsArgumentError,
      );
      expect(
        () => EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: 0,
          totalProgression: 1.01,
        ),
        throwsArgumentError,
      );
    });
  });

  group('EpubReaderLocator JSON', () {
    Map<String, Object?> validJson() => {
      'version': 1,
      'type': 'epub',
      'cfi': 'epubcfi(/6/2)',
      'spineIndex': 0,
      'localProgression': 0.25,
      'totalProgression': 0.5,
    };

    test('rejects an empty CFI', () {
      expect(
        () => ReaderLocator.fromJson(validJson()..['cfi'] = ''),
        throwsFormatException,
      );
    });

    test('rejects a negative spine index', () {
      expect(
        () => ReaderLocator.fromJson(validJson()..['spineIndex'] = -1),
        throwsFormatException,
      );
    });

    test('rejects invalid local progression independently', () {
      expect(
        () => ReaderLocator.fromJson(
          validJson()..['localProgression'] = double.nan,
        ),
        throwsFormatException,
      );
      expect(
        () => ReaderLocator.fromJson(validJson()..['localProgression'] = 1.01),
        throwsFormatException,
      );
    });

    test('rejects invalid total progression independently', () {
      expect(
        () => ReaderLocator.fromJson(
          validJson()..['totalProgression'] = double.infinity,
        ),
        throwsFormatException,
      );
      expect(
        () => ReaderLocator.fromJson(validJson()..['totalProgression'] = -0.01),
        throwsFormatException,
      );
    });
  });

  group('PdfReaderLocator construction', () {
    test('rejects a negative page index', () {
      expect(
        () =>
            PdfReaderLocator(pageIndex: -1, pageOffset: 0, totalProgression: 0),
        throwsArgumentError,
      );
    });

    test('rejects non-finite page offset', () {
      expect(
        () => PdfReaderLocator(
          pageIndex: 0,
          pageOffset: double.negativeInfinity,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects page offset outside zero and one', () {
      expect(
        () => PdfReaderLocator(
          pageIndex: 0,
          pageOffset: -0.01,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => PdfReaderLocator(
          pageIndex: 0,
          pageOffset: 1.01,
          totalProgression: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects non-finite total progression', () {
      expect(
        () => PdfReaderLocator(
          pageIndex: 0,
          pageOffset: 0,
          totalProgression: double.nan,
        ),
        throwsArgumentError,
      );
    });

    test('rejects total progression outside zero and one', () {
      expect(
        () => PdfReaderLocator(
          pageIndex: 0,
          pageOffset: 0,
          totalProgression: -0.01,
        ),
        throwsArgumentError,
      );
      expect(
        () => PdfReaderLocator(
          pageIndex: 0,
          pageOffset: 0,
          totalProgression: 1.01,
        ),
        throwsArgumentError,
      );
    });
  });

  group('PdfReaderLocator JSON', () {
    Map<String, Object?> validJson() => {
      'version': 1,
      'type': 'pdf',
      'pageIndex': 0,
      'pageOffset': 0.25,
      'totalProgression': 0.5,
    };

    test('rejects a negative page index', () {
      expect(
        () => ReaderLocator.fromJson(validJson()..['pageIndex'] = -1),
        throwsFormatException,
      );
    });

    test('rejects invalid page offset independently', () {
      expect(
        () => ReaderLocator.fromJson(validJson()..['pageOffset'] = double.nan),
        throwsFormatException,
      );
      expect(
        () => ReaderLocator.fromJson(validJson()..['pageOffset'] = 1.01),
        throwsFormatException,
      );
    });

    test('rejects invalid total progression independently', () {
      expect(
        () => ReaderLocator.fromJson(
          validJson()..['totalProgression'] = double.infinity,
        ),
        throwsFormatException,
      );
      expect(
        () => ReaderLocator.fromJson(validJson()..['totalProgression'] = -0.01),
        throwsFormatException,
      );
    });
  });
}
