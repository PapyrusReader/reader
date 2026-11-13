# Reader validation

Use the workspace-pinned SDK when available. From this repository:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
(cd example && flutter analyze && flutter test && flutter build web)
python3 tool/check_worker_build.py
(cd tool/browser && npm ci && npx playwright install chromium && npm test)
```

Widget tests inject an in-process EPUB transport because fake clocks do not model
resident-isolate scheduling. Native transport tests and the compiled browser suite
exercise the real transports. Additional-format tests decode real Gutenberg MOBI/KF8
text and covers, compare rendered comic pixels for natural page order, restore
serialized positions, and exercise cancellation. Browser checks also open every
format through the example file picker and record animation-frame gaps during
worker processing. Browser checks require the built example and its
packaged worker. `PAPYRUS_CHROME_EXECUTABLE` selects an installed Chrome;
`PAPYRUS_SCREENSHOT_DIR` saves review images outside source control.

The worker build check uses disposable consumers to verify source and notice
invalidation, dependency resolution, compile failures, native exclusion and Git
package consumption. Pass `--flutter ../tools/flutter` to use the workspace SDK.

Record tested revisions, platforms and remaining checks in the PR. Synthetic
fixtures and CI builds do not establish real-device or arbitrary publisher-book
compatibility. Use the [format limits](../README.md#current-scope) when choosing
representative inputs.

## Real-book client checks

The [Gutenberg fixtures](../test/fixtures/gutenberg/README.md) record reproducible
EPUB inputs and checksums. Serve a temporary local directory on port 8755 with:

- `reader.epub`: the Alice fixture.
- `pride.epub`: the Pride and Prejudice fixture.
- `reader.pdf`: `example/assets/a_tiny_pdf.pdf`.
- Optionally `sql.epub`: a locally licensed SQL book, outside the repository.

With the [local reader override](INTEGRATION.md#local-papyrus-verification)
installed, run from the workspace's `client/app` on an isolated iOS simulator:

```sh
../../tools/flutter drive --no-pub -d <simulator-id> \
  --driver=test_driver/reading_tracking_driver.dart \
  --target=integration_test/reader_real_books_test.dart \
  --dart-define=RUN_READER_VALIDATION=true \
  --dart-define=TRACKING_FIXTURE_ORIGIN=http://127.0.0.1:8755
```

Add `--dart-define=READER_INCLUDE_SQL=true` only when that file is available.
The test uses the client's ReaderPage, DataStore and an isolated guest database.
The driver writes screenshots and timings under `client/app/build/`. Keep run
results with the relevant PR, including the tested revisions, platform and unrun
checks. Debug turn timings include deliberate observation frames and test overhead;
they are not production latency benchmarks.

## Large-book stress checks

Keep large downloads outside Git. The opt-in native corpus expects Webster's
Unabridged Dictionary (Gutenberg 29765) as `websters-dictionary.epub`, `.mobi`,
`.azw3`, and `.txt`, plus `alice-high-resolution.pdf`, `whiz-272-pages.cbz`, and
`whiz-272-pages.cbr`. Record source URLs, checksums and any generated/repeated
content alongside the files. Never present a repeated-page fixture as a newly
published book.

```sh
PAPYRUS_LARGE_BOOKS=/absolute/path/to/corpus \
  ../tools/flutter test test/stress/large_books_test.dart --concurrency=1
```

This checks native loading, seeking and locator restoration, and reports event-loop
gaps and sampled test-process RSS. It does not render Flutter viewports or establish
device memory limits. The corpus is skipped in ordinary test runs.

For actual browser viewports, build the example, serve `example/build/web` on
localhost port 8791, and run:

```sh
PAPYRUS_CHROME_EXECUTABLE=/path/to/chrome \
PAPYRUS_STRESS_OUTPUT=/absolute/path/to/results \
  node tool/browser/stress.mjs /absolute/path/to/corpus/*.epub
```

Pass any supported book files as arguments. `PAPYRUS_STRESS_ORIGIN` overrides the
server URL. `PAPYRUS_STRESS_CANCEL_ONLY=1` checks cancellation during preparation
without waiting for full reading. The runner records idle and loading frame gaps,
long tasks, page-turn screenshots, worker closure and Back response. macOS/Linux
RSS sampling covers all processes belonging to the test browser, including GPU
and workers; it is not the reader's isolated heap. Each file gets a fresh browser.
Screenshots are excluded from the navigation frame measurements.

Functional success does not mean acceptable performance: review load duration,
long tasks and memory separately. Compare frame gaps with the idle baseline, avoid
concurrent builds, and record other desktop load. Browser page turns and native
headless seeks do not certify long-distance Flutter pagination, phone behavior,
or every page in a large publication.
