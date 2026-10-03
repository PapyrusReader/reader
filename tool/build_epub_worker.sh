#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -x ../tools/dart ]; then
  dart_cli=../tools/dart
else
  dart_cli=dart
fi
if [ "${1:-}" = "--check" ]; then
  worker_temp=$(mktemp -d)
  trap 'rm -rf "$worker_temp"' EXIT
  "$dart_cli" compile js -O2 --no-source-maps -o "$worker_temp/epub_worker.js" tool/epub_worker.dart
  if ! cmp -s assets/epub_worker.js "$worker_temp/epub_worker.js"; then
    echo 'EPUB worker asset is stale. Run tool/build_epub_worker.sh.' >&2
    exit 1
  fi
else
  "$dart_cli" compile js -O2 --no-source-maps -o assets/epub_worker.js tool/epub_worker.dart
  rm -f assets/epub_worker.js.deps
fi
