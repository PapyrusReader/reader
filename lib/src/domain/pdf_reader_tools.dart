import 'package:flutter/foundation.dart';

enum PdfFitMode { page, width, custom }

/// Device-local viewing preferences, separate from the synchronized reading locator.
final class PdfViewState {
  const PdfViewState({
    required this.pageIndex,
    required this.zoom,
    required this.centerX,
    required this.centerY,
    required this.fitMode,
  });

  final int pageIndex;
  final double zoom;
  final double centerX;
  final double centerY;
  final PdfFitMode fitMode;

  Map<String, Object?> toJson() => {
    'pageIndex': pageIndex,
    'zoom': zoom,
    'centerX': centerX,
    'centerY': centerY,
    'fitMode': fitMode.name,
  };

  factory PdfViewState.fromJson(Map<String, Object?> json) {
    final page = json['pageIndex'];
    final zoom = json['zoom'];
    final x = json['centerX'];
    final y = json['centerY'];
    final mode = PdfFitMode.values
        .where((mode) => mode.name == json['fitMode'])
        .firstOrNull;

    bool fraction(Object? value) =>
        value is num && value.isFinite && value >= 0 && value <= 1;

    if (page is! int ||
        page < 0 ||
        zoom is! num ||
        !zoom.isFinite ||
        zoom < .1 ||
        zoom > 8 ||
        !fraction(x) ||
        !fraction(y) ||
        mode == null) {
      throw const FormatException('Invalid PDF view state.');
    }

    return PdfViewState(
      pageIndex: page,
      zoom: zoom.toDouble(),
      centerX: (x as num).toDouble(),
      centerY: (y as num).toDouble(),
      fitMode: mode,
    );
  }
}

final class PdfSearchMatch {
  const PdfSearchMatch({required this.pageNumber, required this.text});

  final int pageNumber;
  final String text;
}

/// Optional PDF tools. Custom facades need not expose these controls.
abstract class PdfReaderTools extends ChangeNotifier {
  bool get isReady;
  int get pageCount;
  int get pageNumber;
  double get zoom;
  double get minimumZoom;
  double get maximumZoom;
  bool get canReturn;
  bool get canGoForward;
  bool get searching;
  String get query;
  List<PdfSearchMatch> get matches;
  int? get currentMatch;

  Future<void> setZoom(double zoom);

  /// Scroll vertically by a distance in PDF document coordinates.
  Future<void> scrollVertically(double distance);
  Future<void> fitPage();
  Future<void> fitWidth();
  Future<void> goToPage(int pageNumber);

  /// Restore the view before the last page, search, or internal-link jump.
  Future<void> returnToPrevious();

  /// Revisit a location left via [returnToPrevious]. New jumps clear this stack.
  Future<void> goForward();
  void search(String query);
  Future<void> selectMatch(int index);
}
