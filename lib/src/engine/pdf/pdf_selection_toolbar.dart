import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/reader_selection.dart';
import '../../presentation/reader_interaction_scope.dart';
import '../../presentation/reader_text_toolbar.dart';

/// pdfrx only finalizes its automatic menu for selection handles, not mouse drags.
final class PdfSelectionToolbar extends StatefulWidget {
  const PdfSelectionToolbar({
    required this.controller,
    required this.saveSelection,
    required this.child,
    super.key,
  });

  final PdfViewerController controller;
  final Future<void> Function(
    PdfTextSelectionDelegate selection,
    ValueChanged<ReaderSelection> action,
  )
  saveSelection;
  final Widget child;

  @override
  State<PdfSelectionToolbar> createState() => _PdfSelectionToolbarState();
}

final class _PdfSelectionToolbarState extends State<PdfSelectionToolbar> {
  final _menu = ContextMenuController();
  int _revision = 0;
  int? _pointer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_dismiss);
  }

  @override
  void didUpdateWidget(PdfSelectionToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_dismiss);
      widget.controller.addListener(_dismiss);
      _dismiss();
    }
  }

  void _dismiss() {
    _revision++;
    _menu.remove();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_menu.isShown && event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scheduleMenu() {
    final revision = ++_revision;
    WidgetsBinding.instance.addPostFrameCallback((_) => _show(revision));
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _show(int revision) async {
    final controller = widget.controller;

    if (!mounted || revision != _revision || !controller.isReady) return;

    final selection = controller.textSelectionDelegate;

    if (!selection.hasSelectedText || !selection.isCopyAllowed) return;

    final ranges = await selection.getSelectedTextRanges();

    if (!mounted || revision != _revision || !controller.isReady) return;

    final viewport = context.findRenderObject() as RenderBox?;

    if (viewport == null || !viewport.hasSize) return;

    final viewportBounds = viewport.localToGlobal(Offset.zero) & viewport.size;
    Rect? bounds;

    for (final range in ranges) {
      final page = controller.document.pages[range.pageNumber - 1];
      final pageRect = controller.layout.pageLayouts[range.pageNumber - 1];

      for (final fragment in range.enumerateFragmentBoundingRects()) {
        final rect = fragment.bounds.toRectInDocument(
          page: page,
          pageRect: pageRect,
        );
        final start = controller.documentToGlobal(rect.topLeft);
        final end = controller.documentToGlobal(rect.bottomRight);

        if (start == null || end == null) continue;

        final visible = Rect.fromPoints(start, end).intersect(viewportBounds);

        if (!visible.isEmpty) {
          bounds = bounds?.expandToInclude(visible) ?? visible;
        }
      }
    }

    if (bounds == null) return;

    final interactions = ReaderInteractionScope.maybeOf(context);
    final items = <ContextMenuButtonItem>[];

    for (final (label, action) in [
      ('Annotate', interactions?.onAnnotate),
      ('Add note', interactions?.onNote),
    ]) {
      if (action != null) {
        items.add(
          ContextMenuButtonItem(
            label: label,
            onPressed: () {
              _dismiss();
              widget.saveSelection(selection, action);
            },
          ),
        );
      }
    }

    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () async {
          _dismiss();
          await selection.copyTextSelection();
          await selection.clearTextSelection();
        },
      ),
    );

    final menuBounds = bounds;
    _menu.show(
      context: context,
      contextMenuBuilder: (_) => TapRegion(
        onTapOutside: (_) => _dismiss(),
        child: Focus(
          onKeyEvent: _onKeyEvent,
          child: ReaderTextToolbar(bounds: menuBounds, items: items),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_dismiss);
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      _dismiss();
      _pointer =
          event.kind == PointerDeviceKind.mouse &&
              event.buttons == kPrimaryButton
          ? event.pointer
          : null;
    },
    onPointerUp: (event) {
      if (event.pointer == _pointer) {
        _pointer = null;
        _scheduleMenu();
      }
    },
    onPointerCancel: (_) {
      _pointer = null;
      _dismiss();
    },
    onPointerSignal: (_) => _dismiss(),
    child: Focus(onKeyEvent: _onKeyEvent, child: widget.child),
  );
}
