import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

class FakeReaderEngine extends ReaderEngine {
  FakeReaderEngine({required this.supportedFormats});

  @override
  final Set<ReaderFormat> supportedFormats;

  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    supportsPagination: true,
    supportsScrolling: true,
    supportsTextCustomization: true,
    supportsColumnMode: true,
  );

  @override
  ReaderSnapshot snapshot = const ReaderIdleSnapshot();

  @override
  Widget buildViewport(BuildContext context) {
    return const SizedBox.shrink();
  }

  ReaderDocument? loadedDocument;
  final List<ReaderDocument> loadedDocuments = [];
  ReaderLocator? initialLocator;
  ReaderPreferences? loadedPreferences;
  ReaderException? loadFailure;
  Completer<void>? loadGate;
  final Map<String, ReaderException> loadFailuresByDocument = {};
  final Map<String, Completer<void>> loadGatesByDocument = {};
  final Map<String, Completer<void>> _loadStartsByDocument = {};
  ReaderLocator? currentLocatorResult;
  final List<ReaderLocator> goToCalls = [];
  final List<double> goToProgressCalls = [];
  int goNextCallCount = 0;
  int goPreviousCallCount = 0;
  int currentLocatorCallCount = 0;
  final List<ReaderPreferences> preferenceCalls = [];
  bool notifyOnPreferenceChange = true;
  int activeLoadCount = 0;
  int maxConcurrentLoadCount = 0;
  bool isDisposed = false;

  Completer<void> trackLoadStart(String documentId) {
    return _loadStartsByDocument.putIfAbsent(documentId, Completer<void>.new);
  }

  @override
  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    required ReaderPreferences preferences,
  }) async {
    loadedDocument = document;
    loadedDocuments.add(document);
    this.initialLocator = initialLocator;
    loadedPreferences = preferences;
    activeLoadCount++;
    if (activeLoadCount > maxConcurrentLoadCount) {
      maxConcurrentLoadCount = activeLoadCount;
    }
    final loadStart = _loadStartsByDocument[document.id];
    if (loadStart != null && !loadStart.isCompleted) {
      loadStart.complete();
    }

    try {
      await (loadGatesByDocument[document.id] ?? loadGate)?.future;

      final failure = loadFailuresByDocument[document.id] ?? loadFailure;
      if (failure != null) {
        throw failure;
      }

      snapshot = ReaderReadySnapshot(
        document: document,
        preferences: preferences,
        capabilities: capabilities,
        locator: initialLocator,
      );
      notifyListeners();
    } finally {
      activeLoadCount--;
    }
  }

  @override
  Future<void> goTo(ReaderLocator locator) async {
    goToCalls.add(locator);
  }

  @override
  Future<void> goToProgress(double progress) async {
    goToProgressCalls.add(progress);
  }

  @override
  Future<void> goNext() async {
    goNextCallCount++;
  }

  @override
  Future<void> goPrevious() async {
    goPreviousCallCount++;
  }

  @override
  Future<ReaderLocator?> currentLocator() async {
    currentLocatorCallCount++;
    return currentLocatorResult;
  }

  @override
  Future<void> updatePreferences(ReaderPreferences preferences) async {
    preferenceCalls.add(preferences);
    final current = snapshot;
    final document = current.document;
    if (document == null) {
      return;
    }

    snapshot = ReaderReadySnapshot(
      document: document,
      preferences: preferences,
      capabilities: capabilities,
      locator: current.locator,
      toc: current.toc,
    );
    if (notifyOnPreferenceChange) {
      notifyListeners();
    }
  }

  void emitLocator(ReaderLocator locator) {
    final current = snapshot;
    final document = current.document;
    if (document == null) {
      throw StateError('Load a document before emitting a locator.');
    }

    snapshot = ReaderReadySnapshot(
      document: document,
      preferences: current.preferences,
      capabilities: capabilities,
      locator: locator,
      toc: current.toc,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    isDisposed = true;
    super.dispose();
  }
}
