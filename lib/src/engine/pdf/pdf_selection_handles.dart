import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Uses the same native handle shapes as EPUB's SelectionArea, while adapting
/// their baseline anchors to pdfrx's character-corner coordinates.
class PdfSelectionHandles {
  const PdfSelectionHandles(this.controller);

  final PdfViewerController? controller;

  TextSelectionControls _controls(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.iOS ||
        TargetPlatform.macOS => cupertinoTextSelectionControls,
        _ => materialTextSelectionControls,
      };

  double _lineHeight(PdfTextSelectionAnchor anchor) =>
      anchor.rect.height *
      (controller?.isReady == true ? controller!.currentZoom : 1);

  bool _reversed(PdfTextSelectionAnchor anchor) =>
      anchor.direction == PdfTextDirection.rtl ||
      anchor.direction == PdfTextDirection.vrtl;

  TextSelectionHandleType _type(PdfTextSelectionAnchor anchor) =>
      (anchor.type == PdfTextSelectionAnchorType.a) != _reversed(anchor)
      ? TextSelectionHandleType.left
      : TextSelectionHandleType.right;

  EdgeInsets _padding(Size size) => EdgeInsets.symmetric(
    horizontal: math.max(0, (48 - size.width) / 2),
    vertical: math.max(0, (48 - size.height) / 2),
  );

  Widget build(
    BuildContext context,
    PdfTextSelectionAnchor anchor,
    PdfViewerTextSelectionAnchorHandleState state,
  ) {
    final controls = _controls(context);
    final height = _lineHeight(anchor);
    return ColoredBox(
      key: ValueKey('pdf-selection-handle-${anchor.type.name}'),
      color: Colors.transparent,
      child: Padding(
        padding: _padding(controls.getHandleSize(height)),
        child: controls.buildHandle(context, _type(anchor), height),
      ),
    );
  }

  Offset offset(
    BuildContext context,
    PdfTextSelectionAnchor anchor,
    PdfViewerTextSelectionAnchorHandleState state,
  ) {
    final controls = _controls(context);
    final height = _lineHeight(anchor);
    final size = controls.getHandleSize(height);
    final padding = _padding(size);
    final nativeAnchor = controls.getHandleAnchor(_type(anchor), height);
    final start = anchor.type == PdfTextSelectionAnchorType.a;
    final anchoredRight = start != _reversed(anchor);

    return Offset(
      (anchoredRight ? size.width + padding.horizontal : 0) -
          nativeAnchor.dx -
          padding.left,
      (start ? height + size.height + padding.vertical : 0) -
          nativeAnchor.dy -
          padding.top,
    );
  }
}
