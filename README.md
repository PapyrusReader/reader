# Papyrus Reader

`papyrus_reader` is a self-contained Flutter library for reading reflowable
EPUB 2/3, PDF, MOBI, AZW3, TXT, CBZ and CBR documents on Android, iOS, Web,
Linux, macOS, and Windows.

It provides versioned EPUB content locations, PDF page locations, TOC/outline navigation,
scroll and paginated layouts, configurable appearance, and a responsive
Material 3 reader shell. UI builders and theme data allow Papyrus to replace
the default chrome without forking the engines. EPUB processing runs in a native
isolate or browser Worker; rich pagination preserves content across typography
changes and turns within chapters before crossing the document spine.

The package deliberately has no Papyrus API, PowerSync, filesystem, routing,
or state-management dependency. The host owns document bytes and persistence.

## Add it to an application

```yaml
dependencies:
  papyrus_reader:
    path: ../reader
```

```dart
// Create once per book session and retain across host rebuilds.
final document = ReaderDocument(
  id: book.id,
  title: book.title,
  author: book.author,
  format: ReaderFormat.epub,
  loadBytes: () => file.readAsBytes(),
);

PapyrusReader(
  document: document,
  initialLocator: savedLocator,
  initialPreferences: savedPreferences,
  onLocatorChanged: saveLocator,
  onPreferencesChanged: savePreferences,
  onBack: () => Navigator.of(context).pop(),
)
```

`PapyrusReader` owns its controller when none is supplied. An externally
provided `ReaderController` remains host-owned. With an external controller,
omitted initial preferences remain controller-owned; an explicit value
overrides them for the document load.

Tap the reading surface or press **Escape** to hide or restore controls. The
viewport stays the same size, so this does not repaginate or move the book.
Page-turn keys, EPUB swipes and PDF scrolling remain available. Custom toolbar
builders can expose `ReaderToolbarContext.toggleControls`.

Hosts can supply `ReaderUiBuilders.compactPanelRoute` to put Contents and Reading
settings inside their own sheet shell. The factory receives the panel title, kind,
and a live `buildContent(context, scrollController)` builder without reader headers
or framing. Return an unpushed `Route<void>`; the reader handles presentation,
activity tracking and cleanup. Connect the builder's scroll controller to your
sheet's scrolling coordinator. Omit this hook to use the standalone defaults.
See [Architecture](docs/ARCHITECTURE.md) for the presentation contract.

## Example

```bash
cd example
flutter run
```

The six-platform example includes deterministic long EPUB and three-page PDF
assets, a local book file picker, light/dark themes, and in-memory
position/preference restoration. Example positions reset when the app restarts;
production persistence belongs to the host application.

## Current scope

Supported inputs are reflowable EPUB 2/3, PDF, DRM-free MOBI/AZW3 (KF8), plain
text (UTF-8, BOM-marked UTF-16 and Windows-1252), CBZ and CBR (RAR4/RAR5).
Comic pages use natural filename order and support JPEG, PNG, GIF, WebP and BMP;
animations display as still pages. Password-protected archives, multi-volume
comics, Kindle Print Replica, Topaz and encrypted/DRM books are unsupported.
Fixed-layout EPUBs return `ReaderErrorCode.unsupportedFixedLayout`.

Text and Kindle inputs use the reflow engine. Comics use a transient in-memory
page document for zoom, scrolling and facing pages; original library files are
never changed. Conversion runs in a cancellable isolate/browser worker before
opening; large comics may take longer and require memory for the page document.
Reflow uses EPUB-style content locators; comics use PDF-style page locators, so
saved positions, bookmarks and reading activity use the existing contracts.

EPUB and Kindle use semantic reflow: publisher
stylesheets, embedded fonts, advanced SVG/math, RTL progression and footnote
interaction are incomplete; complex tables render as readable rows.

- [Architecture](docs/ARCHITECTURE.md)
- [Client integration](docs/INTEGRATION.md)

## Development

```bash
flutter analyze
flutter test
(cd example && flutter analyze && flutter test && flutter build web)
# From the reader repository, after building the example:
(cd tool/browser && npm ci && npx playwright install chromium && npm test)
```

Use the parent workspace's pinned SDK wrappers when available. Flutter 3.47 or
newer automatically compiles the browser worker from `tool/epub_worker.dart` during
web builds, using the host application's resolved dependencies. The one-line
`assets/epub_worker` file identifies that Dart entrypoint for the asset transformer.
The generated JavaScript includes dependency license notices; neither is checked
into this package.
Native builds omit this asset. Browser CSP must allow `worker-src blob:`.
Browser checks can use an installed Chrome via `PAPYRUS_CHROME_EXECUTABLE` and save
screenshots via `PAPYRUS_SCREENSHOT_DIR`. See [Validation](docs/VALIDATION.md) for
platform coverage.

Licensed under AGPL-3.0.
