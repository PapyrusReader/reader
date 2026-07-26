# Supported formats

| Format | Initial support | Notes |
| --- | --- | --- |
| Reflowable EPUB 2/3 | Yes | CFI, TOC, embedded images, scroll and measured pagination |
| Fixed-layout EPUB | No | Returns `unsupportedFixedLayout` |
| PDF | Yes | Outline, page/offset restore, continuous/paginated and facing layouts |
| MOBI/AZW/AZW3 | Planned | Future conversion or engine |
| TXT | Planned | Future text engine |
| CBZ/CBR/CB7/CBT | Planned | Future comic engine |

EPUB executable content and external resource loading are removed. Only
archive-relative images resolved inside the book are embedded for display.
