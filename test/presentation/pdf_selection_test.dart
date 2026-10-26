import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/pdf/pdf_facade.dart';
import 'package:papyrus_reader/src/presentation/reader_interaction_scope.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  for (final layout in ReaderLayoutMode.values) {
    testWidgets(
      'PDF mouse drag opens annotation toolbar in $layout',
      (tester) async {
        final facade = await tester.runAsync(() async {
          await pdfrxInitialize();
          return createPdfrxFacade(
            _pdfBytes(),
            sourceName: 'selection-$layout',
          );
        });
        addTearDown(() => (facade as DisposablePdfFacade).dispose());
        ReaderSelection? annotated;
        var turns = 0;
        final configuration = PdfViewportConfiguration(
          pageIndex: 0,
          facingPages: false,
          backgroundColor: Colors.white,
          brightness: Brightness.light,
          layoutMode: layout,
          onPageChanged: (_) {},
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderInteractionScope(
                onTurn: (_) => turns++,
                onSelectionChanged: (_) {},
                suppressTap: () {},
                onAnnotate: (selection) => annotated = selection,
                child: Builder(
                  builder: (context) => facade!.buildViewport(configuration),
                ),
              ),
            ),
          ),
        );
        final controller = tester
            .widget<PdfViewer>(find.byType(PdfViewer))
            .controller!;

        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        expect(controller.isReady, isTrue);
        final page = controller.document.pages.first;
        final text = (await tester.runAsync(page.loadText))!;
        final pageRect = controller.layout.pageLayouts.first;
        Offset character(int index) => controller.documentToGlobal(
          text.charRects[index].center.toOffsetInDocument(
            page: page,
            pageRect: pageRect,
          ),
        )!;
        final start = character(0);
        final end = character(16);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: start);
        await mouse.down(start);
        await mouse.moveTo(Offset.lerp(start, end, .5)!);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.moveTo(end);
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Annotate'), findsNothing);
        await mouse.up();

        for (
          var frame = 0;
          frame < 10 && find.text('Annotate').evaluate().isEmpty;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
        expect(find.text('Annotate'), findsOneWidget);
        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Add note'), findsNothing);
        final toolbar = tester.getRect(find.text('Annotate'));
        expect(toolbar.bottom, lessThan(start.dy));
        expect(turns, 0);
        await tester.tap(find.text('Annotate'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(annotated, isNotNull);
        expect(annotated!.text, contains('Selection'));
        expect(annotated!.rectangles, isNotEmpty);
        expect((annotated!.start as PdfReaderLocator).pageIndex, 0);
        expect(controller.textSelectionDelegate.hasSelectedText, isFalse);
        expect(find.text('Annotate'), findsNothing);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      skip: kIsWeb,
    ); // Browser PDFium is checked through the example asset server.
  }
}

Uint8List _pdfBytes() {
  const content =
      'BT /F1 20 Tf 50 700 Td (Selection toolbar appears here.) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(buffer.length);
    buffer.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF',
  );
  return Uint8List.fromList(ascii.encode(buffer.toString()));
}
