import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/reader_controller.dart';
import '../domain/reader_capabilities.dart';
import '../domain/reader_document.dart';
import '../domain/reader_exception.dart';
import '../domain/reader_locator.dart';
import '../domain/reader_preferences.dart';
import '../domain/reader_snapshot.dart';
import '../domain/reader_toc_entry.dart';
import '../domain/reader_types.dart';
import '../engine/reader_engine_registry.dart';
import 'reader_theme_data.dart';
import 'reader_ui_builders.dart';

enum _ReaderPanel { none, tableOfContents, settings }

final class PapyrusReader extends StatefulWidget {
  const PapyrusReader({
    required this.document,
    this.initialLocator,
    this.initialPreferences,
    this.theme,
    this.controller,
    this.registry,
    this.onLocatorChanged,
    this.onPreferencesChanged,
    this.onBack,
    this.builders = const ReaderUiBuilders(),
    super.key,
  }) : assert(
         controller == null || registry == null,
         'Provide either controller or registry, not both.',
       );

  final ReaderDocument document;
  final ReaderLocator? initialLocator;
  final ReaderPreferences? initialPreferences;
  final ReaderThemeData? theme;
  final ReaderController? controller;
  final ReaderEngineRegistry? registry;
  final ReaderLocatorChanged? onLocatorChanged;
  final ReaderPreferencesChanged? onPreferencesChanged;
  final VoidCallback? onBack;
  final ReaderUiBuilders builders;

  @override
  State<PapyrusReader> createState() => _PapyrusReaderState();
}

final class _PapyrusReaderState extends State<PapyrusReader> {
  late ReaderController _controller;
  late bool _ownsController;
  ReaderSnapshot? _observedSnapshot;
  _ReaderPanel _panel = _ReaderPanel.none;
  double? _dragProgress;
  int _loadGeneration = 0;
  bool _loadedDependencies = false;
  Future<void> _commandQueue = Future<void>.value();
  int _commandGeneration = 0;
  int _pendingCommands = 0;
  String? _commandError;
  final ValueNotifier<int> _commandRevision = ValueNotifier<int>(0);
  Route<dynamic>? _compactPanelRoute;
  NavigatorState? _compactPanelNavigator;
  final FocusNode _tocButtonFocusNode = FocusNode(
    debugLabel: 'reader TOC button',
  );
  final FocusNode _settingsButtonFocusNode = FocusNode(
    debugLabel: 'reader settings button',
  );
  final FocusNode _widePanelFocusNode = FocusNode(
    debugLabel: 'reader wide panel',
  );
  FocusNode? _widePanelOpener;

  bool get _isCommandBusy => _pendingCommands > 0;

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedDependencies) {
      _loadedDependencies = true;
      _loadDocument();
    }
  }

  @override
  void didUpdateWidget(PapyrusReader oldWidget) {
    super.didUpdateWidget(oldWidget);

    final controllerChanged =
        oldWidget.controller != widget.controller ||
        oldWidget.registry != widget.registry;
    final documentChanged = oldWidget.document != widget.document;
    if (controllerChanged || documentChanged) {
      _dismissCompactPanel();
      _invalidateCommands(notify: false);
    }
    if (controllerChanged) {
      _detachController();
      _attachController();
    }

    if (controllerChanged || documentChanged) {
      _panel = _ReaderPanel.none;
      _dragProgress = null;
      _loadDocument();
    }
  }

  void _attachController() {
    final external = widget.controller;
    _ownsController = external == null;
    _controller =
        external ??
        ReaderController(
          registry: widget.registry ?? ReaderEngineRegistry.defaults(),
          initialPreferences:
              widget.initialPreferences ?? const ReaderPreferences(),
        );
    _observedSnapshot = _controller.snapshot;
    _controller.addListener(_controllerChanged);
  }

  void _detachController() {
    _loadGeneration++;
    _controller.removeListener(_controllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
  }

  void _dismissCompactPanel() {
    final route = _compactPanelRoute;
    final navigator = _compactPanelNavigator;
    _compactPanelRoute = null;
    _compactPanelNavigator = null;

    if (route != null && navigator != null && route.isActive) {
      navigator.removeRoute(route);
    }
  }

  void _invalidateCommands({bool notify = true}) {
    _commandGeneration++;
    _commandQueue = Future<void>.value();
    _pendingCommands = 0;
    _commandError = null;

    if (notify && mounted) {
      _commandRevision.value++;
      setState(() {});
    }
  }

  void _loadDocument() {
    final generation = ++_loadGeneration;
    unawaited(
      _controller
          .load(
            widget.document,
            initialLocator: widget.initialLocator,
            preferences: _initialPreferences(),
          )
          .catchError((Object error, StackTrace stackTrace) {
            if (!mounted || generation != _loadGeneration) {
              return;
            }
          }),
    );
  }

  ReaderPreferences _initialPreferences() {
    final provided = widget.initialPreferences;
    if (provided != null) {
      return provided;
    }
    if (!_ownsController) {
      return _controller.preferences;
    }

    final theme = Theme.of(context);
    return ReaderPreferences(
      backgroundColor: theme.colorScheme.surface,
      foregroundColor: theme.colorScheme.onSurface,
      brightness: theme.brightness,
    );
  }

  void _controllerChanged() {
    if (!mounted) {
      return;
    }

    final previous = _observedSnapshot;
    final next = _controller.snapshot;
    _observedSnapshot = next;
    _dragProgress = null;

    if (next.locator != null && next.locator != previous?.locator) {
      _invokeHostCallback(
        () => widget.onLocatorChanged?.call(next.locator!),
        'onLocatorChanged',
      );
    }
    if (next.preferences != previous?.preferences) {
      _invokeHostCallback(
        () => widget.onPreferencesChanged?.call(next.preferences),
        'onPreferencesChanged',
      );
    }

    setState(() {});
  }

  void _invokeHostCallback(VoidCallback callback, String name) {
    try {
      callback();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'papyrus_reader',
          context: ErrorDescription('while invoking PapyrusReader.$name'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _dismissCompactPanel();
    _invalidateCommands(notify: false);
    _detachController();
    _tocButtonFocusNode.dispose();
    _settingsButtonFocusNode.dispose();
    _widePanelFocusNode.dispose();
    _commandRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ?? ReaderThemeData.fromTheme(Theme.of(context));
    final snapshot = _controller.snapshot;

    return Material(
      color: theme.surfaceColor,
      child: SafeArea(
        child: switch (snapshot.status) {
          ReaderStatus.idle => _buildEmpty(context, snapshot, theme),
          ReaderStatus.loading => _buildLoading(context, snapshot, theme),
          ReaderStatus.error => _buildError(context, snapshot, theme),
          ReaderStatus.ready => _buildReady(context, snapshot, theme),
        },
      ),
    );
  }

  ReaderStateContext _stateContext(ReaderSnapshot snapshot) {
    return ReaderStateContext(
      document: widget.document,
      snapshot: snapshot,
      controller: _controller,
      retry: _loadDocument,
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    ReaderSnapshot snapshot,
    ReaderThemeData theme,
  ) {
    final builder = widget.builders.empty;
    if (builder != null) {
      return builder(context, _stateContext(snapshot));
    }

    return Center(
      child: Padding(
        padding: EdgeInsets.all(theme.panelPadding),
        child: const Text('Choose a document to begin reading.'),
      ),
    );
  }

  Widget _buildLoading(
    BuildContext context,
    ReaderSnapshot snapshot,
    ReaderThemeData theme,
  ) {
    final builder = widget.builders.loading;
    if (builder != null) {
      return builder(context, _stateContext(snapshot));
    }

    final title = widget.document.title?.trim();
    return Center(
      child: Padding(
        padding: EdgeInsets.all(theme.panelPadding * 2),
        child: Semantics(
          liveRegion: true,
          label: 'Opening document',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: theme.accentColor),
              const SizedBox(height: 20),
              Text(
                title == null || title.isEmpty
                    ? 'Opening document…'
                    : 'Opening $title…',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(
    BuildContext context,
    ReaderSnapshot snapshot,
    ReaderThemeData theme,
  ) {
    final builder = widget.builders.error;
    if (builder != null) {
      return builder(context, _stateContext(snapshot));
    }

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(theme.panelPadding * 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                color: theme.errorColor,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                'Couldn’t open this document',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                snapshot.error?.message ??
                    'An unexpected reader error occurred.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _loadDocument,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReady(
    BuildContext context,
    ReaderSnapshot snapshot,
    ReaderThemeData theme,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= theme.compactBreakpoint;
        final toolbar = widget.builders.toolbar?.call(
          context,
          ReaderToolbarContext(
            document: widget.document,
            snapshot: snapshot,
            onBack: widget.onBack,
            isBusy: _isCommandBusy,
            openTableOfContents: () => _openPanel(
              context,
              _ReaderPanel.tableOfContents,
              isWide,
              theme,
            ),
            openSettings: () =>
                _openPanel(context, _ReaderPanel.settings, isWide, theme),
          ),
        );

        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): _goPrevious,
            const SingleActivator(LogicalKeyboardKey.pageUp): _goPrevious,
            const SingleActivator(LogicalKeyboardKey.arrowRight): _goNext,
            const SingleActivator(LogicalKeyboardKey.pageDown): _goNext,
          },
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Focus(
              autofocus: true,
              child: Column(
                children: [
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child:
                        toolbar ??
                        _DefaultReaderToolbar(
                          document: widget.document,
                          onBack: widget.onBack,
                          onTableOfContents: () => _openPanel(
                            context,
                            _ReaderPanel.tableOfContents,
                            isWide,
                            theme,
                          ),
                          onSettings: () => _openPanel(
                            context,
                            _ReaderPanel.settings,
                            isWide,
                            theme,
                          ),
                          tocFocusNode: _tocButtonFocusNode,
                          settingsFocusNode: _settingsButtonFocusNode,
                          theme: theme,
                          isWide: isWide,
                        ),
                  ),
                  if (_isCommandBusy)
                    const LinearProgressIndicator(
                      key: ValueKey('reader-command-progress'),
                      minHeight: 2,
                    ),
                  if (_commandError case final error?)
                    _ReaderCommandError(
                      message: error,
                      theme: theme,
                      onDismiss: () => setState(() => _commandError = null),
                    ),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: FocusTraversalOrder(
                            order: const NumericFocusOrder(3),
                            child: _buildViewport(context, snapshot),
                          ),
                        ),
                        if (isWide) ...[
                          VerticalDivider(width: 1, color: theme.dividerColor),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(2),
                            child: SizedBox(
                              key: const ValueKey('reader-side-panel'),
                              width: theme.sidePanelWidth,
                              child: ColoredBox(
                                color: theme.panelColor,
                                child: _buildWidePanel(
                                  context,
                                  snapshot,
                                  theme,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(4),
                    child: _ReaderProgressControls(
                      progress: _dragProgress ?? _progressOf(snapshot.locator),
                      onProgressChanged: (value) {
                        setState(() => _dragProgress = value);
                      },
                      onProgressChangeEnd: _goToProgress,
                      onPrevious: _goPrevious,
                      onNext: _goNext,
                      enabled: !_isCommandBusy,
                      theme: theme,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewport(BuildContext context, ReaderSnapshot snapshot) {
    final viewport = _controller.buildViewport(context);
    final builder = widget.builders.viewport;

    return builder?.call(
          context,
          ReaderViewportContext(
            snapshot: snapshot,
            controller: _controller,
            viewport: viewport,
          ),
        ) ??
        viewport;
  }

  Widget _buildWidePanel(
    BuildContext context,
    ReaderSnapshot snapshot,
    ReaderThemeData theme,
  ) {
    if (_panel == _ReaderPanel.none) {
      return const SizedBox.expand();
    }

    return Focus(
      key: const ValueKey('reader-wide-panel-focus'),
      focusNode: _widePanelFocusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _closeWidePanel();
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: _panelWidget(context, snapshot, _panel, theme, _closeWidePanel),
    );
  }

  void _closeWidePanel() {
    if (_panel == _ReaderPanel.none) {
      return;
    }

    final opener = _widePanelOpener;
    setState(() => _panel = _ReaderPanel.none);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && opener?.canRequestFocus == true) {
        opener!.requestFocus();
      }
    });
  }

  void _openPanel(
    BuildContext context,
    _ReaderPanel panel,
    bool isWide,
    ReaderThemeData theme,
  ) {
    if (isWide) {
      if (_panel == panel) {
        _closeWidePanel();
        return;
      }

      _widePanelOpener =
          FocusManager.instance.primaryFocus ??
          (panel == _ReaderPanel.tableOfContents
              ? _tocButtonFocusNode
              : _settingsButtonFocusNode);
      setState(() => _panel = panel);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panel == panel) {
          _widePanelFocusNode.requestFocus();
        }
      });
      return;
    }

    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    late final ModalBottomSheetRoute<void> route;
    route = ModalBottomSheetRoute<void>(
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxWidth: theme.compactBreakpoint,
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      builder: (sheetContext) {
        Widget buildPanel() {
          return _panelWidget(
            sheetContext,
            _controller.snapshot,
            panel,
            theme,
            () => Navigator.of(sheetContext).pop(),
          );
        }

        return ListenableBuilder(
          listenable: Listenable.merge([_controller, _commandRevision]),
          builder: (context, child) => buildPanel(),
        );
      },
    );
    _compactPanelRoute = route;
    _compactPanelNavigator = navigator;
    final sheet = navigator.push(route);
    unawaited(
      sheet.then<void>(
        (_) {
          if (identical(_compactPanelRoute, route)) {
            _compactPanelRoute = null;
            _compactPanelNavigator = null;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_compactPanelRoute, route)) {
            _compactPanelRoute = null;
            _compactPanelNavigator = null;
          }
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'papyrus_reader',
              context: ErrorDescription('while closing a reader panel'),
            ),
          );
        },
      ),
    );
  }

  Widget _panelWidget(
    BuildContext context,
    ReaderSnapshot snapshot,
    _ReaderPanel panel,
    ReaderThemeData theme,
    VoidCallback close,
  ) {
    final state = ReaderPanelContext(
      snapshot: snapshot,
      controller: _controller,
      close: close,
      isBusy: _isCommandBusy,
    );

    return switch (panel) {
      _ReaderPanel.tableOfContents =>
        widget.builders.tableOfContents?.call(context, state) ??
            _TableOfContentsPanel(
              snapshot: snapshot,
              close: close,
              theme: theme,
              enabled: !_isCommandBusy,
              onNavigate: (locator) {
                close();
                _enqueueCommand(
                  (controller) => controller.goTo(locator),
                  context: 'while navigating from the table of contents',
                );
              },
            ),
      _ReaderPanel.settings =>
        widget.builders.settings?.call(context, state) ??
            _ReaderSettingsPanel(
              snapshot: snapshot,
              close: close,
              theme: theme,
              enabled: !_isCommandBusy,
              isBusy: _isCommandBusy,
              commandRevision: _commandRevision.value,
              onUpdatePreferences: (preferences) => _enqueueCommand(
                (controller) => controller.updatePreferences(preferences),
                context: 'while updating reader preferences',
              ),
            ),
      _ReaderPanel.none => const SizedBox.shrink(),
    };
  }

  void _goToProgress(double progress) {
    setState(() => _dragProgress = progress);
    _enqueueCommand(
      (controller) => controller.goToProgress(progress),
      context: 'while changing reader progress',
    );
  }

  void _goPrevious() {
    _enqueueCommand(
      (controller) => controller.goPrevious(),
      expectedBoundary: true,
      context: 'while moving to the previous section',
    );
  }

  void _goNext() {
    _enqueueCommand(
      (controller) => controller.goNext(),
      expectedBoundary: true,
      context: 'while moving to the next section',
    );
  }

  void _enqueueCommand(
    Future<void> Function(ReaderController controller) operation, {
    required String context,
    bool expectedBoundary = false,
  }) {
    if (!mounted) {
      return;
    }

    final generation = _commandGeneration;
    final controller = _controller;
    _pendingCommands++;
    _commandError = null;
    _commandRevision.value++;
    setState(() {});

    final scheduled = _commandQueue.then((_) async {
      if (!mounted || generation != _commandGeneration) {
        return;
      }

      try {
        await operation(controller);
      } catch (error, stackTrace) {
        if (!mounted || generation != _commandGeneration) {
          return;
        }
        if (expectedBoundary &&
            error is ReaderException &&
            error.code == ReaderErrorCode.navigationBoundary) {
          return;
        }

        _handleCommandError(error, stackTrace, context);
      }
    });
    _commandQueue = scheduled.whenComplete(() {
      if (!mounted || generation != _commandGeneration) {
        return;
      }

      _pendingCommands = math.max(0, _pendingCommands - 1);
      _commandRevision.value++;
      setState(() {});
    });
  }

  void _handleCommandError(
    Object error,
    StackTrace stackTrace,
    String operationContext,
  ) {
    _commandError = error is ReaderException
        ? error.message
        : 'The reader action could not be completed.';
    _commandRevision.value++;
    setState(() {});

    if (error is! ReaderException) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'papyrus_reader',
          context: ErrorDescription(operationContext),
        ),
      );
    }
  }
}

final class _ReaderCommandError extends StatelessWidget {
  const _ReaderCommandError({
    required this.message,
    required this.theme,
    required this.onDismiss,
  });

  final String message;
  final ReaderThemeData theme;
  final VoidCallback onDismiss;

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

final class _DefaultReaderToolbar extends StatelessWidget {
  const _DefaultReaderToolbar({
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
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final height = math.max(
      isWide ? theme.wideToolbarHeight : theme.compactToolbarHeight,
      theme.minimumTargetSize + math.max(8, (textScale - 1) * 12),
    );

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: theme.chromeColor,
      child: IconTheme(
        data: IconThemeData(color: theme.onChromeColor),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.onChromeColor),
          child: Row(
            children: [
              if (onBack != null)
                _ReaderIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onPressed: onBack!,
                  theme: theme,
                ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  document.title?.trim().isNotEmpty == true
                      ? document.title!.trim()
                      : 'Reader',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: theme.onChromeColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _ReaderIconButton(
                key: const ValueKey('reader-toc-button'),
                focusNode: tocFocusNode,
                icon: Icons.format_list_bulleted_rounded,
                tooltip: 'Table of contents',
                onPressed: onTableOfContents,
                theme: theme,
              ),
              _ReaderIconButton(
                key: const ValueKey('reader-settings-button'),
                focusNode: settingsFocusNode,
                icon: Icons.text_fields_rounded,
                tooltip: 'Reading settings',
                onPressed: onSettings,
                theme: theme,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ReaderIconButton extends StatelessWidget {
  const _ReaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.theme,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String tooltip;
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

final class _ReaderProgressControls extends StatelessWidget {
  const _ReaderProgressControls({
    required this.progress,
    required this.onProgressChanged,
    required this.onProgressChangeEnd,
    required this.onPrevious,
    required this.onNext,
    required this.enabled,
    required this.theme,
  });

  final double progress;
  final ValueChanged<double> onProgressChanged;
  final ValueChanged<double> onProgressChangeEnd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool enabled;
  final ReaderThemeData theme;

  @override
  Widget build(BuildContext context) {
    final normalized = progress.clamp(0.0, 1.0);
    final percent = (normalized * 100).round();

    return ColoredBox(
      color: theme.chromeColor,
      child: IconTheme(
        data: IconThemeData(color: theme.onChromeColor),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.onChromeColor),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                _ReaderIconButton(
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
                _ReaderIconButton(
                  icon: Icons.chevron_right_rounded,
                  tooltip: 'Next',
                  onPressed: enabled ? onNext : null,
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

final class _TableOfContentsPanel extends StatelessWidget {
  const _TableOfContentsPanel({
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
        _PanelHeader(title: 'Contents', close: close, theme: theme),
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

final class _ReaderSettingsPanel extends StatelessWidget {
  const _ReaderSettingsPanel({
    required this.snapshot,
    required this.close,
    required this.theme,
    required this.enabled,
    required this.isBusy,
    required this.commandRevision,
    required this.onUpdatePreferences,
  });

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

    return Column(
      children: [
        _PanelHeader(title: 'Reading settings', close: close, theme: theme),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(theme.panelPadding),
            children: [
              if (capabilities.supportsTextCustomization) ...[
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
                const Divider(),
              ],
              if (capabilities.supportsPagination ||
                  capabilities.supportsScrolling) ...[
                DropdownButtonFormField<ReaderLayoutMode>(
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
              Text(
                'Page appearance',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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
                    selected:
                        preferences.backgroundColor == const Color(0xfff4ecd8),
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
          ),
        ),
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
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      avatar: CircleAvatar(backgroundColor: background),
      onSelected: enabled
          ? (_) => onSelected(background, foreground, brightness)
          : null,
    );
  }
}

final class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
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
                _ReaderIconButton(
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

double _progressOf(ReaderLocator? locator) {
  return switch (locator) {
    EpubReaderLocator(:final totalProgression) => totalProgression,
    PdfReaderLocator(:final totalProgression) => totalProgression,
    null => 0,
  };
}
