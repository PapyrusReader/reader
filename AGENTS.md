# Papyrus reader

This is an independent Flutter package and Git repository. The owning workspace
is one level up; use its `tools/flutter` and `tools/dart` SDK wrappers when present.
Read `docs/architecture.md` before changing architecture or expanding formats.

- Domain types are host-facing and serializable. Keep version-1 locators readable.
  EPUB content offsets are chapter-local normalized UTF-16 offsets, never page
  numbers. Legacy CFI strings are compatibility data, not conformant anchors.
- The host owns bytes, persistence, routing and account/profile isolation.
  Package engines own transient resources and must release them on cancellation.
- EPUB document processing is pure Dart in `lib/src/engine/epub/worker`. Native
  isolates and browser workers use the same request/response protocol. Never
  move ZIP, XML or chapter HTML parsing back onto the Flutter UI thread.
- Rebuild `assets/epub_worker.js` with `tool/build_epub_worker.sh` after modifying
  worker source. The packaged JS lets dependent applications build without a
  manual worker generation step. CI checks the generated asset for drift.
  This package commits `pubspec.lock` and pins its CI SDK so the
  browser worker and third-party notices are reproducible.
- UI text measurement belongs in Flutter. Preserve semantic runs, Unicode,
  illustrations and content offsets when reflowing. Layout must use the space
  left after panels, system insets and text scaling, not device width alone.
- Keep custom engines/renderers/builders usable. Don't silently expose settings
  that the active engine cannot apply.
- Use in-process transport in widget tests with fake clocks; exercise native and
  browser transports independently. Run `flutter analyze`, `flutter test`, and
  example checks. Build web for conditional-import and worker changes.
- Client's Git-pinned reader is independent. Use an ignored local path override
  for integration checks; update its release pin only to a committed revision.

Native example Podfiles are intentional platform setup. Generated build/cache
folders are not source. Keep performance claims limited to measurements actually
made; synthetic tests do not certify arbitrary publisher content or every device.
