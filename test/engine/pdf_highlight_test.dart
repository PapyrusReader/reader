import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/pdf/pdf_facade.dart';
import 'package:pdfrx/pdfrx.dart';

class _Page extends Fake implements PdfPage {
  _Page(this.pageNumber);
  @override
  final int pageNumber;
}

class _Canvas extends Fake implements Canvas {
  final rectangles = <Rect>[];
  @override
  void drawRect(Rect rect, Paint paint) => rectangles.add(rect);
}

void main() {
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
      final paint = params.pagePaintCallbacks!.single;
      paint(canvas, const Rect.fromLTWH(10, 20, 200, 400), _Page(3));
      expect(canvas.rectangles.single, const Rect.fromLTRB(30, 100, 170, 140));
      paint(canvas, const Rect.fromLTWH(10, 20, 400, 800), _Page(3));
      expect(canvas.rectangles.last, const Rect.fromLTRB(50, 180, 330, 260));
      paint(canvas, const Rect.fromLTWH(10, 20, 400, 800), _Page(4));
      expect(canvas.rectangles, hasLength(2));
    },
  );
}
