# Architecture

The package has four layers:

1. **Domain** — immutable documents, preferences, capabilities, TOC entries,
   snapshots, errors, and versioned locators.
2. **Controller** — serialized loading/navigation, engine ownership, lifecycle
   protection, and host callbacks.
3. **Engines** — factory-created EPUB and PDF implementations behind
   `ReaderEngine`.
4. **Presentation** — `PapyrusReader`, Material 3 defaults, responsive panels,
   theming, and replaceable builders.

The host supplies a byte loader and optional saved location/preferences. The
controller publishes immutable snapshots and returns state through callbacks.
It never writes to a database or synchronizes directly.

`ReaderEngineRegistration` stores factories rather than shared engine
instances, so each controller owns isolated document state.

EPUB uses `epub_pro` for package/spine/CFI handling. Sanitized XHTML is rendered
through a Papyrus-owned abstraction. Pagination uses measured bounded blocks
and a one-entry layout cache.

PDF uses `pdfrx` behind `PdfFacade`. Temporary metadata documents are disposed
after outline/page inspection and viewer references can safely remount.

Add formats through `ReaderEngineRegistration`, replace UI with
`ReaderUiBuilders`, override chrome with `ReaderThemeData`, and persist
`ReaderLocator.toJson()` in the host.
