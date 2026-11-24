import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/reader_exception.dart';
import 'reader_chrome_insets.dart';

/// Claims page-turn wheel signals before nested scrolling or PDF panning.
final class ReaderPageWheel extends StatefulWidget {
  const ReaderPageWheel({
    required this.canTurn,
    required this.onTurn,
    required this.child,
    this.resistance = false,
    this.showResistance = true,
    super.key,
  });

  final bool Function(Offset delta) canTurn;
  final Future<void> Function(int direction) onTurn;
  final Widget child;
  final bool resistance;
  final bool showResistance;

  @override
  State<ReaderPageWheel> createState() => _ReaderPageWheelState();
}

final class _ReaderPageWheelState extends State<ReaderPageWheel> {
  Timer? _cooldown;
  int? _direction;
  Future<void> _pending = Future.value();
  static const _threshold = 640.0;
  static const _axisLockDistance = 8.0;
  static const _feedbackHold = Duration(milliseconds: 900);
  static const _feedbackFade = Duration(milliseconds: 220);
  static const _tailGap = Duration(milliseconds: 180);
  Timer? _gestureEnd;
  Timer? _tailEnd;
  int? _tailDirection;
  bool _tailHorizontal = false;
  bool _suppressTail = false;
  double _tailMagnitude = 0;
  double _tailFloor = 0;
  int _tailDeclines = 0;
  double _distance = 0;
  double _displayProgress = 0;
  bool _feedbackVisible = false;
  bool _turning = false;
  bool _horizontal = false;
  Offset? _lastDelta;
  Offset _axisIntent = Offset.zero;

  void _clearTail() {
    _tailEnd?.cancel();
    _tailDirection = null;
    _suppressTail = false;
  }

  void _armTail(int direction, Offset delta) {
    _tailDirection = direction;
    _tailHorizontal = delta.dx.abs() > delta.dy.abs();
    _tailMagnitude = _tailHorizontal ? delta.dx.abs() : delta.dy.abs();
    _tailFloor = _tailMagnitude;
    _tailDeclines = 0;
    _suppressTail = false;
    _tailEnd?.cancel();
    _tailEnd = Timer(_tailGap, _clearTail);
  }

  bool _consumeTail(Offset delta) {
    final direction = _tailDirection;

    if (!widget.resistance || direction == null) return false;

    final movement = _tailHorizontal ? delta.dx : delta.dy;
    final crossMovement = _tailHorizontal ? delta.dy : delta.dx;
    final magnitude = movement.abs();
    final reversed = movement != 0 && (movement > 0 ? 1 : -1) != direction;
    final changedAxis = crossMovement.abs() > math.max(8, magnitude * 2);
    final reference = _suppressTail ? _tailFloor : _tailMagnitude;
    final accelerated = magnitude > reference + math.max(4, reference * .5);

    // Browsers do not label momentum events. A renewed impulse or direction
    // change releases the tail immediately; a quiet gap also starts fresh input.
    if (reversed || changedAxis || accelerated) {
      _clearTail();

      if (changedAxis) {
        _resetResistance();
      }

      return false;
    }

    final axisDelta = _tailHorizontal
        ? Offset(movement, 0)
        : Offset(0, movement);
    _tailDeclines = magnitude < _tailMagnitude - .01 ? _tailDeclines + 1 : 0;
    _suppressTail =
        _suppressTail ||
        _tailDeclines >= 2 ||
        (!_turning && !widget.canTurn(axisDelta));
    _tailFloor = _suppressTail ? math.min(_tailFloor, magnitude) : magnitude;
    _tailMagnitude = magnitude;
    _tailEnd?.cancel();
    _tailEnd = Timer(_tailGap, _clearTail);

    if (_suppressTail) {
      _distance = 0;
    }

    return _suppressTail;
  }

  void _resetResistance() {
    _gestureEnd?.cancel();
    _distance = 0;
    _lastDelta = null;
    _axisIntent = Offset.zero;

    if (_feedbackVisible) {
      setState(() => _feedbackVisible = false);
    }
  }

  void _accumulate(Offset offset, double delta) {
    _gestureEnd?.cancel();
    _gestureEnd = Timer(_feedbackHold, _resetResistance);
    final direction = delta > 0 ? 1 : -1;
    final horizontal = offset.dx.abs() > offset.dy.abs();
    final distance = delta.abs();

    if (_distance == 0 || horizontal != _horizontal) {
      _direction = direction;
      _horizontal = horizontal;
      _distance = 0;
    }

    // Small reverse samples unwind pressure rather than flickering between edges.
    if (direction != _direction) {
      _distance -= distance;

      if (_distance < 0) {
        _direction = direction;
        _distance = (-_distance).clamp(0, _threshold);
      }
    } else {
      _distance = (_distance + distance).clamp(0, _threshold);
    }

    _lastDelta = offset;
    setState(() {
      _feedbackVisible = true;
      _displayProgress = _distance / _threshold;
    });
    _turnIfReady();
  }

  void _turnIfReady() {
    final delta = _lastDelta;

    if (!mounted ||
        !widget.resistance ||
        _turning ||
        _distance < _threshold ||
        delta == null ||
        !widget.canTurn(delta)) {
      return;
    }

    _distance = 0;
    _armTail(_direction!, delta);
    _queueTurn(_direction!, delta);
  }

  void _queueTurn(int direction, Offset delta) {
    _turning = true;
    _pending = _pending
        .then((_) async {
          if (mounted && widget.canTurn(delta)) {
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
        })
        .whenComplete(() {
          _turning = false;
          _turnIfReady();
        });
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      _clearTail();
      _resetResistance();
      return;
    }

    if (_consumeTail(event.scrollDelta)) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
      return;
    }

    final offset = _scrollAxis(event.scrollDelta);
    final delta = offset.dy.abs() >= offset.dx.abs() ? offset.dy : offset.dx;
    if (delta == 0) return;

    if (!widget.canTurn(offset) && !(widget.resistance && _turning)) {
      _resetResistance();
      return;
    }

    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final direction = delta > 0 ? 1 : -1;

      if (widget.resistance) {
        _accumulate(offset, delta);
        return;
      }

      if (_cooldown?.isActive == true && direction == _direction) return;

      _direction = direction;
      _cooldown?.cancel();
      _cooldown = Timer(const Duration(milliseconds: 120), () {});
      _queueTurn(direction, event.scrollDelta);
    });
  }

  Offset _scrollAxis(Offset delta) {
    if (!widget.resistance) return delta;

    // Keep diagonal finger drift on the axis chosen for this scroll sequence.
    // Reconsider it only after the sequence ends or ordinary panning resumes.
    var horizontal = _horizontal;

    if (_axisIntent.distanceSquared < _axisLockDistance * _axisLockDistance) {
      _axisIntent += delta;
      horizontal = _axisIntent.dx.abs() > _axisIntent.dy.abs();
    }

    return horizontal ? Offset(delta.dx, 0) : Offset(0, delta.dy);
  }

  @override
  void didUpdateWidget(ReaderPageWheel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.resistance != widget.resistance) {
      _clearTail();
      _resetResistance();
    }
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _gestureEnd?.cancel();
    _tailEnd?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final background = dark ? colors.inverseSurface : colors.surface;
    final foreground = dark ? colors.onInverseSurface : colors.onSurface;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _signal,
          ),
        ),
        if (widget.resistance && widget.showResistance)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _feedbackVisible ? 1 : 0,
                duration: _feedbackVisible ? Duration.zero : _feedbackFade,
                child: ExcludeSemantics(
                  child: SafeArea(
                    minimum: const EdgeInsets.all(12),
                    child: Padding(
                      padding: ReaderChromeInsets.of(context),
                      child: Align(
                        alignment: _horizontal
                            ? (_direction == 1
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft)
                            : (_direction == 1
                                  ? Alignment.bottomCenter
                                  : Alignment.topCenter),
                        child: RotatedBox(
                          quarterTurns: _horizontal
                              ? (_direction == 1 ? 3 : 1)
                              : 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: background,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    !_horizontal && _direction == -1
                                        ? Icons.keyboard_arrow_up
                                        : Icons.keyboard_arrow_down,
                                    size: 18,
                                    color: foreground,
                                  ),
                                  SizedBox(
                                    width: 56,
                                    child: LinearProgressIndicator(
                                      value: _displayProgress,
                                      minHeight: 3,
                                      color: foreground,
                                      backgroundColor: dark
                                          ? foreground.withValues(alpha: .24)
                                          : colors.surfaceContainerHighest,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
