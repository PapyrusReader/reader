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
        const SizedBox(height: 20),
        Text('Page appearance', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _AppearancePreset(
              label: 'Light',
              selected:
                  preferences.brightness == Brightness.light &&
                  preferences.backgroundColor == const Color(0xffffffff),
              background: const Color(0xffffffff),
              foreground: const Color(0xff1b1b1b),
              brightness: Brightness.light,
              enabled: enabled,
              onSelected: _applyAppearance,
            ),
            _AppearancePreset(
              label: 'Sepia',
              selected: preferences.backgroundColor == const Color(0xfff4ecd8),
              background: const Color(0xfff4ecd8),
              foreground: const Color(0xff3d3527),
              brightness: Brightness.light,
              enabled: enabled,
              onSelected: _applyAppearance,
            ),
            _AppearancePreset(
              label: 'Night',
              selected: preferences.brightness == Brightness.dark,
              background: const Color(0xff151719),
              foreground: const Color(0xffece7de),
              brightness: Brightness.dark,
              enabled: enabled,
              onSelected: _applyAppearance,
            ),
          ],
        ),
      ],
    );
    if (!showHeader) return content;
    return Column(
      children: [
        ReaderPanelHeader(
          title: 'Reading settings',
          close: close,
          theme: theme,
        ),
        Expanded(child: content),
      ],
    );
  }

  void _update(ReaderPreferences preferences) {
    onUpdatePreferences(preferences);
  }

  void _applyAppearance(
    Color background,
    Color foreground,
    Brightness brightness,
  ) {
    _update(
      snapshot.preferences.copyWith(
        backgroundColor: background,
        foregroundColor: foreground,
        brightness: brightness,
      ),
    );
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

typedef _AppearanceChanged =
    void Function(Color background, Color foreground, Brightness brightness);

final class _AppearancePreset extends StatelessWidget {
  const _AppearancePreset({
    required this.label,
    required this.selected,
    required this.background,
    required this.foreground,
    required this.brightness,
    required this.enabled,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final Color background;
  final Color foreground;
  final Brightness brightness;
  final bool enabled;
  final _AppearanceChanged onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      labelStyle: TextStyle(
        color: selected ? colors.onSecondaryContainer : colors.onSurface,
      ),
      color: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.secondaryContainer
            : colors.surfaceContainerLow,
      ),
      checkmarkColor: colors.onSecondaryContainer,
      side: BorderSide(color: colors.outlineVariant),
      selected: selected,
      avatar: CircleAvatar(backgroundColor: background),
      onSelected: enabled
          ? (_) => onSelected(background, foreground, brightness)
          : null,
    );
  }
}
