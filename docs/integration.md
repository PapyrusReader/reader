# Papyrus client integration

The client should initially consume this repository through a path dependency.

The client owns book-byte access, PowerSync/server persistence, database IDs,
app routing, and synchronization. The reader owns parsing, rendering,
navigation, progress calculation, and reader-local UI state.

Create one `ReaderDocument` per library book. Deserialize saved state with
`ReaderLocator.fromJson`, pass it as `initialLocator`, and debounce writes from
`onLocatorChanged` in the client persistence layer. Store locator JSON without
discarding format-specific fields.

If the client supplies a `ReaderController`, it must dispose that controller.
Otherwise `PapyrusReader` creates and owns the default controller.

Do not pass PowerSync models, database sessions, or API clients into this
package.
