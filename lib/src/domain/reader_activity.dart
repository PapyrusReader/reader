import 'package:flutter/foundation.dart';

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

  static const int currentVersion = 1;
  final String key;
  final double start;
  final double end;
  final int? chapterCount;
  final int? pdfPageIndex;

  factory ReaderContentCoverage.fromJson(Map<String, Object?> json) {
    if (json['version'] != currentVersion) {
      throw FormatException(
        'Unsupported content coverage version: ${json['version']}.',
      );
    }
    final key = json['key'];
    final start = json['start'];
    final end = json['end'];
    final chapters = json['chapterCount'];
    final page = json['pdfPageIndex'];
    if (key is! String ||
        start is! num ||
        end is! num ||
        (chapters != null && chapters is! int) ||
        (page != null && page is! int)) {
      throw const FormatException('Invalid content coverage fields.');
    }
    final coverage = ReaderContentCoverage(
      key: key,
      start: start.toDouble(),
      end: end.toDouble(),
      chapterCount: chapters as int?,
      pdfPageIndex: page as int?,
    );
    coverage._validate();
    return coverage;
  }

  Map<String, Object?> toJson() {
    _validate();
    return {
      'version': currentVersion,
      'key': key,
      'start': start,
      'end': end,
      if (chapterCount != null) 'chapterCount': chapterCount,
      if (pdfPageIndex != null) 'pdfPageIndex': pdfPageIndex,
    };
  }

  void _validate() {
    if (key.trim().isEmpty ||
        !start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end > 1 ||
        end < start ||
        (chapterCount != null && chapterCount! <= 0) ||
        (pdfPageIndex != null && pdfPageIndex! < 0)) {
      throw const FormatException(
        'Invalid content coverage range or identity.',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderContentCoverage &&
          key == other.key &&
          start == other.start &&
          end == other.end &&
          chapterCount == other.chapterCount &&
          pdfPageIndex == other.pdfPageIndex;

  @override
  int get hashCode => Object.hash(key, start, end, chapterCount, pdfPageIndex);
}

/// Generic observation only. The host owns timing, persistence, and goal rules.
final class ReaderActivityEvent {
  ReaderActivityEvent({
    required this.ready,
    required this.visible,
    required this.cause,
    this.locator,
    List<ReaderContentCoverage> coverage = const [],
    this.atEnd = false,
  }) : coverage = List.unmodifiable(coverage);

  static const int currentVersion = 1;
  final bool ready;
  final bool visible;
  final ReaderNavigationCause cause;
  final ReaderLocator? locator;
  final List<ReaderContentCoverage> coverage;
  final bool atEnd;

  factory ReaderActivityEvent.fromJson(Map<String, Object?> json) {
    if (json['version'] != currentVersion) {
      throw FormatException(
        'Unsupported reader activity version: ${json['version']}.',
      );
    }
    final ready = json['ready'];
    final visible = json['visible'];
    final atEnd = json['atEnd'];
    final cause = json['cause'];
    final locator = json['locator'];
    final coverage = json['coverage'];
    if (ready is! bool ||
        visible is! bool ||
        atEnd is! bool ||
        coverage is! List ||
        (locator != null && locator is! Map<String, Object?>) ||
        !ReaderNavigationCause.values.any((value) => value.name == cause) ||
        coverage.any((value) => value is! Map<String, Object?>)) {
      throw const FormatException('Invalid reader activity fields.');
    }
    return ReaderActivityEvent(
      ready: ready,
      visible: visible,
      atEnd: atEnd,
      cause: ReaderNavigationCause.values.firstWhere(
        (value) => value.name == cause,
      ),
      locator: locator == null
          ? null
          : ReaderLocator.fromJson(locator as Map<String, Object?>),
      coverage: coverage
          .map(
            (value) =>
                ReaderContentCoverage.fromJson(value as Map<String, Object?>),
          )
          .toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'version': currentVersion,
    'ready': ready,
    'visible': visible,
    'atEnd': atEnd,
    'cause': cause.name,
    if (locator != null) 'locator': locator!.toJson(),
    'coverage': coverage.map((value) => value.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderActivityEvent &&
          ready == other.ready &&
          visible == other.visible &&
          cause == other.cause &&
          locator == other.locator &&
          atEnd == other.atEnd &&
          listEquals(coverage, other.coverage);

  @override
  int get hashCode => Object.hash(
    ready,
    visible,
    cause,
    locator,
    atEnd,
    Object.hashAll(coverage),
  );
}
