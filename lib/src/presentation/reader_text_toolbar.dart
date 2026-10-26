import 'package:flutter/material.dart';

/// Positions actions against the actual glyphs rather than a secondary-click anchor.
final class ReaderTextToolbar extends StatelessWidget {
  const ReaderTextToolbar({
    required this.bounds,
    required this.items,
    super.key,
  });

  final Rect bounds;
  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) => TextSelectionToolbar(
    anchorAbove: bounds.topCenter,
    anchorBelow: bounds.bottomCenter,
    children: [
      for (var index = 0; index < items.length; index++)
        TextSelectionToolbarTextButton(
          padding: TextSelectionToolbarTextButton.getPadding(
            index,
            items.length,
          ),
          onPressed: items[index].onPressed,
          child: Text(
            AdaptiveTextSelectionToolbar.getButtonLabel(context, items[index]),
          ),
        ),
    ],
  );
}
