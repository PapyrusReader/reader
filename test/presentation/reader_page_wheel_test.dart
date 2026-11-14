import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
}
