import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'reader_interaction_scope.dart';
import '../domain/reader_selection.dart';

/// Observe taps without competing with selection or the viewport's drag arena.
final class ReaderSurface extends StatefulWidget {
  const ReaderSurface({
    required this.enabled,
    required this.onToggle,
    required this.onTurn,
    required this.child,
    this.onAnnotate,
    this.onNote,
    this.onEditHighlight,
    this.onRemoveHighlight,
    this.highlights = const [],
    super.key,
  });

  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<int> onTurn;
  final Widget child;
  final ValueChanged<ReaderSelection>? onAnnotate;
  final ValueChanged<ReaderSelection>? onNote;
  final ValueChanged<ReaderHighlight>? onEditHighlight;
  final ValueChanged<ReaderHighlight>? onRemoveHighlight;
  final List<ReaderHighlight> highlights;

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
  int _tapRevision = 0;
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
    onAnnotate: widget.onAnnotate,
    onNote: widget.onNote,
    onEditHighlight: widget.onEditHighlight,
    onRemoveHighlight: widget.onRemoveHighlight,
    highlights: widget.highlights,
    onSelectionChanged: (selected) {
      if (selected || _selection) {
        _cancelled = true;
        _tap?.cancel();
      }
      _selection = selected;
    },
    suppressTap: () {
      _tapRevision++;
      _blocked = true;
      _cancelled = true;
      _tap?.cancel();
      // Suppression belongs to this pointer dispatch, including delayed link taps.
      scheduleMicrotask(() => _blocked = false);
    },
    child: LayoutBuilder(
      builder: (context, constraints) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _tapRevision++;
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
          final revision = _tapRevision;
          _tap = Timer(kDoubleTapTimeout, () {
            // Let viewport recognizers consume links before toggling the chrome.
            _tap = Timer(Duration.zero, () {
              if (mounted &&
                  revision == _tapRevision &&
                  widget.enabled &&
                  !_cancelled &&
                  !_selection) {
                widget.onToggle();
              }
            });
          });
        },
        child: widget.child,
      ),
    ),
  );
}
