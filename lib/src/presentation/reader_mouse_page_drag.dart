import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Mouse drags in blank page space participate before the enclosing selection
/// area. Drags starting on text stay with selection, including across lines.
final class ReaderMousePageDrag extends StatefulWidget {
  const ReaderMousePageDrag({
    required this.controller,
    required this.animate,
    required this.canStart,
    required this.onTurn,
    required this.child,
    super.key,
  });

  final PageController controller;
  final bool animate;
  final bool Function(Offset position) canStart;
  final ValueChanged<int> onTurn;
  final Widget child;

  @override
  State<ReaderMousePageDrag> createState() => _ReaderMousePageDragState();
}

final class _ReaderMousePageDragState extends State<ReaderMousePageDrag> {
  ScrollHoldController? _hold;
  Drag? _drag;
  double _distance = 0;

  void _down(DragDownDetails details) {
    _distance = 0;
    if (widget.animate && widget.controller.hasClients) {
      _hold = widget.controller.position.hold(() => _hold = null);
    }
  }

  void _start(DragStartDetails details) {
    if (widget.animate && widget.controller.hasClients) {
      _drag = widget.controller.position.drag(details, () => _drag = null);
    }
  }

  void _update(DragUpdateDetails details) {
    _distance += details.primaryDelta!;
    _drag?.update(details);
  }

  void _end(DragEndDetails details) {
    final drag = _drag;
    _drag = null;
    drag?.end(details);
    _hold?.cancel();
    _hold = null;
    if (!widget.animate && _distance.abs() > 70) {
      widget.onTurn(_distance < 0 ? 1 : -1);
    }
  }

  void _cancel() {
    _drag?.cancel();
    _drag = null;
    _hold?.cancel();
    _hold = null;
  }

  @override
  void didUpdateWidget(ReaderMousePageDrag oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.animate != widget.animate) {
      _cancel();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      _BlankPageMouseDrag:
          GestureRecognizerFactoryWithHandlers<_BlankPageMouseDrag>(
            _BlankPageMouseDrag.new,
            (recognizer) => recognizer
              ..canStart = widget.canStart
              ..dragStartBehavior = DragStartBehavior.down
              ..onDown = _down
              ..onStart = _start
              ..onUpdate = _update
              ..onEnd = _end
              ..onCancel = _cancel,
          ),
    },
    child: widget.child,
  );
}

final class _BlankPageMouseDrag extends HorizontalDragGestureRecognizer {
  _BlankPageMouseDrag() : super(supportedDevices: {PointerDeviceKind.mouse});

  late bool Function(Offset position) canStart;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) && canStart(event.position);
}
