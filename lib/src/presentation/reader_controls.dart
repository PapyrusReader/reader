import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/reader_document.dart';
import 'reader_theme_data.dart';

final class ReaderCommandError extends StatelessWidget {
  const ReaderCommandError({
    super.key,
    required this.message,
    required this.theme,
    required this.onDismiss,
    this.onRetry,
  });

  final String message;
  final ReaderThemeData theme;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('reader-command-error'),
      color: theme.errorColor,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color:
                      ThemeData.estimateBrightnessForColor(theme.errorColor) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                ),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            IconButton(
              tooltip: 'Dismiss reader error',
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

double readerToolbarHeight(
  BuildContext context,
  ReaderThemeData theme,
  bool isWide,
) {
  final textScale = MediaQuery.textScalerOf(context).scale(1);
  return math.max(
    isWide ? theme.wideToolbarHeight : theme.compactToolbarHeight,
    theme.minimumTargetSize + math.max(8, (textScale - 1) * 12),
  );
}

final class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({
    super.key,
    required this.document,
    required this.onBack,
    required this.onTableOfContents,
    required this.onSettings,
    required this.tocFocusNode,
    required this.settingsFocusNode,
    required this.theme,
    required this.isWide,
  });

  final ReaderDocument document;
  final VoidCallback? onBack;
  final VoidCallback onTableOfContents;
  final VoidCallback onSettings;
  final FocusNode tocFocusNode;
  final FocusNode settingsFocusNode;
  final ReaderThemeData theme;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final height = readerToolbarHeight(context, theme, isWide);

    return SizedBox(
      height: height,
      child: AppBar(
        primary: false,
        automaticallyImplyLeading: false,
        toolbarHeight: height,
        backgroundColor: theme.chromeColor,
        foregroundColor: theme.onChromeColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: onBack == null ? null : BackButton(onPressed: onBack),
        actions: [
          ReaderIconButton(
            key: const ValueKey('reader-toc-button'),
            focusNode: tocFocusNode,
            icon: Icons.format_list_bulleted_rounded,
            tooltip: 'Table of contents',
            onPressed: onTableOfContents,
            theme: theme,
          ),
          ReaderIconButton(
            key: const ValueKey('reader-settings-button'),
            focusNode: settingsFocusNode,
            icon: Icons.text_fields_rounded,
            tooltip: 'Reading settings',
            onPressed: onSettings,
            theme: theme,
          ),
        ],
      ),
    );
  }
}

final class ReaderIconButton extends StatelessWidget {
  const ReaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.theme,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final ReaderThemeData theme;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      focusNode: focusNode,
      constraints: BoxConstraints.tightFor(
        width: theme.minimumTargetSize,
        height: theme.minimumTargetSize,
      ),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

final class ReaderProgressControls extends StatelessWidget {
  const ReaderProgressControls({
    super.key,
    required this.progress,
    required this.onProgressChanged,
    required this.onProgressChangeEnd,
    required this.onPrevious,
    required this.onNext,
    required this.enabled,
    required this.theme,
    this.locationLabel,
  });

  final double progress;
  final ValueChanged<double> onProgressChanged;
  final ValueChanged<double> onProgressChangeEnd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool enabled;
  final ReaderThemeData theme;
  final String? locationLabel;

  @override
  Widget build(BuildContext context) {
    final normalized = progress.clamp(0.0, 1.0);
    final percent = (normalized * 100).round();

    final controls = Row(
      children: [
        ReaderIconButton(
          icon: Icons.chevron_left_rounded,
          tooltip: 'Previous',
          onPressed: enabled ? onPrevious : null,
          theme: theme,
        ),
        Expanded(
          child: Semantics(
            label: 'Reading progress',
            value: '$percent percent',
            slider: true,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: theme.progressColor,
                thumbColor: theme.handleColor,
              ),
              child: Slider(
                value: normalized,
                onChanged: enabled ? onProgressChanged : null,
                onChangeEnd: enabled ? onProgressChangeEnd : null,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '$percent%',
            key: const ValueKey('reader-progress-label'),
            textAlign: TextAlign.center,
            maxLines: 1,
            semanticsLabel: '$percent percent read',
          ),
        ),
        ReaderIconButton(
          icon: Icons.chevron_right_rounded,
          tooltip: 'Next',
          onPressed: enabled ? onNext : null,
          theme: theme,
        ),
      ],
    );

    return ColoredBox(
      color: theme.chromeColor,
      child: IconTheme(
        data: IconThemeData(color: theme.onChromeColor),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.onChromeColor),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: locationLabel == null
                ? controls
                : Stack(
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            locationLabel!,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: theme.onChromeColor),
                          ),
                          // Keep the label 11 pixels above the track while the
                          // controls retain their full-height touch targets.
                          SizedBox(height: theme.minimumTargetSize / 2 + 11),
                        ],
                      ),
                      PositionedDirectional(
                        start: 0,
                        end: 0,
                        bottom: 0,
                        child: controls,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
