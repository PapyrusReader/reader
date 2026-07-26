# Papyrus Reader

`papyrus_reader` is a self-contained Flutter library for reading reflowable
EPUB 2/3 and PDF documents on Android, iOS, Web, Linux, macOS, and Windows.

It provides EPUB CFI locations, PDF page locations, TOC/outline navigation,
scroll and paginated layouts, configurable appearance, and a responsive
Material 3 reader shell. UI builders and theme data allow Papyrus to replace
the default chrome without forking the engines.

The package deliberately has no Papyrus API, PowerSync, filesystem, routing,
or state-management dependency. The host owns document bytes and persistence.

## Add it to an application

```yaml
dependencies:
  papyrus_reader:
    path: ../reader
```

```dart
PapyrusReader(
  document: ReaderDocument(
    id: book.id,
    title: book.title,
    author: book.author,
    format: ReaderFormat.epub,
    loadBytes: () => file.readAsBytes(),
  ),
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

The six-platform example includes deterministic EPUB/PDF assets, light and
dark themes, and in-memory position/preference restoration.

## Current scope

The initial release supports reflowable EPUB 2/3 and PDF. Fixed-layout EPUBs
return `ReaderErrorCode.unsupportedFixedLayout`. MOBI/AZW3, TXT, comic
archives, search, bookmarks, highlights, and notes are planned extensions.

- [Architecture](docs/architecture.md)
- [Client integration](docs/integration.md)
- [Supported formats](docs/supported-formats.md)

## Development

```bash
flutter analyze
flutter test
cd example && flutter analyze && flutter test && flutter build web
```

Licensed under AGPL-3.0.
