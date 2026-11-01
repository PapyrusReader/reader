# Client integration

Pass a stable `ReaderDocument` for the lifetime of a book session. Constructing a
new instance on every host rebuild requests a fresh load. File loading is lazy;
the callback may read an offline cache or retrieve missing media. Supply `onBack`
so loading and error screens can exit. Keep host download screens escapable too.

The widget owns its controller unless one is supplied. An external controller is
host-owned and must be disposed by the host. Engine factories must return fresh
instances. Observers should enqueue durable host writes, with a flush on close,
background and profile changes. The package never writes account-scoped data.

Serialize `ReaderLocator.toJson()` in full. EPUB positions use `spineIndex`,
`textOffset`, and an optional `anchor`. Custom HTML scrolling renderers use
approximate progression restoration. EPUB locators do not contain CFI strings;
standardized EPUB CFI interoperability is not implemented.

PDF stores `pageIndex`, `pageOffset` and `totalProgression`. A custom facade can
report intra-page offsets through `PdfViewportConfiguration.onPositionChanged`.
Implement `DisposablePdfFacade` when a custom facade owns document resources.

## Local Papyrus verification

`client/app/pubspec.yaml` pins a separately released reader revision. Temporarily
create the ignored `client/app/pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  papyrus_reader:
    path: ../../reader
```

Run dependency resolution, reader-related client tests, analyze and a web build
against this path. Remove the override afterward and restore the released lockfile
and dependency resolution. Publishing the integration requires committing reader
changes, updating the client's Git revision/lockfile and recording the new reader
submodule revision in the workspace. A sibling edit alone does not update client.

## Browser hosts

The packaged worker is included by Flutter's asset manifest. Applications need no
worker-generation build step. Serving under a URL subpath works because the host
loads the worker through `rootBundle` and creates a local Blob URL. A restrictive
Content Security Policy must allow `worker-src blob:`; do not fall back silently
to main-thread parsing if worker initialization fails. Offline deployment must
cache the packaged worker alongside other Flutter assets.

## Optional activity observations

`PapyrusReader(onActivity: ...)` reports `ReaderActivityEvent` readiness, visibility,
locator, navigation cause, exposed stable coverage, and end-of-document state.
The callback is optional and independent of Goals. Hosts own clocks, foreground lifecycle,
completion confirmation, persistence, and aggregation.

Settings and contents panels mark content obscured. EPUB coverage uses normalized
chapter UTF-16 content extents, with spine count for host calibration; PDF coverage
lists actually exposed page indices, including spreads. Jumps never expose skipped
pages. Engines without page metrics retain time tracking through ready snapshots.
Parsing remains in the existing worker/isolate transports; activity reporting does
not require whole-book layout. Reflow reports coverage without changing the
restored locator's precise content offset.
