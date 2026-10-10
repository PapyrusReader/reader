import 'dart:async';
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
    test('zoomed content is ready without qualifying a full page', () {
      final exposure = pdfViewportExposure([
        const Rect.fromLTWH(0, 0, 1000, 1000),
      ], const Rect.fromLTWH(100, 100, 200, 200));
      expect(exposure.contentVisible, isTrue);
      expect(exposure.pages, isEmpty);
      final spread = pdfViewportExposure([
        const Rect.fromLTWH(0, 0, 500, 800),
        const Rect.fromLTWH(510, 0, 500, 800),
      ], const Rect.fromLTWH(0, 0, 1010, 800));
      expect(spread.pages, [0, 1]);
      expect(
        pdfViewportExposure([
          const Rect.fromLTWH(0, 0, 100, 100),
        ], const Rect.fromLTWH(200, 200, 100, 100)).contentVisible,
        isFalse,
      );
    });

    testWidgets(
      'viewport readiness is independent of qualified page coverage',
      (tester) async {
        final facade = FakePdfFacade(pageCount: 3);
        final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
        addTearDown(engine.dispose);
        await engine.load(document(), preferences: const ReaderPreferences());
        expect(engine.snapshot.contentReady, isFalse);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(builder: engine.buildViewport),
          ),
        );
        final config = facade.lastConfiguration!;
        config.onContentReadyChanged!(false);
        config.onVisiblePagesChanged!([]);
        expect(engine.snapshot.contentReady, isFalse);
        config.onContentReadyChanged!(true);
        expect(engine.snapshot.contentReady, isTrue);
        expect(engine.snapshot.coverage, isEmpty);
        config.onVisiblePagesChanged!([0, 1]);
        expect(engine.snapshot.coverage.map((c) => c.pdfPageIndex), [0, 1]);
        config.onVisiblePagesChanged!([]);
        expect(engine.snapshot.contentReady, isTrue);
        await engine.goNext();
        expect(engine.snapshot.contentReady, isFalse);
      },
    );

    testWidgets('turns whole spreads only in paginated mode', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final facade = FakePdfFacade(pageCount: 5);
      final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
      addTearDown(engine.dispose);
      await engine.load(document(), preferences: const ReaderPreferences());
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: engine.buildViewport),
        ),
      );
      expect(facade.lastConfiguration!.facingPages, isTrue);
      await engine.goNext();
      expect((await engine.currentLocator() as PdfReaderLocator).pageIndex, 2);
      await engine.goNext();
      expect((await engine.currentLocator() as PdfReaderLocator).pageIndex, 4);
      await engine.goPrevious();
      expect((await engine.currentLocator() as PdfReaderLocator).pageIndex, 2);
      await engine.updatePreferences(
        const ReaderPreferences(layoutMode: ReaderLayoutMode.scroll),
      );
      await engine.goNext();
      expect((await engine.currentLocator() as PdfReaderLocator).pageIndex, 3);
    });

    test(
      'failed replacement retains the current PDF and releases its candidate',
      () async {
        final original = FakePdfFacade(pageCount: 3);
        final invalid = FakePdfFacade(pageCount: 0);
        var loads = 0;
        final engine = PdfReaderEngine(
          facadeFactory: (_) async => loads++ == 0 ? original : invalid,
        );
        await engine.load(document(), preferences: const ReaderPreferences());
        await engine.goNext();
        await expectLater(
          engine.load(document(), preferences: const ReaderPreferences()),
          throwsA(isA<ReaderException>()),
        );
        expect((engine.snapshot.locator as PdfReaderLocator).pageIndex, 1);
        expect(original.disposeCount, 0);
        expect(invalid.disposeCount, 1);
        await engine.goNext();
        expect(original.shownPages.last, 2);
        engine.dispose();
        expect(original.disposeCount, 1);
      },
    );

    test('closing while a PDF opens releases the late document', () async {
      final gate = Completer<PdfFacade>();
      final started = Completer<void>();
      final facade = FakePdfFacade(pageCount: 1);
      final engine = PdfReaderEngine(
        facadeFactory: (_) {
          started.complete();
          return gate.future;
        },
      );
      final loading = engine.load(
        document(),
        preferences: const ReaderPreferences(),
      );
      final assertion = expectLater(loading, throwsA(isA<ReaderException>()));
      await started.future;
      engine.dispose();
      gate.complete(facade);
      await assertion;
      expect(facade.disposeCount, 1);
    });

    testWidgets('uses available width and records intra-page position', (
      tester,
    ) async {
      final facade = FakePdfFacade(pageCount: 1);
      final engine = PdfReaderEngine(facadeFactory: (_) async => facade);
      addTearDown(engine.dispose);
      await engine.load(
        document(),
        preferences: const ReaderPreferences(
          columnMode: ReaderColumnMode.double,
        ),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 390,
              child: Builder(builder: engine.buildViewport),
            ),
          ),
        ),
      );
      expect(facade.lastConfiguration!.facingPages, isFalse);
      facade.lastConfiguration!.onPositionChanged!(0, 0.345678);
      final locator = await engine.currentLocator() as PdfReaderLocator;
      expect(locator.pageOffset, 0.3457);
      expect(locator.totalProgression, 0.3457);
      await engine.goToProgress(0.75);
      expect(facade.shownOffsets.last, 0.75);
    });

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

    testWidgets('navigates with bounds and publishes visible page changes', (
      tester,
    ) async {
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

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: engine.buildViewport),
        ),
      );
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

    testWidgets('updates single/facing and light/dark viewport configuration', (
      tester,
    ) async {
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
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: engine.buildViewport),
        ),
      );
      expect(find.byKey(const ValueKey('fake-pdf-viewport')), findsOneWidget);
      expect(facade.lastConfiguration!.facingPages, isTrue);
      expect(
        facade.lastConfiguration!.backgroundColor,
        const Color(0xff101010),
      );
      expect(facade.lastConfiguration!.brightness, Brightness.dark);
      expect(facade.lastConfiguration!.layoutMode, ReaderLayoutMode.scroll);
    });
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

      expect(paginated.scrollPhysics, isNull);
      expect(paginated.normalizeMatrix, isNotNull);
      expect(paginated.layoutPages, isNotNull);
      expect(continuous.scrollPhysics, isA<ClampingScrollPhysics>());
      expect(continuous.layoutPages, isNull);
      expect(continuous.normalizeMatrix, isNull);
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

  test(
    'paginated slots expose only the current page or spread at fit zoom',
    () {
      for (final size in [
        const Size(390, 844),
        const Size(1280, 700),
        const Size(700, 360),
      ]) {
        for (final facing in [false, true]) {
          final layout = buildPaginatedPdfLayout(
            [const Size(300, 420), const Size(360, 600), const Size(300, 420)],
            viewportSize: size,
            facingPages: facing,
          );
          final step = facing ? 2 : 1;
          for (var index = 0; index < 3; index += step) {
            final row = pdfSpreadRect(layout, index, facing);
            final zoom =
                ((size.width - 16) / row.width) <
                    ((size.height - 16) / row.height)
                ? (size.width - 16) / row.width
                : (size.height - 16) / row.height;
            final visible = Rect.fromCenter(
              center: row.center,
              width: size.width / zoom,
              height: size.height / zoom,
            );
            for (var page = 0; page < 3; page++) {
              if (page < index || page >= index + step) {
                expect(
                  visible.overlaps(layout.pageLayouts[page]),
                  isFalse,
                  reason: 'A spare margin must not expose another spread',
                );
              }
            }
          }
        }
      }
    },
  );

  testWidgets('appearance changes retain the PDF viewer element', (
    tester,
  ) async {
    const key = ValueKey('persistent-pdf');
    const child = SizedBox(key: key);
    await tester.pumpWidget(applyPdfBrightness(Brightness.light, child));
    final before = tester.element(find.byKey(key));
    await tester.pumpWidget(applyPdfBrightness(Brightness.dark, child));
    expect(tester.element(find.byKey(key)), same(before));
    await tester.pumpWidget(applyPdfBrightness(Brightness.light, child));
    expect(tester.element(find.byKey(key)), same(before));
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

final class FakePdfFacade implements PdfFacade, DisposablePdfFacade {
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
  int disposeCount = 0;

  @override
  void dispose() => disposeCount++;

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
