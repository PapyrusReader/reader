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
exercise the real transports. Browser checks require the built example and its
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
