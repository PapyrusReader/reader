import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../controller/reader_controller.dart';
import '../domain/reader_document.dart';
import '../domain/reader_activity.dart';
import '../domain/reader_exception.dart';
import '../domain/reader_locator.dart';
import '../domain/reader_preferences.dart';
import '../domain/reader_snapshot.dart';
import '../domain/reader_types.dart';
import '../engine/reader_engine_registry.dart';
import 'reader_material_theme.dart';
import 'reader_controls.dart';
import 'reader_surface.dart';
import 'reader_contents_panel.dart';
import 'reader_settings_panel.dart';
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
    this.onActivity,
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
  final ValueChanged<ReaderActivityEvent>? onActivity;
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
  bool _controlsVisible = true;
  double? _dragProgress;
  int _loadGeneration = 0;
  bool _loadedDependencies = false;
  Future<void> _commandQueue = Future<void>.value();
  int _commandGeneration = 0;
  int _pendingCommands = 0;
  String? _commandError;
  VoidCallback? _retryCommand;
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
  final FocusNode _readerFocusNode = FocusNode(debugLabel: 'reader navigation');

  ReaderActivityEvent? _lastActivity;
  bool _activityReportScheduled = false;

  bool get _isCommandBusy => _pendingCommands > 0;
  Timer? _busyTimer;
  bool _showBusy = false;

  @override
  void initState() {
    super.initState();
    _attachController();
    HardwareKeyboard.instance.addHandler(_handleUnfocusedReadingKey);
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
      _controlsVisible = true;
      _dragProgress = null;
      _loadDocument();
    }
  }

  Map<ShortcutActivator, VoidCallback> get _keyBindings => {
    const SingleActivator(LogicalKeyboardKey.escape): _toggleControls,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): _goPrevious,
    const SingleActivator(LogicalKeyboardKey.pageUp): _goPrevious,
    const SingleActivator(LogicalKeyboardKey.arrowRight): _goNext,
    const SingleActivator(LogicalKeyboardKey.pageDown): _goNext,
    const SingleActivator(LogicalKeyboardKey.space): _goNext,
    const SingleActivator(LogicalKeyboardKey.space, shift: true): _goPrevious,
  };

  bool _handleUnfocusedReadingKey(KeyEvent event) {
    // Browser accessibility can park focus on a scope when chrome disappears.
    // Only the active reader in focus mode may recover keys from that scope;
    // focused inputs, other routes and normal reader shortcuts retain control.
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (!mounted ||
        _controlsVisible ||
        _readerFocusNode.hasFocus ||
        _controller.snapshot.status != ReaderStatus.ready ||
        _compactPanelRoute != null ||
        _panel != _ReaderPanel.none ||
        ModalRoute.of(context)?.isCurrent != true ||
        (primaryFocus != null && primaryFocus is! FocusScopeNode)) {
      return false;
    }
    for (final entry in _keyBindings.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        _readerFocusNode.requestFocus();
        entry.value();
        return true;
      }
    }
    return false;
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
    _busyTimer?.cancel();
    _showBusy = false;
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

    if (next.contentReady) {
      _dragProgress = null;
    }

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
    _reportActivity();
  }

  void _scheduleActivityReport() {
    if (_activityReportScheduled) return;
    _activityReportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activityReportScheduled = false;
      _reportActivity();
    });
  }

  void _reportActivity() {
    if (!mounted) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _scheduleActivityReport();
      return;
    }
    final snapshot = _controller.snapshot;
    final event = ReaderActivityEvent(
      ready: snapshot.contentReady,
      visible:
          snapshot.contentReady &&
          _panel == _ReaderPanel.none &&
          _compactPanelRoute == null &&
          (ModalRoute.of(context)?.isCurrent ?? true),
      cause: _controller.navigationCause,
      locator: snapshot.locator,
      coverage: snapshot.coverage,
      atEnd: snapshot.atEnd,
    );
    if (event == _lastActivity || widget.onActivity == null) return;
    _lastActivity = event;
    _invokeHostCallback(() => widget.onActivity!(event), 'onActivity');
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
    _busyTimer?.cancel();
    _dismissCompactPanel();
    _invalidateCommands(notify: false);
    _detachController();
    _tocButtonFocusNode.dispose();
    _settingsButtonFocusNode.dispose();
    _widePanelFocusNode.dispose();
    HardwareKeyboard.instance.removeHandler(_handleUnfocusedReadingKey);
    _readerFocusNode.dispose();
    _commandRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleActivityReport();
    final snapshot = _controller.snapshot;
    final ambient = Theme.of(context);
    final readerTheme = snapshot.status == ReaderStatus.ready
        ? buildReaderMaterialTheme(ambient, snapshot.preferences.brightness)
        : ambient;
    final theme = widget.theme ?? ReaderThemeData.fromTheme(readerTheme);
    return Theme(
      data: readerTheme,
      child: Builder(
        builder: (context) => Material(
          color: snapshot.status == ReaderStatus.ready
              ? snapshot.preferences.backgroundColor
              : theme.surfaceColor,
          child: SafeArea(
            child: switch (snapshot.status) {
              ReaderStatus.idle => _buildEmpty(context, snapshot, theme),
              ReaderStatus.loading => _buildLoading(context, snapshot, theme),
              ReaderStatus.error => _stateChrome(
                _buildError(context, snapshot, theme),
                theme,
              ),
              ReaderStatus.ready => _buildReady(context, snapshot, theme),
            },
          ),
        ),
      ),
    );
  }

  Widget _stateChrome(Widget child, ReaderThemeData theme) {
    return Column(
      children: [
        if (widget.onBack != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ReaderIconButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              onPressed: widget.onBack,
              theme: theme,
            ),
          ),
        Expanded(child: child),
      ],
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

    return Center(
      child: CircularProgressIndicator(
        color: theme.accentColor,
        semanticsLabel: 'Opening document',
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

  void _toggleControls() {
    _dismissCompactPanel();
    setState(() {
      _controlsVisible = !_controlsVisible;
      _panel = _ReaderPanel.none;
      _widePanelOpener = null;
    });
    unawaited(_restoreControlsFocus());
  }

  Future<void> _restoreControlsFocus() async {
    // Wait for the chrome and its browser semantics to finish reflowing before
    // restoring the view focus that removal of the toolbar can blur.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _controller.snapshot.status != ReaderStatus.ready) return;
    WidgetsBinding.instance.platformDispatcher.requestViewFocusChange(
      viewId: View.of(context).viewId,
      state: ui.ViewFocusState.focused,
      direction: ui.ViewFocusDirection.undefined,
    );
    _readerFocusNode.requestFocus();
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
            toggleControls: _toggleControls,
            controlsVisible: _controlsVisible,
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
          bindings: _keyBindings,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Focus(
              focusNode: _readerFocusNode,
              // Engines and controls own the accessible reading content.
              includeSemantics: false,
              autofocus: true,
              child: Stack(
                children: [
                  Positioned.fill(
                    key: const ValueKey('reader-content'),
                    child: FocusTraversalOrder(
                      order: const NumericFocusOrder(3),
                      child: _readingSurface(context, snapshot, isWide),
                    ),
                  ),
                  PositionedDirectional(
                    top: 0,
                    start: 0,
                    end: 0,
                    child: _chromeVisibility(
                      child: FocusTraversalOrder(
                        key: const ValueKey('reader-toolbar'),
                        order: const NumericFocusOrder(1),
                        child: _overlayBar(
                          theme,
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              toolbar ??
                                  ReaderToolbar(
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
                              if (_showBusy)
                                const LinearProgressIndicator(
                                  key: ValueKey('reader-command-progress'),
                                  minHeight: 2,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    bottom: 0,
                    start: 0,
                    end: 0,
                    child: _chromeVisibility(
                      child: _overlayBar(
                        theme,
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1000),
                            child: FocusTraversalOrder(
                              key: const ValueKey('reader-progress-controls'),
                              order: const NumericFocusOrder(4),
                              child: ReaderProgressControls(
                                progress:
                                    _dragProgress ??
                                    _progressOf(snapshot.locator),
                                locationLabel: snapshot.locationLabel,
                                onProgressChanged: (value) =>
                                    setState(() => _dragProgress = value),
                                onProgressChangeEnd: _goToProgress,
                                onPrevious: _goPrevious,
                                onNext: _goNext,
                                enabled: true,
                                theme: theme,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isWide && _panel != _ReaderPanel.none) ...[
                    Positioned.fill(
                      top: readerToolbarHeight(context, theme, isWide),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeWidePanel,
                        child: const ColoredBox(color: Colors.transparent),
                      ),
                    ),
                    PositionedDirectional(
                      top: readerToolbarHeight(context, theme, isWide),
                      bottom: 0,
                      end: 0,
                      width: theme.sidePanelWidth,
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: _overlayBar(
                          theme,
                          ColoredBox(
                            key: const ValueKey('reader-side-panel'),
                            color: theme.panelColor,
                            child: DecoratedBox(
                              position: DecorationPosition.foreground,
                              decoration: BoxDecoration(
                                border: BorderDirectional(
                                  start: BorderSide(color: theme.dividerColor),
                                  top: BorderSide(color: theme.dividerColor),
                                ),
                              ),
                              child: _buildWidePanel(context, snapshot, theme),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (_commandError case final error?)
                    PositionedDirectional(
                      bottom: 80,
                      start: 8,
                      end: 8,
                      child: ReaderCommandError(
                        message: error,
                        theme: theme,
                        onRetry: _retryCommand,
                        onDismiss: () => setState(() => _commandError = null),
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

  Widget _chromeVisibility({required Widget child}) => Visibility(
    visible: _controlsVisible,
    maintainState: true,
    maintainAnimation: true,
    child: child,
  );

  Widget _overlayBar(ReaderThemeData theme, Widget child) =>
      Material(color: theme.chromeColor, elevation: 0, child: child);

  Widget _readingSurface(
    BuildContext context,
    ReaderSnapshot snapshot,
    bool isWide,
  ) {
    return Semantics(
      key: const ValueKey('reader-surface-actions'),
      container: true,
      customSemanticsActions: {
        CustomSemanticsAction(
          label: _controlsVisible
              ? 'Hide reading controls'
              : 'Show reading controls',
        ): _toggleControls,
      },
      child: ReaderSurface(
        enabled: _panel == _ReaderPanel.none && _compactPanelRoute == null,
        onToggle: _toggleControls,
        onTurn: (direction) => direction > 0 ? _goNext() : _goPrevious(),
        child: _buildViewport(context, snapshot),
      ),
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

      _widePanelOpener = widget.builders.toolbar != null
          ? FocusManager.instance.primaryFocus
          : (panel == _ReaderPanel.tableOfContents
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
    final customRoute = widget.builders.compactPanelRoute;
    late final Route<void> route;
    route = customRoute != null
        ? customRoute(
            context,
            ReaderPanelRouteContext(
              kind: panel == _ReaderPanel.settings
                  ? ReaderPanelKind.settings
                  : ReaderPanelKind.tableOfContents,
              title: panel == _ReaderPanel.settings
                  ? 'Reading settings'
                  : 'Contents',
              buildContent: (context, scrollController) => ListenableBuilder(
                listenable: Listenable.merge([_controller, _commandRevision]),
                builder: (context, child) => _panelWidget(
                  context,
                  _controller.snapshot,
                  panel,
                  ReaderThemeData.fromTheme(Theme.of(context)),
                  () {
                    if (route.isCurrent) navigator.pop();
                  },
                  showHeader: false,
                  scrollController: scrollController,
                ),
              ),
            ),
          )
        : ModalBottomSheetRoute<void>(
            capturedThemes: InheritedTheme.capture(
              from: context,
              to: navigator.context,
            ),
            barrierLabel: localizations.scrimLabel,
            barrierOnTapHint: localizations.scrimOnTapHint(
              localizations.bottomSheetLabel,
            ),
            modalBarrierColor: Theme.of(
              context,
            ).bottomSheetTheme.modalBarrierColor,
            useSafeArea: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            showDragHandle: false,
            constraints: BoxConstraints(
              maxWidth: theme.compactBreakpoint,
              maxHeight: math.max(
                160,
                (MediaQuery.sizeOf(context).height -
                        MediaQuery.viewInsetsOf(context).bottom) *
                    0.88,
              ),
            ),
            builder: (sheetContext) {
              Widget buildPanel() {
                // Captured route themes are a snapshot. Appearance can change while
                // this sheet is open, so use the current reader theme on every update.
                final preferences = _controller.preferences;
                final currentTheme = buildReaderMaterialTheme(
                  Theme.of(this.context),
                  preferences.brightness,
                );
                final colors = currentTheme.colorScheme;
                final panelTheme =
                    widget.theme ?? ReaderThemeData.fromTheme(currentTheme);
                return Theme(
                  data: currentTheme,
                  child: Builder(
                    builder: (context) => Material(
                      color: panelTheme.panelColor,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28),
                        ),
                        side: BorderSide(color: panelTheme.dividerColor),
                      ),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 32,
                            child: Center(
                              child: Container(
                                width: 32,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: colors.onSurfaceVariant,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _panelWidget(
                              context,
                              _controller.snapshot,
                              panel,
                              panelTheme,
                              () => Navigator.of(sheetContext).pop(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
    _reportActivity();
    final sheet = navigator.push(route);
    unawaited(
      sheet.then<void>(
        (_) {
          if (identical(_compactPanelRoute, route)) {
            _compactPanelRoute = null;
            _compactPanelNavigator = null;
            _reportActivity();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_compactPanelRoute, route)) {
            _compactPanelRoute = null;
            _compactPanelNavigator = null;
            _reportActivity();
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
    VoidCallback close, {
    bool showHeader = true,
    ScrollController? scrollController,
  }) {
    final state = ReaderPanelContext(
      snapshot: snapshot,
      controller: _controller,
      close: close,
      isBusy: _isCommandBusy,
    );

    return switch (panel) {
      _ReaderPanel.tableOfContents =>
        widget.builders.tableOfContents?.call(context, state) ??
            ReaderContentsPanel(
              showHeader: showHeader,
              scrollController: scrollController,
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
            ReaderSettingsPanel(
              showHeader: showHeader,
              scrollController: scrollController,
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
    final restoreReadingFocus =
        _readerFocusNode.hasFocus &&
        _panel == _ReaderPanel.none &&
        _compactPanelRoute == null;
    if (_pendingCommands == 0) {
      _busyTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && _isCommandBusy) {
          setState(() => _showBusy = true);
        }
      });
    }

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

        _retryCommand = () => _enqueueCommand(
          operation,
          context: context,
          expectedBoundary: expectedBoundary,
        );
        _handleCommandError(error, stackTrace, context);
      }
    });
    _commandQueue = scheduled.whenComplete(() {
      if (!mounted || generation != _commandGeneration) {
        return;
      }

      _pendingCommands = math.max(0, _pendingCommands - 1);

      if (!_isCommandBusy) {
        _busyTimer?.cancel();
        _showBusy = false;
      }
      _commandRevision.value++;
      setState(() {});
      if (restoreReadingFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              generation == _commandGeneration &&
              _panel == _ReaderPanel.none &&
              _compactPanelRoute == null) {
            _readerFocusNode.requestFocus();
          }
        });
      }
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

double _progressOf(ReaderLocator? locator) {
  return switch (locator) {
    EpubReaderLocator(:final totalProgression) => totalProgression,
    PdfReaderLocator(:final totalProgression) => totalProgression,
    null => 0,
  };
}
