# Real-book regression fixtures

These unmodified Project Gutenberg EPUBs retain the credits and licensing
information embedded by their publisher. Tests run offline against these exact
bytes; do not silently refresh them when Gutenberg republishes an edition.

| File | Source | SHA-256 |
| --- | --- | --- |
| `alice.epub` | [Alice's Adventures in Wonderland, EPUB3 with images](https://www.gutenberg.org/ebooks/11.epub3.images) | `4f81245d31380ac1d6eafb9a321e3691369bc70985736ae4bccf849a4f784036` |
| `pride-and-prejudice.epub` | [Pride and Prejudice, EPUB without illustrations](https://www.gutenberg.org/ebooks/1342.epub.noimages) | `e59e587472723023b21bf380b8327858e7540b25e57affa3a68935b291e370dc` |

Alice is the locally downloaded edition used to reproduce the reported blank
SVG-wrapped cover and 7% progress jump. Pride and Prejudice was retrieved on
2026-10-10; its smaller, unillustrated edition supplies a second publisher layout
without adding the 24 MB illustrated edition to the repository.

The user's SQL Performance Explained EPUB is a local-only validation input and
must not be copied into this fixture directory.

The Kindle fixtures were retrieved for format decoding regressions on 2026-11-08:

| File | Source | SHA-256 |
| --- | --- | --- |
| `alice.mobi` | [Older Kindle edition](https://www.gutenberg.org/ebooks/11.kindle.images) | `1b4222ffdf1862a39d0fae6d42c588f28a34c12ad73cc21c2849fe2646cac3e1` |
| `alice.azw3` | [KF8 edition](https://www.gutenberg.org/ebooks/11.kf8.images) | `d8211269aed55ded8302f289950936db8368b4d4d384c463b722034152f8f1d2` |
