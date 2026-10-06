import 'reader_locator.dart';

/// Navigation is descriptive; hosts must not count skipped locator distances.
enum ReaderNavigationCause { restore, turn, jump, reflow, viewport }

/// Stable visible content. EPUB extents use normalized chapter UTF-16 offsets.
final class ReaderContentCoverage {
  const ReaderContentCoverage({
    required this.key,
    required this.start,
    required this.end,
    this.chapterCount,
    this.pdfPageIndex,
  });
  final String key;
  final double start;
  final double end;
  final int? chapterCount;
  final int? pdfPageIndex;
}

/// Generic observation only. The host owns timing, persistence, and goal rules.
final class ReaderActivityEvent {
  const ReaderActivityEvent({
    required this.ready,
    required this.visible,
    required this.cause,
    this.locator,
    this.coverage = const [],
    this.atEnd = false,
  });
  final bool ready;
  final bool visible;
  final ReaderNavigationCause cause;
  final ReaderLocator? locator;
  final List<ReaderContentCoverage> coverage;
  final bool atEnd;
}
