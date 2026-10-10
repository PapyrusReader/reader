# Architecture

`PapyrusReader` is a Material shell over a host-owned or widget-owned controller.
`ReaderController` resolves a fresh engine from `ReaderEngineRegistry`, publishes
immutable snapshots and notifies observers. New loads dispose pending candidates
and run independently; generation checks prevent stale completion or errors from
replacing the latest document. The selected engine remains controller-owned.

## EPUB document session

`EpubProcessor` owns an `epub_pro` archive in a resident document worker. `open`
returns spine count, TOC metadata and normalized content lengths. A fixed cumulative
index weights progress and seeking by those lengths, with a minimum weight for
image-only items. Indexing does not decode illustrations or retain every chapter.
`chapter` returns sanitized HTML, semantic
runs, illustrations, anchors and chapter-local text offsets. Reading order comes
from linear OPF spine entries. TOC hierarchy remains independent, with anchors
resolved in the target chapter. A fallback supports incomplete publisher spines.
Malformed resources fail explicitly rather than silently shifting stored indices.

The processor removes executable content and remote image/resource requests.
Single-image SVG wrappers are reduced to their embedded raster image; this is
cover support, not a general SVG renderer.
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
Adjacent chapters are prefetched after the current viewport commits. The viewport
retains at most three layouts for the current geometry; document, font, viewport
or typography changes invalidate them. Requested navigation cancels speculative
measurement. Only visible pages are built.

Chapter preparation keeps the committed page and snapshot visible until the
replacement layout is ready. Reflow retains the previous layout while measuring;
appearance changes reuse geometry. Full-page loading is limited to initial opening,
with a small delayed indicator for subsequent slow operations. Failed preparation
keeps readable content and offers retry. Coverage describes committed viewports.

The viewport owns page and scroll controllers and responds to local turns before
the engine crosses chapter boundaries. Single-column content has a maximum line
width; spreads collapse on narrow or highly scaled viewports. Scrolling uses the
same rich content and measured extents. A supplied `EpubContentRenderer` remains
available for custom HTML scrolling, with progression-based restoration.

This is semantic reflow, not a browser CSS engine. Basic tables are rendered as
readable text rows. Publisher stylesheets, embedded fonts, footnote popovers and
complex table/math layout require follow-on work. `EpubPaginator` serves custom content renderers; the default engine uses rich
line measurement.

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
commands and keeps error views escapable. Initial opening uses a centered spinner
without toolbar chrome; hosts can supply a loading builder to match their file-fetch
loader. Reader appearance controls the
chrome brightness as well as page colors. Wide panels overlay the reading area;
compact panels fit available height and insets. A distinct surface color and
outlined page-facing edges separate panels from book content without shadows.
Neither changes reader geometry.
Toolbar and progress controls overlay a full-size reading viewport, flush with the
screen edges. The titleless toolbar uses the standard app-bar back button and
56-pixel default height; the compact location label sits just above the progress track.
Wide panels dock against the toolbar and side/bottom edges. Hiding controls
leaves no reserved strips or persistent toggle; safe-area backgrounds match the page.
Plain page taps toggle controls on both compact and wide viewports after excluding
selection, link glyphs, dragging, long presses, double taps and multi-touch. Empty
selection notifications do not suppress taps. Escape and reading-surface accessibility
actions also toggle controls. Navigation
from buttons, keyboard and boundary swipes shares the command queue.
Sliders preview locally and commit
on release, so dragging typography sliders does not continuously reflow the book.
Keyboard navigation has a persistent shell focus node and restores focus after
chapter replacement when the command originated in the reading surface. Panels
retain their own focus. Reader text/icon colors follow the selected appearance,
including mobile sheets whose captured route theme would otherwise become stale.
Material defaults are constructed from the reading palette rather than copying
the host's resolved colors. This includes the legacy canvas color used by dropdown
popup routes, field labels/borders and disabled controls. Host typography, control
geometry, theme extensions and motion policy remain available to the reader.

The presentation layer keeps session, keyboard and viewport coordination in
`papyrus_reader.dart`. Toolbar/progress controls, contents, settings and the panel
header live in separate presentation modules. These modules are implementation
details and are not exported by the package entry point. Public builder contexts
and custom-engine integration remain in the shell's existing public API.

Hosts can supply `ReaderUiBuilders.compactPanelRoute` to own compact panel
presentation. The factory returns an **unpushed** `Route<void>`; the reader pushes
and tracks it, pauses reading activity, and removes that specific route when the
document/controller changes or the reader is disposed. `ReaderPanelRouteContext`
provides the panel kind, title, and `buildContent(context, scrollController)`.
Default content is reactive, headerless, shrink-wrapped, and uses the host theme.
The supplied controller connects it to the host's draggable sheet. Settings and
TOC navigation still use the reader command queue. Existing custom panel builders
continue to replace content and are responsible for any headers they include.
Omitting the route factory retains the standalone sheet and its live reader
appearance. Wide docked panels continue to use the reader shell.

Papyrus client supplies this route with its shared `AppBottomSheet` and
`ExpandableBottomSheet`; header, handle, safe areas, sizing, dismissal, app theme,
and e-ink motion policy are therefore maintained in the client. Reading appearance
changes affect the book while the host sheet keeps the app's theme.


## Library decisions

- Retain `epub_pro` 5.6 for EPUB container, metadata and navigation parsing behind
  a worker boundary. Do not treat its TOC as the OPF spine.
- Retain `pdfrx` 2.x for all six PDF targets. Its native/WASM viewer already owns
  rendering and zoom; a facade keeps engine tests independent of PDFium.
- Retain `flutter_html` for the injectable HTML scrolling renderer. Native rich
  pagination must preserve semantic runs and images instead of extracting only
  plain text. Reader preferences override publisher colors and text sizing.
- Use Dart/Flutter SDK concurrency plus `web` for a packaged browser worker.
  Flutter `compute` alone is insufficient: it uses the UI event loop on web.
- Avoid adding platform WebViews for this release: desktop/Linux and web would
  need different engines and bridges. Re-evaluate a browser EPUB renderer for
  full publisher CSS, fixed-layout EPUB and standardized CFI interoperability.

Sources: [Flutter isolate behavior](https://docs.flutter.dev/perf/isolates),
[epub_pro API](https://pub.dev/documentation/epub_pro/5.6.0/epub_pro/EpubReader-class.html),
[pdfrx](https://github.com/espresso3389/pdfrx/tree/master/packages/pdfrx).

## UI and integration

Keep a quiet reading canvas, readable line length, 48px controls, clear contents
and appearance panels, and a progress scrubber. Typography and navigation must
behave the same on phone and desktop. Respect reduced motion and e-ink hosts.
Capability flags expose only controls implemented by the active engine.

`ReaderDocument`, controller ownership and observer callbacks form the host API.
EPUB locators contain a spine index, content offset or anchor, and progression;
they do not contain synthetic CFI strings. The Papyrus adapter stores complete
locator JSON. Host preference and progress writes remain host-owned.
