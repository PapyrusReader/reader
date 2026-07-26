import 'reader_locator.dart';

final class ReaderTocEntry {
  ReaderTocEntry({
    required this.title,
    required this.locator,
    List<ReaderTocEntry> children = const [],
  }) : children = List.unmodifiable(children);

  final String title;
  final ReaderLocator locator;
  final List<ReaderTocEntry> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderTocEntry &&
          title == other.title &&
          locator == other.locator &&
          _listsEqual(children, other.children);

  @override
  int get hashCode => Object.hash(title, locator, Object.hashAll(children));
}

bool _listsEqual(List<Object?> left, List<Object?> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }

  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }

  return true;
}
