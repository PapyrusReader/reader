import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/src/presentation/reader_page_wheel.dart';

void main() {
  testWidgets(
    'small wheel turns win once, reverse promptly, and release zoom signals',
    (tester) async {
      final turns = <int>[];
      var nativeSignals = 0;
      var canTurn = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            canTurn: (_) => canTurn,
            onTurn: (direction) async => turns.add(direction),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (event) => GestureBinding
                  .instance
                  .pointerSignalResolver
                  .register(event, (_) => nativeSignals++),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(400, 300),
            scrollDelta: delta,
          ),
        );
        await tester.pump();
      }

      await wheel(const Offset(0, 1));
      await wheel(const Offset(0, 1));
      expect(turns, [1]);
      expect(nativeSignals, 0);
      await wheel(const Offset(0, -1));
      expect(turns, [1, -1]);
      await tester.pump(const Duration(milliseconds: 120));
      await wheel(const Offset(-1, 0));
      expect(turns, [1, -1, -1]);
      for (final key in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(key);
        await wheel(const Offset(0, 1));
        await tester.sendKeyUpEvent(key);
      }
      canTurn = false;
      await wheel(const Offset(0, 1));
      expect(turns, [1, -1, -1]);
      expect(nativeSignals, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'resistance stays visible and continued scrolling keeps turning',
    (tester) async {
      final turns = <int>[];
      var nativeSignals = 0;
      var canTurn = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            resistance: true,
            canTurn: (_) => canTurn,
            onTurn: (direction) async => turns.add(direction),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (event) => GestureBinding
                  .instance
                  .pointerSignalResolver
                  .register(event, (_) => nativeSignals++),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      Future<void> wheel(double delta, {int milliseconds = 80}) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(400, 300),
            scrollDelta: Offset(0, delta),
          ),
        );
        await tester.pump(Duration(milliseconds: milliseconds));
      }

      double progress() => tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value!;
      double opacity() =>
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

      await wheel(80);
      final partial = progress();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        opacity(),
        1,
        reason: 'Feedback persists between touchpad strokes',
      );
      expect(progress(), partial);
      await wheel(-1);
      expect(
        find.byIcon(Icons.keyboard_arrow_down),
        findsOneWidget,
        reason: 'Reverse jitter unwinds pressure without jumping edges',
      );
      await wheel(1);

      for (var tick = 0; tick < 6; tick++) {
        await wheel(80);
      }

      expect(turns, isEmpty, reason: 'Two wheel notches no longer turn a page');
      await wheel(80);
      expect(turns, [1]);
      expect(opacity(), 1, reason: 'Feedback stays visible across page turns');

      for (var tick = 0; tick < 8; tick++) {
        await wheel(80);
      }

      expect(turns, [
        1,
        1,
      ], reason: 'Continued input turns without an idle pause');
      expect(nativeSignals, 0);
      await tester.pump(const Duration(milliseconds: 700));
      expect(opacity(), 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), 0);
      final fade = tester.renderObject<RenderAnimatedOpacity>(
        find.descendant(
          of: find.byType(AnimatedOpacity),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(
        fade.opacity.value,
        greaterThan(0),
        reason: 'Hide fades instead of popping',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(fade.opacity.value, 0);

      await wheel(80);
      expect(
        progress(),
        partial,
        reason: 'Idle input starts with fresh resistance',
      );
      canTurn = false;
      await wheel(40);
      expect(opacity(), 0);
      canTurn = true;
      await wheel(80);
      expect(progress(), partial, reason: 'Panning clears partial pressure');

      for (final key in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(key);
        await wheel(80);
        await tester.sendKeyUpEvent(key);
        expect(opacity(), 0);
      }

      expect(nativeSignals, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final interval in [8, 80]) {
    for (final sampleDistance in [40.0, 160.0]) {
      testWidgets(
        'swipes count distance at $interval ms intervals with $sampleDistance samples',
        (tester) async {
          final turns = <int>[];
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderPageWheel(
                resistance: true,
                canTurn: (_) => true,
                onTurn: (direction) async => turns.add(direction),
                child: const SizedBox.expand(),
              ),
            ),
          );
          final samplesPerPage = (640 / sampleDistance).round();

          for (var page = 0; page < 2; page++) {
            for (var sample = 0; sample < samplesPerPage; sample++) {
              await tester.sendEventToBinding(
                PointerScrollEvent(
                  position: const Offset(400, 300),
                  scrollDelta: Offset(0, sampleDistance),
                ),
              );
              await tester.pump(Duration(milliseconds: interval));
              final completed = sample == samplesPerPage - 1;
              expect(turns.length, page + (completed ? 1 : 0));
              expect(
                tester
                    .widget<LinearProgressIndicator>(
                      find.byType(LinearProgressIndicator),
                    )
                    .value,
                closeTo((sample + 1) / samplesPerPage, .0001),
                reason:
                    'Active motion must count regardless of speed or event batching',
              );
            }
          }

          expect(turns, [
            1,
            1,
          ], reason: 'Both turns complete without an inertia tail');
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final horizontal in [false, true]) {
    testWidgets('diagonal drift does not reset $horizontal scrolling', (
      tester,
    ) async {
      final turns = <int>[];
      final claimed = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            resistance: true,
            canTurn: (delta) {
              claimed.add(delta);
              return true;
            },
            onTurn: (direction) async => turns.add(direction),
            child: const SizedBox.expand(),
          ),
        ),
      );

      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(400, 300),
            scrollDelta: delta,
          ),
        );
        await tester.pump(const Duration(milliseconds: 8));
      }

      for (var sample = 0; sample < 8; sample++) {
        final drift = sample == 0 ? 0.0 : (sample.isEven ? -100.0 : 100.0);
        await wheel(horizontal ? Offset(80, drift) : Offset(drift, 80));
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          closeTo((sample + 1) / 8, .0001),
        );
      }

      expect(turns, [1]);
      expect(
        claimed.every((delta) => horizontal ? delta.dy == 0 : delta.dx == 0),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await wheel(horizontal ? const Offset(0, -80) : const Offset(-80, 0));
      expect(
        claimed.last,
        horizontal ? const Offset(0, -80) : const Offset(-80, 0),
        reason: 'A fresh sequence can choose a different axis',
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .125,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'tiny initial sideways movement does not lock out a vertical swipe',
    (tester) async {
      final turns = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            resistance: true,
            canTurn: (_) => true,
            onTurn: (direction) async => turns.add(direction),
            child: const SizedBox.expand(),
          ),
        ),
      );

      for (final delta in [
        const Offset(1, 0),
        ...List.filled(8, const Offset(0, 80)),
      ]) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(400, 300),
            scrollDelta: delta,
          ),
        );
        await tester.pump(const Duration(milliseconds: 8));
      }

      expect(turns, [1]);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final fitted in [false, true]) {
    testWidgets(
      'a page turn absorbs its decaying scroll tail, fitted $fitted',
      (tester) async {
        final turns = <int>[];
        final nativeSignals = <Offset>[];
        var canTurn = true;
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPageWheel(
              resistance: true,
              canTurn: (_) => canTurn,
              onTurn: (direction) async {
                turns.add(direction);
                canTurn = fitted;
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    GestureBinding.instance.pointerSignalResolver.register(
                      event,
                      (_) => nativeSignals.add(event.scrollDelta),
                    );
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        Future<void> wheel(double delta) async {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: const Offset(400, 300),
              scrollDelta: Offset(0, delta),
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }

        for (var sample = 0; sample < 8; sample++) {
          await wheel(80);
        }

        expect(turns, [1]);

        for (var tail = 79.0; tail >= 1; tail--) {
          await wheel(tail);
        }

        expect(turns, [
          1,
        ], reason: 'Even a long momentum tail must not turn again');
        expect(
          nativeSignals,
          isEmpty,
          reason: 'The tail must not pan the new page',
        );
        await wheel(12);

        if (fitted) {
          expect(
            tester
                .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator),
                )
                .value,
            closeTo(12 / 640, .0001),
          );
        } else {
          expect(nativeSignals, [
            const Offset(0, 12),
          ], reason: 'A fresh impulse pans immediately without waiting');
        }

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final release in ['reverse', 'axis', 'pause', 'zoom']) {
    testWidgets('post-turn inertia releases on $release', (tester) async {
      var canTurn = true;
      var nativeSignals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            resistance: true,
            canTurn: (_) => canTurn,
            onTurn: (_) async => canTurn = false,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (event) => GestureBinding
                  .instance
                  .pointerSignalResolver
                  .register(event, (_) => nativeSignals++),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(400, 300),
            scrollDelta: delta,
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }

      for (var sample = 0; sample < 8; sample++) {
        await wheel(const Offset(0, 80));
      }

      await wheel(const Offset(0, 40));
      expect(nativeSignals, 0);

      if (release == 'pause') {
        await tester.pump(const Duration(milliseconds: 200));
      } else if (release == 'zoom') {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      }

      await wheel(switch (release) {
        'reverse' => const Offset(0, -20),
        'axis' => const Offset(40, 0),
        _ => const Offset(0, 20),
      });
      expect(nativeSignals, 1);

      if (release == 'zoom') {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'input during navigation builds the next turn without queuing a burst',
    (tester) async {
      final turns = <int>[];
      final navigation = Completer<void>();
      var canTurn = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            resistance: true,
            canTurn: (_) => canTurn,
            onTurn: (direction) async {
              turns.add(direction);

              if (turns.length == 1) {
                canTurn = false;
                await navigation.future;
                canTurn = true;
              }
            },
            child: const SizedBox.expand(),
          ),
        ),
      );

      Future<void> stroke(int count) async {
        for (var tick = 0; tick < count; tick++) {
          await tester.sendEventToBinding(
            const PointerScrollEvent(
              position: Offset(400, 300),
              scrollDelta: Offset(0, 80),
            ),
          );
          await tester.pump(const Duration(milliseconds: 80));
        }
      }

      await stroke(8);
      expect(turns, [1]);
      await stroke(12);
      expect(turns, [1]);
      navigation.complete();
      await tester.pump();
      expect(turns, [1, 1]);
      await tester.pump(const Duration(seconds: 2));
      expect(turns, [
        1,
        1,
      ], reason: 'Excess input must not queue multiple pages');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'resistance works without feedback and clears on layout changes',
    (tester) async {
      final turns = <int>[];
      Future<void> mount({required bool resistance}) => tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWheel(
            resistance: resistance,
            showResistance: false,
            canTurn: (_) => true,
            onTurn: (direction) async => turns.add(direction),
            child: const SizedBox.expand(),
          ),
        ),
      );
      Future<void> wheel() async {
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(400, 300),
            scrollDelta: Offset(0, 80),
          ),
        );
        await tester.pump(const Duration(milliseconds: 80));
      }

      await mount(resistance: true);
      await wheel();
      expect(turns, isEmpty);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await mount(resistance: false);
      await mount(resistance: true);

      for (var tick = 0; tick < 7; tick++) {
        await wheel();
      }

      expect(turns, isEmpty);
      await wheel();
      expect(turns, [1]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
