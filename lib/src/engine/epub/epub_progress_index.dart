import 'dart:math' as math;

/// Stable content coordinates independent of pagination and chapter count.
final class EpubProgressIndex {
  EpubProgressIndex(List<int> lengths)
    : lengths = List.unmodifiable(lengths),
      starts = [0] {
    for (final length in lengths) {
      starts.add(starts.last + math.max(1, length));
    }
  }

  final List<int> lengths;
  final List<int> starts;

  double progress(int chapter, {int? offset, double local = 0}) {
    final weight = starts[chapter + 1] - starts[chapter];
    final within = offset == null ? local * weight : offset.clamp(0, weight);
    return ((starts[chapter] + within) / starts.last).clamp(0, 1);
  }

  ({int chapter, int offset}) position(double progress) {
    final target = progress * starts.last;
    var chapter = lengths.length - 1;

    for (var index = 0; index < lengths.length; index++) {
      if (target < starts[index + 1]) {
        chapter = index;
        break;
      }
    }

    return (
      chapter: chapter,
      offset: (target - starts[chapter]).round().clamp(0, lengths[chapter]),
    );
  }
}
