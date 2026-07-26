import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/fake_reader_engine.dart';

void main() {
  group('ReaderController', () {
    late FakeReaderEngine engine;
    late ReaderController controller;
    late ReaderDocument document;
    late List<ReaderLocator> locatorChanges;
    late List<ReaderPreferences> preferenceChanges;
    late bool controllerDisposed;

    setUp(() {
      engine = FakeReaderEngine(supportedFormats: const {ReaderFormat.epub});
      locatorChanges = [];
      preferenceChanges = [];
      document = ReaderDocument(
        id: 'book-1',
        format: ReaderFormat.epub,
        title: 'A Book',
        loadBytes: () async => Uint8List.fromList([1, 2, 3]),
      );
      controller = ReaderController(
        registry: ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub},
            factory: () => engine,
          ),
        ]),
        onLocatorChanged: locatorChanges.add,
        onPreferencesChanged: preferenceChanges.add,
      );
      controllerDisposed = false;
    });

    tearDown(() {
      if (!controllerDisposed) {
        controller.dispose();
      }
    });

    ReaderDocument makeDocument(
      String id, {
      ReaderFormat format = ReaderFormat.epub,
    }) {
      return ReaderDocument(
        id: id,
        format: format,
        loadBytes: () async => Uint8List(0),
      );
    }

    Future<void> expectEngineUnavailable(
      Future<Object?> Function() operation,
    ) async {
      await expectLater(
        operation(),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.engineUnavailable,
          ),
        ),
      );
    }

    test('starts with an immutable idle snapshot', () {
      final snapshot = controller.snapshot;

      expect(snapshot, isA<ReaderIdleSnapshot>());
      expect(snapshot.status, ReaderStatus.idle);
      expect(snapshot.document, isNull);
      expect(snapshot.locator, isNull);
      expect(snapshot.preferences, const ReaderPreferences());
      expect(snapshot.toc, isEmpty);
      expect(snapshot.capabilities, isNull);
      expect(snapshot.error, isNull);
    });

    test('exposes loading while the selected engine load is pending', () async {
      final loadGate = Completer<void>();
      engine.loadGate = loadGate;

      final load = controller.load(document);

      expect(controller.snapshot, isA<ReaderLoadingSnapshot>());
      expect(controller.snapshot.status, ReaderStatus.loading);
      expect(controller.snapshot.document, same(document));

      loadGate.complete();
      await load;

      expect(controller.snapshot.status, ReaderStatus.ready);
    });

    test('delegates loading to the matching engine', () async {
      final initialLocator = EpubReaderLocator(
        cfi: 'epubcfi(/6/2!/4/1:0)',
        spineIndex: 0,
        localProgression: 0,
        totalProgression: 0,
      );

      await controller.load(document, initialLocator: initialLocator);

      expect(engine.loadedDocument, same(document));
      expect(engine.initialLocator, initialLocator);
      expect(engine.loadedPreferences, const ReaderPreferences());
      expect(controller.snapshot, same(engine.snapshot));
      expect(controller.snapshot.status, ReaderStatus.ready);
    });

    test('mirrors engine state and emits locator changes once', () async {
      await controller.load(document);
      final locator = EpubReaderLocator(
        cfi: 'epubcfi(/6/6!/4/1:4)',
        spineIndex: 2,
        localProgression: 0.4,
        totalProgression: 0.5,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      engine.emitLocator(locator);

      expect(controller.snapshot.locator, locator);
      expect(locatorChanges, [locator]);
      expect(notifications, 1);
    });

    test('delegates navigation and current location', () async {
      await controller.load(document);
      final locator = EpubReaderLocator(
        cfi: 'epubcfi(/6/4!/4/1:0)',
        spineIndex: 1,
        localProgression: 0.1,
        totalProgression: 0.2,
      );
      engine.currentLocatorResult = locator;

      await controller.goTo(locator);
      await controller.goNext();
      await controller.goPrevious();
      final currentLocator = await controller.currentLocator();

      expect(engine.goToCalls, [locator]);
      expect(engine.goNextCallCount, 1);
      expect(engine.goPreviousCallCount, 1);
      expect(currentLocator, locator);
    });

    test('validates and delegates continuous progress navigation', () async {
      await controller.load(document);

      await controller.goToProgress(0.625);

      expect(engine.goToProgressCalls, [0.625]);
      await expectLater(controller.goToProgress(-0.01), throwsArgumentError);
      await expectLater(controller.goToProgress(1.01), throwsArgumentError);
      await expectLater(
        controller.goToProgress(double.nan),
        throwsArgumentError,
      );
      expect(engine.goToProgressCalls, [0.625]);
    });

    test('delegates preferences and emits preference changes once', () async {
      await controller.load(document);
      const preferences = ReaderPreferences(
        fontSize: 22,
        layoutMode: ReaderLayoutMode.scroll,
      );

      await controller.updatePreferences(preferences);

      expect(engine.preferenceCalls, [preferences]);
      expect(controller.snapshot.preferences, preferences);
      expect(preferenceChanges, [preferences]);
    });

    test('surfaces engine failures as an immutable error state', () async {
      final failure = ReaderException(
        ReaderErrorCode.invalidDocument,
        'The document is malformed.',
      );
      engine.loadFailure = failure;

      await expectLater(controller.load(document), throwsA(same(failure)));

      final snapshot = controller.snapshot;
      expect(snapshot, isA<ReaderErrorSnapshot>());
      expect(snapshot.status, ReaderStatus.error);
      expect(snapshot.error, same(failure));
      expect(snapshot.document, same(document));
    });

    test('requires a loaded engine before reader operations', () async {
      await expectEngineUnavailable(controller.goNext);
    });

    test('exposes the active engine viewport only when ready', () async {
      expect(
        () => controller.buildViewport(FakeBuildContext()),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.engineUnavailable,
          ),
        ),
      );

      await controller.load(document);

      expect(controller.buildViewport(FakeBuildContext()), isA<SizedBox>());
    });

    test('serializes overlapping loads and leaves the second ready', () async {
      final firstDocument = makeDocument('first');
      final secondDocument = makeDocument('second');
      final firstGate = Completer<void>();
      final firstEngine = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );
      final secondEngine = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );
      firstEngine.loadGatesByDocument[firstDocument.id] = firstGate;
      final firstStarted = firstEngine.trackLoadStart(firstDocument.id);
      final engines = [firstEngine, secondEngine].iterator;
      controller.dispose();
      controller = ReaderController(
        registry: ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub},
            factory: () {
              engines.moveNext();
              return engines.current;
            },
          ),
        ]),
      );

      final firstLoad = controller.load(firstDocument);
      await firstStarted.future;
      final secondLoad = controller.load(secondDocument);

      expect(controller.snapshot.status, ReaderStatus.loading);
      expect(controller.snapshot.document, same(secondDocument));
      expect(secondEngine.loadedDocuments, isEmpty);

      firstGate.complete();
      await firstLoad;
      await secondLoad;

      expect(firstEngine.loadedDocuments, [firstDocument]);
      expect(secondEngine.loadedDocuments, [secondDocument]);
      expect(firstEngine.isDisposed, isTrue);
      expect(secondEngine.isDisposed, isFalse);
      expect(controller.snapshot.status, ReaderStatus.ready);
      expect(controller.snapshot.document, same(secondDocument));
    });

    test('a stale load failure cannot replace the second result', () async {
      final firstDocument = makeDocument('first');
      final secondDocument = makeDocument('second');
      final firstGate = Completer<void>();
      final firstFailure = ReaderException(
        ReaderErrorCode.invalidDocument,
        'The first document failed.',
      );
      final firstEngine = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );
      final secondEngine = FakeReaderEngine(
        supportedFormats: const {ReaderFormat.epub},
      );
      firstEngine.loadGatesByDocument[firstDocument.id] = firstGate;
      firstEngine.loadFailuresByDocument[firstDocument.id] = firstFailure;
      final firstStarted = firstEngine.trackLoadStart(firstDocument.id);
      final engines = [firstEngine, secondEngine].iterator;
      controller.dispose();
      controller = ReaderController(
        registry: ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub},
            factory: () {
              engines.moveNext();
              return engines.current;
            },
          ),
        ]),
      );
      final publishedErrors = <ReaderErrorSnapshot>[];
      controller.addListener(() {
        final snapshot = controller.snapshot;
        if (snapshot is ReaderErrorSnapshot) {
          publishedErrors.add(snapshot);
        }
      });

      final firstLoad = controller.load(firstDocument);
      final firstExpectation = expectLater(
        firstLoad,
        throwsA(same(firstFailure)),
      );
      await firstStarted.future;
      final secondLoad = controller.load(secondDocument);

      firstGate.complete();
      await firstExpectation;
      await secondLoad;

      expect(publishedErrors, isEmpty);
      expect(firstEngine.isDisposed, isTrue);
      expect(secondEngine.isDisposed, isFalse);
      expect(controller.snapshot.status, ReaderStatus.ready);
      expect(controller.snapshot.document, same(secondDocument));
    });

    test('pending loads cannot publish after disposal', () async {
      final gate = Completer<void>();
      engine.loadGatesByDocument[document.id] = gate;
      final started = engine.trackLoadStart(document.id);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final load = controller.load(document);
      await started.future;
      final snapshotAtDisposal = controller.snapshot;
      final notificationsAtDisposal = notifications;

      controller.dispose();
      controllerDisposed = true;
      gate.complete();
      await load;

      expect(controller.snapshot, same(snapshotAtDisposal));
      expect(notifications, notificationsAtDisposal);
      expect(locatorChanges, isEmpty);
      expect(preferenceChanges, isEmpty);
    });

    test('reader operations are rejected while loading', () async {
      final gate = Completer<void>();
      engine.loadGatesByDocument[document.id] = gate;
      final started = engine.trackLoadStart(document.id);
      final load = controller.load(document);
      await started.future;
      final locator = EpubReaderLocator(
        cfi: 'epubcfi(/6/2)',
        spineIndex: 0,
        localProgression: 0,
        totalProgression: 0,
      );

      await expectEngineUnavailable(() => controller.goTo(locator));
      await expectEngineUnavailable(controller.goNext);
      await expectEngineUnavailable(controller.goPrevious);
      await expectEngineUnavailable(controller.currentLocator);
      await expectEngineUnavailable(
        () =>
            controller.updatePreferences(const ReaderPreferences(fontSize: 20)),
      );

      expect(engine.goToCalls, isEmpty);
      expect(engine.goNextCallCount, 0);
      expect(engine.goPreviousCallCount, 0);
      expect(engine.currentLocatorCallCount, 0);
      expect(engine.preferenceCalls, isEmpty);

      gate.complete();
      await load;
    });

    test('reader operations are rejected after a load error', () async {
      final failure = ReaderException(
        ReaderErrorCode.invalidDocument,
        'The document failed.',
      );
      engine.loadFailure = failure;
      await expectLater(controller.load(document), throwsA(same(failure)));
      final locator = EpubReaderLocator(
        cfi: 'epubcfi(/6/2)',
        spineIndex: 0,
        localProgression: 0,
        totalProgression: 0,
      );

      await expectEngineUnavailable(() => controller.goTo(locator));
      await expectEngineUnavailable(controller.goNext);
      await expectEngineUnavailable(controller.goPrevious);
      await expectEngineUnavailable(controller.currentLocator);
      await expectEngineUnavailable(
        () =>
            controller.updatePreferences(const ReaderPreferences(fontSize: 20)),
      );

      expect(engine.goToCalls, isEmpty);
      expect(engine.goNextCallCount, 0);
      expect(engine.goPreviousCallCount, 0);
      expect(engine.currentLocatorCallCount, 0);
      expect(engine.preferenceCalls, isEmpty);
    });

    test(
      'registry failure publishes loading then attempted-document error',
      () async {
        final unsupportedDocument = makeDocument(
          'unsupported',
          format: ReaderFormat.pdf,
        );
        final statuses = <ReaderStatus>[];
        controller.addListener(() => statuses.add(controller.snapshot.status));

        final load = controller.load(unsupportedDocument);

        expect(controller.snapshot.status, ReaderStatus.loading);
        expect(controller.snapshot.document, same(unsupportedDocument));
        await expectLater(
          load,
          throwsA(
            isA<ReaderException>().having(
              (error) => error.code,
              'code',
              ReaderErrorCode.engineUnavailable,
            ),
          ),
        );

        expect(statuses, [ReaderStatus.loading, ReaderStatus.error]);
        expect(controller.snapshot, isA<ReaderErrorSnapshot>());
        expect(controller.snapshot.document, same(unsupportedDocument));
      },
    );

    test(
      'registry failure replaces a ready document with attempted error',
      () async {
        await controller.load(document);
        final unsupportedDocument = makeDocument(
          'unsupported',
          format: ReaderFormat.pdf,
        );

        final load = controller.load(unsupportedDocument);

        expect(controller.snapshot.status, ReaderStatus.loading);
        expect(controller.snapshot.document, same(unsupportedDocument));
        await expectLater(load, throwsA(isA<ReaderException>()));

        expect(controller.snapshot.status, ReaderStatus.error);
        expect(controller.snapshot.document, same(unsupportedDocument));
        expect(controller.snapshot.document, isNot(same(document)));
      },
    );

    test(
      'throwing locator callback is reported without stopping load',
      () async {
        final callbackFailure = StateError('locator callback failed');
        final reportedErrors = <FlutterErrorDetails>[];
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = previousErrorHandler);
        controller.dispose();
        controller = ReaderController(
          registry: ReaderEngineRegistry([
            ReaderEngineRegistration(
              formats: const {ReaderFormat.epub},
              factory: () => engine,
            ),
          ]),
          onLocatorChanged: (_) => throw callbackFailure,
        );
        final locator = EpubReaderLocator(
          cfi: 'epubcfi(/6/2)',
          spineIndex: 0,
          localProgression: 0,
          totalProgression: 0,
        );

        await controller.load(document, initialLocator: locator);

        expect(controller.snapshot.status, ReaderStatus.ready);
        expect(controller.snapshot.locator, locator);
        expect(engine.loadedDocument, same(document));
        expect(reportedErrors, hasLength(1));
        expect(reportedErrors.single.exception, same(callbackFailure));
        expect(reportedErrors.single.library, 'papyrus_reader');
      },
    );

    test(
      'throwing preferences callback is reported without escaping',
      () async {
        final callbackFailure = StateError('preferences callback failed');
        final reportedErrors = <FlutterErrorDetails>[];
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = previousErrorHandler);
        controller.dispose();
        controller = ReaderController(
          registry: ReaderEngineRegistry([
            ReaderEngineRegistration(
              formats: const {ReaderFormat.epub},
              factory: () => engine,
            ),
          ]),
          onPreferencesChanged: (_) => throw callbackFailure,
        );
        engine.notifyOnPreferenceChange = false;
        await controller.load(document);
        const preferences = ReaderPreferences(fontSize: 20);

        await controller.updatePreferences(preferences);

        expect(controller.snapshot.status, ReaderStatus.ready);
        expect(controller.snapshot.preferences, preferences);
        expect(engine.preferenceCalls, [preferences]);
        expect(reportedErrors, hasLength(1));
        expect(reportedErrors.single.exception, same(callbackFailure));
        expect(reportedErrors.single.library, 'papyrus_reader');
      },
    );
  });

  test(
    'two controllers sharing a registry own independent engine lifecycles',
    () async {
      final engines = <FakeReaderEngine>[];
      final registry = ReaderEngineRegistry([
        ReaderEngineRegistration(
          formats: const {ReaderFormat.epub},
          factory: () {
            final engine = FakeReaderEngine(
              supportedFormats: const {ReaderFormat.epub},
            );
            engines.add(engine);
            return engine;
          },
        ),
      ]);
      final first = ReaderController(registry: registry);
      final second = ReaderController(registry: registry);
      final firstDocument = ReaderDocument(
        id: 'first',
        format: ReaderFormat.epub,
        loadBytes: () async => Uint8List(0),
      );
      final secondDocument = ReaderDocument(
        id: 'second',
        format: ReaderFormat.epub,
        loadBytes: () async => Uint8List(0),
      );

      await first.load(firstDocument);
      await second.load(secondDocument);
      await first.goNext();

      expect(engines, hasLength(2));
      expect(engines[0].loadedDocument, same(firstDocument));
      expect(engines[1].loadedDocument, same(secondDocument));
      expect(engines[0].goNextCallCount, 1);
      expect(engines[1].goNextCallCount, 0);

      first.dispose();

      expect(engines[0].isDisposed, isTrue);
      expect(engines[1].isDisposed, isFalse);

      await second.goNext();
      expect(engines[1].goNextCallCount, 1);

      second.dispose();
      expect(engines[1].isDisposed, isTrue);
    },
  );
}

final class FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
