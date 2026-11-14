import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/pdf/pdf_facade.dart';
import 'package:papyrus_reader/src/presentation/reader_pdf_controls.dart';
import 'package:papyrus_reader/src/presentation/reader_pdf_search_panel.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../support/pdfium_test_setup.dart';

Future<Uint8List> _document({
  pdf.PdfPageFormat? pageFormat,
  bool withLink = false,
  bool samePageLink = false,
  int pageCount = 3,
}) async {
  final document = pw.Document();
  for (var page = 1; page <= pageCount; page++) {
    document.addPage(
      pw.Page(
        pageFormat: pageFormat ?? pdf.PdfPageFormat.a4,
        build: (_) {
          if (!withLink) {
            return pw.Text('Needle on page $page');
          }

          if (samePageLink && page == 1) {
            return pw.Column(
              children: [
                pw.SizedBox(height: 80),
                pw.Link(
                  destination: 'local-footnote',
                  child: pw.Text('Footnote reference'),
                ),
                pw.Spacer(),
                pw.Anchor(
                  name: 'local-footnote',
                  child: pw.Text('Footnote text'),
                ),
              ],
            );
          }

          final content = switch (page) {
            1 => pw.Link(
              destination: 'footnote',
              child: pw.Text('Footnote reference'),
            ),
            2 => pw.Anchor(name: 'footnote', child: pw.Text('Footnote text')),
            _ => pw.Text('Page $page'),
          };
          return pw.Center(child: content);
        },
      ),
    );
  }
  return document.save();
}

Future<void> _ready(WidgetTester tester, PdfReaderTools tools) async {
  for (var attempt = 0; attempt < 100 && !tools.isReady; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(tools.isReady, isTrue);
}

Future<void> _navigate(WidgetTester tester, Future<void> operation) async {
  var completed = false;
  final pending = operation.whenComplete(() => completed = true);
  for (var attempt = 0; attempt < 100 && !completed; attempt++) {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(
    completed,
    isTrue,
    reason: 'PDF navigation must finish after the destination mounts',
  );
  await pending;
}

void main() {
  testWidgets(
    'PDF wheel turns respond to a one-pixel delta and preserve zoomed panning',
    (tester) async {
      final bytes = await tester.runAsync(() => _document());
      await tester.runAsync(initializePdfiumForTest);
      final facade = (await tester.runAsync(
        () => createPdfrxFacade(bytes!, sourceName: 'wheel-pdf'),
      ))!;
      final tools = facade as PdfReaderTools;
      addTearDown(() => (facade as DisposablePdfFacade).dispose());
      await tester.pumpWidget(
        MaterialApp(
          home: facade.buildViewport(
            PdfViewportConfiguration(
              pageIndex: 0,
              facingPages: false,
              backgroundColor: Colors.white,
              brightness: Brightness.light,
              layoutMode: ReaderLayoutMode.paginated,
              onPageChanged: (_) {},
            ),
          ),
        ),
      );
      await _ready(tester, tools);
      await tester.pumpAndSettle();
      final original = tester
          .widgetList<PdfViewer>(find.byType(PdfViewer))
          .firstWhere((viewer) => viewer.initialPageNumber == 1)
          .controller!;
      final page = original.document.pages.first;
      final text = (await tester.runAsync(() => page.loadText()))!;
      await tester.runAsync(
        () => original.textSelectionDelegate.selectWord(
          text.charRects.first.center.toOffsetInDocument(
            page: page,
            pageRect: original.layout.pageLayouts.first,
          ),
        ),
      );
      await tester.pump();
      expect(original.textSelectionDelegate.hasSelectedText, isTrue);
      for (final direction in [1, -1]) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(400, 300),
            scrollDelta: Offset(0, direction.toDouble()),
          ),
        );
        await tester.pumpAndSettle();
        await _ready(tester, tools);
        expect(tools.pageNumber, direction > 0 ? 2 : 1);
        expect(original.textSelectionDelegate.hasSelectedText, isFalse);
        expect(
          tester.widget<PageView>(find.byType(PageView)).physics,
          isNot(isA<NeverScrollableScrollPhysics>()),
        );
        expect(
          tester.widget<PageView>(find.byType(PageView)).controller!.page,
          direction > 0 ? 1 : 0,
        );
      }
      await tools.setZoom(tools.zoom * 2);
      await tester.pumpAndSettle();
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 300),
          scrollDelta: Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      expect(tools.pageNumber, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final facingPages in [false, true]) {
    testWidgets(
      'zoomed PDF wheel pans and turns at spread edges, facing $facingPages',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = await tester.runAsync(() => _document(pageCount: 5));
        await tester.runAsync(initializePdfiumForTest);
        final facade = (await tester.runAsync(
          () => createPdfrxFacade(bytes!, sourceName: 'zoomed-wheel'),
        ))!;
        final tools = facade as PdfReaderTools;
        addTearDown(() => (facade as DisposablePdfFacade).dispose());
        var reportedOffset = 0.0;
        await tester.pumpWidget(
          MaterialApp(
            home: facade.buildViewport(
              PdfViewportConfiguration(
                pageIndex: 0,
                facingPages: facingPages,
                backgroundColor: Colors.white,
                brightness: Brightness.light,
                layoutMode: ReaderLayoutMode.paginated,
                onPageChanged: (_) {},
                onPositionChanged: (_, offset) => reportedOffset = offset,
              ),
            ),
          ),
        );
        await _ready(tester, tools);
        await tester.pumpAndSettle();
        await tools.setZoom(tools.zoom * 3);
        await tester.pumpAndSettle();
        final zoom = tools.zoom;
        PdfViewerController controller() => tester
            .widgetList<PdfViewer>(find.byType(PdfViewer))
            .firstWhere(
              (viewer) => viewer.initialPageNumber == tools.pageNumber,
            )
            .controller!;
        Rect spread() => pdfSpreadRect(
          controller().layout,
          tools.pageNumber - 1,
          facingPages,
        );
        Future<void> wheel(Offset delta) async {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: const Offset(720, 450),
              scrollDelta: delta,
            ),
          );
          await tester.pumpAndSettle();
          await _ready(tester, tools);
          await tester.pump(const Duration(milliseconds: 120));
        }

        Future<void> pan(double distance) async {
          await tools.scrollVertically(distance);
          await tester.pumpAndSettle();
        }

        for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
          await pan(-100000);
          final top = controller().visibleRect.top;
          final drag = await tester.startGesture(
            const Offset(720, 450),
            kind: kind,
          );
          await tester.pump();
          await drag.moveBy(const Offset(0, -30));
          await tester.pump();
          await drag.moveBy(const Offset(0, -100));
          await tester.pump();
          expect(tools.pageNumber, 1);
          expect(controller().visibleRect.top, greaterThan(top));
          await drag.up();
          await tester.pumpAndSettle();
        }
        final left = controller().visibleRect.left;
        final touch = await tester.startGesture(const Offset(720, 450));
        await touch.moveBy(const Offset(-30, 0));
        await tester.pump();
        await touch.moveBy(const Offset(-100, 0));
        await tester.pump();
        expect(tools.pageNumber, 1, reason: 'Zoomed touch drags still pan');
        expect(controller().visibleRect.left, greaterThan(left));
        await touch.up();
        await tester.pumpAndSettle();
        await pan(-100000);
        final before = controller().visibleRect.top;
        await wheel(const Offset(0, 40));
        expect(tools.pageNumber, 1);
        expect(controller().visibleRect.top, greaterThan(before));
        await pan(-100000);
        await wheel(const Offset(0, -1));
        expect(tools.pageNumber, 1, reason: 'The first page is a boundary');
        await pan(100000);
        await wheel(const Offset(40, 0));
        expect(
          tools.pageNumber,
          1,
          reason: 'Horizontal zoomed input still pans',
        );
        await wheel(const Offset(0, 1));
        expect(tools.pageNumber, facingPages ? 3 : 2);
        expect(tools.zoom, closeTo(zoom, .001));
        expect(controller().visibleRect.top, closeTo(spread().top, .01));
        expect(reportedOffset, closeTo(0, .001));
        await wheel(const Offset(0, -1));
        expect(tools.pageNumber, 1);
        expect(tools.zoom, closeTo(zoom, .001));
        expect(controller().visibleRect.bottom, closeTo(spread().bottom, .01));
        expect(reportedOffset, greaterThan(0));
        final bottom = controller().visibleRect.top;
        await wheel(const Offset(0, -40));
        expect(
          tools.pageNumber,
          1,
          reason: 'Reverse input pans into the previous page',
        );
        expect(controller().visibleRect.top, lessThan(bottom));
        await _navigate(tester, facade.showPage(4, 0));
        await pan(100000);
        await wheel(const Offset(0, 1));
        expect(tools.pageNumber, 5, reason: 'The last page is a boundary');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final (kind, zoomed) in [
    (PointerDeviceKind.touch, false),
    (PointerDeviceKind.mouse, false),
    (PointerDeviceKind.mouse, true),
  ]) {
    for (final direction in [1, -1]) {
      testWidgets(
        'PDF $kind swipes can catch and continue a settling turn, direction $direction, zoomed $zoomed',
        (tester) async {
          final width = kind == PointerDeviceKind.mouse ? 1440.0 : 800.0;
          await tester.binding.setSurfaceSize(Size(width, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final bytes = await tester.runAsync(() => _document(pageCount: 6));
          await tester.runAsync(initializePdfiumForTest);
          final facade = (await tester.runAsync(
            () => createPdfrxFacade(bytes!, sourceName: 'repeat-swipes'),
          ))!;
          final tools = facade as PdfReaderTools;
          final initialPage = direction > 0 ? 0 : 5;
          await facade.showPage(initialPage, 0);
          addTearDown(() => (facade as DisposablePdfFacade).dispose());
          await tester.pumpWidget(
            MaterialApp(
              home: facade.buildViewport(
                PdfViewportConfiguration(
                  pageIndex: initialPage,
                  facingPages: false,
                  backgroundColor: Colors.white,
                  brightness: Brightness.light,
                  layoutMode: ReaderLayoutMode.paginated,
                  onPageChanged: (_) {},
                ),
              ),
            ),
          );
          await _ready(tester, tools);
          await tester.pumpAndSettle();
          if (zoomed) {
            await tools.setZoom(tools.zoom * 3);
            await tester.pumpAndSettle();
          }
          final initialZoom = tools.zoom;
          final original = tester
              .widgetList<PdfViewer>(find.byType(PdfViewer))
              .firstWhere(
                (viewer) => viewer.initialPageNumber == initialPage + 1,
              )
              .controller!;
          final originalCenter = original.visibleRect.center;
          var newViewers = 0;
          debugOnRebuildDirtyWidget = (element, builtOnce) {
            if (!builtOnce && element.widget is PdfViewer) newViewers++;
          };
          addTearDown(() => debugOnRebuildDirtyWidget = null);
          final pages = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          final first = await tester.startGesture(
            Offset(width / 2, 300),
            kind: kind,
          );
          await first.moveBy(Offset(-30.0 * direction, 0));
          await tester.pump();
          await first.moveBy(Offset(-width * .6 * direction, 0));
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            newViewers,
            0,
            reason: 'Speculative viewers must not initialize during a swipe',
          );
          if (zoomed) {
            expect(
              original.visibleRect.center.dx,
              closeTo(originalCenter.dx, .01),
            );
          }
          await first.up();
          await tester.pump(const Duration(milliseconds: 60));
          expect(pages.position.isScrollingNotifier.value, isTrue);
          final beforeCatch = pages.position.pixels;
          final second = await tester.startGesture(
            Offset(width / 2, 300),
            kind: kind,
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            pages.position.pixels,
            closeTo(beforeCatch, 1),
            reason: 'Touching a moving page must not snap it to an endpoint',
          );
          await second.moveBy(Offset(-30.0 * direction, 0));
          await tester.pump();
          final beforeDrag = pages.position.pixels;
          await second.moveBy(Offset(-120.0 * direction, 0));
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            pages.position.pixels,
            closeTo(beforeDrag + 120 * direction, 1),
          );
          await second.moveBy(Offset(-width * .82 * direction, 0));
          await tester.pump(const Duration(milliseconds: 80));
          await second.up();
          await tester.pumpAndSettle();
          expect(tools.pageNumber, direction > 0 ? 3 : 4);
          expect(tools.zoom, closeTo(initialZoom, .001));
          expect(tools.canReturn, isTrue);
          await _navigate(tester, tools.returnToPrevious());
          await tester.pumpAndSettle();
          expect(tools.pageNumber, initialPage + 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final zoomed in [false, true]) {
    testWidgets(
      'PDF mouse hold and release keeps navigation and selection alive, zoomed $zoomed',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = await tester.runAsync(() => _document());
        await tester.runAsync(initializePdfiumForTest);
        final facade = (await tester.runAsync(
          () => createPdfrxFacade(bytes!, sourceName: 'mouse-hold'),
        ))!;
        final tools = facade as PdfReaderTools;
        addTearDown(() => (facade as DisposablePdfFacade).dispose());
        await tester.pumpWidget(
          MaterialApp(
            home: facade.buildViewport(
              PdfViewportConfiguration(
                pageIndex: 0,
                facingPages: false,
                backgroundColor: Colors.white,
                brightness: Brightness.light,
                layoutMode: ReaderLayoutMode.paginated,
                onPageChanged: (_) {},
              ),
            ),
          ),
        );
        await _ready(tester, tools);
        await tester.pumpAndSettle();
        if (zoomed) {
          await tools.setZoom(tools.zoom * 2);
          await tester.pumpAndSettle();
        }
        final first = await tester.startGesture(
          const Offset(1250, 450),
          kind: PointerDeviceKind.mouse,
        );
        await first.moveBy(const Offset(-30, 0));
        await tester.pump();
        await first.moveBy(const Offset(-900, 0));
        await tester.pump(const Duration(milliseconds: 80));
        await first.up();
        await tester.pump(const Duration(milliseconds: 60));
        final held = await tester.startGesture(
          const Offset(1000, 450),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(seconds: 1));
        await held.up();
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 2);

        final viewer = tester
            .widgetList<PdfViewer>(find.byType(PdfViewer))
            .singleWhere((viewer) => viewer.initialPageNumber == 2);
        final controller = viewer.controller!;
        for (
          var attempt = 0;
          attempt < 100 && !controller.document.pages[1].isLoaded;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        final page = controller.document.pages[1];
        expect(page.isLoaded, isTrue);
        final text = (await tester.runAsync(() => page.loadText()))!;
        Offset character(int index) => controller.documentToGlobal(
          text.charRects[index].center.toOffsetInDocument(
            page: page,
            pageRect: controller.layout.pageLayouts[1],
          ),
        )!;
        final selection = await tester.startGesture(
          character(0),
          kind: PointerDeviceKind.mouse,
        );
        await selection.moveTo(character(12));
        await tester.pump();
        await selection.up();
        await tester.pumpAndSettle();
        expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
        expect(
          tools.pageNumber,
          2,
          reason: 'Selecting text must not turn the page',
        );
        await tester.tapAt(
          const Offset(1200, 450),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final reverse = await tester.startGesture(
          const Offset(190, 450),
          kind: PointerDeviceKind.mouse,
        );
        await reverse.moveBy(const Offset(30, 0));
        await tester.pump();
        await reverse.moveBy(const Offset(900, 0));
        await reverse.up();
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final initialZoom in [null, .5]) {
    testWidgets('PDF page pixels survive settling at zoom $initialZoom', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final document = pw.Document();

      for (final color in [
        const pdf.PdfColor(1, 0, 0),
        const pdf.PdfColor(0, 0, 1),
      ]) {
        document.addPage(
          pw.Page(
            pageTheme: pw.PageTheme(
              buildBackground: (_) => pw.FullPage(
                ignoreMargins: true,
                child: pw.Container(color: color),
              ),
            ),
            build: (_) => pw.Text('Rendered page'),
          ),
        );
      }

      final bytes = await tester.runAsync(document.save);
      await tester.runAsync(initializePdfiumForTest);
      final facade = (await tester.runAsync(
        () => createPdfrxFacade(bytes!, sourceName: 'settling-pdf'),
      ))!;
      final tools = facade as PdfReaderTools;
      addTearDown(() => (facade as DisposablePdfFacade).dispose());
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundaryKey,
            child: facade.buildViewport(
              PdfViewportConfiguration(
                pageIndex: 0,
                facingPages: false,
                backgroundColor: Colors.white,
                brightness: Brightness.light,
                layoutMode: ReaderLayoutMode.paginated,
                onPageChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await _ready(tester, tools);
      if (initialZoom != null) {
        await tools.setZoom(initialZoom);
        await tester.pumpAndSettle();
      }

      Future<List<int>> centerPixel() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final offset =
              (image.width * (image.height ~/ 2) + image.width ~/ 2) * 4;
          final pixel = data.buffer.asUint8List(offset, 3).toList();
          image.dispose();
          return pixel;
        }))!;
      }

      Future<void> waitForPixel(List<int> expected) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          if (listEquals(await centerPixel(), expected)) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(await centerPixel(), expected);
      }

      await waitForPixel([255, 0, 0]);
      for (final direction in [1, -1]) {
        final expected = direction > 0 ? [0, 0, 255] : [255, 0, 0];
        final gesture = await tester.startGesture(const Offset(400, 300));
        await gesture.moveBy(Offset(-30.0 * direction, 0));
        await tester.pump();
        await gesture.moveBy(Offset(-720.0 * direction, 0));
        await tester.pump();
        await waitForPixel(expected);
        await gesture.up();

        for (var frame = 0; frame < 90; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            await centerPixel(),
            expected,
            reason: 'direction $direction, settling frame $frame',
          );
        }

        expect(tools.pageNumber, direction > 0 ? 2 : 1);
        if (initialZoom != null) expect(tools.zoom, closeTo(initialZoom, .001));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final animation in [true, false]) {
    for (final facing in [false, true]) {
      testWidgets(
        'PDF touch turns track the finger, animation $animation, facing $facing',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(800, 600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final bytes = await tester.runAsync(_document);
          await tester.runAsync(initializePdfiumForTest);
          final facade = await tester.runAsync(
            () => createPdfrxFacade(bytes!, sourceName: 'drag-pdf'),
          );
          final tools = facade! as PdfReaderTools;
          addTearDown(() => (facade as DisposablePdfFacade).dispose());
          var page = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: facade.buildViewport(
                PdfViewportConfiguration(
                  pageIndex: 0,
                  facingPages: facing,
                  pageTurnAnimation: animation,
                  backgroundColor: Colors.white,
                  brightness: Brightness.light,
                  layoutMode: ReaderLayoutMode.paginated,
                  onPageChanged: (value) => page = value,
                ),
              ),
            ),
          );
          await _ready(tester, tools);
          await tester.pumpAndSettle();
          final viewport = find.byType(PageView);
          final bounds = tester.getRect(viewport);
          Finder spread(int index) =>
              find.byKey(ValueKey(('pdf-spread', index)));
          for (final direction in [1, -1]) {
            final oldPage = page;
            State? incomingState;
            final outgoing = spread(direction > 0 ? 0 : 1);
            final incoming = spread(direction > 0 ? 1 : 0);
            final gesture = await tester.startGesture(bounds.center);
            await gesture.moveBy(Offset(-30.0 * direction, 0));
            await tester.pump();
            for (final distance in [80.0, 90.0, 70.0]) {
              final oldLeft = tester.getTopLeft(outgoing).dx;
              await gesture.moveBy(Offset(-distance * direction, 0));
              await tester.pump(const Duration(milliseconds: 16));
              final current = tester.getRect(outgoing);
              expect(tester.getRect(viewport), bounds);
              if (animation) {
                final next = tester.getRect(incoming);
                expect(
                  current.left,
                  closeTo(oldLeft - distance * direction, 1),
                );
                expect(
                  direction > 0 ? current.right : next.right,
                  closeTo(direction > 0 ? next.left : current.left, .01),
                  reason: 'PDF spreads must remain adjacent, never overlap',
                );
              } else {
                expect(current, bounds);
              }
              expect(page, oldPage);
            }
            if (animation) {
              await gesture.cancel();
              await tester.pumpAndSettle();
              expect(page, oldPage);
              expect(tester.getRect(outgoing), bounds);
              final turn = await tester.startGesture(bounds.center);
              await turn.moveBy(Offset(-30.0 * direction, 0));
              await tester.pump();
              await turn.moveBy(Offset(-bounds.width * .65 * direction, 0));
              await tester.pump(const Duration(milliseconds: 16));
              expect(page, oldPage);
              incomingState = tester.state(
                find.descendant(of: incoming, matching: find.byType(PdfViewer)),
              );
              await turn.up();
            } else {
              await gesture.up();
            }
            await tester.pumpAndSettle();
            expect(page, direction > 0 ? (facing ? 2 : 1) : 0);
            expect(tester.getRect(incoming), bounds);
            if (incomingState != null) {
              expect(
                tester.state(
                  find.descendant(
                    of: incoming,
                    matching: find.byType(PdfViewer),
                  ),
                ),
                same(incomingState),
              );
            }
          }
          if (animation) {
            final fittedZoom = tools.zoom;
            final left = await tester.startGesture(
              bounds.center - const Offset(60, 0),
              pointer: 41,
            );
            final right = await tester.startGesture(
              bounds.center + const Offset(60, 0),
              pointer: 42,
            );
            await tester.pump();
            await left.moveBy(const Offset(-30, 0));
            await right.moveBy(const Offset(30, 0));
            await tester.pump(const Duration(milliseconds: 30));
            await left.moveBy(const Offset(-30, 0));
            await right.moveBy(const Offset(30, 0));
            await tester.pump(const Duration(milliseconds: 30));
            expect(
              tools.zoom,
              greaterThan(fittedZoom),
              reason: 'Pinching at fit size must zoom instead of paging',
            );
            await left.up();
            await right.up();
            await tester.pumpAndSettle();
            expect(page, 0);
          }

          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final explicit in [false, true]) {
    testWidgets(
      explicit
          ? 'explicit PDF locator overrides a saved center on the same page'
          : 'saved PDF view restores its page and center without a locator',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = await tester.runAsync(_document);
        await tester.runAsync(initializePdfiumForTest);
        final controller = ReaderController(
          registry: ReaderEngineRegistry.defaults(),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PapyrusReader(
              controller: controller,
              document: ReaderDocument(
                id: 'explicit-offset',
                format: ReaderFormat.pdf,
                loadBytes: () async => bytes!,
                initialPdfView: const PdfViewState(
                  pageIndex: 1,
                  zoom: 1.8,
                  centerX: .5,
                  centerY: .2,
                  fitMode: PdfFitMode.custom,
                ),
              ),
              initialLocator: explicit
                  ? PdfReaderLocator(
                      totalProgression: .5,
                      pageIndex: 1,
                      pageOffset: .55,
                    )
                  : null,
              initialPreferences: const ReaderPreferences(
                layoutMode: ReaderLayoutMode.scroll,
              ),
            ),
          ),
        );

        for (
          var attempt = 0;
          attempt < 100 && controller.pdfTools == null;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }

        await _ready(tester, controller.pdfTools!);
        PdfViewerController viewer() =>
            tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
        final page = viewer().layout.pageLayouts[1];
        expect(controller.pdfTools!.zoom, closeTo(1.8, .001));
        expect((controller.snapshot.locator as PdfReaderLocator).pageIndex, 1);
        if (explicit) {
          expect(
            (viewer().visibleRect.top - page.top) / page.height,
            closeTo(.55, .001),
          );
        } else {
          expect(
            (viewer().visibleRect.center.dy - page.top) / page.height,
            closeTo(.2, .001),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: kIsWeb,
    );
  }

  test('view preferences reject malformed values and round trip', () {
    const state = PdfViewState(
      pageIndex: 2,
      zoom: 1.37,
      centerX: .4,
      centerY: .7,
      fitMode: PdfFitMode.custom,
    );
    expect(PdfViewState.fromJson(state.toJson()).toJson(), state.toJson());
    for (final patch in [
      {'zoom': double.nan},
      {'zoom': 0},
      {'centerX': 2},
      {'pageIndex': -1},
      {'fitMode': 'invalid'},
    ]) {
      expect(
        () => PdfViewState.fromJson({...state.toJson(), ...patch}),
        throwsFormatException,
      );
    }
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    for (final samePage in [false, true]) {
      testWidgets(
        'PDF reference taps navigate immediately with $kind (same page: $samePage)',
        (tester) async {
          final bytes = await tester.runAsync(
            () => _document(withLink: true, samePageLink: samePage),
          );
          final facade = await tester.runAsync(() async {
            await initializePdfiumForTest();
            return createPdfrxFacade(bytes!, sourceName: 'footnotes-$kind');
          });
          final tools = facade! as PdfReaderTools;
          final controller = ReaderController(
            registry: ReaderEngineRegistry([
              ReaderEngineRegistration(
                formats: const {ReaderFormat.pdf},
                factory: () =>
                    PdfReaderEngine(facadeFactory: (_) async => facade),
              ),
            ]),
          );
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: PapyrusReader(
                controller: controller,
                document: ReaderDocument(
                  id: 'footnotes',
                  format: ReaderFormat.pdf,
                  title: 'Footnotes',
                  loadBytes: () async => bytes!,
                ),
              ),
            ),
          );
          await _ready(tester, tools);
          PdfViewerController viewer() =>
              tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
          final page = viewer().document.pages.first;
          final links = (await tester.runAsync(() => page.loadLinks()))!;
          final link = links.firstWhere((link) => link.dest != null);
          for (var frame = 0; frame < 10; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          if (samePage) {
            await tools.setZoom(1.5);
            await tester.pumpAndSettle();
          }
          final controls = find.byTooltip('Reading settings');
          expect(controls, findsNothing);
          await _navigate(tester, tools.goToPage(1));
          await tester.pumpAndSettle();
          final linkRect = link.rects.first.toRectInDocument(
            page: page,
            pageRect: viewer().layout.pageLayouts.first,
          );
          final drag = await tester.startGesture(
            viewer().documentToGlobal(linkRect.center)!,
            kind: kind,
          );
          await drag.moveBy(const Offset(0, 40));
          await tester.pump(const Duration(milliseconds: 50));
          await drag.up();
          await tester.pump(const Duration(milliseconds: 350));
          expect(tools.pageNumber, 1);
          expect(controls, findsNothing);
          await viewer().textSelectionDelegate.clearTextSelection();
          await tester.pump(const Duration(milliseconds: 350));

          for (final initiallyVisible in [false, true]) {
            await _navigate(tester, tools.goToPage(1));
            await tester.pumpAndSettle();
            final rect = link.rects.first.toRectInDocument(
              page: page,
              pageRect: viewer().layout.pageLayouts.first,
            );
            final original = viewer().visibleRect;
            await tester.tapAt(
              viewer().documentToGlobal(rect.center)!,
              kind: kind,
            );
            await tester.pump(const Duration(milliseconds: 16));
            expect(tools.pageNumber, samePage ? 1 : 2);
            if (samePage) {
              expect(viewer().visibleRect.top, greaterThan(original.top + 100));
            }
            final destination = viewer().visibleRect;
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pumpAndSettle();
            expect(viewer().visibleRect, destination);
            expect(controls, initiallyVisible ? findsOneWidget : findsNothing);
            final blank =
                tester.getCenter(find.byType(PdfViewer)) + const Offset(0, 100);
            await tester.tapAt(blank, kind: kind);
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pumpAndSettle();
            expect(controls, initiallyVisible ? findsNothing : findsOneWidget);
            await _navigate(tester, tools.returnToPrevious());
            await tester.pumpAndSettle();
            expect(
              (viewer().visibleRect.center - original.center).distance,
              lessThan(.001),
            );
          }
          controller.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('PDF shell keyboard zoom and search visibility', (tester) async {
    final bytes = await tester.runAsync(_document);
    final facade = await tester.runAsync(() async {
      await initializePdfiumForTest();
      return createPdfrxFacade(bytes!, sourceName: 'shell-tools');
    });
    final tools = facade! as PdfReaderTools;
    final controller = ReaderController(
      registry: ReaderEngineRegistry([
        ReaderEngineRegistration(
          formats: const {ReaderFormat.pdf},
          factory: () => PdfReaderEngine(facadeFactory: (_) async => facade),
        ),
      ]),
    );
    addTearDown(controller.dispose);
    final events = <ReaderActivityEvent>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PapyrusReader(
          controller: controller,
          document: ReaderDocument(
            id: 'shell-tools',
            format: ReaderFormat.pdf,
            title: 'PDF tools',
            loadBytes: () async => bytes!,
          ),
          onActivity: events.add,
        ),
      ),
    );
    await _ready(tester, tools);
    await tools.setZoom(1.37);
    await tester.pumpAndSettle();
    PdfViewerController viewer() =>
        tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      final top = viewer().visibleRect.top;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(viewer().visibleRect.top, greaterThan(top));
      final scrolledTop = viewer().visibleRect.top;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(viewer().visibleRect.top, lessThan(scrolledTop));
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tools.zoom, closeTo(1.42, .001));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final beforeScrolling = viewer().visibleRect.top;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    expect(viewer().visibleRect.top, closeTo(beforeScrolling + 50, .001));

    // Pointer interaction may instead leave focus in pdfrx's own key handler.
    viewer().requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final beforeViewerScroll = viewer().visibleRect.top;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(viewer().visibleRect.top, greaterThan(beforeViewerScroll));

    final toolbar = find.byKey(const ValueKey('reader-toolbar'));
    final progress = find.byKey(const ValueKey('reader-progress-controls'));
    final toolbarRect = tester.getRect(toolbar);
    final progressRect = tester.getRect(progress);
    final viewportRect = tester.getRect(find.byType(PdfViewer));
    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
    expect(controller.preferences.highlightLinks, isTrue);
    await tester.tap(find.text('Highlight links'));
    await tester.pumpAndSettle();
    expect(controller.preferences.highlightLinks, isFalse);
    final links = tester
        .widget<PdfViewer>(find.byType(PdfViewer))
        .params
        .linkHandlerParams!;
    links.customPainter!(
      _NoPaintCanvas(),
      viewer().layout.pageLayouts.first,
      viewer().document.pages.first,
      [
        PdfLink(const [
          PdfRect(0, 100, 100, 0),
        ], url: Uri.parse('https://example.com')),
      ],
    );
    expect(tester.getRect(find.byType(PdfViewer)), viewportRect);
    await tester.tap(find.byTooltip('Close panel'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byTooltip('Zoom in by 5%')).bottom,
      lessThanOrEqualTo(toolbarRect.bottom),
    );
    expect(progressRect.height, lessThanOrEqualTo(56));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Search in document'),
      findsOneWidget,
    );
    expect(events.last.visible, isFalse);
    final beforeInputArrow = viewer().visibleRect;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(viewer().visibleRect, beforeInputArrow);
    final panelRect = tester.getRect(find.byType(ReaderPdfSearchPanel));
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    final pageBeforeTyping = tools.pageNumber;
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Needle on',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    await tester.pump();
    expect(tools.query, 'Needle on');
    expect(tools.pageNumber, pageBeforeTyping);
    await tester.enterText(find.byType(TextField), 'Needle');
    for (
      var attempt = 0;
      attempt < 100 && tools.matches.length < 3;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(tools.matches.length, 3);
    await tester.pumpAndSettle();
    expect(tester.getRect(toolbar), toolbarRect);
    expect(tester.getRect(progress), progressRect);
    expect(tester.getRect(find.byType(PdfViewer)), viewportRect);
    expect(tester.getRect(find.byType(ReaderPdfSearchPanel)), panelRect);
    expect(tools.zoom, closeTo(1.42, .001));
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(events.last.visible, isTrue);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    await _ready(tester, tools);
    await tester.tap(find.byTooltip('Search in document'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ReaderPdfSearchPanel)).width, 390);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.tap(find.textContaining('Needle on page 2'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPdfSearchPanel), findsNothing);
    expect(tools.pageNumber, 2);
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ReaderLayoutMode.values) {
    testWidgets('PDF navigation back and forward restore locations in $mode', (
      tester,
    ) async {
      final bytes = await tester.runAsync(_document);
      final facade = await tester.runAsync(() async {
        await initializePdfiumForTest();
        return createPdfrxFacade(bytes!, sourceName: 'history-$mode');
      });
      final tools = facade! as PdfReaderTools;
      final controller = ReaderController(
        registry: ReaderEngineRegistry([
          ReaderEngineRegistration(
            formats: const {ReaderFormat.pdf},
            factory: () => PdfReaderEngine(facadeFactory: (_) async => facade),
          ),
        ]),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PapyrusReader(
            controller: controller,
            initialPreferences: ReaderPreferences(layoutMode: mode),
            document: ReaderDocument(
              id: 'history-$mode',
              format: ReaderFormat.pdf,
              title: 'PDF history',
              loadBytes: () async => bytes!,
            ),
          ),
        ),
      );
      await _ready(tester, tools);
      await tester.pumpAndSettle();
      expect(tools.canReturn, isFalse);
      expect(tools.canGoForward, isFalse);
      await tools.setZoom(1.5);
      await tester.pumpAndSettle();
      await tools.scrollVertically(100);
      await tester.pumpAndSettle();
      PdfViewerController viewer() =>
          tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
      final original = viewer().visibleRect;
      expect(tools.canReturn, isFalse);

      for (final page in [2, 3]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(tools.pageNumber, page);
        expect(tools.canReturn, isTrue);
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      for (final page in [2, 1]) {
        await tester.tap(find.byTooltip('Return to previous location'));
        await tester.pumpAndSettle();
        expect(tools.pageNumber, page);
        expect(tools.canGoForward, isTrue);
      }
      expect(tools.canReturn, isFalse);
      expect(
        (viewer().visibleRect.center - original.center).distance,
        lessThan(.001),
      );
      expect(tools.zoom, closeTo(1.5, .001));

      for (final page in [2, 3]) {
        await tester.tap(find.byTooltip('Go forward to next location'));
        await tester.pumpAndSettle();
        expect(tools.pageNumber, page);
      }
      expect(tools.canGoForward, isFalse);

      // An unchanged page entry must not add a duplicate history item.
      await _navigate(tester, tools.goToPage(3));
      await tester.pumpAndSettle();
      await _navigate(tester, tools.returnToPrevious());
      await tester.pumpAndSettle();
      expect(tools.pageNumber, 2);
      expect(tools.canGoForward, isTrue);
      await _navigate(tester, tools.goToPage(2));
      await tester.pumpAndSettle();
      expect(tools.canGoForward, isTrue);

      // A new progress/contents/bookmark jump replaces the forward branch.
      await _navigate(tester, controller.goToProgress(0));
      await tester.pumpAndSettle();
      expect(tools.pageNumber, 1);
      expect(tools.canGoForward, isFalse);
      final beforeLink = viewer().visibleRect;
      final params = tester.widget<PdfViewer>(find.byType(PdfViewer)).params;
      for (final page in [1, 3]) {
        params.linkHandlerParams!.onLinkTap(
          PdfLink([], dest: PdfDest(page, PdfDestCommand.xyz, [100, 400, 2])),
        );
        await tester.pumpAndSettle();
        final destination = viewer().visibleRect;
        expect(tools.pageNumber, page);
        expect(tools.zoom, closeTo(2, .001));
        await _navigate(tester, tools.returnToPrevious());
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 1);
        expect(
          (viewer().visibleRect.center - beforeLink.center).distance,
          lessThan(.001),
        );
        expect(tools.zoom, closeTo(1.5, .001));
        await _navigate(tester, tools.goForward());
        await tester.pumpAndSettle();
        expect(tools.pageNumber, page);
        expect(
          (viewer().visibleRect.center - destination.center).distance,
          lessThan(.001),
        );
        expect(tools.zoom, closeTo(2, .001));
        await _navigate(tester, tools.returnToPrevious());
        await tester.pumpAndSettle();
      }

      // Both actions remain available from the compact toolbar menu.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      await _ready(tester, tools);
      await tester.tap(find.byTooltip('More reader actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go forward to next location'));
      await tester.pumpAndSettle();
      expect(tools.pageNumber, 3);
      await tester.tap(find.byTooltip('More reader actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Return to previous location'));
      await tester.pumpAndSettle();
      expect(tools.pageNumber, 1);
      expect(tester.takeException(), isNull);
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('PDF fit page has no vertical travel above or below 100%', (
    tester,
  ) async {
    final facade = await tester.runAsync(() async {
      await initializePdfiumForTest();
      return createPdfrxFacade(
        await _document(pageFormat: const pdf.PdfPageFormat(300, 400)),
        sourceName: 'fit-page-bounds',
      );
    });
    final tools = facade! as PdfReaderTools;
    addTearDown(tools.dispose);

    for (final viewportSize in [const Size(800, 600), const Size(240, 360)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: viewportSize,
                child: facade.buildViewport(
                  PdfViewportConfiguration(
                    pageIndex: 0,
                    facingPages: false,
                    backgroundColor: Colors.white,
                    brightness: Brightness.light,
                    layoutMode: ReaderLayoutMode.paginated,
                    onPageChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _ready(tester, tools);
      await tools.fitPage();
      await tester.pumpAndSettle();
      PdfViewerController viewer() =>
          tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
      final fitted = viewer().visibleRect;
      expect(
        tools.zoom,
        closeTo(viewportSize.height == 600 ? 1.5 : .8, .000001),
      );
      expect(
        fitted.center.dx,
        closeTo(viewer().layout.pageLayouts.first.center.dx, .001),
      );
      expect(
        fitted.center.dy,
        closeTo(viewer().layout.pageLayouts.first.center.dy, .001),
      );

      for (final distance in [25.0, -25.0]) {
        await tools.scrollVertically(distance);
        await tester.pumpAndSettle();
        expect(viewer().visibleRect.top, closeTo(fitted.top, .001));
        expect(viewer().visibleRect.bottom, closeTo(fitted.bottom, .001));
        await tester.drag(find.byType(PdfViewer), Offset(0, distance * 4));
        await tester.pumpAndSettle();
        expect(viewer().visibleRect.top, closeTo(fitted.top, .001));
        expect(viewer().visibleRect.bottom, closeTo(fitted.bottom, .001));
      }
    }
  }, skip: kIsWeb);

  for (final mode in ReaderLayoutMode.values) {
    testWidgets(
      'PDF zoom, resize, page entry, search, links and return in $mode',
      (tester) async {
        PdfViewState? saved;
        Uri? opened;
        var visiblePage = 0;
        final facade = await tester.runAsync(() async {
          await initializePdfiumForTest();
          return createPdfrxFacade(
            await _document(),
            sourceName: 'tools-$mode',
            onViewChanged: (state) => saved = state,
            onOpenLink: (uri) async => opened = uri,
          );
        });
        final tools = facade! as PdfReaderTools;
        addTearDown(tools.dispose);
        var width = 800.0;
        Widget viewport() => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: 600,
                child: facade.buildViewport(
                  PdfViewportConfiguration(
                    pageIndex: 0,
                    facingPages: false,
                    backgroundColor: Colors.white,
                    brightness: Brightness.light,
                    layoutMode: mode,
                    onPageChanged: (page) => visiblePage = page,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(viewport());
        await _ready(tester, tools);
        PdfViewerController viewer() =>
            tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
        await tools.setZoom(1.37);
        await tester.pumpAndSettle();
        expect(tools.zoom, closeTo(1.37, .001));
        final pinchCenter = tester.getCenter(find.byType(PdfViewer));
        final leftFinger = await tester.createGesture(
          pointer: 41,
          kind: PointerDeviceKind.touch,
        );
        final rightFinger = await tester.createGesture(
          pointer: 42,
          kind: PointerDeviceKind.touch,
        );
        await leftFinger.down(pinchCenter - const Offset(60, 0));
        await rightFinger.down(pinchCenter + const Offset(60, 0));
        await tester.pump();
        await leftFinger.moveTo(pinchCenter - const Offset(70, 0));
        await rightFinger.moveTo(pinchCenter + const Offset(70, 0));
        await tester.pump(const Duration(milliseconds: 50));
        await leftFinger.moveTo(pinchCenter - const Offset(80, 0));
        await rightFinger.moveTo(pinchCenter + const Offset(80, 0));
        await tester.pump(const Duration(milliseconds: 50));
        final pinchedZoom = tools.zoom;
        expect(pinchedZoom, greaterThan(1.37));
        expect(pinchedZoom, lessThan(2));
        await leftFinger.up();
        await rightFinger.up();
        await tester.pumpAndSettle();
        expect(tools.zoom, closeTo(pinchedZoom, pinchedZoom * .011));
        expect(tools.pageNumber, 1);
        await tools.setZoom(1.37);
        await tester.pumpAndSettle();
        final center = viewer().visibleRect.center;
        await tools.setZoom(1.42);
        await tester.pumpAndSettle();
        expect(tools.zoom, closeTo(1.42, .001));
        expect((viewer().visibleRect.center - center).distance, lessThan(1));
        await _navigate(tester, tools.goToPage(2));
        await tester.pumpAndSettle();
        expect(visiblePage, 1);
        expect(tools.zoom, closeTo(1.42, .001));
        await _navigate(tester, tools.returnToPrevious());
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 1);
        width = 640;
        await tester.pumpWidget(viewport());
        await _ready(tester, tools);
        await tester.pumpAndSettle();
        expect(tools.zoom, closeTo(1.42, .001));
        await tester.pump(const Duration(milliseconds: 300));
        expect(saved!.zoom, closeTo(1.42, .001));
        await tools.fitWidth();
        await tester.pumpAndSettle();
        expect(
          tools.zoom,
          closeTo(640 / viewer().layout.pageLayouts.first.width, .000001),
        );
        final fittedPage = viewer().layout.pageLayouts.first;
        final fittedTop = viewer().visibleRect.top;
        expect(viewer().visibleRect.left, closeTo(fittedPage.left, .001));
        expect(viewer().visibleRect.right, closeTo(fittedPage.right, .001));

        for (final direction in [-1.0, 1.0]) {
          await tester.drag(
            find.byType(PdfViewer),
            Offset(100 * direction, -40),
          );
          await tester.pumpAndSettle();
          expect(viewer().visibleRect.left, closeTo(fittedPage.left, .001));
          expect(viewer().visibleRect.right, closeTo(fittedPage.right, .001));
        }

        expect(viewer().visibleRect.top, greaterThan(fittedTop));
        await tools.setZoom(tools.zoom * 1.5);
        await tester.pumpAndSettle();
        final zoomedLeft = viewer().visibleRect.left;
        await tester.drag(find.byType(PdfViewer), const Offset(-60, 0));
        await tester.pumpAndSettle();
        expect(viewer().visibleRect.left, greaterThan(zoomedLeft));

        await tools.setZoom(1.37);
        await tester.pumpAndSettle();
        tools.search('Needle');
        for (
          var attempt = 0;
          attempt < 100 && tools.matches.length < 3;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(tools.matches.length, 3);
        final selecting = tools.selectMatch(2);
        await tester.pumpAndSettle();
        await selecting;
        expect(tools.pageNumber, 3);
        expect(tools.currentMatch, 2);
        final searchLocation = viewer().visibleRect;
        await _navigate(tester, tools.returnToPrevious());
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 1);
        expect(tools.zoom, closeTo(1.37, .001));
        await _navigate(tester, tools.goForward());
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 3);
        expect(
          (viewer().visibleRect.center - searchLocation.center).distance,
          lessThan(.001),
        );
        await _navigate(tester, tools.returnToPrevious());
        await tester.pumpAndSettle();
        final params = tester.widget<PdfViewer>(find.byType(PdfViewer)).params;
        params.linkHandlerParams!.onLinkTap(
          PdfLink([], dest: PdfDest(2, PdfDestCommand.xyz, [0, 600, 1.5])),
        );
        await tester.pumpAndSettle();
        expect(tools.pageNumber, 2);
        expect(tools.zoom, closeTo(1.5, .001));
        params.linkHandlerParams!.onLinkTap(
          PdfLink([], url: Uri.parse('https://example.com')),
        );
        await tester.pumpAndSettle();
        expect(opened, Uri.parse('https://example.com'));
        tools.search('');
        await tools.setZoom(1.37);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        final resume = saved!;
        tools.dispose();
        await tester.pumpWidget(const SizedBox());
        final reopened = await tester.runAsync(
          () async => createPdfrxFacade(
            await _document(),
            sourceName: 'reopen-$mode',
            initialView: resume,
          ),
        );
        final reopenedTools = reopened! as PdfReaderTools;
        await reopened.showPage(resume.pageIndex, 0);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: reopened.buildViewport(
                PdfViewportConfiguration(
                  pageIndex: resume.pageIndex,
                  facingPages: false,
                  backgroundColor: Colors.white,
                  brightness: Brightness.light,
                  layoutMode: mode,
                  onPageChanged: (_) {},
                ),
              ),
            ),
          ),
        );
        await _ready(tester, reopenedTools);
        expect(reopenedTools.pageNumber, resume.pageIndex + 1);
        expect(reopenedTools.zoom, closeTo(1.37, .001));
        reopenedTools.dispose();
        await tester.pumpWidget(const SizedBox());
      },
      skip: kIsWeb,
    );
  }

  testWidgets(
    'PDF empty results have an icon and only the panel close button',
    (tester) async {
      final tools = _Tools()..search('missing phrase');
      addTearDown(tools.dispose);
      Widget panel({WidgetBuilder? emptyBuilder}) => MaterialApp(
        home: Scaffold(
          body: ReaderPdfSearchPanel(
            tools: tools,
            close: () {},
            closeOnSelection: false,
            emptyBuilder: emptyBuilder,
          ),
        ),
      );
      await tester.pumpWidget(panel());
      expect(find.byIcon(Icons.search_off), findsOneWidget);
      expect(find.text('No results found'), findsOneWidget);
      expect(find.text('Try a different word or phrase.'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('0 of 0 matches'), findsNothing);
      expect(find.byTooltip('Next match'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.suffixIcon,
        isNull,
      );
      await tester.pumpWidget(
        panel(emptyBuilder: (_) => const Text('Host empty results')),
      );
      expect(find.text('Host empty results'), findsOneWidget);
      expect(find.text('No results found'), findsNothing);
    },
  );

  testWidgets('PDF search results keep their bounds across search states', (
    tester,
  ) async {
    final tools = _Tools();
    addTearDown(tools.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 600,
            child: ReaderPdfSearchPanel(
              tools: tools,
              close: () {},
              closeOnSelection: false,
            ),
          ),
        ),
      ),
    );
    final input = tester.getRect(find.byType(TextField));
    final results = tester.getRect(
      find.byKey(const ValueKey('pdf-search-results')),
    );
    tools.searching = true;
    tools.search('phrase');
    await tester.pump();
    expect(tester.getRect(find.byType(TextField)), input);
    expect(
      tester.getRect(find.byKey(const ValueKey('pdf-search-results'))),
      results,
    );
    expect(find.byTooltip('Next match'), findsNothing);
    tools.searching = false;
    tools.search('phrase');
    await tester.pump();
    expect(find.text('No results found'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('pdf-search-results'))),
      results,
    );
    tools.matches = const [PdfSearchMatch(pageNumber: 1, text: 'A phrase')];
    tools.search('phrase');
    await tester.pump();
    expect(tester.getRect(find.byType(TextField)), input);
    expect(
      tester.getRect(find.byKey(const ValueKey('pdf-search-results'))),
      results,
    );
    expect(
      tester.getRect(find.byTooltip('Next match')).bottom,
      lessThanOrEqualTo(input.top),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF result arrows stay enabled and queue rapid navigation', (
    tester,
  ) async {
    var closeRequests = 0;
    final tools = _DelayedTools()
      ..currentMatch = 0
      ..matches = List.generate(
        4,
        (index) => PdfSearchMatch(pageNumber: index + 1, text: 'Result $index'),
      );
    addTearDown(tools.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderPdfSearchPanel(
            tools: tools,
            close: () => closeRequests++,
            closeOnSelection: true,
          ),
        ),
      ),
    );
    final next = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Next match',
    );
    final previous = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Previous match',
    );
    await tester.tap(next);
    await tester.pump();
    expect(tools.calls, [1]);
    expect(tools.isReady, isFalse);
    expect(tester.widget<IconButton>(next).onPressed, isNotNull);
    expect(tester.widget<IconButton>(previous).onPressed, isNotNull);
    await tester.tap(next);
    await tester.pump();
    expect(tools.calls, [1]);
    expect(tester.widget<IconButton>(next).onPressed, isNotNull);
    final selectedText = tester.widget<Text>(find.text('Result 2'));
    final colors = Theme.of(tester.element(find.text('Result 2'))).colorScheme;
    expect(selectedText.style!.color, colors.primary);
    tools.pending.removeAt(0).complete();
    await tester.pump();
    expect(tools.calls, [1, 2]);
    expect(tester.widget<IconButton>(next).onPressed, isNotNull);
    tools.pending.removeAt(0).complete();
    await tester.pump();
    expect(tools.currentMatch, 2);
    await tester.tap(next);
    await tester.pump();
    expect(tools.calls, [1, 2, 3]);
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    expect(tester.widget<IconButton>(previous).onPressed, isNotNull);
    tools.pending.removeAt(0).complete();
    await tester.pumpAndSettle();
    expect(tools.currentMatch, 3);
    expect(closeRequests, 0);
    await tester.tap(previous);
    await tester.pump();
    tools.pending.removeAt(0).complete();
    await tester.pumpAndSettle();
    expect(tools.currentMatch, 2);
    expect(closeRequests, 0);
    await tester.tap(find.text('Result 0'));
    await tester.pump();
    tools.pending.removeAt(0).complete();
    await tester.pumpAndSettle();
    expect(tools.currentMatch, 0);
    expect(closeRequests, 1);
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets('PDF arrows keep results visible at text scale $textScale', (
      tester,
    ) async {
      final tools = _Tools()
        ..currentMatch = 0
        ..matches = List.generate(
          85,
          (index) => PdfSearchMatch(
            pageNumber: index + 1,
            text: 'Result $index ${'search excerpt ' * (index % 4 * 5)}',
          ),
        );
      addTearDown(tools.dispose);
      var closeRequests = 0;
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: ReaderPdfSearchPanel(
              tools: tools,
              close: () => closeRequests++,
              closeOnSelection: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      final scroll = tester.widget<ListView>(list).controller!;

      void expectActiveVisible(int index) {
        final row = find.ancestor(
          of: find.text(tools.matches[index].text),
          matching: find.byType(ListTile),
        );
        expect(row, findsOneWidget);
        expect(tester.widget<ListTile>(row).selected, isTrue);
        final bounds = tester.getRect(list);
        final result = tester.getRect(row);
        expect(result.top, greaterThanOrEqualTo(bounds.top - .01));
        expect(result.bottom, lessThanOrEqualTo(bounds.bottom + .01));
      }

      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expectActiveVisible(1);
      expect(scroll.offset, 0);

      for (var index = 2; index <= 12; index++) {
        await tester.tap(find.byTooltip('Next match'));
        await tester.pumpAndSettle();
        expectActiveVisible(index);
      }

      expect(scroll.offset, greaterThan(0));

      for (var index = 11; index >= 0; index--) {
        await tester.tap(find.byTooltip('Previous match'));
        await tester.pumpAndSettle();
        expectActiveVisible(index);
      }

      // Manual scrolling can dispose the active row and its neighbours.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expectActiveVisible(1);

      tools.currentMatch = 83;
      tools.search('excerpt');
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expectActiveVisible(84);
      expect(closeRequests, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('PDF search remains usable with large text and keyboard space', (
    tester,
  ) async {
    final tools = _Tools();
    addTearDown(tools.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 320,
              height: 180,
              child: ReaderPdfSearchPanel(
                tools: tools,
                close: () {},
                closeOnSelection: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.widgetWithText(TextField, 'Search in document'),
      findsOneWidget,
    );
  });

  testWidgets(
    'PDF controls validate page entry and allow exact zoom at compact widths',
    (tester) async {
      final tools = _Tools();
      addTearDown(tools.dispose);
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 720),
                textScaler: TextScaler.linear(2),
              ),
              child: ReaderPdfControls(
                tools: tools,
                compact: true,
                onSearch: () {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('100%'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '137');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(tools.zoom, 1.37);
      await tester.tap(find.byTooltip('More reader actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go to page (1 of 3)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '4');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a number from 1 to 3.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '2');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(tools.pageNumber, 2);
    },
  );
}

class _Tools extends PdfReaderTools {
  @override
  Future<void> scrollVertically(double distance) async {}

  @override
  bool get isReady => true;
  @override
  int get pageCount => 3;
  @override
  int pageNumber = 1;
  @override
  double zoom = 1;
  @override
  double get minimumZoom => .1;
  @override
  double get maximumZoom => 8;
  @override
  bool get canReturn => false;
  @override
  bool get canGoForward => false;
  @override
  bool searching = false;
  @override
  String query = '';
  @override
  List<PdfSearchMatch> matches = const [];
  @override
  int? currentMatch;
  @override
  Future<void> setZoom(double value) async {
    zoom = value;
    notifyListeners();
  }

  @override
  Future<void> fitPage() async {}
  @override
  Future<void> fitWidth() async {}
  @override
  Future<void> goToPage(int number) async {
    pageNumber = number;
    notifyListeners();
  }

  @override
  Future<void> returnToPrevious() async {}
  @override
  Future<void> goForward() async {}
  @override
  void search(String value) {
    query = value;
    notifyListeners();
  }

  @override
  Future<void> selectMatch(int index) async {
    currentMatch = index;
    notifyListeners();
  }
}

class _DelayedTools extends _Tools {
  final calls = <int>[];
  final pending = <Completer<void>>[];

  @override
  bool get isReady => pending.isEmpty;

  @override
  Future<void> selectMatch(int index) async {
    calls.add(index);
    final completion = Completer<void>();
    pending.add(completion);
    notifyListeners();
    await completion.future;
    currentMatch = index;
    notifyListeners();
  }
}

// Any drawing call fails: disabled link highlighting must paint nothing.
class _NoPaintCanvas extends Fake implements Canvas {}
