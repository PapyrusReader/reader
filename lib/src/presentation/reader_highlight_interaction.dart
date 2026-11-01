import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/reader_selection.dart';
import 'reader_interaction_scope.dart';
import 'reader_text_toolbar.dart';

typedef ReaderHighlightTarget = ({ReaderHighlight highlight, Rect bounds});

/// Observes short taps without taking drags or long presses away from selection.
final class ReaderHighlightInteraction extends StatefulWidget {
  const ReaderHighlightInteraction({
    required this.hitTest,
    required this.isSelecting,
    required this.child,
    super.key,
  });

  final ReaderHighlightTarget? Function(Offset position) hitTest;
  final bool Function() isSelecting;
  final Widget child;

  @override
  State<ReaderHighlightInteraction> createState() =>
      _ReaderHighlightInteractionState();
}

final class _ReaderHighlightInteractionState
    extends State<ReaderHighlightInteraction> {
  final _menu = ContextMenuController();
  final _pointers = <int>{};
  PointerDownEvent? _start;
  ReaderHighlightTarget? _target;

  void _show(ReaderHighlightTarget target) {
    final interactions = ReaderInteractionScope.maybeOf(context);
    final items = <ContextMenuButtonItem>[];

    for (final (label, action) in [
      ('Edit', interactions?.onEditHighlight),
      ('Remove', interactions?.onRemoveHighlight),
    ]) {
      if (action != null) {
        items.add(
          ContextMenuButtonItem(
            label: label,
            onPressed: () {
              _menu.remove();
              action(target.highlight);
            },
          ),
        );
      }
    }

    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () {
          _menu.remove();
          Clipboard.setData(
            ClipboardData(text: target.highlight.selection.text),
          );
        },
      ),
    );

    _menu.show(
      context: context,
      contextMenuBuilder: (context) => TapRegion(
        groupId: SelectableRegion,
        onTapOutside: (_) => _menu.remove(),
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              _menu.remove();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ReaderTextToolbar(bounds: target.bounds, items: items),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _menu.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (_) => _menu.remove(),
    onPointerDown: (event) {
      _menu.remove();
      _pointers.add(event.pointer);
      _target = null;
      _start = event;

      if (_pointers.length != 1 ||
          event.buttons != kPrimaryButton ||
          widget.isSelecting()) {
        return;
      }

      _target = widget.hitTest(event.position);

      if (_target != null) {
        ReaderInteractionScope.maybeOf(context)?.suppressTap();
      }
    },
    onPointerMove: (event) {
      if (_start != null &&
          (event.position - _start!.position).distance > kTouchSlop) {
        _target = null;
      }
    },
    onPointerCancel: (event) {
      _pointers.remove(event.pointer);
      _target = null;
    },
    onPointerUp: (event) {
      _pointers.remove(event.pointer);
      final target = _target;
      final start = _start;
      _target = null;

      if (target != null &&
          start != null &&
          event.pointer == start.pointer &&
          _pointers.isEmpty &&
          !widget.isSelecting() &&
          event.timeStamp - start.timeStamp < kLongPressTimeout) {
        _show(target);
      }
    },
    child: widget.child,
  );
}
