sealed class ReaderLocator {
  const ReaderLocator();

  static const int currentVersion = 1;

  factory ReaderLocator.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version != currentVersion) {
      throw FormatException('Unsupported reader locator version: $version.');
    }

    return switch (json['type']) {
      'epub' => EpubReaderLocator._fromJson(json),
      'pdf' => PdfReaderLocator._fromJson(json),
      final type => throw FormatException(
        'Unsupported reader locator type: $type.',
      ),
    };
  }

  Map<String, Object?> toJson();
}

final class EpubReaderLocator extends ReaderLocator {
  factory EpubReaderLocator({
    required String cfi,
    required int spineIndex,
    required double localProgression,
    required double totalProgression,
  }) {
    if (cfi.trim().isEmpty) {
      throw ArgumentError.value(cfi, 'cfi', 'must not be empty');
    }
    if (spineIndex < 0) {
      throw ArgumentError.value(
        spineIndex,
        'spineIndex',
        'must be non-negative',
      );
    }
    _validateProgressionArgument(localProgression, 'localProgression');
    _validateProgressionArgument(totalProgression, 'totalProgression');

    return EpubReaderLocator._(
      cfi: cfi,
      spineIndex: spineIndex,
      localProgression: localProgression,
      totalProgression: totalProgression,
    );
  }

  const EpubReaderLocator._({
    required this.cfi,
    required this.spineIndex,
    required this.localProgression,
    required this.totalProgression,
  });

  factory EpubReaderLocator._fromJson(Map<String, Object?> json) {
    final cfi = json['cfi'];
    final spineIndex = json['spineIndex'];

    if (cfi is! String || cfi.trim().isEmpty) {
      throw const FormatException('EPUB locator CFI must not be empty.');
    }
    if (spineIndex is! int || spineIndex < 0) {
      throw const FormatException(
        'EPUB locator spineIndex must be a non-negative integer.',
      );
    }

    return EpubReaderLocator._(
      cfi: cfi,
      spineIndex: spineIndex,
      localProgression: _readProgression(json, 'localProgression'),
      totalProgression: _readProgression(json, 'totalProgression'),
    );
  }

  final String cfi;
  final int spineIndex;
  final double localProgression;
  final double totalProgression;

  @override
  Map<String, Object?> toJson() {
    if (cfi.isEmpty || spineIndex < 0) {
      throw const FormatException('Cannot serialize an invalid EPUB locator.');
    }
    _validateProgression(localProgression, 'localProgression');
    _validateProgression(totalProgression, 'totalProgression');

    return {
      'version': ReaderLocator.currentVersion,
      'type': 'epub',
      'cfi': cfi,
      'spineIndex': spineIndex,
      'localProgression': localProgression,
      'totalProgression': totalProgression,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpubReaderLocator &&
          cfi == other.cfi &&
          spineIndex == other.spineIndex &&
          localProgression == other.localProgression &&
          totalProgression == other.totalProgression;

  @override
  int get hashCode =>
      Object.hash(cfi, spineIndex, localProgression, totalProgression);
}

final class PdfReaderLocator extends ReaderLocator {
  factory PdfReaderLocator({
    required int pageIndex,
    required double pageOffset,
    required double totalProgression,
  }) {
    if (pageIndex < 0) {
      throw ArgumentError.value(pageIndex, 'pageIndex', 'must be non-negative');
    }
    _validateProgressionArgument(pageOffset, 'pageOffset');
    _validateProgressionArgument(totalProgression, 'totalProgression');

    return PdfReaderLocator._(
      pageIndex: pageIndex,
      pageOffset: pageOffset,
      totalProgression: totalProgression,
    );
  }

  const PdfReaderLocator._({
    required this.pageIndex,
    required this.pageOffset,
    required this.totalProgression,
  });

  factory PdfReaderLocator._fromJson(Map<String, Object?> json) {
    final pageIndex = json['pageIndex'];
    if (pageIndex is! int || pageIndex < 0) {
      throw const FormatException(
        'PDF locator pageIndex must be a non-negative integer.',
      );
    }

    return PdfReaderLocator._(
      pageIndex: pageIndex,
      pageOffset: _readProgression(json, 'pageOffset'),
      totalProgression: _readProgression(json, 'totalProgression'),
    );
  }

  final int pageIndex;
  final double pageOffset;
  final double totalProgression;

  @override
  Map<String, Object?> toJson() {
    if (pageIndex < 0) {
      throw const FormatException('Cannot serialize an invalid PDF locator.');
    }
    _validateProgression(pageOffset, 'pageOffset');
    _validateProgression(totalProgression, 'totalProgression');

    return {
      'version': ReaderLocator.currentVersion,
      'type': 'pdf',
      'pageIndex': pageIndex,
      'pageOffset': pageOffset,
      'totalProgression': totalProgression,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfReaderLocator &&
          pageIndex == other.pageIndex &&
          pageOffset == other.pageOffset &&
          totalProgression == other.totalProgression;

  @override
  int get hashCode => Object.hash(pageIndex, pageOffset, totalProgression);
}

double _readProgression(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException('Reader locator $key must be a number.');
  }

  final progression = value.toDouble();
  _validateProgression(progression, key);

  return progression;
}

void _validateProgression(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw FormatException('Reader locator $name must be between 0 and 1.');
  }
}

void _validateProgressionArgument(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(value, name, 'must be between 0 and 1');
  }
}
