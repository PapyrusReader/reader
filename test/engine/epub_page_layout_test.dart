import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/epub_page_layout.dart';
import 'package:papyrus_reader/src/engine/epub/epub_rich_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a huge unchaptered stream measures only the requested pages', () async {
    final source = _CountingBlocks(10000);
    final layout = EpubPageLayout(
      paginateEpub(
        EpubContentBlocks(source),
        contentSize: const Size(280, 60),
        preferences: const ReaderPreferences(),
        textScaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        cancelled: () => false,
      ),
    );
    addTearDown(layout.dispose);
    await layout.ensure(count: 4);
    expect(layout.pages, hasLength(4));
    expect(layout.complete, isFalse);
    expect(source.reads, lessThan(12));
    final first = layout.pages.first;

    await Future.wait([layout.ensure(count: 8), layout.ensure(count: 10)]);
    expect(layout.pages, hasLength(10));
    expect(identical(first, layout.pages.first), isTrue);
    expect(layout.pages.map((page) => page.offset).toSet(), hasLength(10));
    expect(source.reads, lessThan(30));

    await layout.ensure(offset: 4000);
    expect(layout.pages.last.offset, greaterThan(4000));
    expect(source.reads, lessThan(100));
  });

  test(
    'background totals do not expand or consume the reading window',
    () async {
      Stream<EpubRichPage> source() async* {
        for (var index = 0; index < 100; index++) {
          final block = EpubContentBlock({
            'kind': 'p',
            'offset': index * 100,
            'length': 90,
            'runs': [
              {'text': 'A page'},
            ],
          });
          yield EpubRichPage([EpubPageFragment(block, 0, 90, 30)]);
        }
      }

      final layout = EpubPageLayout(source(), countSource: source);
      addTearDown(layout.dispose);
      await layout.ensure(count: 4);
      expect(layout.pageCount, isNull);
      expect(layout.estimatedPageCount(10000), 100);
      await layout.countPages();
      expect(layout.pageCount, 100);
      expect(layout.pages, hasLength(4));
      expect(layout.complete, isFalse);
      await layout.ensure(count: 5);
      expect(layout.pages.last.offset, 400);
      expect(layout.pageCount, 100);
    },
  );

  test('a failed background count cannot publish a truncated total', () async {
    Stream<EpubRichPage> source() async* {
      yield const EpubRichPage([]);
      throw StateError('Unreadable content');
    }

    final layout = EpubPageLayout(source(), countSource: source);
    addTearDown(layout.dispose);
    await layout.ensure(count: 1);
    await expectLater(layout.countPages(), throwsStateError);
    await layout.countPages();
    expect(layout.pageCount, isNull);
  });

  testWidgets('disposing a cursor cancels pending background yields', (
    tester,
  ) async {
    final layout = EpubPageLayout(const Stream.empty());
    final waiting = layout.yieldWork();
    layout.dispose();
    await waiting;
  });

  test('a layout failure must not become a false end of the book', () async {
    Stream<EpubRichPage> source() async* {
      yield const EpubRichPage([]);
      throw StateError('Unreadable content');
    }

    final layout = EpubPageLayout(source());
    addTearDown(layout.dispose);
    await layout.ensure(count: 1);
    await expectLater(layout.ensure(count: 2), throwsStateError);
    await expectLater(layout.ensure(count: 2), throwsStateError);
    expect(layout.complete, isFalse);
    expect(layout.pages, hasLength(1));
  });

  test('cancelling speculation does not discard a foreground cursor', () async {
    final layout = EpubPageLayout(
      Stream.fromIterable([
        for (var i = 0; i < 100; i++) const EpubRichPage([]),
      ]),
    );
    addTearDown(layout.dispose);
    await layout.ensure(count: 3);
    await layout.ensure(toEnd: true, cancelled: () => true);
    expect(layout.pages, hasLength(3));
    await layout.ensure(count: 5);
    expect(layout.pages, hasLength(5));
    layout.dispose();
    await layout.ensure(toEnd: true);
    expect(layout.pages, hasLength(5));
  });
}

final class _CountingBlocks extends ListBase<Object?> {
  _CountingBlocks(this.length);
  @override
  final int length;
  int reads = 0;

  @override
  Object? operator [](int index) {
    reads++;
    final text = 'Passage $index continues without any chapter break. ';
    return {
      'kind': 'p',
      'offset': index * 100,
      'length': text.length,
      'runs': [
        {'text': text},
      ],
    };
  }

  @override
  set length(int value) => throw UnsupportedError('Read-only');
  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('Read-only');
}
