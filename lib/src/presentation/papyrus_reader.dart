import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
  final FocusNode _controlsToggleFocusNode = FocusNode(
    debugLabel: 'reader controls toggle',
  );

  bool get _isCommandBusy => _pendingCommands > 0;

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
    if (!_controlsVisible)
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
    _reportActivity();
  }

  void _reportActivity() {
    if (!mounted) return;
    final snapshot = _controller.snapshot;
    _invokeHostCallback(
      () => widget.onActivity?.call(
        ReaderActivityEvent(
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
        ),
      ),
      'onActivity',
    );
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
    HardwareKeyboard.instance.removeHandler(_handleUnfocusedReadingKey);
    _readerFocusNode.dispose();
    _controlsToggleFocusNode.dispose();
    _commandRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportActivity());
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
          color: theme.surfaceColor,
          child: SafeArea(
            child: switch (snapshot.status) {
              ReaderStatus.idle => _buildEmpty(context, snapshot, theme),
              ReaderStatus.loading => _stateChrome(
                _buildLoading(context, snapshot, theme),
                theme,
              ),
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
    final focus = _controlsVisible && widget.builders.toolbar == null
        ? _controlsToggleFocusNode
        : _readerFocusNode;
    focus.requestFocus();
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
                  Column(
                    children: [
                      if (_controlsVisible)
                        FocusTraversalOrder(
                          key: const ValueKey('reader-toolbar'),
                          order: const NumericFocusOrder(1),
                          child:
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
                        ),
                      if (_controlsVisible)
                        SizedBox(
                          key: const ValueKey('reader-toolbar-border'),
                          height: 1,
                          child: _isCommandBusy
                              ? const LinearProgressIndicator(
                                  key: ValueKey('reader-command-progress'),
                                  minHeight: 1,
                                )
                              : ColoredBox(color: theme.dividerColor),
                        ),
                      if (_commandError case final error?)
                        ReaderCommandError(
                          message: error,
                          theme: theme,
                          onDismiss: () => setState(() => _commandError = null),
                        ),
                      Expanded(
                        key: const ValueKey('reader-content'),
                        child: Row(
                          children: [
                            Expanded(
                              child: FocusTraversalOrder(
                                order: const NumericFocusOrder(3),
                                child: _buildViewport(context, snapshot),
                              ),
                            ),
                            if (isWide && _panel != _ReaderPanel.none) ...[
                              VerticalDivider(
                                width: 1,
                                color: theme.dividerColor,
                              ),
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
                      if (_controlsVisible)
                        FocusTraversalOrder(
                          key: const ValueKey('reader-progress-controls'),
                          order: const NumericFocusOrder(4),
                          child: ReaderProgressControls(
                            progress:
                                _dragProgress ?? _progressOf(snapshot.locator),
                            locationLabel: snapshot.locationLabel,
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
                  if (toolbar == null || !_controlsVisible)
                    PositionedDirectional(
                      key: const ValueKey('reader-controls-toggle'),
                      top: _controlsVisible
                          ? (readerToolbarHeight(context, theme, isWide) -
                                    theme.minimumTargetSize) /
                                2
                          : 8,
                      end: 8,
                      child: ListenableBuilder(
                        listenable: _controlsToggleFocusNode,
                        builder: (context, _) {
                          final label = _controlsVisible
                              ? 'Hide controls'
                              : 'Show controls';
                          return Semantics(
                            container: true,
                            button: true,
                            label: label,
                            focusable: true,
                            focused: _controlsToggleFocusNode.hasFocus,
                            onTap: _toggleControls,
                            onDidGainAccessibilityFocus:
                                _controlsToggleFocusNode.requestFocus,
                            excludeSemantics: true,
                            child: Tooltip(
                              message: label,
                              excludeFromSemantics: true,
                              child: Material(
                                color: _controlsVisible
                                    ? Colors.transparent
                                    : theme.chromeColor,
                                shape: const CircleBorder(),
                                child: IconTheme(
                                  data: IconThemeData(
                                    color: theme.onChromeColor,
                                  ),
                                  child: ReaderIconButton(
                                    icon: _controlsVisible
                                        ? Icons.fullscreen_rounded
                                        : Icons.fullscreen_exit_rounded,
                                    tooltip: null,
                                    focusNode: _controlsToggleFocusNode,
                                    onPressed: _toggleControls,
                                    theme: theme,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
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
              builder: (context) => ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                child: ColoredBox(
                  color: panelTheme.panelColor,
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
            ReaderContentsPanel(
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
