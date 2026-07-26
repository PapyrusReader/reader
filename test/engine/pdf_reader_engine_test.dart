import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/pdf/pdf_facade.dart';

void main() {
  ReaderDocument document({ReaderFormat format = ReaderFormat.pdf}) {
    return ReaderDocument(
      id: 'pdf',
      format: format,
      loadBytes: () async => Uint8List.fromList([37, 80, 68, 70]),
    );
  }

  group('PdfReaderEngine', () {
    test(
      'loads outline and restores a page locator through the facade',
      () async {
        final facade = FakePdfFacade(
          pageCount: 4,
          outline: const [
            PdfFacadeOutlineEntry(
              title: 'Section',
              pageIndex: 1,
              children: [PdfFacadeOutlineEntry(title: 'Detail', pageIndex: 2)],
            ),
          ],
        );
        final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
        final restored = PdfReaderLocator(
          pageIndex: 2,
          pageOffset: 0.25,
          totalProgression: 2 / 3,
        );

        await engine.load(
          document(),
          initialLocator: restored,
          preferences: const ReaderPreferences(),
        );

        expect(engine.snapshot, isA<ReaderReadySnapshot>());
        expect(engine.snapshot.toc.single.title, 'Section');
        expect(engine.snapshot.toc.single.children.single.title, 'Detail');
        expect(await engine.currentLocator(), restored);
        expect(facade.shownPages, [2]);
        expect(facade.shownOffsets, [0.25]);
      },
    );

    test('navigates with bounds and publishes visible page changes', () async {
      final facade = FakePdfFacade(pageCount: 3);
      final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
      await engine.load(
        document(),
        preferences: const ReaderPreferences(
          columnMode: ReaderColumnMode.single,
        ),
      );

      await engine.goNext();
      expect((await engine.currentLocator() as PdfReaderLocator).pageIndex, 1);
      await engine.goPrevious();
      expect((await engine.currentLocator() as PdfReaderLocator).pageIndex, 0);
      await expectLater(
        engine.goPrevious(),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code.name,
            'code name',
            'navigationBoundary',
          ),
        ),
      );

      engine.buildViewport(FakeBuildContext());
      facade.emitVisiblePage(2);
      expect((engine.snapshot.locator! as PdfReaderLocator).pageIndex, 2);
      expect(
        (engine.snapshot.locator! as PdfReaderLocator).totalProgression,
        1,
      );
    });

    test('maps continuous progress to a page and page offset', () async {
      final facade = FakePdfFacade(pageCount: 5);
      final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
      await engine.load(document(), preferences: const ReaderPreferences());

      await engine.goToProgress(0.375);

      final middle = await engine.currentLocator() as PdfReaderLocator;
      expect(middle.pageIndex, 1);
      expect(middle.pageOffset, 0.5);
      expect(middle.totalProgression, 0.375);
      expect(facade.shownPages.last, 1);
      expect(facade.shownOffsets.last, 0.5);

      await engine.goToProgress(1);

      final end = await engine.currentLocator() as PdfReaderLocator;
      expect(end.pageIndex, 4);
      expect(end.pageOffset, 0);
      expect(end.totalProgression, 1);
    });

    test('rejects invalid continuous progress', () async {
      final facade = FakePdfFacade(pageCount: 2);
      final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
      await engine.load(document(), preferences: const ReaderPreferences());

      await expectLater(engine.goToProgress(-0.1), throwsArgumentError);
      await expectLater(engine.goToProgress(1.1), throwsArgumentError);
      await expectLater(engine.goToProgress(double.nan), throwsArgumentError);
    });

    test('validates locator type, bounds, and document format', () async {
      final facade = FakePdfFacade(pageCount: 2);
      final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
      await engine.load(document(), preferences: const ReaderPreferences());

      await expectLater(
        engine.goTo(
          EpubReaderLocator(
            cfi: 'epubcfi(/6/2)',
            spineIndex: 0,
            localProgression: 0,
            totalProgression: 0,
          ),
        ),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.invalidDocument,
          ),
        ),
      );

      final wrongFormat = PdfReaderEngine(facadeFactory: (_) async => facade);
      await expectLater(
        wrongFormat.load(
          document(format: ReaderFormat.epub),
          preferences: const ReaderPreferences(),
        ),
        throwsA(isA<ReaderException>()),
      );
    });

    test(
      'maps invalid and encrypted facade failures to stable errors',
      () async {
        final invalid = PdfReaderEngine(
          facadeFactory: (_) async =>
              throw const PdfFacadeException(PdfFacadeError.invalid),
        );
        await expectLater(
          invalid.load(document(), preferences: const ReaderPreferences()),
          throwsA(
            isA<ReaderException>().having(
              (error) => error.code,
              'code',
              ReaderErrorCode.invalidDocument,
            ),
          ),
        );

        final encrypted = PdfReaderEngine(
          facadeFactory: (_) async =>
              throw const PdfFacadeException(PdfFacadeError.encrypted),
        );
        await expectLater(
          encrypted.load(document(), preferences: const ReaderPreferences()),
          throwsA(
            isA<ReaderException>().having(
              (error) => error.code,
              'code',
              ReaderErrorCode.encryptedDocument,
            ),
          ),
        );
      },
    );

    test(
      'updates single/facing and light/dark viewport configuration',
      () async {
        final facade = FakePdfFacade(pageCount: 2);
        final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
        await engine.load(document(), preferences: const ReaderPreferences());
        const updated = ReaderPreferences(
          layoutMode: ReaderLayoutMode.scroll,
          columnMode: ReaderColumnMode.double,
          brightness: Brightness.dark,
          backgroundColor: Color(0xff101010),
        );

        await engine.updatePreferences(updated);

        expect(engine.snapshot.preferences, updated);
        final viewport = engine.buildViewport(FakeBuildContext());
        expect(viewport, same(facade.viewport));
        expect(facade.lastConfiguration!.facingPages, isTrue);
        expect(
          facade.lastConfiguration!.backgroundColor,
          const Color(0xff101010),
        );
        expect(facade.lastConfiguration!.brightness, Brightness.dark);
        expect(facade.lastConfiguration!.layoutMode, ReaderLayoutMode.scroll);
      },
    );
  });

  test(
    'metadata documents are disposed after successful facade creation',
    () async {
      final metadata = FakePdfMetadataDocument(pageCount: 2);

      final facade = await createPdfrxFacade(
        Uint8List.fromList([37, 80, 68, 70]),
        sourceName: 'success',
        metadataDocumentLoader: () async => metadata,
      );

      expect(facade.pageCount, 2);
      expect(metadata.disposeCount, 1);
    },
  );

  test('metadata documents are disposed when outline loading fails', () async {
    final metadata = FakePdfMetadataDocument(
      pageCount: 2,
      outlineFailure: StateError('outline failed'),
    );

    await expectLater(
      createPdfrxFacade(
        Uint8List.fromList([37, 80, 68, 70]),
        sourceName: 'failure',
        metadataDocumentLoader: () async => metadata,
      ),
      throwsA(
        isA<PdfFacadeException>().having(
          (error) => error.error,
          'error',
          PdfFacadeError.invalid,
        ),
      ),
    );

    expect(metadata.disposeCount, 1);
  });

  test('replacing an unmounted PDF disposes both metadata documents', () async {
    final metadataDocuments = [
      FakePdfMetadataDocument(pageCount: 1),
      FakePdfMetadataDocument(pageCount: 2),
    ];
    var nextMetadata = 0;
    final engine = PdfReaderEngine(
      facadeFactory: (bytes) {
        final index = nextMetadata++;
        return createPdfrxFacade(
          bytes,
          sourceName: 'replacement-$index',
          metadataDocumentLoader: () async => metadataDocuments[index],
        );
      },
    );

    await engine.load(document(), preferences: const ReaderPreferences());
    await engine.load(document(), preferences: const ReaderPreferences());

    expect(metadataDocuments.map((metadata) => metadata.disposeCount), [1, 1]);
    expect((engine.snapshot.locator as PdfReaderLocator).pageIndex, 0);
  });

  test(
    'real pdfrx parameters distinguish paginated and continuous layouts',
    () {
      final paginated = buildPdfViewerParams(
        PdfViewportConfiguration(
          pageIndex: 0,
          facingPages: false,
          backgroundColor: const Color(0xffffffff),
          brightness: Brightness.light,
          layoutMode: ReaderLayoutMode.paginated,
          onPageChanged: (_) {},
        ),
      );
      final continuous = buildPdfViewerParams(
        PdfViewportConfiguration(
          pageIndex: 0,
          facingPages: false,
          backgroundColor: const Color(0xffffffff),
          brightness: Brightness.light,
          layoutMode: ReaderLayoutMode.scroll,
          onPageChanged: (_) {},
        ),
      );
      final facing = buildPdfViewerParams(
        PdfViewportConfiguration(
          pageIndex: 0,
          facingPages: true,
          backgroundColor: const Color(0xffffffff),
          brightness: Brightness.light,
          layoutMode: ReaderLayoutMode.scroll,
          onPageChanged: (_) {},
        ),
      );

      expect(paginated.scrollPhysics, isA<PageScrollPhysics>());
      expect(paginated.layoutPages, isNotNull);
      expect(continuous.scrollPhysics, isA<ClampingScrollPhysics>());
      expect(continuous.layoutPages, isNull);
      expect(facing.layoutPages, isNotNull);
    },
  );

  testWidgets('real PDF viewport applies a deterministic dark color filter', (
    tester,
  ) async {
    const child = SizedBox(key: ValueKey('pdf-child'));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: applyPdfBrightness(Brightness.dark, child),
      ),
    );

    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-child')), findsOneWidget);
  });

  testWidgets('delegates PDF viewport construction to the facade', (
    tester,
  ) async {
    final facade = FakePdfFacade(pageCount: 2);
    final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
    await engine.load(document(), preferences: const ReaderPreferences());

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: engine.buildViewport),
      ),
    );

    expect(find.byKey(const ValueKey('fake-pdf-viewport')), findsOneWidget);
    expect(facade.viewportBuildCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: engine.buildViewport),
      ),
    );

    expect(find.byKey(const ValueKey('fake-pdf-viewport')), findsOneWidget);
    expect(facade.viewportBuildCount, 2);
  });
}

final class FakePdfMetadataDocument implements PdfMetadataDocument {
  FakePdfMetadataDocument({
    required this.pageCount,
    this.outline = const [],
    this.outlineFailure,
  }) : pageSizes = List.filled(pageCount, const Size(600, 800));

  @override
  final int pageCount;

  @override
  final List<Size> pageSizes;

  final List<PdfFacadeOutlineEntry> outline;
  final Object? outlineFailure;
  int disposeCount = 0;

  @override
  Future<void> dispose() async {
    disposeCount++;
  }

  @override
  Future<List<PdfFacadeOutlineEntry>> loadOutline() async {
    final failure = outlineFailure;
    if (failure != null) {
      throw failure;
    }

    return outline;
  }
}

final class FakePdfFacade implements PdfFacade {
  FakePdfFacade({required this.pageCount, this.outline = const []});

  @override
  final int pageCount;

  @override
  final List<PdfFacadeOutlineEntry> outline;

  final Widget viewport = const SizedBox(key: ValueKey('fake-pdf-viewport'));
  final List<int> shownPages = [];
  final List<double> shownOffsets = [];
  PdfViewportConfiguration? lastConfiguration;
  int viewportBuildCount = 0;

  @override
  Widget buildViewport(PdfViewportConfiguration configuration) {
    viewportBuildCount++;
    lastConfiguration = configuration;
    return viewport;
  }

  @override
  Future<void> showPage(int pageIndex, double pageOffset) async {
    shownPages.add(pageIndex);
    shownOffsets.add(pageOffset);
  }

  void emitVisiblePage(int pageIndex) {
    lastConfiguration?.onPageChanged(pageIndex);
  }
}

final class FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
