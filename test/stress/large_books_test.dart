import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/pdfium_test_setup.dart';

// Opt in with PAPYRUS_LARGE_BOOKS pointing to the downloaded stress corpus.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final directory = Platform.environment['PAPYRUS_LARGE_BOOKS'];
  const cases = {
    'websters-dictionary.epub': ReaderFormat.epub,
    'websters-dictionary.txt': ReaderFormat.txt,
    'websters-dictionary.mobi': ReaderFormat.mobi,
    'websters-dictionary.azw3': ReaderFormat.azw3,
    'alice-high-resolution.pdf': ReaderFormat.pdf,
    'whiz-272-pages.cbz': ReaderFormat.cbz,
    'whiz-272-pages.cbr': ReaderFormat.cbr,
  };

  group(
    'large real-book corpus',
    () {
      setUpAll(initializePdfiumForTest);

      for (final entry in cases.entries) {
        test(entry.key, () async {
          final document = ReaderDocument(
            id: entry.key,
            format: entry.value,
            loadBytes: () => File('$directory/${entry.key}').readAsBytes(),
          );
          final engine = ReaderEngineRegistry.defaults().resolve(entry.value);
          addTearDown(engine.dispose);
          final clock = Stopwatch()..start();
          var ticks = 0;
          var lastTick = 0;
          var longestGap = 0;
          var peakRss = ProcessInfo.currentRss;
          final heartbeat = Timer.periodic(const Duration(milliseconds: 16), (
            _,
          ) {
            final now = clock.elapsedMilliseconds;
            final gap = now - lastTick;
            if (gap > longestGap) longestGap = gap;
            lastTick = now;
            ticks++;
            final rss = ProcessInfo.currentRss;
            if (rss > peakRss) peakRss = rss;
          });
          addTearDown(heartbeat.cancel);

          await engine.load(document, preferences: const ReaderPreferences());
          final openMs = clock.elapsedMilliseconds;
          expect(engine.snapshot.status, ReaderStatus.ready);
          expect(ticks, greaterThan(0));
          await engine.goToProgress(.9);
          final locator = (await engine.currentLocator())!;
          final serialized = ReaderLocator.fromJson(locator.toJson());
          expect(serialized, locator);
          final progress = switch (locator) {
            EpubReaderLocator() => locator.totalProgression,
            PdfReaderLocator() => locator.totalProgression,
          };
          expect(progress, closeTo(.9, .02));
          await engine.goToProgress(.1);
          await engine.goTo(serialized);
          expect(await engine.currentLocator(), locator);
          expect(engine.snapshot.status, ReaderStatus.ready);
          heartbeat.cancel();
          stdout.writeln(
            jsonEncode({
              'file': entry.key,
              'openMs': openMs,
              'openAndSeekMs': clock.elapsedMilliseconds,
              'heartbeatTicks': ticks,
              'longestEventLoopGapMs': longestGap,
              'peakTestProcessRssMiB': peakRss / (1024 * 1024),
            }),
          );
        }, timeout: const Timeout(Duration(minutes: 5)));
      }
    },
    skip: directory == null
        ? 'Set PAPYRUS_LARGE_BOOKS to run the opt-in corpus.'
        : false,
  );
}
