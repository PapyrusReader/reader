# Papyrus Reader

`papyrus_reader` is a self-contained Flutter library for reading reflowable
EPUB 2/3 and PDF documents on Android, iOS, Web, Linux, macOS, and Windows.

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

## Example

```bash
cd example
flutter run
```

The six-platform example includes deterministic long EPUB and three-page PDF
assets, a local EPUB/PDF file picker, light/dark themes, and in-memory
position/preference restoration. Example positions reset when the app restarts;
production persistence belongs to the host application.

## Current scope

The initial release supports reflowable EPUB 2/3 and PDF. Fixed-layout EPUBs
return `ReaderErrorCode.unsupportedFixedLayout`. MOBI/AZW3, TXT, comic
archives, search, bookmarks, highlights, and notes are planned extensions.

- [Architecture](docs/architecture.md)
- [Core release plan](docs/reader-plan.md)
- [Client integration](docs/integration.md)
- [Supported formats](docs/supported-formats.md)

## Development

```bash
flutter analyze
flutter test
./tool/build_epub_worker.sh
(cd example && flutter analyze && flutter test && flutter build web)
# From the reader repository, after building the example:
(cd tool/browser && npm ci && npx playwright install chromium && npm test)
```

Use the parent workspace's pinned SDK wrappers when available. The generated
browser worker is packaged so host applications need no extra build step; rebuild
it after changing worker source. Browser CSP must allow `worker-src blob:`.
Use `tool/build_epub_worker.sh --check` to check asset drift. Browser checks can
use an installed Chrome via `PAPYRUS_CHROME_EXECUTABLE` and save screenshots via
`PAPYRUS_SCREENSHOT_DIR`. See [Validation](docs/validation.md) for platform coverage.

Licensed under AGPL-3.0.
