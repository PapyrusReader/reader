import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader_example/main.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_processor.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_worker.dart';

void main() {
  testWidgets('chooses a document, changes theme, and reopens the reader', (
    tester,
  ) async {
    final memory = DemoReaderMemory();
    await tester.pumpWidget(
      PapyrusReaderDemoApp(memory: memory, registry: testRegistry()),
    );

    expect(find.text('Papyrus Reader'), findsOneWidget);
    expect(find.text('A small library, thoughtfully read.'), findsOneWidget);
    expect(find.text('The Garden Letter'), findsOneWidget);
    expect(find.text('A Tiny PDF'), findsOneWidget);

    await tester.tap(find.byTooltip('Use dark theme'));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    final readEpub = find.widgetWithText(FilledButton, 'Read EPUB');
    await tester.scrollUntilVisible(readEpub, 200);
    await tester.tap(readEpub);
    await tester.pumpAndSettle();

    expect(find.byType(PapyrusReader), findsOneWidget);

    final progressSlider = tester.widget<Slider>(find.byType(Slider));
    progressSlider.onChangeEnd!(0.65);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
    final fontSlider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max == 72);
    fontSlider.onChanged!(25);
    fontSlider.onChangeEnd!(25);
    await tester.pumpAndSettle();

    expect(
      (memory.locatorFor('garden-letter') as EpubReaderLocator)
          .totalProgression,
      0.65,
    );
    expect(memory.preferencesFor('garden-letter')!.fontSize, 25);

    await tester.tap(find.byTooltip('Close panel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('A small library, thoughtfully read.'), findsOneWidget);

    await tester.scrollUntilVisible(readEpub, 200);
    await tester.tap(readEpub);
    await tester.pumpAndSettle();
    expect(find.byType(PapyrusReader), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0.65);

    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
    final restoredFontSlider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max == 72);
    expect(restoredFontSlider.value, 25);
  });

  testWidgets('opens the bundled PDF reader', (tester) async {
    await tester.pumpWidget(PapyrusReaderDemoApp(registry: testRegistry()));

    final readPdf = find.widgetWithText(FilledButton, 'Read PDF');
    await tester.scrollUntilVisible(readPdf, 300);
    await tester.tap(readPdf);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PapyrusReader), findsOneWidget);
  });
}

ReaderEngineRegistry testRegistry() => ReaderEngineRegistry([
  ReaderEngineRegistration(
    formats: const {ReaderFormat.epub},
    factory: () => EpubReaderEngine(workerFactory: () async => _TestWorker()),
  ),
  ReaderEngineRegistration(
    formats: const {ReaderFormat.pdf},
    factory: PdfReaderEngine.new,
  ),
]);

final class _TestWorker implements EpubWorker {
  final EpubProcessor processor = EpubProcessor();
  @override
  Future<Map<String, Object?>> request(String command, Object? argument) =>
      processor.dispatch(command, argument);
  @override
  void dispose() {}
}
