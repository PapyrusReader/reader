import 'package:flutter/material.dart';

import 'reader_theme_data.dart';
import 'reader_controls.dart';

final class ReaderPanelHeader extends StatelessWidget {
  const ReaderPanelHeader({
    super.key,
    required this.title,
    required this.close,
    required this.theme,
  });

  final String title;
  final VoidCallback close;
  final ReaderThemeData theme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: IconTheme(
        data: IconThemeData(color: theme.onChromeColor),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.onChromeColor),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: theme.onChromeColor,
                      ),
                    ),
                  ),
                ),
                ReaderIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close panel',
                  onPressed: close,
                  theme: theme,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
