import 'package:flutter/widgets.dart';

import '../domain/reader_document.dart';
import '../domain/reader_activity.dart';
import '../domain/reader_exception.dart';
import '../domain/reader_locator.dart';
import '../domain/reader_preferences.dart';
import '../domain/reader_snapshot.dart';
import '../domain/reader_types.dart';
import '../engine/reader_engine.dart';
import '../engine/reader_engine_registry.dart';

typedef ReaderLocatorChanged = void Function(ReaderLocator locator);
typedef ReaderPreferencesChanged = void Function(ReaderPreferences preferences);

final class ReaderController extends ChangeNotifier {
  ReaderController({
    required ReaderEngineRegistry registry,
    ReaderPreferences initialPreferences = const ReaderPreferences(),
    this.onLocatorChanged,
    this.onPreferencesChanged,
  }) : _registry = registry,
       _snapshot = ReaderIdleSnapshot(preferences: initialPreferences);

  final ReaderEngineRegistry _registry;
  final ReaderLocatorChanged? onLocatorChanged;
  final ReaderPreferencesChanged? onPreferencesChanged;

  ReaderEngine? _engine;
  ReaderSnapshot _snapshot;
  final Set<ReaderEngine> _loadingEngines = {};
  int _latestLoadId = 0;
  bool _isDisposed = false;

  ReaderSnapshot get snapshot => _snapshot;
  ({Object token, ReaderNavigationCause cause})? _navigationCommand;
  ReaderNavigationCause navigationCause = ReaderNavigationCause.restore;

  ReaderPreferences get preferences => _snapshot.preferences;

  Widget buildViewport(BuildContext context) {
    return _requireReadyEngine().buildViewport(context);
  }

  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    ReaderPreferences? preferences,
  }) {
    if (_isDisposed) {
      return Future<void>.error(
        const ReaderException(
          ReaderErrorCode.engineUnavailable,
          'The reader controller has been disposed.',
        ),
      );
    }

    for (final candidate in _loadingEngines.toList()) {
      candidate.dispose();
    }
    _loadingEngines.clear();
    _navigationCommand = null;
    navigationCause = ReaderNavigationCause.restore;
    final request = _ReaderLoadRequest(
      id: ++_latestLoadId,
      document: document,
      initialLocator: initialLocator,
      preferences: preferences ?? this.preferences,
    );
    _publish(
      ReaderLoadingSnapshot(
        document: document,
        preferences: request.preferences,
        locator: initialLocator,
      ),
    );

    // Give the shell a chance to paint loading chrome. A newer request owns an
    // independent engine and never waits for an obsolete file read.
    return Future<void>.microtask(() => _performLoad(request));
  }

  Future<void> _performLoad(_ReaderLoadRequest request) async {
    if (!_canPublish(request)) {
      return;
    }

    ReaderEngine? candidate;
    try {
      candidate = _registry.resolve(request.document.format);
      _loadingEngines.add(candidate);

      await candidate.load(
        request.document,
        initialLocator: request.initialLocator,
        preferences: request.preferences,
      );

      if (_canPublish(request)) {
        _selectEngine(candidate);
        _publish(candidate.snapshot);
      } else {
        if (_loadingEngines.remove(candidate)) candidate.dispose();
      }
    } on ReaderException catch (error) {
      if (candidate != null &&
          _loadingEngines.remove(candidate) &&
          !identical(candidate, _engine)) {
        candidate.dispose();
      }
      _publishLoadError(request, error);
      rethrow;
    } catch (error, stackTrace) {
      if (candidate != null &&
          _loadingEngines.remove(candidate) &&
          !identical(candidate, _engine)) {
        candidate.dispose();
      }
      final readerError = ReaderException(
        ReaderErrorCode.invalidDocument,
        'The reader engine could not load the document.',
        cause: error,
      );
      _publishLoadError(request, readerError);

      Error.throwWithStackTrace(readerError, stackTrace);
    } finally {
      _loadingEngines.remove(candidate);
    }
  }

  Future<void> goTo(ReaderLocator locator) async {
    await _navigate(
      ReaderNavigationCause.jump,
      (engine) => engine.goTo(locator),
    );
  }

  Future<void> goToProgress(double progress) async {
    if (!progress.isFinite || progress < 0 || progress > 1) {
      throw ArgumentError.value(
        progress,
        'progress',
        'must be between 0 and 1',
      );
    }

    await _navigate(
      ReaderNavigationCause.jump,
      (engine) => engine.goToProgress(progress),
    );
  }

  Future<void> goNext() async {
    await _navigate(ReaderNavigationCause.turn, (engine) => engine.goNext());
  }

  Future<void> goPrevious() async {
    await _navigate(
      ReaderNavigationCause.turn,
      (engine) => engine.goPrevious(),
    );
  }

  Future<ReaderLocator?> currentLocator() async {
    return _requireReadyEngine().currentLocator();
  }

  Future<void> updatePreferences(ReaderPreferences preferences) async {
    await _navigate(ReaderNavigationCause.reflow, (engine) async {
      await engine.updatePreferences(preferences);
      if (identical(_engine, engine)) _syncFromEngine();
    });
  }

  Future<void> _navigate(
    ReaderNavigationCause cause,
    Future<void> Function(ReaderEngine) action,
  ) async {
    final engine = _requireReadyEngine();
    final token = Object();
    _navigationCommand = (token: token, cause: cause);
    navigationCause = cause;
    try {
      await action(engine);
    } finally {
      if (identical(_navigationCommand?.token, token)) {
        _navigationCommand = null;
      }
    }
  }

  void _selectEngine(ReaderEngine engine) {
    if (identical(engine, _engine)) {
      return;
    }

    final previous = _engine;
    previous?.removeListener(_syncFromEngine);
    previous?.dispose();
    _engine = engine;
    engine.addListener(_syncFromEngine);
  }

  ReaderEngine _requireReadyEngine() {
    final engine = _engine;
    if (_isDisposed ||
        engine == null ||
        _snapshot.status != ReaderStatus.ready) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The reader is not ready for this operation.',
      );
    }

    return engine;
  }

  void _syncFromEngine() {
    if (_isDisposed || _snapshot.status != ReaderStatus.ready) {
      return;
    }

    final engine = _engine;
    if (engine != null) {
      if (engine.snapshot.locator != _snapshot.locator) {
        navigationCause =
            _navigationCommand?.cause ?? ReaderNavigationCause.viewport;
      }
      _publish(engine.snapshot);
    }
  }

  void _publish(ReaderSnapshot next) {
    if (_isDisposed || identical(next, _snapshot)) {
      return;
    }

    final previous = _snapshot;
    _snapshot = next;

    if (next.locator != null && next.locator != previous.locator) {
      _invokeObserver(
        () => onLocatorChanged?.call(next.locator!),
        'onLocatorChanged',
      );
    }
    if (next.preferences != previous.preferences) {
      _invokeObserver(
        () => onPreferencesChanged?.call(next.preferences),
        'onPreferencesChanged',
      );
    }

    if (!_isDisposed) {
      notifyListeners();
    }
  }

  bool _canPublish(_ReaderLoadRequest request) {
    return !_isDisposed && request.id == _latestLoadId;
  }

  void _publishLoadError(_ReaderLoadRequest request, ReaderException error) {
    if (!_canPublish(request)) {
      return;
    }

    _publish(
      ReaderErrorSnapshot(
        document: request.document,
        preferences: request.preferences,
        locator: request.initialLocator,
        error: error,
      ),
    );
  }

  void _invokeObserver(VoidCallback callback, String callbackName) {
    try {
      callback();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'papyrus_reader',
          context: ErrorDescription('while invoking $callbackName'),
        ),
      );
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    _latestLoadId++;
    for (final candidate in _loadingEngines) {
      candidate.dispose();
    }
    _loadingEngines.clear();
    final engine = _engine;
    _engine = null;
    engine?.removeListener(_syncFromEngine);
    engine?.dispose();
    super.dispose();
  }
}

final class _ReaderLoadRequest {
  const _ReaderLoadRequest({
    required this.id,
    required this.document,
    required this.initialLocator,
    required this.preferences,
  });

  final int id;
  final ReaderDocument document;
  final ReaderLocator? initialLocator;
  final ReaderPreferences preferences;
}
