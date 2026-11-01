import 'package:flutter/widgets.dart';

import '../domain/reader_capabilities.dart';
import '../domain/reader_document.dart';
import '../domain/reader_locator.dart';
import '../domain/reader_preferences.dart';
import '../domain/reader_snapshot.dart';
import '../domain/reader_types.dart';

abstract class ReaderEngine extends ChangeNotifier {
  Set<ReaderFormat> get supportedFormats;

  ReaderCapabilities get capabilities;

  ReaderSnapshot get snapshot;

  Widget buildViewport(BuildContext context);

  Future<void> load(
    ReaderDocument document, {
    ReaderLocator? initialLocator,
    required ReaderPreferences preferences,
  });

  Future<void> goTo(ReaderLocator locator);

  Future<void> goToProgress(double progress);

  /// Stop a pending progress seek when supported. Engines that cannot cancel
  /// finish the active operation before the shell runs the latest queued seek.
  void cancelPendingSeek() {}

  Future<void> goNext();

  Future<void> goPrevious();

  Future<ReaderLocator?> currentLocator();

  Future<void> updatePreferences(ReaderPreferences preferences);
}
