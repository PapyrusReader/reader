import 'package:flutter/material.dart';

import '../domain/reader_locator.dart';
import '../domain/reader_snapshot.dart';
import '../domain/reader_toc_entry.dart';
import 'reader_panel_header.dart';
import 'reader_theme_data.dart';

final class ReaderContentsPanel extends StatelessWidget {
  const ReaderContentsPanel({
    super.key,
    required this.snapshot,
    required this.close,
    required this.theme,
    required this.enabled,
    required this.onNavigate,
  });

  final ReaderSnapshot snapshot;
  final VoidCallback close;
  final ReaderThemeData theme;
  final bool enabled;
  final ValueChanged<ReaderLocator> onNavigate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ReaderPanelHeader(title: 'Contents', close: close, theme: theme),
        Expanded(
          child: snapshot.toc.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No table of contents is available.'),
                  ),
                )
              : ListView(
                  children: [
                    for (final entry in snapshot.toc)
                      _TocEntryTile(
                        entry: entry,
                        enabled: enabled,
                        onNavigate: onNavigate,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

final class _TocEntryTile extends StatefulWidget {
  const _TocEntryTile({
    required this.entry,
    required this.enabled,
    required this.onNavigate,
    this.depth = 0,
  });

  final ReaderTocEntry entry;
  final bool enabled;
  final ValueChanged<ReaderLocator> onNavigate;
  final int depth;

  @override
  State<_TocEntryTile> createState() => _TocEntryTileState();
}

final class _TocEntryTileState extends State<_TocEntryTile> {
  bool _expanded = false;

  void _navigate() {
    widget.onNavigate(widget.entry.locator);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    if (entry.children.isEmpty) {
      return ListTile(
        contentPadding: EdgeInsetsDirectional.only(
          start: 16 + widget.depth * 16,
          end: 16,
        ),
        minVerticalPadding: 12,
        title: Text(entry.title),
        onTap: widget.enabled ? _navigate : null,
      );
    }

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsetsDirectional.only(
            start: 16 + widget.depth * 16,
            end: 4,
          ),
          title: Text(entry.title),
          onTap: widget.enabled ? _navigate : null,
          trailing: IconButton(
            tooltip: _expanded ? 'Collapse section' : 'Expand section',
            onPressed: widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
            icon: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
          ),
        ),
        if (_expanded)
          for (final child in entry.children)
            _TocEntryTile(
              entry: child,
              enabled: widget.enabled,
              onNavigate: widget.onNavigate,
              depth: widget.depth + 1,
            ),
      ],
    );
  }
}
