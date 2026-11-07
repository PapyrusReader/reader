# Papyrus Reader example

A standalone Flutter host for the reader package on Android, iOS, Web, Linux,
macOS and Windows. It includes deterministic EPUB/PDF fixtures, a local file
picker, light/dark themes and in-memory position/preferences. Saved positions
reset when the app restarts.

From this directory, using the workspace-pinned Flutter SDK when available:

```sh
flutter pub get --enforce-lockfile
flutter run
```

See [client integration](../docs/INTEGRATION.md) for production persistence and
[validation](../docs/VALIDATION.md) for automated and platform checks.
