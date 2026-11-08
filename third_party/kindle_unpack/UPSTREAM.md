# Kindle decoder provenance

Vendored from [`kindle_unpack` 0.2.0](https://pub.dev/packages/kindle_unpack/versions/0.2.0),
[upstream repository](https://github.com/emaurel/kindle_unpack). The upstream GPL-3.0
license is retained in LICENSE and included in generated browser worker notices.

Papyrus changes:

- Use archive's pure Dart ZLibDecoder for embedded fonts instead of dart:io,
  so the same parser runs in browser workers and native isolates.

- Resolve KF8 indices relative to the KF8 section in dual-format files, retain
  shared images from the MOBI section, and recognize both boundary conventions.

Keep format-specific integration and sanitization in the reader's formats folder.
The source book is never rewritten. This package does not remove DRM.
