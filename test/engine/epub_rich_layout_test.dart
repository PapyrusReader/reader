import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';
import 'package:papyrus_reader/src/engine/epub/epub_rich_layout.dart';
import 'package:papyrus_reader/src/engine/epub/worker/epub_content.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('measured fragments match the rendered Material reader text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final content = collectEpubContent(
      List.generate(
        25,
        (index) =>
            '<p>Passage $index. Reading should feel calm on a small phone and a wide desktop. '
            'A page turn keeps its place, while <em>emphasis</em> and <strong>meaning</strong> '
            'remain part of the story. Resize the window or change the typeface to try reflow.</p>',
      ).join(),
    );
    final blocks = [
      for (final json in content['blocks'] as List)
        EpubContentBlock(Map<String, Object?>.from(json as Map)),
    ];
    const preferences = ReaderPreferences();
    final pages = (await tester.runAsync(
      () => layoutEpubChapter(
        blocks,
        contentSize: const Size(592, 662),
        preferences: preferences,
        textScaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        cancelled: () => false,
      ),
    ))!;
    for (final page in pages) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 592,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final fragment in page.fragments)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: fragment.spacing(preferences),
                        ),
                        child: buildEpubFragment(fragment, preferences),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final textWidgets = find.byType(Text);
      var height = 0.0;
      for (var i = 0; i < page.fragments.length; i++) {
        final rendered = tester.getSize(textWidgets.at(i)).height;
        expect(rendered, closeTo(page.fragments[i].height, 1));
        height += rendered + page.fragments[i].spacing(preferences);
      }
      expect(height, lessThanOrEqualTo(663));
    }
  });

  test(
    'long rich paragraphs preserve every character across page boundaries',
    () async {
      final paragraph = List.filled(
        250,
        'A👩🏽‍🚀 café 中文 line of text. ',
      ).join();
      final content = collectEpubContent('<p><strong>$paragraph</strong></p>');
      final blocks = [
        for (final json in content['blocks'] as List)
          EpubContentBlock(Map<String, Object?>.from(json as Map)),
      ];
      final pages = await layoutEpubChapter(
        blocks,
        contentSize: const Size(260, 310),
        preferences: const ReaderPreferences(),
        textScaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        cancelled: () => false,
      );
      expect(pages.length, greaterThan(3));
      final rendered = pages
          .expand((page) => page.fragments)
          .map(
            (f) => f.block
                .span(const ReaderPreferences(), start: f.start, end: f.end)
                .toPlainText(),
          )
          .join();
      expect(rendered, paragraph);
      for (final page in pages) {
        var used = 0.0;
        for (final fragment in page.fragments) {
          final painter = TextPainter(
            text: fragment.block.span(
              const ReaderPreferences(),
              start: fragment.start,
              end: fragment.end,
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 260);
          used += painter.height + fragment.spacing(const ReaderPreferences());
          painter.dispose();
        }
        expect(
          used,
          lessThanOrEqualTo(311),
          reason: 'Rendered content must fit its page',
        );
      }
    },
  );

  test(
    'content offsets and styles survive reflow and anchored navigation',
    () async {
      final content = collectEpubContent(
        '<h1>Heading</h1><p>Before <em id="target">italic</em> <strong>bold</strong></p>',
      );
      final blocks = [
        for (final json in content['blocks'] as List)
          EpubContentBlock(Map<String, Object?>.from(json as Map)),
      ];
      expect((content['anchors'] as Map)['target'], 15);
      final paragraph = blocks.last.span(const ReaderPreferences());
      expect(
        paragraph.children!.whereType<TextSpan>().any(
          (s) => s.style?.fontStyle == FontStyle.italic,
        ),
        isTrue,
      );
      expect(
        paragraph.children!.whereType<TextSpan>().any(
          (s) => s.style?.fontWeight == FontWeight.bold,
        ),
        isTrue,
      );
      final locator = EpubReaderLocator(
        spineIndex: 0,
        localProgression: .3,
        totalProgression: .1,
        textOffset: 15,
        anchor: 'target',
      );
      expect(ReaderLocator.fromJson(locator.toJson()), locator);
    },
  );
}
