# Supported formats

| Format | Current behavior |
| --- | --- |
| Reflowable EPUB 2/3 | OPF spine, nested TOC, basic anchors, rich text, raster illustrations, scroll/pagination, adaptive spreads and content-offset resume |
| PDF | pdfrx native/WASM rendering, outline, zoom/text selection, page navigation, scroll/spreads and page-offset resume |
| Fixed-layout EPUB | Explicit unsupported-layout error |
| Encrypted/DRM books | No DRM support; encrypted PDF reports an error |
| TXT, comic archives, MOBI/AZW3 | Not implemented |

EPUB uses semantic reflow: headings, emphasis, lists, quotes, preformatted lines
and illustrations are preserved. Complex tables become readable rows; publisher
stylesheets, embedded fonts, advanced SVG/math, RTL book progression and footnote
interaction are not complete. Font choices use installed platform families.

Search, bookmarks, highlights and notes are future extensions. Do not
advertise them until their engines, UI and host persistence contracts exist.
