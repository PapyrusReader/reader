import 'package:flutter/widgets.dart';
import 'package:flutter_html/flutter_html.dart';

import '../../domain/reader_preferences.dart';

abstract interface class EpubContentRenderer {
  Widget render({
    required String xhtml,
    required ReaderPreferences preferences,
    required ScrollController controller,
  });
}

final class FlutterHtmlEpubContentRenderer implements EpubContentRenderer {
  const FlutterHtmlEpubContentRenderer();

  @override
  Widget render({
    required String xhtml,
    required ReaderPreferences preferences,
    required ScrollController controller,
  }) {
    return ColoredBox(
      color: preferences.backgroundColor,
      child: SingleChildScrollView(
        controller: controller,
        padding: preferences.pageMargins,
        child: DefaultTextStyle(
          style: TextStyle(
            color: preferences.foregroundColor,
            fontFamily: preferences.fontFamily,
            fontSize: preferences.fontSize,
            height: preferences.lineHeight,
            letterSpacing: preferences.letterSpacing,
          ),
          child: Html(
            data: xhtml,
            shrinkWrap: true,
            doNotRenderTheseTags: const {
              'script',
              'form',
              'input',
              'button',
              'iframe',
              'object',
              'embed',
            },
          ),
        ),
      ),
    );
  }
}

final class EpubScrollViewport extends StatefulWidget {
  const EpubScrollViewport({
    super.key,
    required this.xhtml,
    required this.preferences,
    required this.localProgression,
    required this.restorationRevision,
    required this.renderer,
    required this.onProgressChanged,
  });

  final String xhtml;
  final ReaderPreferences preferences;
  final double localProgression;
  final int restorationRevision;
  final EpubContentRenderer renderer;
  final ValueChanged<double> onProgressChanged;

  @override
  State<EpubScrollViewport> createState() => _EpubScrollViewportState();
}

final class _EpubScrollViewportState extends State<EpubScrollViewport> {
  late final ScrollController _controller;
  bool _isRestoring = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _restoreProgress();
  }

  @override
  void didUpdateWidget(covariant EpubScrollViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.xhtml != widget.xhtml ||
        oldWidget.restorationRevision != widget.restorationRevision) {
      _restoreProgress();
    }
  }

  void _restoreProgress() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) {
        return;
      }

      _isRestoring = true;
      try {
        _controller.jumpTo(
          _controller.position.maxScrollExtent * widget.localProgression,
        );
      } finally {
        _isRestoring = false;
      }
    });
  }

  bool _handleScroll(ScrollNotification notification) {
    if (_isRestoring) {
      return false;
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _publishProgress(notification.metrics);
    }

    return false;
  }

  void _publishProgress(ScrollMetrics metrics) {
    final maximum = metrics.maxScrollExtent;
    final progression = maximum <= 0
        ? 0.0
        : (metrics.pixels / maximum).clamp(0.0, 1.0);
    widget.onProgressChanged(progression);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: widget.renderer.render(
        xhtml: widget.xhtml,
        preferences: widget.preferences,
        controller: _controller,
      ),
    );
  }
}
