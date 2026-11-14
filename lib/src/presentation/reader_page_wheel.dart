import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../domain/reader_exception.dart';

/// Claims page-turn wheel signals before nested scrolling or PDF panning.
final class ReaderPageWheel extends StatefulWidget {
  const ReaderPageWheel({
    required this.canTurn,
    required this.onTurn,
    required this.child,
    super.key,
  });

  final bool Function(Offset delta) canTurn;
  final Future<void> Function(int direction) onTurn;
  final Widget child;

  @override
  State<ReaderPageWheel> createState() => _ReaderPageWheelState();
}

final class _ReaderPageWheelState extends State<ReaderPageWheel> {
  Timer? _cooldown;
  int? _direction;
  Future<void> _pending = Future.value();

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !widget.canTurn(event.scrollDelta) ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return;
    }

    final delta = event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final direction = delta > 0 ? 1 : -1;
      if (_cooldown?.isActive == true && direction == _direction) return;
      _direction = direction;
      _cooldown?.cancel();
      _cooldown = Timer(const Duration(milliseconds: 120), () {});
      _pending = _pending
          .then((_) async {
            if (mounted && widget.canTurn(event.scrollDelta)) {
              await widget.onTurn(direction);
            }
          })
          .catchError((Object error, StackTrace stack) {
            if (error is ReaderException &&
                error.code == ReaderErrorCode.navigationBoundary) {
              return;
            }
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: 'papyrus_reader',
                context: ErrorDescription(
                  'while turning a page with the scroll wheel',
                ),
              ),
            );
          });
    });
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: _signal,
        ),
      ),
    ],
  );
}
