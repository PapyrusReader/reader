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
Material defaults are constructed from the reading palette rather than copying
the host's resolved colors. This includes the legacy canvas color used by dropdown
popup routes, field labels/borders and disabled controls. Host typography, control
geometry, theme extensions and motion policy remain available to the reader.

The presentation layer keeps session, keyboard and viewport coordination in
`papyrus_reader.dart`. Toolbar/progress controls, contents, settings and the panel
header live in separate presentation modules. These modules are implementation
details and are not exported by the package entry point. Public builder contexts
and custom-engine integration remain in the shell's existing public API.

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

Existing `ReaderDocument`, controller ownership and observer callbacks remain
compatible. EPUB locators gain optional content offsets; legacy CFI strings are
compatibility data, not a claim of full EPUB CFI conformance. The Papyrus adapter
already stores complete locator JSON, so optional locator fields need no database
schema migration. Host preference and progress writes remain host-owned.
