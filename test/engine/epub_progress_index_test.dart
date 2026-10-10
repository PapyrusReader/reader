import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/src/engine/epub/epub_progress_index.dart';

void main() {
  test(
    'a cover and a long chapter receive content weights, not equal shares',
    () {
      final index = EpubProgressIndex([2, 998]);
      expect(index.progress(0, offset: 0), 0);
      expect(index.progress(1, offset: 0), .002);
      expect(index.progress(1, offset: 498), .5);
      expect(index.position(.5), (chapter: 1, offset: 498));
      expect(index.position(0), (chapter: 0, offset: 0));
      expect(index.position(1), (chapter: 1, offset: 998));
    },
  );

  test('empty spine items remain addressable without division by zero', () {
    final index = EpubProgressIndex([0, 0]);
    expect(index.progress(0), 0);
    expect(index.progress(1), .5);
    expect(index.position(1), (chapter: 1, offset: 0));
  });
}
