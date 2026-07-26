import 'reader_capabilities.dart';
import 'reader_document.dart';
import 'reader_exception.dart';
import 'reader_locator.dart';
import 'reader_preferences.dart';
import 'reader_toc_entry.dart';
import 'reader_types.dart';

sealed class ReaderSnapshot {
  const ReaderSnapshot();

  ReaderStatus get status;

  ReaderDocument? get document;

  ReaderPreferences get preferences;

  ReaderLocator? get locator;

  List<ReaderTocEntry> get toc;

  ReaderCapabilities? get capabilities;

  ReaderException? get error;
}

final class ReaderIdleSnapshot extends ReaderSnapshot {
  const ReaderIdleSnapshot({this.preferences = const ReaderPreferences()});

  @override
  ReaderStatus get status => ReaderStatus.idle;

  @override
  ReaderDocument? get document => null;

  @override
  final ReaderPreferences preferences;

  @override
  ReaderLocator? get locator => null;

  @override
  List<ReaderTocEntry> get toc => const [];

  @override
  ReaderCapabilities? get capabilities => null;

  @override
  ReaderException? get error => null;
}

final class ReaderLoadingSnapshot extends ReaderSnapshot {
  const ReaderLoadingSnapshot({
    required this.document,
    required this.preferences,
    this.locator,
  });

  @override
  ReaderStatus get status => ReaderStatus.loading;

  @override
  final ReaderDocument document;

  @override
  final ReaderPreferences preferences;

  @override
  final ReaderLocator? locator;

  @override
  List<ReaderTocEntry> get toc => const [];

  @override
  ReaderCapabilities? get capabilities => null;

  @override
  ReaderException? get error => null;
}

final class ReaderReadySnapshot extends ReaderSnapshot {
  ReaderReadySnapshot({
    required this.document,
    required this.preferences,
    required this.capabilities,
    this.locator,
    List<ReaderTocEntry> toc = const [],
  }) : toc = List.unmodifiable(toc);

  @override
  ReaderStatus get status => ReaderStatus.ready;

  @override
  final ReaderDocument document;

  @override
  final ReaderPreferences preferences;

  @override
  final ReaderLocator? locator;

  @override
  final List<ReaderTocEntry> toc;

  @override
  final ReaderCapabilities capabilities;

  @override
  ReaderException? get error => null;
}

final class ReaderErrorSnapshot extends ReaderSnapshot {
  const ReaderErrorSnapshot({
    required this.error,
    required this.preferences,
    this.document,
    this.locator,
  });

  @override
  ReaderStatus get status => ReaderStatus.error;

  @override
  final ReaderDocument? document;

  @override
  final ReaderPreferences preferences;

  @override
  final ReaderLocator? locator;

  @override
  List<ReaderTocEntry> get toc => const [];

  @override
  ReaderCapabilities? get capabilities => null;

  @override
  final ReaderException error;
}
