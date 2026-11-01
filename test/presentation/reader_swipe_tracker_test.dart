import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/src/presentation/reader_swipe_tracker.dart';

void main() {
  test('only a single touch drag can become a boundary swipe', () {
    for (final kind in [
      PointerDeviceKind.touch,
      PointerDeviceKind.mouse,
      PointerDeviceKind.stylus,
    ]) {
      final tracker = ReaderSwipeTracker();
      tracker.start(PointerDownEvent(pointer: 1, kind: kind));
      tracker.update(
        PointerMoveEvent(
          pointer: 1,
          kind: kind,
          position: const Offset(100, 0),
        ),
      );
      final offset = tracker.end(
        PointerUpEvent(pointer: 1, kind: kind, position: const Offset(100, 0)),
      );
      expect(
        offset,
        kind == PointerDeviceKind.touch ? const Offset(100, 0) : isNull,
      );
    }
  });

  test('selection stays disqualified after it clears during a drag', () {
    final tracker = ReaderSwipeTracker();
    tracker.start(const PointerDownEvent(pointer: 1));
    tracker.update(
      const PointerMoveEvent(pointer: 1, position: Offset(100, 0)),
    );
    tracker.selectionChanged(true);
    tracker.selectionChanged(false);
    expect(
      tracker.end(const PointerUpEvent(pointer: 1, position: Offset(200, 0))),
      isNull,
    );
    tracker.start(const PointerDownEvent(pointer: 2));
    tracker.update(
      const PointerMoveEvent(pointer: 2, position: Offset(-100, 0)),
    );
    expect(
      tracker.end(const PointerUpEvent(pointer: 2, position: Offset(-100, 0))),
      const Offset(-100, 0),
    );
  });

  test('dragging an existing selection cannot turn a page', () {
    final tracker = ReaderSwipeTracker()..selectionChanged(true);
    tracker.start(const PointerDownEvent(pointer: 1));
    tracker.update(
      const PointerMoveEvent(pointer: 1, position: Offset(100, 0)),
    );
    tracker.selectionChanged(false);
    expect(
      tracker.end(const PointerUpEvent(pointer: 1, position: Offset(100, 0))),
      isNull,
    );
  });

  test(
    'holding before dragging cancels a swipe without a selection callback',
    () {
      final tracker = ReaderSwipeTracker();
      tracker.start(const PointerDownEvent(pointer: 1));
      tracker.update(
        PointerMoveEvent(
          pointer: 1,
          position: const Offset(100, 0),
          timeStamp: kLongPressTimeout,
        ),
      );
      expect(
        tracker.end(const PointerUpEvent(pointer: 1, position: Offset(100, 0))),
        isNull,
      );
    },
  );

  test('a moving swipe can continue longer than the long-press timeout', () {
    final tracker = ReaderSwipeTracker();
    tracker.start(const PointerDownEvent(pointer: 1));
    tracker.update(const PointerMoveEvent(pointer: 1, position: Offset(30, 0)));
    tracker.update(
      PointerMoveEvent(
        pointer: 1,
        position: const Offset(100, 0),
        timeStamp: kLongPressTimeout,
      ),
    );
    expect(
      tracker.end(const PointerUpEvent(pointer: 1, position: Offset(100, 0))),
      const Offset(100, 0),
    );
  });

  test('multi-touch and cancelled gestures cannot turn pages', () {
    final tracker = ReaderSwipeTracker();
    tracker.start(const PointerDownEvent(pointer: 1));
    tracker.start(const PointerDownEvent(pointer: 2));
    tracker.end(const PointerUpEvent(pointer: 2));
    tracker.update(
      const PointerMoveEvent(pointer: 1, position: Offset(100, 0)),
    );
    expect(
      tracker.end(const PointerUpEvent(pointer: 1, position: Offset(100, 0))),
      isNull,
    );
    tracker.start(const PointerDownEvent(pointer: 3));
    tracker.update(
      const PointerMoveEvent(pointer: 3, position: Offset(100, 0)),
    );
    tracker.cancel(const PointerCancelEvent(pointer: 3));
    expect(
      tracker.end(const PointerUpEvent(pointer: 3, position: Offset(100, 0))),
      isNull,
    );
  });
}
