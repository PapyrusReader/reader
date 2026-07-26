import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('splits blocks into multiple pages and caches identical layout', () {
    final paginator = EpubPaginator();
    final blocks = List.generate(
      40,
      (index) => 'Paragraph $index with enough words to wrap to another line.',
    );
    const preferences = ReaderPreferences();

    final first = paginator.paginate(
      blocks,
      viewport: const Size(300, 360),
      preferences: preferences,
    );
    final second = paginator.paginate(
      blocks,
      viewport: const Size(300, 360),
      preferences: preferences,
    );

    expect(first.length, greaterThan(1));
    expect(second, same(first));
  });

  test('invalidates cache when viewport or typography changes', () {
    final paginator = EpubPaginator();
    final blocks = List.generate(20, (index) => 'Paragraph $index text.');
    final first = paginator.paginate(
      blocks,
      viewport: const Size(300, 360),
      preferences: const ReaderPreferences(),
    );
    final resized = paginator.paginate(
      blocks,
      viewport: const Size(420, 360),
      preferences: const ReaderPreferences(),
    );
    final restyled = paginator.paginate(
      blocks,
      viewport: const Size(300, 360),
      preferences: const ReaderPreferences(fontSize: 25),
    );

    expect(resized, isNot(same(first)));
    expect(restyled, isNot(same(first)));
  });

  test('compares block content instead of trusting a hash collision', () {
    final paginator = EpubPaginator();
    const viewport = Size(300, 360);
    const preferences = ReaderPreferences();
    final collision = _findBlockHashCollision();

    final first = paginator.paginate(
      [collision.first],
      viewport: viewport,
      preferences: preferences,
    );
    final second = paginator.paginate(
      [collision.second],
      viewport: viewport,
      preferences: preferences,
    );

    expect(collision.first, isNot(collision.second));
    expect(
      Object.hashAll([collision.first]),
      Object.hashAll([collision.second]),
    );
    expect(first.expand((page) => page), [collision.first]);
    expect(second.expand((page) => page), [collision.second]);
  });

  test('evicts the previous pagination entry', () {
    final paginator = EpubPaginator();
    const viewport = Size(300, 360);
    const preferences = ReaderPreferences();
    final first = paginator.paginate(
      const ['first'],
      viewport: viewport,
      preferences: preferences,
    );

    paginator.paginate(
      const ['second'],
      viewport: viewport,
      preferences: preferences,
    );
    final reloaded = paginator.paginate(
      const ['first'],
      viewport: viewport,
      preferences: preferences,
    );

    expect(reloaded, isNot(same(first)));
  });

  test('clear invalidates the cached pagination entry', () {
    final paginator = EpubPaginator();
    const blocks = ['cached'];
    const viewport = Size(300, 360);
    const preferences = ReaderPreferences();
    final first = paginator.paginate(
      blocks,
      viewport: viewport,
      preferences: preferences,
    );

    expect(() => (paginator as dynamic).clear(), returnsNormally);
    final reloaded = paginator.paginate(
      blocks,
      viewport: viewport,
      preferences: preferences,
    );

    expect(reloaded, isNot(same(first)));
  });

  test('splits one oversized paragraph into lossless bounded fragments', () {
    final paginator = EpubPaginator();
    final paragraph = List.generate(500, (index) => 'word$index').join(' ');
    const preferences = ReaderPreferences(
      fontSize: 18,
      lineHeight: 1.5,
      paragraphSpacing: 8,
      pageMargins: EdgeInsets.all(24),
    );
    const viewport = Size(300, 240);
    final pages = paginator.paginate(
      [paragraph],
      viewport: viewport,
      preferences: preferences,
    );
    final usableWidth = viewport.width - preferences.pageMargins.horizontal;
    final usableHeight = viewport.height - preferences.pageMargins.vertical;

    expect(pages.length, greaterThan(1));
    for (final page in pages) {
      var pageHeight = 0.0;
      for (final fragment in page) {
        final painter = TextPainter(
          text: TextSpan(
            text: fragment,
            style: const TextStyle(fontSize: 18, height: 1.5),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: usableWidth);
        pageHeight += painter.height + preferences.paragraphSpacing;
      }
      expect(pageHeight, lessThanOrEqualTo(usableHeight));
    }

    String normalized(String value) =>
        value.replaceAll(RegExp(r'\s+'), ' ').trim();
    expect(
      normalized(pages.expand((page) => page).join(' ')),
      normalized(paragraph),
    );
  });
}

({String first, String second}) _findBlockHashCollision() {
  final seen = <int, String>{};

  for (var index = 0; index < 300000; index++) {
    final value = 'block-$index';
    final hash = Object.hashAll([value]);
    final previous = seen[hash];
    if (previous != null && previous != value) {
      return (first: previous, second: value);
    }
    seen[hash] = value;
  }

  throw StateError('Could not find a block-content hash collision.');
}
