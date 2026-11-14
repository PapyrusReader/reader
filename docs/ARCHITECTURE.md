# Reader architecture

## Ownership and cancellation

`PapyrusReader` is a Material shell over `ReaderController`. A controller owns its
engines; a host-supplied controller remains the host's responsibility to dispose.
Engine factories create fresh instances. Document loads use generation checks so
late completion cannot replace a newer session. The host owns document bytes,
account-scoped persistence and routing; the package owns transient reader resources.
See [integration](INTEGRATION.md) for the public host contract.

## EPUB processing and layout

ZIP, XML and chapter HTML processing live in `EpubProcessor`, in a resident native
isolate or packaged browser worker. Flutter `compute` does not provide a background
worker on web. Both transports use the same protocol and release sessions on
cancellation/disposal. Browser transfers preserve the host's byte buffer. Worker
source changes invalidate the asset, which Flutter regenerates during web builds
using the host application’s dependency resolution.

Reading order follows the OPF spine, independently of TOC hierarchy. Chapter-local
normalized UTF-16 offsets identify content across layout changes; screen page
numbers are not persisted locations. Sanitization removes executable content and
remote resource requests. Cache limits bound retained chapters, not total archive
or renderer memory.

Flutter measures semantic runs using the actual viewport, typography and text
scale. Layout yields in batches and prepares nearby pages without replacing the
committed viewport. Foreground navigation and prefetch share pending work. A
failed or stale preparation cannot overwrite the visible page or saved locator.
Geometry changes invalidate layout and page totals; appearance-only changes do not.

Reading coverage is published only for committed viewports. EPUB page keys contain
the spine index, page start and chapter content length. The end offset is excluded
because background pagination can extend it over a paragraph separator. Scrolling
clips visible extents without changing the page key. Host aggregation is described
in [activity observations](INTEGRATION.md#optional-activity-observations).

This is semantic reflow, not a browser CSS engine. `epub_pro` handles container and
metadata parsing; `flutter_html` supports an injectable HTML scrolling renderer.
Custom HTML rendering restores approximate progression rather than the default
renderer’s precise content offset. Supported-format limits are in the
[README](../README.md#current-scope).

## Additional input formats

The shared document worker prepares TXT and MOBI/AZW3 as transient EPUB content,
then applies the same sanitizer, semantic offsets and layout pipeline. Text
chapters use deterministic bounded chunks. The vendored Kindle decoder records
its upstream version, license and browser adjustments in
`third_party/kindle_unpack/UPSTREAM.md`.

CBZ and CBR are decoded in the worker into a transient PDF page document. Natural
path ordering determines page indices. Images preserve their aspect ratios and
JPEG data; archive readers release their resources after preparation. Binary
responses transfer typed byte buffers in browsers instead of serializing them
as large JSON arrays. Cancelling a load terminates its conversion worker.

Input format remains on `ReaderDocument`; reflow inputs use `EpubReaderLocator`
and fixed-page inputs use `PdfReaderLocator`. The host retains the original file,
and no conversion cache or second persisted copy is introduced. Comic colors
are preserved in dark mode.

## PDF resources

`PdfReaderEngine` uses a `PdfFacade` so engine tests do not depend on PDFium.
The pdfrx implementation shares one document reference between metadata inspection
and the viewer, retaining it until disposal. Appearance changes preserve the viewer and zoom. Custom zoom and the page-local
view center survive viewport/layout changes; fit modes adapt to the available
space. Paginated slots isolate spreads even when zoomed out. pdfrx owns rendering,
selection, and bounded text search. `PdfReaderTools` exposes zoom, fit, page entry,
search, and a bounded return history to the shell without exposing PDFium types.
Each paginated spread retains its viewer and rendered images through a swipe and
settlement. Neighboring viewers mount lazily and release their resources when
evicted from the page cache. Search results belong to the document; navigation and
keyboard focus follow the active spread.

The host persists the synchronized locator separately from `PdfViewState`, which
is device-local view configuration. `ReaderDocument.initialPdfView` and
`onPdfViewChanged` restore/save it; a host must scope storage to the library and
book. External links are delegated to `ReaderDocument.onOpenLink`; the host owns
allowed URL schemes and platform launch behavior. Internal destinations retain
PDF coordinates. Search and link jumps retain the previous view for return.

## Shell and host presentation

The shell serializes navigation. Page turns retain order; seeks supersede earlier
queued seeks, and stale results cannot commit a locator. Cooperative seek
cancellation releases navigation without restarting the document worker. Slider
drags preview locally and commit on release.

Controls and panels overlay the reading viewport so visibility changes do not
repaginate content. Page-tap toggles exclude selections, links and competing
pointer gestures. Keyboard focus survives chapter replacement without stealing
focus from an open panel. Reduced motion changes transitions, not layout.

Internal presentation modules are not public API. Host customization uses
`ReaderUiBuilders` and exported builder contexts. A `compactPanelRoute` factory
returns an unpushed route and connects the provided content scroll controller to
its sheet. The reader owns presentation and activity-obscuring state; the host owns
sheet framing, dismissal and app-theme behavior. The contents builder remains live
when reader appearance changes. Omitting the factory retains standalone panels.
