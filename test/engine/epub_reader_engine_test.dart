import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:papyrus_reader/papyrus_reader.dart';

import '../support/synthetic_epub.dart';

void main() {
  ReaderDocument document(Uint8List bytes, {String id = 'epub'}) {
    return ReaderDocument(
      id: id,
      format: ReaderFormat.epub,
      loadBytes: () async => bytes,
    );
  }

  group('EpubReaderEngine', () {
    test(
      'lazily loads a valid EPUB and builds nested table of contents',
      () async {
        var loads = 0;
        final book = ReaderDocument(
          id: 'book',
          format: ReaderFormat.epub,
          loadBytes: () async {
            loads++;
            return syntheticEpub();
          },
        );
        final engine = EpubReaderEngine();

        expect(loads, 0);
        await engine.load(book, preferences: const ReaderPreferences());

        expect(loads, 1);
        expect(engine.snapshot, isA<ReaderReadySnapshot>());
        expect(engine.snapshot.toc.map((entry) => entry.title), [
          'Chapter One',
          'Chapter Two',
        ]);
        expect(engine.snapshot.toc.first.children.single.title, 'Part A');
        expect(engine.currentChapterHtml, contains('Chapter One'));
      },
    );

    test('restores, navigates, and publishes CFI locators', () async {
      final engine = EpubReaderEngine();
      final book = document(syntheticEpub());
      final restored = EpubReaderLocator(
        cfi: 'epubcfi(/6/4!/4/1:0)',
        spineIndex: 1,
        localProgression: 0.2,
        totalProgression: 0.6,
      );

      await engine.load(
        book,
        initialLocator: restored,
        preferences: const ReaderPreferences(),
      );
      expect(await engine.currentLocator(), restored);
      expect(engine.currentChapterHtml, contains('Chapter Two'));

      await engine.goPrevious();
      expect(
        (await engine.currentLocator() as EpubReaderLocator).spineIndex,
        0,
      );
      await engine.goNext();
      expect(
        (await engine.currentLocator() as EpubReaderLocator).spineIndex,
        1,
      );

      await engine.goTo(
        EpubReaderLocator(
          cfi: 'epubcfi(/6/6!/4/1:0)',
          spineIndex: 2,
          localProgression: 0,
          totalProgression: 1,
        ),
      );
      await expectLater(
        engine.goNext(),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code.name,
            'code name',
            'navigationBoundary',
          ),
        ),
      );
      await expectLater(
        engine.goTo(
          PdfReaderLocator(pageIndex: 0, pageOffset: 0, totalProgression: 0),
        ),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.invalidDocument,
          ),
        ),
      );
    });

    test('maps continuous progress across spine and local progress', () async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub()),
        preferences: const ReaderPreferences(),
      );

      await engine.goToProgress(0.5);

      final middle = await engine.currentLocator() as EpubReaderLocator;
      expect(middle.spineIndex, 1);
      expect(middle.localProgression, 0.5);
      expect(middle.totalProgression, 0.5);
      expect(engine.currentChapterHtml, contains('Chapter Two'));

      await engine.goToProgress(1);

      final end = await engine.currentLocator() as EpubReaderLocator;
      expect(end.spineIndex, 2);
      expect(end.localProgression, 1);
      expect(end.totalProgression, 1);
    });

    test('rejects invalid continuous progress', () async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub()),
        preferences: const ReaderPreferences(),
      );

      await expectLater(engine.goToProgress(-0.1), throwsArgumentError);
      await expectLater(engine.goToProgress(1.1), throwsArgumentError);
      await expectLater(
        engine.goToProgress(double.infinity),
        throwsArgumentError,
      );
    });

    test('rejects an out-of-bounds restored locator', () async {
      final engine = EpubReaderEngine();

      await expectLater(
        engine.load(
          document(syntheticEpub()),
          initialLocator: EpubReaderLocator(
            cfi: 'epubcfi(/6/18!/4/1:0)',
            spineIndex: 8,
            localProgression: 0,
            totalProgression: 1,
          ),
          preferences: const ReaderPreferences(),
        ),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.invalidDocument,
          ),
        ),
      );
    });

    test('maps malformed and fixed-layout books to stable errors', () async {
      final malformed = EpubReaderEngine();
      await expectLater(
        malformed.load(
          document(Uint8List.fromList([1, 2, 3])),
          preferences: const ReaderPreferences(),
        ),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.invalidDocument,
          ),
        ),
      );

      final fixed = EpubReaderEngine();
      await expectLater(
        fixed.load(
          document(syntheticEpub(fixedLayout: true)),
          preferences: const ReaderPreferences(),
        ),
        throwsA(
          isA<ReaderException>().having(
            (error) => error.code,
            'code',
            ReaderErrorCode.unsupportedFixedLayout,
          ),
        ),
      );
    });

    test('applies preference changes to the ready snapshot', () async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub()),
        preferences: const ReaderPreferences(),
      );
      const updated = ReaderPreferences(
        fontSize: 24,
        layoutMode: ReaderLayoutMode.scroll,
      );

      await engine.updatePreferences(updated);

      expect(engine.snapshot.preferences, updated);
    });

    test(
      'clears pagination cache when documents and chapters change',
      () async {
        final paginator = TrackingEpubPaginator();
        final engine = EpubReaderEngine(paginator: paginator);

        await engine.load(
          document(syntheticEpub(), id: 'first'),
          preferences: const ReaderPreferences(),
        );
        await engine.goNext();
        await engine.load(
          document(syntheticEpub(), id: 'second'),
          preferences: const ReaderPreferences(),
        );

        expect(paginator.clearCount, 3);
      },
    );

    test(
      'failed chapter navigation preserves the ready chapter state',
      () async {
        final paginator = TrackingEpubPaginator();
        final engine = EpubReaderEngine(paginator: paginator);
        await engine.load(
          document(syntheticEpub(corruptSecondChapter: true)),
          preferences: const ReaderPreferences(),
        );
        final previousSnapshot = engine.snapshot;
        final previousLocator = await engine.currentLocator();
        final previousHtml = engine.currentChapterHtml;
        final previousClearCount = paginator.clearCount;

        await expectLater(engine.goNext(), throwsA(anything));

        expect(engine.snapshot, same(previousSnapshot));
        expect(await engine.currentLocator(), same(previousLocator));
        expect(engine.currentChapterHtml, previousHtml);
        expect(paginator.clearCount, previousClearCount);
      },
    );

    test('failed initial chapter load leaves the engine idle', () async {
      final paginator = TrackingEpubPaginator();
      final engine = EpubReaderEngine(paginator: paginator);
      final restored = EpubReaderLocator(
        cfi: 'epubcfi(/6/4!/4/1:0)',
        spineIndex: 1,
        localProgression: 0,
        totalProgression: 1 / 3,
      );

      await expectLater(
        engine.load(
          document(syntheticEpub(corruptSecondChapter: true)),
          initialLocator: restored,
          preferences: const ReaderPreferences(),
        ),
        throwsA(isA<ReaderException>()),
      );

      expect(engine.snapshot, isA<ReaderIdleSnapshot>());
      expect(await engine.currentLocator(), isNull);
      expect(engine.currentChapterHtml, isEmpty);
      expect(paginator.clearCount, 0);
      expect(
        () => engine.buildViewport(FakeBuildContext()),
        throwsA(isA<ReaderException>()),
      );
    });

    test(
      'failed replacement load preserves the ready document state',
      () async {
        final paginator = TrackingEpubPaginator();
        final engine = EpubReaderEngine(paginator: paginator);
        await engine.load(
          document(syntheticEpub(), id: 'ready'),
          preferences: const ReaderPreferences(),
        );
        final previousSnapshot = engine.snapshot;
        final previousLocator = await engine.currentLocator();
        final previousHtml = engine.currentChapterHtml;
        final previousClearCount = paginator.clearCount;
        final restored = EpubReaderLocator(
          cfi: 'epubcfi(/6/4!/4/1:0)',
          spineIndex: 1,
          localProgression: 0,
          totalProgression: 1 / 3,
        );

        await expectLater(
          engine.load(
            document(
              syntheticEpub(corruptSecondChapter: true),
              id: 'replacement',
            ),
            initialLocator: restored,
            preferences: const ReaderPreferences(fontSize: 24),
          ),
          throwsA(isA<ReaderException>()),
        );

        expect(engine.snapshot, same(previousSnapshot));
        expect(await engine.currentLocator(), same(previousLocator));
        expect(engine.currentChapterHtml, previousHtml);
        expect(paginator.clearCount, previousClearCount);
      },
    );

    test(
      'sanitizes active content and resource-loading URLs with a DOM',
      () async {
        final engine = EpubReaderEngine();
        await engine.load(
          document(syntheticEpub(malicious: true)),
          preferences: const ReaderPreferences(),
        );

        final fragment = html_parser.parseFragment(engine.currentChapterHtml);
        const forbiddenTags = {
          'script',
          'form',
          'iframe',
          'object',
          'embed',
          'input',
          'button',
          'link',
          'style',
          'video',
          'audio',
          'source',
          'track',
          'use',
        };

        for (final tag in forbiddenTags) {
          expect(fragment.querySelectorAll(tag), isEmpty, reason: '<$tag>');
        }
        for (final element in fragment.querySelectorAll('*')) {
          expect(
            element.attributes.keys.where(
              (name) => name.toString().toLowerCase().startsWith('on'),
            ),
            isEmpty,
          );
          expect(element.attributes.containsKey('srcset'), isFalse);
        }

        final images = fragment.querySelectorAll('img');
        expect(images, hasLength(1));
        expect(images.single.attributes['src'], startsWith('data:image/png;'));
        expect(images.single.attributes.containsKey('onerror'), isFalse);

        final styled = fragment.querySelector('#styled')!;
        expect(styled.attributes['style'], contains('color: red'));
        expect(styled.attributes['style'], isNot(contains('url(')));
        expect(styled.attributes['style'], isNot(contains('expression(')));
        expect(styled.attributes.containsKey('onclick'), isFalse);

        expect(
          fragment.querySelector('#safe-link')!.attributes['href'],
          'https://example.com/chapter',
        );
        expect(
          fragment
              .querySelector('#unsafe-link')!
              .attributes
              .containsKey('href'),
          isFalse,
        );
      },
    );
  });

  testWidgets(
    'scroll viewport renders sanitized EPUB content and local image',
    (tester) async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub(malicious: true)),
        preferences: const ReaderPreferences(
          layoutMode: ReaderLayoutMode.scroll,
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: engine.buildViewport),
        ),
      );
      await tester.pump();

      expect(find.text('Chapter One'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('window.evil'), findsNothing);
      expect(find.byType(EditableText), findsNothing);
    },
  );

  testWidgets('paginated viewport splits content into bounded pages', (
    tester,
  ) async {
    final engine = EpubReaderEngine();
    await engine.load(
      document(syntheticEpub(longChapter: true)),
      preferences: const ReaderPreferences(
        layoutMode: ReaderLayoutMode.paginated,
      ),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 400,
          child: Builder(builder: engine.buildViewport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsOneWidget);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.childrenDelegate.estimatedChildCount, greaterThan(1));
  });

  testWidgets('paginated text blocks preserve sanitized semantic content', (
    tester,
  ) async {
    final engine = EpubReaderEngine();
    await engine.load(
      document(
        syntheticEpub(
          firstChapterBody: '''
<h1>Fish &amp; Chips</h1>
<p>First<br/>second <em>inline</em></p>
<div>Before <strong>nested</strong><p>Inner block</p>After</div>
<ul><li>List one</li><li>List <span>two</span></li></ul>
<blockquote>Quoted <b>words</b></blockquote>
<pre>line one
  line two</pre>
<table><tr><th>Heading</th><td>Cell <i>value</i></td></tr></table>
''',
        ),
      ),
      preferences: const ReaderPreferences(
        fontSize: 10,
        pageMargins: EdgeInsets.zero,
      ),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 1000,
          height: 1000,
          child: Builder(builder: engine.buildViewport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final blocks = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();

    expect(blocks, [
      'Fish & Chips',
      'First\nsecond inline',
      'Before nested',
      'Inner block',
      'After',
      'List one',
      'List two',
      'Quoted words',
      'line one\n  line two',
      'Heading',
      'Cell value',
    ]);
  });

  testWidgets('paginated viewport publishes page progression', (tester) async {
    final engine = EpubReaderEngine();
    await engine.load(
      document(syntheticEpub(longChapter: true)),
      preferences: const ReaderPreferences(
        layoutMode: ReaderLayoutMode.paginated,
      ),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 400,
          child: Builder(builder: engine.buildViewport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(-600, 0), 1200);
    await tester.pumpAndSettle();

    final locator = await engine.currentLocator() as EpubReaderLocator;
    expect(locator.cfi, startsWith('epubcfi('));
    expect(locator.localProgression, greaterThan(0));
  });

  testWidgets(
    'paginated viewport restores and updates the visual page from locator progress',
    (tester) async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub(longChapter: true)),
        initialLocator: EpubReaderLocator(
          cfi: 'epubcfi(/6/2!/4/1:0)',
          spineIndex: 0,
          localProgression: 0.5,
          totalProgression: 0.25,
        ),
        preferences: const ReaderPreferences(
          layoutMode: ReaderLayoutMode.paginated,
        ),
      );

      Widget viewport() {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 320,
            height: 400,
            child: Builder(builder: engine.buildViewport),
          ),
        );
      }

      await tester.pumpWidget(viewport());
      await tester.pumpAndSettle();

      var pageView = tester.widget<PageView>(find.byType(PageView));
      final pageCount = pageView.childrenDelegate.estimatedChildCount!;
      expect(pageView.controller, isNotNull);
      expect(
        pageView.controller!.page,
        closeTo(((pageCount - 1) * 0.5).round(), 0.01),
      );

      await engine.goTo(
        EpubReaderLocator(
          cfi: 'epubcfi(/6/2!/4/1:80)',
          spineIndex: 0,
          localProgression: 0.8,
          totalProgression: 0.4,
        ),
      );
      await tester.pumpWidget(viewport());
      await tester.pumpAndSettle();

      pageView = tester.widget<PageView>(find.byType(PageView));
      expect(
        pageView.controller!.page,
        closeTo(((pageCount - 1) * 0.8).round(), 0.01),
      );
    },
  );

  testWidgets(
    'scroll viewport restores visual offset and publishes scroll progression',
    (tester) async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub(longChapter: true)),
        initialLocator: EpubReaderLocator(
          cfi: 'epubcfi(/6/2!/4/1:0)',
          spineIndex: 0,
          localProgression: 0.5,
          totalProgression: 0.25,
        ),
        preferences: const ReaderPreferences(
          layoutMode: ReaderLayoutMode.scroll,
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 320,
            height: 400,
            child: Builder(builder: engine.buildViewport),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final position = scrollView.controller!.position;
      expect(position.pixels, closeTo(position.maxScrollExtent * 0.5, 1));

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      final locator = await engine.currentLocator() as EpubReaderLocator;
      final expectedLocal = position.pixels / position.maxScrollExtent;
      expect(locator.localProgression, closeTo(expectedLocal, 0.01));
      expect(locator.totalProgression, closeTo(expectedLocal / 3, 0.01));
    },
  );

  testWidgets('scroll viewport publishes the final ballistic progression', (
    tester,
  ) async {
    final engine = EpubReaderEngine();
    await engine.load(
      document(syntheticEpub(longChapter: true)),
      preferences: const ReaderPreferences(layoutMode: ReaderLayoutMode.scroll),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 400,
          child: Builder(builder: engine.buildViewport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    final position = scrollView.controller!.position;

    await tester.fling(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
      1800,
    );
    await tester.pumpAndSettle();

    final locator = await engine.currentLocator() as EpubReaderLocator;
    final expectedLocal = position.pixels / position.maxScrollExtent;
    expect(position.pixels, greaterThan(300));
    expect(locator.localProgression, closeTo(expectedLocal, 0.001));
  });

  testWidgets(
    'total progression stays continuous through the final spine items',
    (tester) async {
      final engine = EpubReaderEngine();
      await engine.load(
        document(syntheticEpub(longChapter: true)),
        preferences: const ReaderPreferences(
          layoutMode: ReaderLayoutMode.scroll,
        ),
      );
      await engine.goNext();

      Widget viewport() {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 320,
            height: 400,
            child: Builder(builder: engine.buildViewport),
          ),
        );
      }

      await tester.pumpWidget(viewport());
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -100000),
      );
      await tester.pumpAndSettle();

      var locator = await engine.currentLocator() as EpubReaderLocator;
      expect(locator.spineIndex, 1);
      expect(locator.localProgression, closeTo(1, 0.001));
      expect(locator.totalProgression, closeTo(2 / 3, 0.001));

      await engine.goNext();
      locator = await engine.currentLocator() as EpubReaderLocator;
      expect(locator.spineIndex, 2);
      expect(locator.localProgression, 0);
      expect(locator.totalProgression, closeTo(2 / 3, 0.001));

      await tester.pumpWidget(viewport());
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -100000),
      );
      await tester.pumpAndSettle();

      locator = await engine.currentLocator() as EpubReaderLocator;
      expect(locator.localProgression, closeTo(1, 0.001));
      expect(locator.totalProgression, 1);
    },
  );
}

final class TrackingEpubPaginator extends EpubPaginator {
  int clearCount = 0;

  @override
  void clear() {
    clearCount++;
    super.clear();
  }
}

final class FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
