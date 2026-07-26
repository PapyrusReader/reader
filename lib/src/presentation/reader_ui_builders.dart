import 'package:flutter/widgets.dart';

import '../controller/reader_controller.dart';
import '../domain/reader_document.dart';
import '../domain/reader_snapshot.dart';

typedef ReaderToolbarBuilder =
    Widget Function(BuildContext context, ReaderToolbarContext state);
typedef ReaderPanelBuilder =
    Widget Function(BuildContext context, ReaderPanelContext state);
typedef ReaderStateBuilder =
    Widget Function(BuildContext context, ReaderStateContext state);
typedef ReaderViewportBuilder =
    Widget Function(BuildContext context, ReaderViewportContext state);

final class ReaderToolbarContext {
  const ReaderToolbarContext({
    required this.document,
    required this.snapshot,
    required this.openTableOfContents,
    required this.openSettings,
    this.onBack,
    this.isBusy = false,
  });

  final ReaderDocument document;
  final ReaderSnapshot snapshot;
  final VoidCallback? onBack;
  final VoidCallback openTableOfContents;
  final VoidCallback openSettings;
  final bool isBusy;
}

final class ReaderPanelContext {
  const ReaderPanelContext({
    required this.snapshot,
    required this.controller,
    required this.close,
    this.isBusy = false,
  });

  final ReaderSnapshot snapshot;
  final ReaderController controller;
  final VoidCallback close;
  final bool isBusy;
}

final class ReaderStateContext {
  const ReaderStateContext({
    required this.document,
    required this.snapshot,
    required this.controller,
    required this.retry,
  });

  final ReaderDocument document;
  final ReaderSnapshot snapshot;
  final ReaderController controller;
  final VoidCallback retry;
}

final class ReaderViewportContext {
  const ReaderViewportContext({
    required this.snapshot,
    required this.controller,
    required this.viewport,
  });

  final ReaderSnapshot snapshot;
  final ReaderController controller;
  final Widget viewport;
}

final class ReaderUiBuilders {
  const ReaderUiBuilders({
    this.toolbar,
    this.tableOfContents,
    this.settings,
    this.loading,
    this.error,
    this.empty,
    this.viewport,
  });

  final ReaderToolbarBuilder? toolbar;
  final ReaderPanelBuilder? tableOfContents;
  final ReaderPanelBuilder? settings;
  final ReaderStateBuilder? loading;
  final ReaderStateBuilder? error;
  final ReaderStateBuilder? empty;
  final ReaderViewportBuilder? viewport;
}
