# Architecture

`PapyrusReader` is a Material shell over a host-owned or widget-owned controller.
`ReaderController` resolves a fresh engine from `ReaderEngineRegistry`, publishes
immutable snapshots and notifies observers. New loads dispose pending candidates
and run independently; generation checks prevent stale completion or errors from
replacing the latest document. The selected engine remains controller-owned.

## EPUB document session

`EpubProcessor` owns an `epub_pro` archive in a resident document worker. `open`
returns spine count and TOC metadata. `chapter` returns sanitized HTML, semantic
runs, illustrations, anchors and chapter-local text offsets. Reading order comes
from linear OPF spine entries. TOC hierarchy remains independent, with anchors
resolved in the target chapter. A fallback supports incomplete publisher spines.
Malformed resources fail explicitly rather than silently shifting stored indices.

The processor removes executable content and remote image/resource requests.
The cache retains at most three chapters and at most four million HTML characters;
oversized chapters can be read but are not retained. This is a cache bound, not a
bound on the archive, rendered content or total process memory.

Native uses a `SendPort`/`ReceivePort` isolate. Web uses a packaged Dart-to-JS
browser Worker; document bytes are copied before transfer, preserving the host's
buffer. Both transports map processing errors into stable reader errors and
terminate their sessions on disposal. The browser must permit `worker-src blob:`.

## EPUB layout

Flutter's `TextPainter` measures styled runs at the actual column width, text
scale and direction. Pagination cuts at line boundaries, keeps run styles and
uses content offsets for restoration. Work yields between bounded batches.
Only the current chapter is laid out, and only visible pages are built.

The viewport owns page and scroll controllers and responds to local turns before
the engine crosses chapter boundaries. Single-column content has a maximum line
width; spreads collapse on narrow or highly scaled viewports. Scrolling uses the
same rich content and measured extents. A supplied `EpubContentRenderer` remains
available for custom HTML scrolling, with progression-based restoration.

This is semantic reflow, not a browser CSS engine. Basic tables are rendered as
readable text rows. Publisher stylesheets, embedded fonts, footnote popovers and
complex table/math layout require follow-on work. The old exported `EpubPaginator`
remains compatible for hosts, but the default engine uses rich line measurement.

## PDF

`PdfReaderEngine` uses a testable `PdfFacade`. The default pdfrx facade acquires a
shared document reference during metadata inspection and keeps it until disposal.
The viewer uses that same reference, avoiding a second PDF parse. Viewer matrix
updates publish a quantized page offset, and layout depends on viewport constraints.
Paginated mode fits a complete page or spread into a bounded viewport slot;
wheel and touch turns advance whole spreads. Zoomed content can pan inside the
active spread. Continuous mode fits the document width including margins and scrolls within and between
pages. Changes to mode, columns or available space refit the current page using
the same document reference. Appearance changes retain the viewer and its scale.
pdfrx owns PDF rendering, zoom and text selection. Its facade preserves platform
independence without exposing PDFium details to the shell or host persistence.

## Shell

The shell retains the content widget during position updates, serializes user
commands and keeps loading/error views escapable. Reader appearance controls the
chrome brightness as well as page colors. Wide panels reserve space in the row;
compact panels fit available height and insets. Sliders preview locally and commit
on release, so dragging typography sliders does not continuously reflow the book.
Keyboard navigation has a persistent shell focus node and restores focus after
chapter replacement when the command originated in the reading surface. Panels
retain their own focus. Reader text/icon colors follow the selected appearance,
including mobile sheets whose captured route theme would otherwise become stale.
