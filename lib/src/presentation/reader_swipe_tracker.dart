import 'package:flutter/gestures.dart';

/// Raw boundary gestures must yield to selection, long presses and multi-touch.
final class ReaderSwipeTracker {
  final Set<int> _pointers = {};
  PointerDownEvent? _start;
  bool _cancelled = false;
  bool _dragging = false;
  bool _selected = false;

  void selectionChanged(bool selected) {
    if (selected || _selected) {
      _cancelled = true;
    }

    _selected = selected;
  }

  void start(PointerDownEvent event) {
    _pointers.add(event.pointer);

    if (_pointers.length != 1) {
      _cancelled = true;
      return;
    }

    _start = event;
    _dragging = false;
    _cancelled = _selected || event.kind != PointerDeviceKind.touch;
  }

  void update(PointerMoveEvent event) {
    final start = _start;

    if (start == null || _cancelled || event.pointer != start.pointer) {
      return;
    }

    if (!_dragging && event.timeStamp - start.timeStamp >= kLongPressTimeout) {
      _cancelled = true;
      return;
    }

    if ((event.position - start.position).distance > kTouchSlop) {
      _dragging = true;
    }
  }

  Offset? end(PointerUpEvent event) {
    final start = _start;
    _pointers.remove(event.pointer);

    if (start == null || event.pointer != start.pointer) {
      return null;
    }

    _start = null;

    if (_cancelled || _selected || !_dragging || _pointers.isNotEmpty) {
      return null;
    }

    return event.position - start.position;
  }

  void cancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _cancelled = true;
    _start = null;
  }
}
