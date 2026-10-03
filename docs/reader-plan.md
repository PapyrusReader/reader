# Core reader release

## Goal and acceptance criteria

Make reflowable EPUB and PDF comfortable to read on phones, tablets and desktops.
The first release prioritizes opening, navigation, layout, appearance and resume.
Search, bookmarks, annotations and additional formats are separate releases.

- File loading must leave Back and the loading UI responsive. A newer open must
  not wait for an obsolete open; closing releases document workers.
- EPUB archive/XML/HTML processing runs outside the UI thread on native **and
  web**. Only the current chapter is prepared, with a bounded chapter cache.
- EPUB reading order comes from the OPF spine, independent of TOC order.
- Next/Previous and keyboard controls turn a page before crossing chapters.
  Swiping beyond a chapter reaches the adjacent chapter.
- Preserve headings, emphasis, paragraphs, lists, line breaks and illustrations.
  Layout uses the available viewport, including panels and accessible text scale.
  Narrow screens use one column; wide screens can display a two-page spread.
- Persist content-based EPUB positions through typography changes; keep reading
  existing version-1 locators. PDF retains page and intra-page offset.
- Settings apply to content and chrome; mobile panels fit landscape and keyboard
  insets. Loading and error views always offer a way back.
- Run unit/widget tests, analyze, example web compilation and visual checks at
  phone, landscape and desktop sizes. Validate the client against a local path
  override before updating its released Git pin.

## Architecture

Host application → PapyrusReader shell → ReaderController → format engine.
The host owns bytes, routing, account scope and durable persistence. The package
owns transient document sessions, rendering, navigation and reader chrome.

EPUB engine → document worker (resident native isolate / browser Worker) →
epub_pro archive and OPF parser → sanitized chapter and structured content.
Flutter measures and lays out the current chapter; expensive layout yields
between work batches, caches results and creates only visible page widgets.
Document processing never needs Flutter, network access or host services.

PDF engine → pdfrx facade → PDFium on native / PDFium WASM on web. Retain pdfrx
instead of writing another PDF renderer. Use viewport constraints for spreads,
preserve its zoom/text interaction, and observe offsets for accurate resume.

Controller load requests have independent candidate engines. Publication is
generation-guarded; superseded candidates are disposed immediately. The shell
serializes user navigation and preference commands, with errors visible to the
user. A content viewport remains mounted while progress chrome updates.

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

## Follow-on releases

1. Search with a cancellable worker index, bookmarks and chapter/page jump UI.
2. Selection-based highlights and notes, versioned annotation anchors and an
   explicit host persistence interface; offline synchronization stays in client.
3. Publisher CSS/embedded fonts, RTL progression, footnotes/internal links,
   standardized CFI conformance and complex tables/math fixtures.
4. Fixed-layout EPUB, TXT and comics via separate engines. MOBI/AZW3 requires a
   conversion/parser decision and legal/license review before claiming support.

Performance acceptance needs a representative corpus: long chapters, images,
tables, malformed archives and large PDFs. Synthetic tests prevent regressions
but do not establish a device-wide performance guarantee.
