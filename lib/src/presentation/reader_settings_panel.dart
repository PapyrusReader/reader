import 'package:flutter/material.dart';

import '../domain/reader_capabilities.dart';
import '../domain/reader_preferences.dart';
import '../domain/reader_snapshot.dart';
import '../domain/reader_types.dart';
import 'reader_panel_header.dart';
import 'reader_theme_data.dart';

final class ReaderSettingsPanel extends StatelessWidget {
  const ReaderSettingsPanel({
    super.key,
    this.showHeader = true,
    this.scrollController,
    required this.snapshot,
    required this.close,
    required this.theme,
    required this.enabled,
    required this.isBusy,
    required this.commandRevision,
    required this.onUpdatePreferences,
  });

  final bool showHeader;
  final ScrollController? scrollController;
  final ReaderSnapshot snapshot;
  final VoidCallback close;
  final ReaderThemeData theme;
  final bool enabled;
  final bool isBusy;
  final int commandRevision;
  final ValueChanged<ReaderPreferences> onUpdatePreferences;

  @override
  Widget build(BuildContext context) {
    final capabilities = snapshot.capabilities ?? const ReaderCapabilities();
    final preferences = snapshot.preferences;
    final appearance = switch (preferences) {
      _ when preferences.brightness == Brightness.dark => _PageAppearance.night,
      _ when preferences.backgroundColor == const Color(0xfff4ecd8) =>
        _PageAppearance.sepia,
      _ when preferences.backgroundColor == const Color(0xffffffff) =>
        _PageAppearance.light,
      _ => null,
    };

    final content = ListView(
      controller: scrollController,
      shrinkWrap: !showHeader,
      padding: EdgeInsets.all(theme.panelPadding),
      children: [
        if (capabilities.supportsTextCustomization) ...[
          DropdownButtonFormField<String>(
            key: ValueKey(('reader-font', preferences.fontFamily)),
            initialValue:
                const <String?>[
                  null,
                  'serif',
                  'sans-serif',
                  'monospace',
                ].contains(preferences.fontFamily)
                ? preferences.fontFamily ?? 'system'
                : 'system',
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Typeface',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'system', child: Text('System')),
              DropdownMenuItem(value: 'serif', child: Text('Serif')),
              DropdownMenuItem(value: 'sans-serif', child: Text('Sans serif')),
              DropdownMenuItem(value: 'monospace', child: Text('Monospace')),
            ],
            onChanged: enabled
                ? (value) => _update(
                    preferences.copyWith(
                      fontFamily: value == 'system' ? null : value,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 20),
          _SettingSlider(
            title: 'Font size',
            value: preferences.fontSize.clamp(8, 72),
            min: 8,
            max: 72,
            divisions: 64,
            valueLabel: preferences.fontSize.round().toString(),
            enabled: enabled,
            isBusy: isBusy,
            commandRevision: commandRevision,
            onChangeEnd: (value) =>
                _update(preferences.copyWith(fontSize: value)),
          ),
          _SettingSlider(
            title: 'Line height',
            value: preferences.lineHeight.clamp(1, 2.5),
            min: 1,
            max: 2.5,
            divisions: 15,
            valueLabel: preferences.lineHeight.toStringAsFixed(1),
            enabled: enabled,
            isBusy: isBusy,
            commandRevision: commandRevision,
            onChangeEnd: (value) =>
                _update(preferences.copyWith(lineHeight: value)),
          ),
          _SettingSlider(
            title: 'Margins',
            value: preferences.pageMargins.left.clamp(0, 64),
            min: 0,
            max: 64,
            divisions: 16,
            valueLabel: preferences.pageMargins.left.round().toString(),
            enabled: enabled,
            isBusy: isBusy,
            commandRevision: commandRevision,
            onChangeEnd: (value) => _update(
              preferences.copyWith(pageMargins: EdgeInsets.all(value)),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (capabilities.supportsPagination ||
            capabilities.supportsScrolling) ...[
          DropdownButtonFormField<ReaderLayoutMode>(
            key: ValueKey(('reader-mode', preferences.layoutMode)),
            initialValue: preferences.layoutMode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Reading mode',
              border: OutlineInputBorder(),
            ),
            items: [
              if (capabilities.supportsPagination)
                const DropdownMenuItem(
                  value: ReaderLayoutMode.paginated,
                  child: Text('Paginated'),
                ),
              if (capabilities.supportsScrolling)
                const DropdownMenuItem(
                  value: ReaderLayoutMode.scroll,
                  child: Text('Continuous scroll'),
                ),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) {
                      _update(preferences.copyWith(layoutMode: value));
                    }
                  }
                : null,
          ),
        ],
        if (capabilities.supportsPageTurnAnimation &&
            preferences.layoutMode == ReaderLayoutMode.paginated) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<bool>(
            key: ValueKey(('reader-animation', preferences.pageTurnAnimation)),
            initialValue: preferences.pageTurnAnimation,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Page turn animation',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: true, child: Text('Slide')),
              DropdownMenuItem(value: false, child: Text('None')),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) {
                      _update(preferences.copyWith(pageTurnAnimation: value));
                    }
                  }
                : null,
          ),
        ],
        if (capabilities.supportsColumnMode) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<ReaderColumnMode>(
            key: ValueKey(('reader-columns', preferences.columnMode)),
            initialValue: preferences.columnMode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Columns',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: ReaderColumnMode.automatic,
                child: Text('Automatic'),
              ),
              DropdownMenuItem(
                value: ReaderColumnMode.single,
                child: Text('Single'),
              ),
              DropdownMenuItem(
                value: ReaderColumnMode.double,
                child: Text('Double'),
              ),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) {
                      _update(preferences.copyWith(columnMode: value));
                    }
                  }
                : null,
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<_PageAppearance>(
          key: ValueKey(('reader-appearance', appearance)),
          initialValue: appearance,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Page appearance',
            border: OutlineInputBorder(),
          ),
          hint: const Text('Custom'),
          items: [
            for (final preset in _PageAppearance.values)
              DropdownMenuItem(value: preset, child: Text(preset.label)),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null) {
                    _update(
                      preferences.copyWith(
                        backgroundColor: value.background,
                        foregroundColor: value.foreground,
                        brightness: value.brightness,
                      ),
                    );
                  }
                }
              : null,
        ),
        if (capabilities.supportsLinkHighlighting) ...[
          const SizedBox(height: 12),
          Theme(
            data: Theme.of(context).copyWith(
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Highlight links'),
              value: preferences.highlightLinks,
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed) ||
                    !states.contains(WidgetState.focused)) {
                  return Colors.transparent;
                }

                return null;
              }),
              onChanged: enabled
                  ? (value) =>
                        _update(preferences.copyWith(highlightLinks: value))
                  : null,
            ),
          ),
        ],
      ],
    );
    final accessibleContent = Semantics(
      container: true,
      explicitChildNodes: true,
      child: content,
    );

    if (!showHeader) return accessibleContent;
    return Column(
      children: [
        ReaderPanelHeader(
          title: 'Reading settings',
          close: close,
          theme: theme,
        ),
        Expanded(child: accessibleContent),
      ],
    );
  }

  void _update(ReaderPreferences preferences) {
    onUpdatePreferences(preferences);
  }
}

final class _SettingSlider extends StatefulWidget {
  const _SettingSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.enabled,
    required this.isBusy,
    required this.commandRevision,
    required this.onChangeEnd,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final bool enabled;
  final bool isBusy;
  final int commandRevision;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_SettingSlider> createState() => _SettingSliderState();
}

final class _SettingSliderState extends State<_SettingSlider> {
  late double _preview = widget.value;
  bool _interacting = false;

  @override
  void didUpdateWidget(_SettingSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final commandSettled =
        oldWidget.commandRevision != widget.commandRevision && !widget.isBusy;
    if (!_interacting && (oldWidget.value != widget.value || commandSettled)) {
      _preview = widget.value;
    }
  }

  String get _previewLabel {
    if (_preview == widget.value) {
      return widget.valueLabel;
    }

    return widget.max <= 3
        ? _preview.toStringAsFixed(1)
        : _preview.round().toString();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.title)),
            Text(_previewLabel),
          ],
        ),
        Slider(
          value: _preview,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: _previewLabel,
          onChangeStart: widget.enabled
              ? (_) => setState(() => _interacting = true)
              : null,
          onChanged: widget.enabled
              ? (value) => setState(() => _preview = value)
              : null,
          onChangeEnd: widget.enabled
              ? (value) {
                  setState(() {
                    _preview = value;
                    _interacting = false;
                  });
                  widget.onChangeEnd(value);
                }
              : null,
        ),
      ],
    );
  }
}

enum _PageAppearance {
  light('Light', Color(0xffffffff), Color(0xff1b1b1b), Brightness.light),
  sepia('Sepia', Color(0xfff4ecd8), Color(0xff3d3527), Brightness.light),
  night('Night', Color(0xff151719), Color(0xffece7de), Brightness.dark);

  const _PageAppearance(
    this.label,
    this.background,
    this.foreground,
    this.brightness,
  );

  final String label;
  final Color background;
  final Color foreground;
  final Brightness brightness;
}
