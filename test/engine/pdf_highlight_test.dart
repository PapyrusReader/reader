import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/pdf/pdf_facade.dart';
import 'package:pdfrx/pdfrx.dart';

class _Page extends Fake implements PdfPage {
  _Page(this.pageNumber);
  @override
  final int pageNumber;
  @override
  double get width => 100;
  @override
  double get height => 100;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
}

class _Canvas extends Fake implements Canvas {
  final rectangles = <Rect>[];
  @override
  void drawRect(Rect rect, Paint paint) => rectangles.add(rect);
}

void main() {
  testWidgets('overlapping PDF links have one uniform tint', (tester) async {
    final params = buildPdfViewerParams(
      PdfViewportConfiguration(
        pageIndex: 0,
        facingPages: false,
        backgroundColor: const Color(0xffffffff),
        brightness: Brightness.light,
        layoutMode: ReaderLayoutMode.scroll,
        onPageChanged: (_) {},
      ),
      onLink: (_) {},
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    params.linkHandlerParams!.customPainter!(
      canvas,
      const Rect.fromLTWH(0, 0, 100, 100),
      _Page(1),
      [
        PdfLink(const [
          PdfRect(10, 90, 60, 70),
          PdfRect(10, 90, 60, 70),
          PdfRect(10, 60, 40, 50),
        ], url: Uri.parse('https://example.com/multiline')),
        PdfLink(const [
          PdfRect(30, 85, 80, 70),
        ], url: Uri.parse('https://example.com/overlapping')),
      ],
    );
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(100, 100));
    final pixels = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    int alpha(int x, int y) => pixels.getUint8((y * 100 + x) * 4 + 3);

    expect(alpha(15, 20), 50); // Duplicate rectangles within one link.
    expect(alpha(40, 20), 50); // Overlap between separate links.
    expect(alpha(75, 20), 50); // Only the second link.
    expect(alpha(15, 45), 50); // Wrapped continuation.
    expect(alpha(15, 35), 0); // Preserve gaps between lines.
    expect(alpha(45, 45), 0); // Do not expand to a bounding rectangle.
    image!.dispose();
    picture.dispose();
  });

  test(
    'PDF highlight hits follow page position and choose the topmost overlapping highlight',
    () {
      final locator = PdfReaderLocator(
        pageIndex: 1,
        pageOffset: .2,
        totalProgression: .5,
      );
      final highlight = ReaderHighlight(
        id: 'saved',
        color: const Color(0xffffff00),
        selection: ReaderSelection(
          text: 'Saved passage',
          start: locator,
          end: locator,
          rectangles: const [
            ReaderSelectionRect(
              pageIndex: 1,
              rect: Rect.fromLTRB(.1, .2, .8, .3),
            ),
          ],
        ),
      );
      final pages = [
        const Rect.fromLTWH(0, 0, 200, 400),
        const Rect.fromLTWH(220, 0, 200, 400),
      ];
      expect(
        pdfHighlightAt(const Offset(250, 100), pages, [
          highlight,
        ])?.highlight.id,
        'saved',
      );
      expect(
        pdfHighlightAt(const Offset(250, 100), pages, [highlight])?.bounds,
        const Rect.fromLTRB(240, 80, 380, 120),
      );
      expect(pdfHighlightAt(const Offset(30, 100), pages, [highlight]), isNull);
      expect(
        pdfHighlightAt(const Offset(250, 200), pages, [highlight]),
        isNull,
      );
      final overlap = ReaderHighlight(
        id: 'newer',
        color: const Color(0xff00ff00),
        selection: highlight.selection,
      );
      expect(
        pdfHighlightAt(const Offset(250, 100), pages, [
          highlight,
          overlap,
        ])?.highlight.id,
        'newer',
      );
    },
  );

  test(
    'PDF highlights scale with the page and never bleed into other pages',
    () {
      final locator = PdfReaderLocator(
        pageIndex: 2,
        pageOffset: .2,
        totalProgression: .4,
      );
      final selection = ReaderSelection(
        text: 'Selected PDF text',
        start: locator,
        end: locator,
        rectangles: const [
          ReaderSelectionRect(
            pageIndex: 2,
            rect: Rect.fromLTRB(.1, .2, .8, .3),
          ),
        ],
      );
      final restored = ReaderSelection.fromJson(selection.toJson());
      final params = buildPdfViewerParams(
        PdfViewportConfiguration(
          pageIndex: 2,
          facingPages: false,
          backgroundColor: const Color(0xffffffff),
          brightness: Brightness.light,
          layoutMode: ReaderLayoutMode.scroll,
          onPageChanged: (_) {},
        ),
        highlights: [
          ReaderHighlight(
            id: 'saved',
            selection: restored,
            color: const Color(0xffffff00),
          ),
        ],
      );
      final canvas = _Canvas();
      final paint = params.pagePaintCallbacks!.last;
      paint(canvas, const Rect.fromLTWH(10, 20, 200, 400), _Page(3));
      expect(canvas.rectangles.single, const Rect.fromLTRB(30, 100, 170, 140));
      paint(canvas, const Rect.fromLTWH(10, 20, 400, 800), _Page(3));
      expect(canvas.rectangles.last, const Rect.fromLTRB(50, 180, 330, 260));
      paint(canvas, const Rect.fromLTWH(10, 20, 400, 800), _Page(4));
      expect(canvas.rectangles, hasLength(2));
    },
  );
}
