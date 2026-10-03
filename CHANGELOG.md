# Changelog

## Unreleased

- Process EPUB archives and chapters in cancellable native/browser workers.
- Follow OPF spine order independently of TOC hierarchy and restore TOC anchors.
- Add rich lazy pagination, adaptive spreads and page-first navigation.
- Preserve EPUB content offsets through typography and viewport changes.
- Keep reading viewports mounted during progress updates; add typeface controls,
  consistent appearance and escapable loading/error screens.
- Share one pdfrx document between metadata and rendering; report PDF page offsets.
- Fit and turn bounded PDF pages/spreads in paginated mode; preserve scale on
  appearance changes and refit after column, mode and viewport changes.
- Retain keyboard navigation across EPUB chapters and correct reader settings
  colors under opposite host themes and in open mobile sheets.
- Add a long-chapter reading lab, architecture plan and platform integration guide.

## 0.0.1

- Add reflowable EPUB 2/3 and PDF engines.
- Add serializable locations and host-owned persistence callbacks.
- Add responsive, themeable Material 3 reader UI.
- Add scroll/paginated navigation, TOC/outline, appearance controls, and
  keyboard navigation.
- Add a six-platform example with deterministic EPUB/PDF assets.
