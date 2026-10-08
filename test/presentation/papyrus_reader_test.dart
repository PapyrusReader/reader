import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('presentation tests', () {
    ReaderDocument document(
      String id, {
      ReaderFormat format = ReaderFormat.epub,
    }) {
      return ReaderDocument(
        id: id,
        format: format,
        title: 'The $id Reader',
        author: 'Papyrus',
        loadBytes: () async => Uint8List.fromList([1, 2, 3]),
      );
    }

    ReaderController controllerFor(
      Iterable<_UiReaderEngine> engines, {
      ReaderPreferences initialPreferences = const ReaderPreferences(),
    }) {
      final iterator = engines.iterator;

      return ReaderController(
        initialPreferences: initialPreferences,
        registry: ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.epub, ReaderFormat.pdf},
            factory: () {
              if (!iterator.moveNext()) {
                throw StateError('No fake reader engine remains.');
              }

              return iterator.current;
            },
          ),
        ]),
      );
    }

    Future<void> pumpReader(
      WidgetTester tester, {
      required ReaderDocument document,
      required ReaderController controller,
      Size size = const Size(600, 800),
      ThemeMode themeMode = ThemeMode.light,
      double textScale = 1,
      ReaderUiBuilders builders = const ReaderUiBuilders(),
      ReaderLocatorChanged? onLocatorChanged,
      ValueChanged<ReaderActivityEvent>? onActivity,
      ReaderPreferencesChanged? onPreferencesChanged,
      ReaderPreferences? initialPreferences,
      ReaderThemeData? readerTheme,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: false,
            splashFactory: NoSplash.splashFactory,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.amber,
              brightness: Brightness.dark,
            ),
            useMaterial3: false,
            splashFactory: NoSplash.splashFactory,
          ),
          themeMode: themeMode,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: PapyrusReader(
            document: document,
            controller: controller,
            builders: builders,
            initialPreferences: initialPreferences,
            theme: readerTheme,
            onLocatorChanged: onLocatorChanged,
            onActivity: onActivity,
            onPreferencesChanged: onPreferencesChanged,
          ),
        ),
      );
    }

    testWidgets('custom snapshot viewports refresh without losing state', (
      tester,
    ) async {
      final engine = _UiReaderEngine(
        viewportBuilder: (context, snapshot) => _SnapshotViewport(
          progression:
              (snapshot.locator as EpubReaderLocator?)?.totalProgression ?? 0,
        ),
      );
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Custom viewport'),
        controller: controller,
      );
      await tester.pumpAndSettle();
      final viewport = find.byType(_SnapshotViewport);
      final state = tester.state(viewport);
      expect(find.text('Custom position 0'), findsOneWidget);

      await controller.goToProgress(0.4);
      await tester.pumpAndSettle();
      expect(find.text('Custom position 40'), findsOneWidget);
      expect(tester.state(viewport), same(state));

      await controller.goToProgress(0.8);
      await tester.pumpAndSettle();
      expect(find.text('Custom position 80'), findsOneWidget);
      expect(tester.state(viewport), same(state));

      await tester.tap(find.byTooltip('Hide controls'));
      await tester.pumpAndSettle();
      expect(find.text('Custom position 80'), findsOneWidget);
      expect(tester.state(viewport), same(state));
    });

    testWidgets(
      'a host rebuilding on activity does not create a frame feedback loop',
      (tester) async {
        final events = <ReaderActivityEvent>[];
        final controller = controllerFor([_UiReaderEngine()]);
        final book = document('Host rebuild');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, rebuild) {
                return PapyrusReader(
                  document: book,
                  controller: controller,
                  onActivity: (event) {
                    events.add(event);
                    rebuild(() {});
                  },
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 50),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        final count = events.length;
        expect(events.last.ready, isTrue);
        expect(count, lessThan(5));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(events.length, count);
        await controller.goToProgress(.5);
        await tester.pumpAndSettle();
        expect(events.length, count + 1);
        expect(events.last.cause, ReaderNavigationCause.jump);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'generic activity pauses behind panels and observes jumps without page metrics',
      (tester) async {
        final events = <ReaderActivityEvent>[];
        final controller = controllerFor([_UiReaderEngine()]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Activity'),
          controller: controller,
          size: const Size(1100, 800),
          onActivity: events.add,
        );
        await tester.pumpAndSettle();
        expect(events.last.ready, isTrue);
        expect(events.last.visible, isTrue);
        expect(events.last.coverage, isEmpty);
        await controller.goToProgress(.5);
        await tester.pumpAndSettle();
        expect(events.last.cause, ReaderNavigationCause.jump);
        await tester.tap(find.byTooltip('Reading settings'));
        await tester.pumpAndSettle();
        expect(events.last.visible, isFalse);
        await tester.tap(find.byTooltip('Close panel'));
        await tester.pumpAndSettle();
        expect(events.last.visible, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('sidebar meets the toolbar border without an empty gap', (
      tester,
    ) async {
      final controller = controllerFor([_UiReaderEngine()]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Border'),
        controller: controller,
        size: const Size(1200, 1000),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      final toolbar = tester.getRect(
        find.byKey(const ValueKey('reader-toolbar')),
      );
      final border = tester.getRect(
        find.byKey(const ValueKey('reader-toolbar-border')),
      );
      final panel = tester.getRect(
        find.byKey(const ValueKey('reader-side-panel')),
      );
      expect(border.top, toolbar.bottom);
      expect(border.height, 1);
      expect(panel.top, border.bottom);
      // The panel header keeps its border; text settings have no separator.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'focus mode retains viewport and navigation on phone and desktop',
      (tester) async {
        for (final width in [390.0, 1200.0]) {
          final engine = _UiReaderEngine();
          final controller = controllerFor([engine]);
          final book = document('Focus $width');
          await pumpReader(
            tester,
            document: book,
            controller: controller,
            size: Size(width, 844),
          );
          await tester.pumpAndSettle();
          final viewport = find.byKey(const ValueKey('reader-viewport'));
          final element = tester.element(viewport);
          final height = tester.getSize(viewport).height;
          if (width > 720) {
            await tester.tap(find.byTooltip('Reading settings'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('Hide controls'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('reader-toolbar')), findsNothing);
          expect(
            find.byKey(const ValueKey('reader-progress-controls')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('reader-side-panel')), findsNothing);
          expect(find.byTooltip('Show controls'), findsOneWidget);
          expect(tester.element(viewport), same(element));
          expect(tester.getSize(viewport), Size(width, 844));
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pumpAndSettle();
          expect(engine.goNextCallCount, 1);
          expect(engine.goPreviousCallCount, 1);
          final locator = controller.snapshot.locator;
          await tester.tap(find.byTooltip('Show controls'));
          await tester.pumpAndSettle();
          expect(tester.element(viewport), same(element));
          expect(tester.getSize(viewport).height, height);
          expect(controller.snapshot.locator, locator);
          await tester.tap(find.byTooltip('Hide controls'));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byTooltip('Reading settings'), findsOneWidget);
          expect(find.byTooltip('Next'), findsOneWidget);
          // Opening a different book must restore its exit/navigation controls.
          await tester.tap(find.byTooltip('Hide controls'));
          await tester.pumpAndSettle();
          await pumpReader(
            tester,
            document: document('Replacement'),
            controller: controllerFor([_UiReaderEngine()]),
            size: Size(width, 844),
          );
          await tester.pumpAndSettle();
          expect(find.byTooltip('Hide controls'), findsOneWidget);
          final replacement = tester
              .widget<PapyrusReader>(find.byType(PapyrusReader))
              .controller!;
          await tester.pumpWidget(const SizedBox.shrink());
          replacement.dispose();
          controller.dispose();
        }
      },
    );

    testWidgets(
      'focus mode recovers page keys and Escape from a parked scope',
      (tester) async {
        final engine = _UiReaderEngine();
        final controller = controllerFor([engine]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Parked focus'),
          controller: controller,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Hide controls'));
        await tester.pumpAndSettle();
        FocusManager.instance.rootScope.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(engine.goNextCallCount, 1);
        FocusManager.instance.rootScope.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Hide controls'), findsOneWidget);
      },
    );

    testWidgets('focus mode does not intercept keys from a covering dialog', (
      tester,
    ) async {
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Dialog focus'),
        controller: controller,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide controls'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(PapyrusReader));
      final dialog = showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(engine.goNextCallCount, 0);
      FocusManager.instance.rootScope.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(engine.goNextCallCount, 0);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      await dialog;
      expect(find.byTooltip('Show controls'), findsOneWidget);
    });

    testWidgets(
      'the controls toggle retains one accessible button through reflow',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final controller = controllerFor([_UiReaderEngine()]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Accessible focus'),
          controller: controller,
        );
        await tester.pumpAndSettle();
        final before = tester
            .getSemantics(find.bySemanticsLabel('Hide controls'))
            .id;
        await tester.tap(find.byTooltip('Hide controls'));
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.bySemanticsLabel('Show controls')).id,
          before,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.bySemanticsLabel('Hide controls')).id,
          before,
        );
        semantics.dispose();
      },
    );

    testWidgets(
      'custom toolbars can enter focus mode and restore with Escape',
      (tester) async {
        final controller = controllerFor([_UiReaderEngine()]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Custom focus'),
          controller: controller,
          builders: ReaderUiBuilders(
            toolbar: (context, state) => TextButton(
              onPressed: state.toggleControls,
              child: Text(state.controlsVisible ? 'Focus' : 'Controls'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Focus'));
        await tester.pumpAndSettle();
        expect(find.text('Focus'), findsNothing);
        expect(find.byTooltip('Show controls'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Focus'), findsOneWidget);
      },
    );

    testWidgets('all settings dropdown routes follow the reading appearance', (
      tester,
    ) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final width in [600.0, 1200.0]) {
          final controller = controllerFor([_UiReaderEngine()]);
          await pumpReader(
            tester,
            document: document('Menu colors'),
            controller: controller,
            size: Size(width, 1000),
            themeMode: brightness == Brightness.light
                ? ThemeMode.dark
                : ThemeMode.light,
            initialPreferences: ReaderPreferences(brightness: brightness),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Reading settings'));
          await tester.pumpAndSettle();
          for (final pair in [
            ('System', 'Monospace'),
            ('Paginated', 'Continuous scroll'),
            ('Automatic', 'Double'),
          ]) {
            await tester.ensureVisible(find.text(pair.$1).first);
            await tester.tap(find.text(pair.$1).first);
            await tester.pumpAndSettle();
            final option = find.text(pair.$2).last;
            final menuTheme = Theme.of(tester.element(option));
            expect(menuTheme.brightness, brightness);
            expect(menuTheme.canvasColor, menuTheme.colorScheme.surface);
            final text = tester.widget<RichText>(
              find
                  .descendant(of: option, matching: find.byType(RichText))
                  .first,
            );
            final foreground = text.text.style!.color!.computeLuminance();
            final background = menuTheme.canvasColor.computeLuminance();
            expect(
              (math.max(foreground, background) + .05) /
                  (math.min(foreground, background) + .05),
              greaterThanOrEqualTo(4.5),
            );
            await tester.tap(option);
            await tester.pumpAndSettle();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        }
      }
    });

    testWidgets(
      'settings text follows reader appearance in opposite app themes',
      (tester) async {
        for (final brightness in [Brightness.dark, Brightness.light]) {
          final engine = _UiReaderEngine();
          final controller = controllerFor([engine]);
          final preferences = ReaderPreferences(brightness: brightness);
          await pumpReader(
            tester,
            document: document('Opposite theme'),
            controller: controller,
            size: const Size(1200, 800),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.light
                : ThemeMode.dark,
            initialPreferences: preferences,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Reading settings'));
          await tester.pumpAndSettle();
          final label = find.text('Page appearance');
          final theme = Theme.of(tester.element(label));
          expect(theme.brightness, brightness);
          final rich = tester.widget<RichText>(
            find.descendant(of: label, matching: find.byType(RichText)),
          );
          expect(rich.text.style!.color, theme.colorScheme.onSurface);
          final dropdown = find.text('Paginated');
          final dropdownText = tester.widget<RichText>(
            find
                .descendant(of: dropdown, matching: find.byType(RichText))
                .first,
          );
          expect(dropdownText.text.style!.color, theme.colorScheme.onSurface);
          for (final chip in tester.widgetList<ChoiceChip>(
            find.byType(ChoiceChip),
          )) {
            final label = find.text((chip.label as Text).data!);
            final text = tester.widget<RichText>(
              find.descendant(of: label, matching: find.byType(RichText)).first,
            );
            final foreground = text.text.style!.color!.computeLuminance();
            final background = chip.color!.resolve({
              if (chip.selected) WidgetState.selected,
            })!.computeLuminance();
            final contrast =
                (math.max(foreground, background) + .05) /
                (math.min(foreground, background) + .05);
            expect(
              contrast,
              greaterThanOrEqualTo(4.5),
              reason: 'Every appearance option must stay readable',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        }
      },
    );

    testWidgets(
      'an open mobile panel updates its theme when Night is selected',
      (tester) async {
        final engine = _UiReaderEngine();
        final controller = controllerFor([engine]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Live sheet'),
          controller: controller,
          size: const Size(600, 1000),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reading settings'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Night'));
        await tester.tap(find.text('Night'));
        await tester.pumpAndSettle();
        final label = find.text('Page appearance');
        final theme = Theme.of(tester.element(label));
        expect(theme.brightness, Brightness.dark);
        final rich = tester.widget<RichText>(
          find.descendant(of: label, matching: find.byType(RichText)),
        );
        expect(rich.text.style!.color, theme.colorScheme.onSurface);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('moves from a usable loading state to the engine viewport', (
      tester,
    ) async {
      final gate = Completer<void>();
      final engine = _UiReaderEngine(loadGate: gate);
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);

      await pumpReader(
        tester,
        document: document('Loading'),
        controller: controller,
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Opening The Loading Reader…'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('reader-viewport')), findsOneWidget);
      expect(find.text('The Loading Reader'), findsOneWidget);
      expect(find.byTooltip('Table of contents'), findsOneWidget);
      expect(find.byTooltip('Reading settings'), findsOneWidget);
    });

    testWidgets('compact chrome opens TOC and settings as bottom sheets', (
      tester,
    ) async {
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Compact'),
        controller: controller,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Table of contents'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Chapter one'), findsOneWidget);

      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Reading mode'), findsOneWidget);
    });

    testWidgets('compact settings rebuild and preserve sequential edits', (
      tester,
    ) async {
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Reactive settings'),
        controller: controller,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();

      Slider fontSlider() => tester
          .widgetList<Slider>(find.byType(Slider))
          .singleWhere((slider) => slider.max == 72);
      Slider lineHeightSlider() => tester
          .widgetList<Slider>(find.byType(Slider))
          .singleWhere((slider) => slider.max == 2.5);

      fontSlider().onChanged!(26);
      fontSlider().onChangeEnd!(26);
      await tester.pump();

      expect(fontSlider().value, 26);
      expect(controller.snapshot.preferences.fontSize, 26);

      lineHeightSlider().onChanged!(2);
      lineHeightSlider().onChangeEnd!(2);
      await tester.pump();

      expect(lineHeightSlider().value, 2);
      expect(controller.snapshot.preferences.fontSize, 26);
      expect(controller.snapshot.preferences.lineHeight, 2);
    });

    testWidgets(
      'settings sliders preview locally and commit once on change end',
      (tester) async {
        final engine = _UiReaderEngine();
        final controller = controllerFor([engine]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Coalesced settings'),
          controller: controller,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reading settings'));
        await tester.pumpAndSettle();

        Slider fontSlider() => tester
            .widgetList<Slider>(find.byType(Slider))
            .singleWhere((slider) => slider.max == 72);

        fontSlider().onChangeStart!(18);
        fontSlider().onChanged!(22);
        await tester.pump();
        fontSlider().onChanged!(28);
        await tester.pump();

        expect(fontSlider().value, 28);
        expect(engine.preferenceCalls, isEmpty);
        expect(controller.snapshot.preferences.fontSize, 18);

        fontSlider().onChangeEnd!(28);
        await tester.pump();

        expect(engine.preferenceCalls, hasLength(1));
        expect(engine.preferenceCalls.single.fontSize, 28);
        expect(controller.snapshot.preferences.fontSize, 28);
      },
    );

    testWidgets(
      'failed settings commits restore the authoritative slider value',
      (tester) async {
        final engine = _UiReaderEngine(
          preferenceFailure: const ReaderException(
            ReaderErrorCode.invalidDocument,
            'Could not apply reading settings.',
          ),
        );
        final controller = controllerFor([engine]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Failed settings'),
          controller: controller,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Reading settings'));
        await tester.pumpAndSettle();

        Slider fontSlider() => tester
            .widgetList<Slider>(find.byType(Slider))
            .singleWhere((slider) => slider.max == 72);

        fontSlider().onChangeStart!(18);
        fontSlider().onChanged!(28);
        fontSlider().onChangeEnd!(28);
        await tester.pumpAndSettle();

        expect(fontSlider().value, 18);
        expect(controller.snapshot.preferences.fontSize, 18);
        expect(find.text('Could not apply reading settings.'), findsOneWidget);
      },
    );

    testWidgets('compact sheet closes before controller and document swap', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final firstEngine = _UiReaderEngine();
      final secondEngine = _UiReaderEngine();
      final firstController = controllerFor([firstEngine]);
      final secondController = controllerFor([secondEngine]);
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);

      Widget app(ReaderDocument selected, ReaderController controller) {
        return MaterialApp(
          home: PapyrusReader(document: selected, controller: controller),
        );
      }

      await tester.pumpWidget(app(document('First sheet'), firstController));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      await tester.pumpWidget(app(document('Second sheet'), secondController));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('The Second sheet Reader'), findsOneWidget);
      expect(secondController.snapshot.status, ReaderStatus.ready);
      expect(firstEngine.isDisposed, isFalse);
    });

    testWidgets('pending compact sheets are removed on immediate unmount', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      late StateSetter updateHost;
      var showReader = true;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return showReader
                  ? PapyrusReader(
                      document: document('Pending sheet'),
                      controller: controller,
                    )
                  : const SizedBox(key: ValueKey('reader-removed'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Reading settings'));
      updateHost(() => showReader = false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('reader-removed')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide chrome uses the full viewport until a panel is opened', (
      tester,
    ) async {
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Wide'),
        controller: controller,
        size: const Size(1100, 800),
      );
      await tester.pumpAndSettle();

      final viewportBefore = tester.getSize(
        find.byKey(const ValueKey('reader-viewport')),
      );
      expect(find.byKey(const ValueKey('reader-side-panel')), findsNothing);
      await tester.tap(find.byTooltip('Table of contents'));
      await tester.pumpAndSettle();
      final viewportAfter = tester.getSize(
        find.byKey(const ValueKey('reader-viewport')),
      );

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('reader-side-panel')), findsOneWidget);
      expect(find.text('Chapter one'), findsOneWidget);
      expect(viewportAfter.width, lessThan(viewportBefore.width));
      expect(viewportAfter.height, viewportBefore.height);

      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      expect(find.text('Reading mode'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('reader-viewport'))),
        viewportAfter,
      );
      await tester.tap(find.byTooltip('Close panel'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('reader-viewport'))),
        viewportBefore,
      );
    });

    testWidgets('TOC entries navigate and PDF settings hide text controls', (
      tester,
    ) async {
      final engine = _UiReaderEngine(
        capabilities: const ReaderCapabilities(
          supportsPagination: true,
          supportsScrolling: true,
          supportsColumnMode: true,
        ),
      );
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('PDF', format: ReaderFormat.pdf),
        controller: controller,
        size: const Size(1100, 800),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Table of contents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chapter one'));
      await tester.pump();

      expect(engine.goToCalls, [engine.toc.single.locator]);

      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();

      expect(find.text('Font size'), findsNothing);
      expect(find.text('Line height'), findsNothing);
      expect(find.text('Margins'), findsNothing);
      expect(find.text('Reading mode'), findsOneWidget);
    });

    testWidgets('slider, buttons, and keyboard delegate navigation', (
      tester,
    ) async {
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Navigate'),
        controller: controller,
      );
      await tester.pumpAndSettle();

      final slider = tester.widget<Slider>(find.byType(Slider).first);
      slider.onChangeEnd!(0.75);
      await tester.pump();
      await tester.tap(find.byTooltip('Previous'));
      await tester.tap(find.byTooltip('Next'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();

      expect(engine.goToProgressCalls, [0.75]);
      expect(engine.goPreviousCallCount, 2);
      expect(engine.goNextCallCount, 2);

      final previous = tester.getSize(find.byTooltip('Previous'));
      final next = tester.getSize(find.byTooltip('Next'));
      expect(previous.width, greaterThanOrEqualTo(44));
      expect(previous.height, greaterThanOrEqualTo(44));
      expect(next.width, greaterThanOrEqualTo(44));
      expect(next.height, greaterThanOrEqualTo(44));
    });

    testWidgets(
      'navigation commands serialize and expose disabled busy controls',
      (tester) async {
        final firstGate = Completer<void>();
        final secondGate = Completer<void>();
        final engine = _UiReaderEngine(nextGates: [firstGate, secondGate]);
        final controller = controllerFor([engine]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Queued navigation'),
          controller: controller,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Next'));
        await tester.tap(find.byTooltip('Next'));
        await tester.pump();

        expect(engine.maxActiveNavigationCount, 1);
        expect(engine.navigationEvents, ['next-start-0']);
        expect(
          find.byKey(const ValueKey('reader-command-progress')),
          findsOneWidget,
        );
        final nextButton = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.chevron_right_rounded),
            matching: find.byType(IconButton),
          ),
        );
        expect(nextButton.onPressed, isNull);

        firstGate.complete();
        await tester.pump();
        expect(engine.navigationEvents, [
          'next-start-0',
          'next-end-0',
          'next-start-1',
        ]);
        expect(engine.maxActiveNavigationCount, 1);

        secondGate.complete();
        await tester.pumpAndSettle();
        expect(engine.navigationEvents.last, 'next-end-1');
        expect(
          find.byKey(const ValueKey('reader-command-progress')),
          findsNothing,
        );
      },
    );

    testWidgets('only navigation boundaries stay nonfatal', (tester) async {
      final engine = _UiReaderEngine(
        nextFailure: const ReaderException(
          ReaderErrorCode.invalidDocument,
          'The next section is invalid.',
        ),
        previousFailure: const ReaderException(
          ReaderErrorCode.navigationBoundary,
          'There is no previous section.',
        ),
      );
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Command errors'),
        controller: controller,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-command-error')), findsNothing);

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reader-command-error')),
        findsOneWidget,
      );
      expect(find.text('The next section is invalid.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('custom chrome honors the configured foreground color', (
      tester,
    ) async {
      const foreground = Color(0xffd0007f);
      const readerTheme = ReaderThemeData(
        chromeColor: Color(0xff101010),
        surfaceColor: Color(0xff202020),
        panelColor: Color(0xff181818),
        accentColor: Color(0xff00ffcc),
        progressColor: Color(0xff00ffcc),
        handleColor: Color(0xff00ffcc),
        errorColor: Color(0xffff5555),
        onChromeColor: foreground,
        dividerColor: Color(0xff444444),
      );
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Contrast'),
        controller: controller,
        readerTheme: readerTheme,
      );
      await tester.pumpAndSettle();

      final nextIcon = find.descendant(
        of: find.byTooltip('Next'),
        matching: find.byType(Icon),
      );
      expect(IconTheme.of(tester.element(nextIcon)).color, foreground);
      final progressLabel = tester.widget<Text>(
        find.byKey(const ValueKey('reader-progress-label')),
      );
      expect(
        DefaultTextStyle.of(
          tester.element(find.byKey(const ValueKey('reader-progress-label'))),
        ).style.color,
        foreground,
      );
      expect(progressLabel.data, '0%');
    });

    testWidgets(
      'wide panels receive focus, close on Escape, and restore opener',
      (tester) async {
        final engine = _UiReaderEngine();
        final controller = controllerFor([engine]);
        addTearDown(controller.dispose);
        await pumpReader(
          tester,
          document: document('Keyboard panel'),
          controller: controller,
          size: const Size(1100, 800),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Table of contents'));
        await tester.pump();

        final panelFocus = tester.widget<Focus>(
          find.byKey(const ValueKey('reader-wide-panel-focus')),
        );
        expect(panelFocus.focusNode!.hasFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(find.text('Chapter one'), findsNothing);
        expect(
          Focus.of(
            tester.element(find.byKey(const ValueKey('reader-toc-button'))),
          ).hasFocus,
          isTrue,
        );
      },
    );

    testWidgets('wide panels restore a custom toolbar opener', (tester) async {
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      final customOpener = FocusNode(debugLabel: 'custom settings opener');
      final focusDecoy = FocusNode(debugLabel: 'custom focus decoy');
      addTearDown(controller.dispose);
      addTearDown(customOpener.dispose);
      addTearDown(focusDecoy.dispose);
      await pumpReader(
        tester,
        document: document('Custom keyboard panel'),
        controller: controller,
        size: const Size(1100, 800),
        builders: ReaderUiBuilders(
          toolbar: (context, state) => SizedBox(
            height: 56,
            child: Row(
              children: [
                TextButton(
                  key: const ValueKey('custom-settings-opener'),
                  focusNode: customOpener,
                  onPressed: state.openSettings,
                  child: const Text('Custom settings'),
                ),
                TextButton(
                  focusNode: focusDecoy,
                  onPressed: () {},
                  child: const Text('Focus decoy'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      customOpener.requestFocus();
      await tester.pump();
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('custom-settings-opener')),
          )
          .onPressed!();
      await tester.pump();

      expect(customOpener.hasFocus, isFalse);
      final panelFocus = tester
          .widget<Focus>(find.byKey(const ValueKey('reader-wide-panel-focus')))
          .focusNode!;
      expect(panelFocus.hasFocus, isTrue);

      focusDecoy.requestFocus();
      await tester.pump();
      panelFocus.requestFocus();
      await tester.pump();
      expect(panelFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(customOpener.hasFocus, isTrue);
    });

    testWidgets('error state retries and state builders can replace defaults', (
      tester,
    ) async {
      final failure = ReaderException(
        ReaderErrorCode.invalidDocument,
        'This file needs attention.',
      );
      final failedEngine = _UiReaderEngine(loadFailure: failure);
      final recoveredEngine = _UiReaderEngine();
      final controller = controllerFor([failedEngine, recoveredEngine]);
      addTearDown(controller.dispose);
      await pumpReader(
        tester,
        document: document('Retry'),
        controller: controller,
        builders: ReaderUiBuilders(
          loading: (context, state) => const Text('Custom loading'),
          error: (context, state) => Column(
            children: [
              const Text('Custom error'),
              TextButton(
                onPressed: state.retry,
                child: const Text('Try custom'),
              ),
            ],
          ),
        ),
      );

      expect(find.text('Custom loading'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Custom error'), findsOneWidget);

      await tester.tap(find.text('Try custom'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('reader-viewport')), findsOneWidget);
    });

    testWidgets(
      'external controllers survive unmount and callbacks observe data',
      (tester) async {
        final engine = _UiReaderEngine();
        final controller = controllerFor([engine]);
        final locators = <ReaderLocator>[];
        final preferences = <ReaderPreferences>[];
        await pumpReader(
          tester,
          document: document('External'),
          controller: controller,
          onLocatorChanged: locators.add,
          onPreferencesChanged: preferences.add,
        );
        await tester.pumpAndSettle();

        await engine.goToProgress(0.4);
        await controller.updatePreferences(
          const ReaderPreferences(fontSize: 24),
        );
        await tester.pump();

        expect((locators.last as EpubReaderLocator).totalProgression, 0.4);
        expect(preferences.last.fontSize, 24);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(engine.isDisposed, isFalse);

        controller.dispose();
        expect(engine.isDisposed, isTrue);
      },
    );

    testWidgets(
      'external controller preferences survive a dark ambient theme when omitted',
      (tester) async {
        const externalPreferences = ReaderPreferences(
          fontSize: 31,
          backgroundColor: Color(0xfff4ecd8),
          foregroundColor: Color(0xff3d3527),
          brightness: Brightness.light,
        );
        final engine = _UiReaderEngine();
        final controller = controllerFor([
          engine,
        ], initialPreferences: externalPreferences);
        addTearDown(controller.dispose);

        await pumpReader(
          tester,
          document: document('External dark host'),
          controller: controller,
          themeMode: ThemeMode.dark,
        );
        await tester.pumpAndSettle();

        expect(controller.snapshot.preferences, externalPreferences);
        expect(engine.loadedPreferences, externalPreferences);
      },
    );

    testWidgets(
      'explicit dark preferences override external state in a light ambient theme',
      (tester) async {
        const externalPreferences = ReaderPreferences(fontSize: 31);
        const explicitPreferences = ReaderPreferences(
          fontSize: 22,
          backgroundColor: Color(0xff151719),
          foregroundColor: Color(0xffece7de),
          brightness: Brightness.dark,
        );
        final engine = _UiReaderEngine();
        final controller = controllerFor([
          engine,
        ], initialPreferences: externalPreferences);
        addTearDown(controller.dispose);

        await pumpReader(
          tester,
          document: document('Explicit preferences'),
          controller: controller,
          initialPreferences: explicitPreferences,
        );
        await tester.pumpAndSettle();

        expect(controller.snapshot.preferences, explicitPreferences);
        expect(engine.loadedPreferences, explicitPreferences);
      },
    );

    testWidgets(
      'document replacement ignores stale completion and loads latest',
      (tester) async {
        final firstGate = Completer<void>();
        final firstEngine = _UiReaderEngine(loadGate: firstGate);
        final secondEngine = _UiReaderEngine();
        final controller = controllerFor([firstEngine, secondEngine]);
        addTearDown(controller.dispose);

        Widget app(ReaderDocument selected) {
          return MaterialApp(
            home: PapyrusReader(document: selected, controller: controller),
          );
        }

        await tester.pumpWidget(app(document('First')));
        await tester.pumpWidget(app(document('Second')));
        firstGate.complete();
        await tester.pumpAndSettle();

        expect(controller.snapshot.document!.id, 'Second');
        expect(find.text('The Second Reader'), findsOneWidget);
        expect(firstEngine.isDisposed, isTrue);
      },
    );

    testWidgets('light, dark, and 200 percent text render without overflow', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final engine = _UiReaderEngine();
      final controller = controllerFor([engine]);
      addTearDown(controller.dispose);

      await pumpReader(
        tester,
        document: document('Accessible'),
        controller: controller,
        themeMode: ThemeMode.dark,
        textScale: 2,
      );
      await tester.pumpAndSettle();
      final exception = tester.takeException();

      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(PapyrusReader),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, isNot(Colors.white));
      expect(exception, isNull);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Reading progress',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}

final class _UiReaderEngine extends ReaderEngine {
  _UiReaderEngine({
    this.viewportBuilder,
    this.loadGate,
    this.loadFailure,
    this.nextGates = const [],
    this.nextFailure,
    this.previousFailure,
    this.preferenceFailure,
    this.capabilities = const ReaderCapabilities(
      supportsPagination: true,
      supportsScrolling: true,
      supportsTextCustomization: true,
      supportsColumnMode: true,
    ),
  });

  final Completer<void>? loadGate;
  final Widget Function(BuildContext, ReaderSnapshot)? viewportBuilder;
  final ReaderException? loadFailure;
  final List<Completer<void>> nextGates;
  final ReaderException? nextFailure;
  final ReaderException? previousFailure;
  final ReaderException? preferenceFailure;

  @override
  final ReaderCapabilities capabilities;

  @override
  Set<ReaderFormat> get supportedFormats => const {
    ReaderFormat.epub,
    ReaderFormat.pdf,
  };

  @override
  ReaderSnapshot snapshot = const ReaderIdleSnapshot();

  final toc = [
    ReaderTocEntry(
      title: 'Chapter one',
      locator: EpubReaderLocator(
        cfi: 'epubcfi(/6/2!/4/1:0)',
        spineIndex: 0,
        localProgression: 0,
        totalProgression: 0,
      ),
      children: [
        ReaderTocEntry(
          title: 'A nested section',
          locator: EpubReaderLocator(
            cfi: 'epubcfi(/6/2!/4/2:0)',
            spineIndex: 0,
            localProgression: 0.2,
            totalProgression: 0.1,
          ),
        ),
      ],
    ),
  ];
  final List<ReaderLocator> goToCalls = [];
  final List<double> goToProgressCalls = [];
  int goNextCallCount = 0;
  int goPreviousCallCount = 0;
  bool isDisposed = false;
  ReaderPreferences? loadedPreferences;
  final List<ReaderPreferences> preferenceCalls = [];
  final List<String> navigationEvents = [];
  int activeNavigationCount = 0;
  int maxActiveNavigationCount = 0;

  @override
  Widget buildViewport(BuildContext context) {
    if (viewportBuilder case final builder?) {
      return builder(context, snapshot);
    }
    return const ColoredBox(
      key: ValueKey('reader-viewport'),
      color: Colors.transparent,
      child: Center(child: Text('Engine content')),
    );
  }

  @override
  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    required ReaderPreferences preferences,
  }) async {
    loadedPreferences = preferences;
    await loadGate?.future;
    if (loadFailure case final failure?) {
      throw failure;
    }

    snapshot = ReaderReadySnapshot(
      document: document,
      preferences: preferences,
      capabilities: capabilities,
      locator:
          initialLocator ??
          EpubReaderLocator(
            cfi: 'epubcfi(/6/2!/4/1:0)',
            spineIndex: 0,
            localProgression: 0,
            totalProgression: 0,
          ),
      toc: toc,
    );
    notifyListeners();
  }

  @override
  Future<void> goTo(ReaderLocator locator) async {
    goToCalls.add(locator);
    _publishLocator(locator);
  }

  @override
  Future<void> goToProgress(double progress) async {
    goToProgressCalls.add(progress);
    _publishLocator(
      EpubReaderLocator(
        cfi: 'epubcfi(/6/2!/4/1:${(progress * 100).round()})',
        spineIndex: 0,
        localProgression: progress,
        totalProgression: progress,
      ),
    );
  }

  @override
  Future<void> goNext() async {
    final call = goNextCallCount++;
    activeNavigationCount++;
    maxActiveNavigationCount = math.max(
      maxActiveNavigationCount,
      activeNavigationCount,
    );
    navigationEvents.add('next-start-$call');
    try {
      if (call < nextGates.length) {
        await nextGates[call].future;
      }
      final failure = nextFailure;
      if (failure != null) {
        throw failure;
      }
    } finally {
      navigationEvents.add('next-end-$call');
      activeNavigationCount--;
    }
  }

  @override
  Future<void> goPrevious() async {
    goPreviousCallCount++;
    final failure = previousFailure;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<ReaderLocator?> currentLocator() async => snapshot.locator;

  @override
  Future<void> updatePreferences(ReaderPreferences preferences) async {
    preferenceCalls.add(preferences);
    final failure = preferenceFailure;
    if (failure != null) {
      throw failure;
    }

    final current = snapshot;
    snapshot = ReaderReadySnapshot(
      document: current.document!,
      preferences: preferences,
      capabilities: capabilities,
      locator: current.locator,
      toc: current.toc,
    );
    notifyListeners();
  }

  void _publishLocator(ReaderLocator locator) {
    final current = snapshot;
    snapshot = ReaderReadySnapshot(
      document: current.document!,
      preferences: current.preferences,
      capabilities: capabilities,
      locator: locator,
      toc: current.toc,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    isDisposed = true;
    super.dispose();
  }
}

final class _SnapshotViewport extends StatefulWidget {
  const _SnapshotViewport({required this.progression});

  final double progression;

  @override
  State<_SnapshotViewport> createState() => _SnapshotViewportState();
}

final class _SnapshotViewportState extends State<_SnapshotViewport> {
  @override
  Widget build(BuildContext context) =>
      Text('Custom position ${(widget.progression * 100).toStringAsFixed(0)}');
}
