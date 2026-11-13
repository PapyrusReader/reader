import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/pdf_reader_tools.dart';

/// Search overlays the document without resizing the viewport or reader chrome.
final class ReaderPdfSearchPanel extends StatefulWidget {
  const ReaderPdfSearchPanel({
    required this.tools,
    required this.close,
    required this.closeOnSelection,
    this.emptyBuilder,
    this.focusNode,
    super.key,
  });

  final PdfReaderTools tools;
  final VoidCallback close;
  final bool closeOnSelection;
  final WidgetBuilder? emptyBuilder;
  final FocusNode? focusNode;

  @override
  State<ReaderPdfSearchPanel> createState() => _ReaderPdfSearchPanelState();
}

final class _ReaderPdfSearchPanelState extends State<ReaderPdfSearchPanel> {
  late final _query = TextEditingController(text: widget.tools.query);
  final _resultsScroll = ScrollController();
  final _resultKeys = <int, GlobalKey>{};
  Future<void> _selectionQueue = Future.value();
  int? _requestedMatch;
  int _selectionRevision = 0;
  int _queryRevision = 0;

  @override
  void dispose() {
    _query.dispose();
    _resultsScroll.dispose();
    super.dispose();
  }

  void _search(String query) {
    _queryRevision++;
    _resultKeys.clear();
    setState(() => _requestedMatch = null);
    widget.tools.search(query);
  }

  Future<void> _select(int index, {bool closePanel = true}) {
    final tools = widget.tools;
    if (index < 0 || index >= tools.matches.length) return Future.value();
    final queryRevision = _queryRevision;
    final selectionRevision = ++_selectionRevision;
    setState(() => _requestedMatch = index);
    _revealResult(index, selectionRevision, queryRevision);

    _selectionQueue = _selectionQueue.then((_) async {
      if (!mounted ||
          widget.tools != tools ||
          queryRevision != _queryRevision) {
        return;
      }

      try {
        await tools.selectMatch(index);
        if (mounted &&
            queryRevision == _queryRevision &&
            closePanel &&
            widget.closeOnSelection) {
          widget.close();
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('Could not open this search result. Try again.'),
            ),
          );
        }
      } finally {
        if (mounted &&
            queryRevision == _queryRevision &&
            selectionRevision == _selectionRevision) {
          setState(() => _requestedMatch = null);
        }
      }
    });
    return _selectionQueue;
  }

  void _revealResult(
    int index,
    int selectionRevision,
    int queryRevision, {
    double lowerOffset = 0,
    double upperOffset = double.infinity,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          selectionRevision != _selectionRevision ||
          queryRevision != _queryRevision ||
          !_resultsScroll.hasClients) {
        return;
      }

      final position = _resultsScroll.position;
      final target = _resultKeys[index]?.currentContext?.findRenderObject();

      if (target != null && target.attached) {
        // Preserve the current offset when the entire row is already visible.
        position.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        position.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return;
      }

      // A manually scrolled list may not have built the active row. Estimate
      // its offset from the nearest built row, then refine after layout.
      int? nearestIndex;
      RenderBox? nearestRow;

      for (final entry in _resultKeys.entries) {
        final row = entry.value.currentContext?.findRenderObject();

        if (row is RenderBox &&
            row.attached &&
            row.hasSize &&
            (nearestIndex == null ||
                (entry.key - index).abs() < (nearestIndex - index).abs())) {
          nearestIndex = entry.key;
          nearestRow = row;
        }
      }

      if (nearestIndex == null || nearestRow == null) return;

      var lower = lowerOffset;
      var upper = upperOffset;

      if (nearestIndex < index) {
        lower = position.pixels;
      } else {
        upper = position.pixels;
      }

      if (upper - lower < 1) return;

      final estimate =
          position.pixels + (index - nearestIndex) * nearestRow.size.height;
      final offset = estimate > lower && estimate < upper
          ? estimate
          : (lower + upper) / 2;
      position.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
      _revealResult(
        index,
        selectionRevision,
        queryRevision,
        lowerOffset: lower,
        upperOffset: upper,
      );
    });
  }

  Widget _emptyState(BuildContext context, PdfReaderTools tools) {
    final hasQuery = tools.query.isNotEmpty;
    if (hasQuery && !tools.searching && widget.emptyBuilder != null) {
      return widget.emptyBuilder!(context);
    }

    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (title, description) = switch ((tools.searching, hasQuery)) {
      (true, _) => ('Searching…', 'Looking for matches in the document.'),
      (false, true) => ('No results found', 'Try a different word or phrase.'),
      (false, false) => (
        'Search this PDF',
        'Enter a word or phrase to find it in the document.',
      ),
    };

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery && !tools.searching ? Icons.search_off : Icons.search,
              size: 40,
              color: colors.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.tools,
    builder: (context, _) {
      final tools = widget.tools;
      final matches = tools.matches;
      final current = _requestedMatch ?? tools.currentMatch;
      final ready = tools.isReady || _requestedMatch != null;
      final colors = Theme.of(context).colorScheme;
      final status = current == null
          ? '${matches.length} matches'
          : '${current + 1} of ${matches.length} matches';

      final content = Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Search',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (matches.isNotEmpty) ...[
                  Tooltip(
                    message: status,
                    child: Semantics(
                      liveRegion: true,
                      label: status,
                      excludeSemantics: true,
                      child: Text(
                        current == null
                            ? '${matches.length}'
                            : '${current + 1}/${matches.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous match',
                    style: const ButtonStyle(animationDuration: Duration.zero),
                    onPressed: ready && current != null && current > 0
                        ? () => _select(current - 1, closePanel: false)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Next match',
                    style: const ButtonStyle(animationDuration: Duration.zero),
                    onPressed: ready && (current ?? -1) + 1 < matches.length
                        ? () => _select((current ?? -1) + 1, closePanel: false)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ],
                IconButton(
                  tooltip: 'Close search',
                  onPressed: widget.close,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // Leave text insertion to the platform instead of the reader's
            // page-turn shortcuts higher in the focus chain.
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.space):
                    DoNothingAndStopPropagationIntent(),
                SingleActivator(LogicalKeyboardKey.space, shift: true):
                    DoNothingAndStopPropagationIntent(),
              },
              child: TextField(
                autofocus: true,
                focusNode: widget.focusNode,
                controller: _query,
                decoration: const InputDecoration(
                  labelText: 'Search in document',
                  prefixIcon: Icon(Icons.search),
                ),
                textInputAction: TextInputAction.search,
                onChanged: _search,
                onSubmitted: (_) {
                  if (ready && matches.isNotEmpty) _select(0);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          Expanded(
            key: const ValueKey('pdf-search-results'),
            child: matches.isEmpty
                ? _emptyState(context, tools)
                : ListView.builder(
                    controller: _resultsScroll,
                    itemCount: matches.length,
                    itemBuilder: (context, index) => ListTile(
                      key: _resultKeys.putIfAbsent(index, GlobalKey.new),
                      selected: index == current,
                      title: Text(
                        matches[index].text,
                        style: TextStyle(
                          color: index == current
                              ? colors.primary
                              : colors.onSurface,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Page ${matches[index].pageNumber}',
                        style: TextStyle(
                          color: index == current
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      onTap: ready ? () => _select(index) : null,
                    ),
                  ),
          ),
        ],
      );

      return LayoutBuilder(
        builder: (context, constraints) {
          final minimumHeight = 240 * MediaQuery.textScalerOf(context).scale(1);
          if (constraints.maxHeight >= minimumHeight) return content;

          return SingleChildScrollView(
            child: SizedBox(height: minimumHeight, child: content),
          );
        },
      );
    },
  );
}
