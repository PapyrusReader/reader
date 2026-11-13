import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/pdf_reader_tools.dart';

/// A single toolbar row. Compact layouts move secondary actions into a menu.
final class ReaderPdfControls extends StatefulWidget {
  const ReaderPdfControls({
    required this.tools,
    required this.onSearch,
    this.onBack,
    this.actions = const [],
    this.compact = false,
    super.key,
  });

  final PdfReaderTools tools;
  final VoidCallback onSearch;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final bool compact;

  @override
  State<ReaderPdfControls> createState() => _ReaderPdfControlsState();
}

final class _ReaderPdfControlsState extends State<ReaderPdfControls> {
  Future<void> _commands = Future.value();

  void _run(Future<void> Function() command) {
    final tools = widget.tools;
    _commands = _commands.then((_) async {
      if (!mounted || widget.tools != tools || !tools.isReady) return;

      try {
        await command();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('Could not update the PDF view. Try again.'),
            ),
          );
        }
      }
    });
  }

  Future<void> _enterNumber({required bool zoom}) async {
    final tools = widget.tools;
    final value = await showDialog<int>(
      context: context,
      builder: (context) => _PdfNumberDialog(
        title: zoom ? 'Zoom' : 'Go to page',
        label: zoom ? 'Zoom percentage' : 'Page number',
        initial: zoom ? (tools.zoom * 100).round() : tools.pageNumber,
        minimum: zoom ? (tools.minimumZoom * 100).ceil() : 1,
        maximum: zoom ? (tools.maximumZoom * 100).floor() : tools.pageCount,
        suffix: zoom ? '%' : 'of ${tools.pageCount}',
      ),
    );

    if (!mounted || value == null || widget.tools != tools) return;
    _run(() => zoom ? tools.setZoom(value / 100) : tools.goToPage(value));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.tools,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final tools = widget.tools;
        final ready = tools.isReady;
        final compact = widget.compact;
        final showSteps =
            !compact ||
            constraints.maxWidth >=
                240 + MediaQuery.textScalerOf(context).scale(64);
        final zoomOut = ready && tools.zoom > tools.minimumZoom + .001
            ? () => _run(() => tools.setZoom(tools.zoom - .05))
            : null;
        final zoomIn = ready && tools.zoom < tools.maximumZoom - .001
            ? () => _run(() => tools.setZoom(tools.zoom + .05))
            : null;

        return Row(
          children: [
            if (widget.onBack != null) BackButton(onPressed: widget.onBack),
            const Spacer(),
            if (!compact) ...[
              IconButton(
                tooltip: 'Return to previous location',
                onPressed: ready && tools.canReturn
                    ? () => _run(tools.returnToPrevious)
                    : null,
                icon: const Icon(Icons.undo),
              ),
              TextButton(
                onPressed: ready ? () => _enterNumber(zoom: false) : null,
                child: Text(
                  'Page ${tools.pageNumber} of ${tools.pageCount}',
                  semanticsLabel:
                      'Page ${tools.pageNumber} of ${tools.pageCount}. Go to page',
                ),
              ),
              IconButton(
                tooltip: 'Go forward to next location',
                onPressed: ready && tools.canGoForward
                    ? () => _run(tools.goForward)
                    : null,
                icon: const Icon(Icons.redo),
              ),
              const SizedBox(
                height: 24,
                child: VerticalDivider(width: 8, thickness: 1),
              ),
            ],
            if (showSteps)
              IconButton(
                tooltip: 'Zoom out by 5%',
                onPressed: zoomOut,
                icon: const Icon(Icons.remove),
              ),
            TextButton(
              onPressed: ready ? () => _enterNumber(zoom: true) : null,
              child: Text(
                '${(tools.zoom * 100).round()}%',
                semanticsLabel:
                    'Zoom ${(tools.zoom * 100).round()} percent. Set zoom',
              ),
            ),
            if (showSteps)
              IconButton(
                tooltip: 'Zoom in by 5%',
                onPressed: zoomIn,
                icon: const Icon(Icons.add),
              ),
            if (!compact)
              const SizedBox(
                height: 24,
                child: VerticalDivider(width: 8, thickness: 1),
              ),
            if (!compact)
              PopupMenuButton<PdfFitMode>(
                tooltip: 'Fit document',
                enabled: ready,
                icon: const Icon(Icons.fit_screen),
                onSelected: (mode) => _run(
                  mode == PdfFitMode.page ? tools.fitPage : tools.fitWidth,
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: PdfFitMode.page,
                    child: Text('Fit page'),
                  ),
                  PopupMenuItem(
                    value: PdfFitMode.width,
                    child: Text('Fit width'),
                  ),
                ],
              ),
            IconButton(
              tooltip: 'Search in document',
              onPressed: ready ? widget.onSearch : null,
              icon: const Icon(Icons.search),
            ),
            if (!compact) ...widget.actions,
            if (compact)
              MenuAnchor(
                crossAxisUnconstrained: false,
                style: MenuStyle(
                  maximumSize: WidgetStatePropertyAll(
                    Size(
                      MediaQuery.sizeOf(context).width - 16,
                      double.infinity,
                    ),
                  ),
                ),
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.find_in_page_outlined),
                    onPressed: ready ? () => _enterNumber(zoom: false) : null,
                    child: Text(
                      'Go to page (${tools.pageNumber} of ${tools.pageCount})',
                    ),
                  ),
                  if (!showSteps) ...[
                    MenuItemButton(
                      onPressed: zoomOut,
                      leadingIcon: const Icon(Icons.remove),
                      child: const Text('Zoom out by 5%'),
                    ),
                    MenuItemButton(
                      onPressed: zoomIn,
                      leadingIcon: const Icon(Icons.add),
                      child: const Text('Zoom in by 5%'),
                    ),
                  ],
                  MenuItemButton(
                    onPressed: ready ? () => _run(tools.fitPage) : null,
                    leadingIcon: const Icon(Icons.fit_screen),
                    child: const Text('Fit page'),
                  ),
                  MenuItemButton(
                    onPressed: ready ? () => _run(tools.fitWidth) : null,
                    leadingIcon: const Icon(Icons.width_normal),
                    child: const Text('Fit width'),
                  ),
                  MenuItemButton(
                    onPressed: ready && tools.canReturn
                        ? () => _run(tools.returnToPrevious)
                        : null,
                    leadingIcon: const Icon(Icons.undo),
                    child: const Text('Return to previous location'),
                  ),
                  MenuItemButton(
                    onPressed: ready && tools.canGoForward
                        ? () => _run(tools.goForward)
                        : null,
                    leadingIcon: const Icon(Icons.redo),
                    child: const Text('Go forward to next location'),
                  ),
                  const Divider(),
                  ...widget.actions,
                ],
                builder: (context, controller, child) => IconButton(
                  tooltip: 'More reader actions',
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              ),
          ],
        );
      },
    ),
  );
}

final class _PdfNumberDialog extends StatefulWidget {
  const _PdfNumberDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.minimum,
    required this.maximum,
    required this.suffix,
  });

  final String title;
  final String label;
  final int initial;
  final int minimum;
  final int maximum;
  final String suffix;

  @override
  State<_PdfNumberDialog> createState() => _PdfNumberDialogState();
}

final class _PdfNumberDialogState extends State<_PdfNumberDialog> {
  late final _text = TextEditingController(text: '${widget.initial}')
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.initial}'.length,
    );
  String? _error;

  void _submit() {
    final number = int.tryParse(_text.text);
    if (number == null || number < widget.minimum || number > widget.maximum) {
      setState(
        () => _error =
            'Enter a number from ${widget.minimum} to ${widget.maximum}.',
      );
      return;
    }
    Navigator.pop(context, number);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      autofocus: true,
      controller: _text,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: widget.suffix,
        errorText: _error,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Apply')),
    ],
  );
}
