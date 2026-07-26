import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  testWidgets('programmatic restoration does not publish progress', (
    tester,
  ) async {
    final renderer = _TrackingRenderer();
    final progressions = <double>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 300,
          height: 300,
          child: EpubScrollViewport(
            xhtml: '<p>Chapter</p>',
            preferences: const ReaderPreferences(),
            localProgression: 0.5,
            restorationRevision: 1,
            renderer: renderer,
            onProgressChanged: progressions.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      renderer.controller.offset,
      renderer.controller.position.maxScrollExtent * 0.5,
    );
    expect(progressions, isEmpty);
  });

  testWidgets(
    'scroll-originated progression rebuild does not restore the viewport',
    (tester) async {
      final renderer = _TrackingRenderer();

      Widget viewport(double localProgression) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 300,
            child: EpubScrollViewport(
              xhtml: '<p>Chapter</p>',
              preferences: const ReaderPreferences(),
              localProgression: localProgression,
              restorationRevision: 1,
              renderer: renderer,
              onProgressChanged: (_) {},
            ),
          ),
        );
      }

      await tester.pumpWidget(viewport(0.2));
      await tester.pumpAndSettle();

      renderer.controller.jumpTo(300);
      await tester.pump();
      expect(renderer.controller.offset, 300);

      await tester.pumpWidget(viewport(0.8));
      await tester.pumpAndSettle();

      expect(renderer.controller.offset, 300);
    },
  );
}

final class _TrackingRenderer implements EpubContentRenderer {
  late ScrollController controller;

  @override
  Widget render({
    required String xhtml,
    required ReaderPreferences preferences,
    required ScrollController controller,
  }) {
    this.controller = controller;

    return SingleChildScrollView(
      controller: controller,
      child: const SizedBox(height: 2000),
    );
  }
}
