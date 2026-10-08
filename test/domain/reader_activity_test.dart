import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  final epub = EpubReaderLocator(
    cfi: 'epubcfi(/6/2)',
    spineIndex: 0,
    localProgression: .5,
    totalProgression: .25,
    textOffset: 50,
  );
  final pdf = PdfReaderLocator(
    pageIndex: 2,
    pageOffset: .1,
    totalProgression: .4,
  );
  for (final locator in [epub, pdf]) {
    test(
      'activity round-trips version 1 ${locator.runtimeType} locators and coverage',
      () {
        final source = <ReaderContentCoverage>[
          if (locator is EpubReaderLocator)
            const ReaderContentCoverage(
              key: 'chapter:0',
              start: .25,
              end: .5,
              chapterCount: 2,
            )
          else
            const ReaderContentCoverage(
              key: 'pdf:2',
              start: 0,
              end: 1,
              pdfPageIndex: 2,
            ),
        ];
        final event = ReaderActivityEvent(
          ready: true,
          visible: true,
          cause: ReaderNavigationCause.viewport,
          locator: locator,
          coverage: source,
          atEnd: true,
        );
        source.clear();
        final json =
            jsonDecode(jsonEncode(event.toJson())) as Map<String, Object?>;
        final restored = ReaderActivityEvent.fromJson(json);
        expect(restored, event);
        expect(restored.hashCode, event.hashCode);
        expect(restored.locator, ReaderLocator.fromJson(locator.toJson()));
        expect(restored.coverage, hasLength(1));
        expect(() => restored.coverage.clear(), throwsUnsupportedError);
      },
    );
  }
  test('activity rejects malformed and unsupported representations', () {
    final valid = ReaderActivityEvent(
      ready: true,
      visible: true,
      cause: ReaderNavigationCause.restore,
    ).toJson();
    for (final patch in <Map<String, Object?>>[
      {'version': 2},
      {'ready': 1},
      {'visible': null},
      {'atEnd': 'true'},
      {'cause': 'unknown'},
      {'locator': 7},
      {
        'coverage': [7],
      },
      {
        'locator': {...pdf.toJson(), 'version': 2},
      },
    ]) {
      expect(
        () => ReaderActivityEvent.fromJson({...valid, ...patch}),
        throwsFormatException,
      );
    }
  });
  test(
    'coverage validates versions, normalized extents and calibration identity',
    () {
      final valid = const ReaderContentCoverage(
        key: 'chapter:0',
        start: 0,
        end: 1,
      ).toJson();
      for (final patch in <Map<String, Object?>>[
        {'version': 2},
        {'key': ''},
        {'start': -1},
        {'end': 2},
        {'start': .75, 'end': .5},
        {'start': double.nan},
        {'chapterCount': 0},
        {'pdfPageIndex': -1},
        {'chapterCount': 'two'},
      ]) {
        expect(
          () => ReaderContentCoverage.fromJson({...valid, ...patch}),
          throwsFormatException,
        );
      }
    },
  );
}
