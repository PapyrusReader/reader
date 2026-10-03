# Core reader validation

The core implementation is checked with Flutter 3.41.2 / Dart 3.11. Use the
parent workspace's pinned wrappers when working from the Papyrus workspace.

## Automated coverage

- Unit/widget suite: concurrent opens and disposal, OPF spine versus TOC order,
  repeated chapter anchors, sanitization, rich runs and Unicode preservation,
  measured/rendered paragraph sizes, page/chapter boundaries, typography and
  viewport/font reflow, large text, PDF position/resource handling, bounded spread
  geometry, chapter-boundary keyboard focus and opposite host/reader themes.
- Native EPUB transport tests run actual resident isolates. Widget tests inject
  the same processor in-process to avoid fake-clock/isolate scheduling problems.
- Browser checks run the compiled example and packaged worker in Chromium:
  protocol errors, page turns, desktop/phone/landscape, settings, local file
  picking, malformed files, worker cleanup and real PDF navigation/resume.
  PDF checks switch Single/Double repeatedly, retain scale across Light/Night,
  and distinguish discrete paginated wheel turns from continuous intra-page scroll.
  Opened reading-mode/typeface menus are reviewed under opposite app/reader themes.
- The client is verified with a temporary sibling-reader path override: adapter,
  session, route and stable-document rebuild tests, analysis and web compilation.
  The override is removed afterward; publishing requires a committed reader pin.
  Client theme tests use the actual light/dark/e-ink palettes, inspect opened menus
  and label contrast on wide/mobile layouts, and change appearance in open panels.

Run from this repository:

```bash
flutter pub get --enforce-lockfile
./tool/build_epub_worker.sh --check
flutter analyze
flutter test
(cd example && flutter analyze && flutter test && flutter build web)
(cd tool/browser && npm ci && npx playwright install chromium && npm test)
```

Set `PAPYRUS_CHROME_EXECUTABLE` to an installed Chrome executable to reuse it.
Set `PAPYRUS_SCREENSHOT_DIR` to save the browser review images. If a dependency
was added but its web plugin is missing at runtime, clear the generated web build
cache and rebuild; do not patch generated plugin files.

## Native builds and remaining verification

The macOS example builds for Apple Silicon with local Xcode 27. A universal build
with this Flutter/Xcode combination fails the upstream architecture verification
step: [Flutter issue 188346](https://github.com/flutter/flutter/issues/188346).
An unsigned local Apple Silicon build can be checked with:

```bash
cd example
flutter build macos --config-only --release
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -derivedDataPath build/macos -sdk macosx \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

CI also builds Linux, Windows and the macOS runner's native architecture. These
jobs are configured here; a local
macOS run does not establish successful Linux/Windows builds. Android/iOS device
checks, Safari/Firefox, low-end devices and a representative publisher corpus
remain necessary before declaring a production release. No cold-open or frame
latency guarantee is claimed from the synthetic fixtures.

Publisher CSS/fonts, RTL progression, complex tables/math and fixed-layout EPUB
are outside this core implementation; see `supported-formats.md` and the release
plan before evaluating books that rely on those features.
