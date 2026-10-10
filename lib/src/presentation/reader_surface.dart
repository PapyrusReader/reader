import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'reader_interaction_scope.dart';

/// Observe taps without competing with selection or the viewport's drag arena.
final class ReaderSurface extends StatefulWidget {
  const ReaderSurface({
    required this.enabled,
    required this.onToggle,
    required this.onTurn,
    required this.child,
    super.key,
  });

  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<int> onTurn;
  final Widget child;

  @override
  State<ReaderSurface> createState() => _ReaderSurfaceState();
}

final class _ReaderSurfaceState extends State<ReaderSurface> {
  final Set<int> _pointers = {};
  Offset? _start;
  Duration _startedAt = Duration.zero;
  bool _cancelled = false;
  bool _selection = false;
  bool _blocked = false;
  Timer? _tap;
  Timer? _hold;

  @override
  void dispose() {
    _tap?.cancel();
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ReaderInteractionScope(
    onTurn: widget.onTurn,
    onSelectionChanged: (selected) {
      if (selected || _selection) {
        _cancelled = true;
        _tap?.cancel();
      }
      _selection = selected;
    },
    suppressTap: () {
      _blocked = true;
      _cancelled = true;
      _tap?.cancel();
    },
    child: LayoutBuilder(
      builder: (context, constraints) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          final doubleTap = _tap?.isActive ?? false;
          _tap?.cancel();
          _pointers.add(event.pointer);
          if (_pointers.length == 1) {
            _start = event.localPosition;
            _startedAt = event.timeStamp;
            _hold?.cancel();
            _hold = Timer(kLongPressTimeout, () => _cancelled = true);
            _cancelled = doubleTap || _selection || _blocked;
          } else {
            _cancelled = true;
          }
        },
        onPointerMove: (event) {
          if (_start != null &&
              (event.localPosition - _start!).distance > kTouchSlop) {
            _cancelled = true;
          }
        },
        onPointerCancel: (event) {
          _hold?.cancel();
          _pointers.remove(event.pointer);
          _cancelled = true;
        },
        onPointerUp: (event) {
          _hold?.cancel();
          _pointers.remove(event.pointer);
          _blocked = false;
          if (!widget.enabled ||
              _cancelled ||
              _pointers.isNotEmpty ||
              event.timeStamp - _startedAt >= kLongPressTimeout) {
            return;
          }
          _tap = Timer(kDoubleTapTimeout, () {
            if (mounted && widget.enabled && !_cancelled && !_selection) {
              widget.onToggle();
            }
          });
        },
        child: widget.child,
      ),
    ),
  );
}
