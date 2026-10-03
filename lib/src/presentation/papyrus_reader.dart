import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import 'reader_material_theme.dart';
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
            child: _ReaderIconButton(
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
                        _ReaderCommandError(
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
                          child: _ReaderProgressControls(
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
                          ? (_readerToolbarHeight(context, theme, isWide) -
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
                                  child: _ReaderIconButton(
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

double _readerToolbarHeight(
  BuildContext context,
  ReaderThemeData theme,
  bool isWide,
) {
  final textScale = MediaQuery.textScalerOf(context).scale(1);
  return math.max(
    isWide ? theme.wideToolbarHeight : theme.compactToolbarHeight,
    theme.minimumTargetSize + math.max(8, (textScale - 1) * 12),
  );
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
    final height = _readerToolbarHeight(context, theme, isWide);

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
              // The controls toggle stays mounted in the shell overlay during
              // reflow, preserving browser accessibility and keyboard focus.
              SizedBox(width: theme.minimumTargetSize),
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
  final String? tooltip;
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
    this.locationLabel,
  });

  final double progress;
  final ValueChanged<double> onProgressChanged;
  final ValueChanged<double> onProgressChangeEnd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool enabled;
  final ReaderThemeData theme;
  final String? locationLabel;

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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (locationLabel != null)
                  Text(
                    locationLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: theme.onChromeColor,
                    ),
                  ),
                Row(
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
                    DropdownMenuItem(
                      value: 'sans-serif',
                      child: Text('Sans serif'),
                    ),
                    DropdownMenuItem(
                      value: 'monospace',
                      child: Text('Monospace'),
                    ),
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
