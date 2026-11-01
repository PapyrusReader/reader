# Reader navigation validation — 2026-10-10

## Overlay-controls follow-up

The subsequent controls revision replaces reserved toolbar/footer space with overlays
on desktop and mobile. The final visual refinement docks the bars and desktop
side panels flush to the screen edges, removes the book title, and uses the standard
56-pixel app bar and platform back button to match book details. Chapter/page
information sits above the slider, 11 pixels from the track center, with four
pixels of top padding and full-height
touch targets retained. There is no persistent show/hide button.
An ordinary page tap toggles the controls; Escape and accessible surface actions
provide alternatives. The full reading viewport and pagination remain unchanged
when the overlays appear or disappear, and safe areas use the page background.

Two gesture bugs were corrected: empty selection notifications cancelled ordinary
text taps, and paragraphs containing links suppressed taps even on ordinary words.
Link exclusion now tests the actual linked glyph bounds. A selectable mixed-text
regression checks ordinary words before and after a link, the link itself, and empty
selection notifications. Existing long-press, drag, multi-touch and selection
exclusions remain covered.

The actual client on the iOS simulator passed text-tap hide/show sessions with Alice,
Pride and the local SQL book. Desktop Chrome confirmed that clicking text removes
both overlays completely, with no remaining bars or toggle, and Escape restores
them. Screenshots are in ignored `build/overlay-validation/` (desktop controls shown
and hidden; native book pages shown and hidden). All 167 reader tests, 27 focused
client tests and two example tests pass, as do analysis, client checks, both web
builds and the browser smoke covering PDF controls, paging and scrolling. The entries
below record the original navigation validation before this visual follow-up.

The flush-bar refinement passes all 168 reader tests (including a comparison of
reader and standard app-bar/back-icon bounds), two example tests, reader analysis,
client checks and the client production web build. The actual iOS client again
passes Alice, Pride and local SQL navigation, tap hide/show, persistence and PDF
controls. Desktop Chrome confirms the titleless bars and docked settings panel.
Current screenshots and logs are in ignored `build/flush-controls-validation/`.
The subsequent footer-spacing correction restores the label above the track and
halves the label-to-track-center gap from 24 to 12 pixels. All 42 focused shell
and real-book tests pass, including explicit spacing and width checks at phone
and desktop sizes. Alice/Pride and PDF client checks pass on the iOS simulator;
updated screenshots are in `build/footer-spacing-validation/`.
Native turn plus observation times were 863 ms, 793 ms and 1856 ms respectively;
as above these include deliberate frame observation and debug/test overhead.

The fixes were validated with the workspace-pinned Flutter 3.41.2 SDK and an
ignored client `pubspec_overrides.yaml` pointing `papyrus_reader` to `../../reader`.
These navigation checks used locator version 1. Subsequent pre-release contract
cleanup removed synthetic CFI strings; positions use spine indices and content
offsets. Package versions are unchanged; the coordinating client PR pins the
committed reader revision.

## Opening-screen follow-up

Initial opening now shows only a centered, accessible loader without a back arrow
or book title. The client uses its motion-aware loader for both media fetching and
engine preparation, keeping identical safe-area bounds and background color.
Tests explicitly hold loading open and compare spinner positions across stages.
All 34 shell tests, two client page tests and two example tests pass, along with
reader/client analysis, client checks and a production web build. Actual iOS
Alice/Pride opening captures and subsequent EPUB/PDF interactions pass; screenshots
and logs are in ignored `build/opening-validation/`.

## Panel-contrast follow-up

TOC/settings panels now use the theme's higher-contrast container surface. Wide
panels have a one-pixel leading/top border; mobile sheets have a matching outline.
Borders do not change reader geometry or add floating margins/shadows. All 168
reader tests, two example tests, reader analysis and the client web build pass.
Actual client Chrome screenshots in dark and light appearances are retained in
ignored `build/panel-contrast-validation/`.

## Reproducible inputs

The offline [Gutenberg fixtures](../test/fixtures/gutenberg/README.md) record exact
source URLs and SHA-256 checksums for Alice and Pride and Prejudice. SQL Performance
Explained was tested using the user's existing local file and is not distributed.

## Checks and observations

| Target | Result |
| --- | --- |
| Reader | 166 tests passed; analysis and formatting clean |
| Reader example | 2 tests passed; analysis and production web build passed |
| Packaged worker | Regeneration check and real browser transport smoke passed |
| Client | 51 reader, activity, persistence, mapper and page integration tests passed; client checks and production web build passed |
| Actual client, desktop Chrome | Alice cover, forward/backward chapters, TOC and settings overlays, scrolling and paginated spreads; SQL cover/main-content/cover round trip stays at 0% instead of 50% |
| Actual client, 390 × 844 Chrome | Pride cover/main-content/cover returns to 0%; show/hide toggle bounds identical: x334, y4, 48 × 48 CSS pixels |
| Actual client ReaderPage, iOS 27 iPhone 18 Pro simulator | Alice, Pride and local SQL passed cover/next/previous, intermediate-frame checks, panels, stable toggle coordinates, persisted locator and visible position after reopening; PDF opens and retains its settings controls |
| Browser example smoke | Keyboard focus across chapters, hidden controls, mobile sheets, landscape, PDF page turns, wheel scrolling, spreads, appearance changes, local file opening and worker cleanup passed |

Real-book widget tests exercise both 390 × 844 and 1280 × 850 viewports, slider
endpoints, rapid queued turns, rotation, typography, appearance without controller
replacement, native worker restart and content-offset locators. A gated worker verifies
that slow and failed chapter preparation retains the committed page and progress,
then succeeds on retry. Gesture regressions exclude dragging, long presses, double
taps, multi-touch, selection and link interactions from the center-tap toggle.

Native frame observation checks every sampled frame for retained PageView content
and absence of the full-page preparation message. The measured next-turn plus
20-frame observation and settling times were Alice 841 ms, Pride 793 ms and SQL
2041 ms in a debug simulator build. These include test overhead and intentional
observation time; they are not production frame-latency benchmarks. The large SQL
body is a single spine item, making it a useful slow-layout case.

Local evidence is retained under ignored `build/reader-validation/`: desktop and
native screenshots, timings and check logs. Phone browser screenshot capture had
a device-scale mismatch in the automation surface; phone geometry was checked
through DOM bounds and widget tests, with native simulator screenshots used for
visual evidence. No physical iOS/Android or e-ink hardware session was run. Existing
reduced-motion and large-text regressions pass; this is not a hardware certification.
Authenticated live synchronization and release deployment were not exercised.

## Running the device check

Serve a temporary local directory on port 8755 containing:

- `reader.epub`: the Alice fixture.
- `pride.epub`: the Pride and Prejudice fixture.
- `reader.pdf`: `example/assets/a_tiny_pdf.pdf`.
- Optionally `sql.epub`: a locally licensed SQL book, outside the repository.

From `client/app`, with the local reader override installed:

```sh
../../tools/flutter drive --no-pub -d <simulator-id> \
  --driver=test_driver/reading_tracking_driver.dart \
  --target=integration_test/reader_real_books_test.dart \
  --dart-define=RUN_READER_VALIDATION=true \
  --dart-define=TRACKING_FIXTURE_ORIGIN=http://127.0.0.1:8755
```

Add `--dart-define=READER_INCLUDE_SQL=true` only when that local file is available.
The test uses the client's actual ReaderPage, DataStore and isolated guest database.
Its driver writes screenshots and timings to `client/app/build/integration_response_data.json`.

On this machine Xcode 27 rejected older deployment targets in dependency Pods.
The simulator command used a temporary `XCODE_XCCONFIG_FILE` containing
`IPHONEOS_DEPLOYMENT_TARGET = 15.0`. No deployment target or Pod lockfile change
is included in the fix.

The native persistence check exposed an additional client bug: activity updates
stored `reader_locator` outside the metadata envelope consumed by the book mapper.
The final implementation writes and reads the current flat `custom_metadata`
contract. Missing locator patches preserve the previous position; legacy envelope
and locator recovery paths were removed as part of the pre-release cleanup.
