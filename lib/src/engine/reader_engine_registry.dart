import '../domain/reader_exception.dart';
import '../domain/reader_types.dart';
import 'epub/epub_reader_engine.dart';
import 'pdf/pdf_reader_engine.dart';
import 'reader_engine.dart';

typedef ReaderEngineFactory = ReaderEngine Function();

final class ReaderEngineRegistration {
  ReaderEngineRegistration({
    required Iterable<ReaderFormat> formats,
    required this.factory,
  }) : formats = Set.unmodifiable(formats) {
    if (this.formats.isEmpty) {
      throw ArgumentError.value(formats, 'formats', 'must not be empty');
    }
  }

  final Set<ReaderFormat> formats;
  final ReaderEngineFactory factory;
}

final class ReaderEngineRegistry {
  ReaderEngineRegistry(Iterable<ReaderEngineRegistration> registrations)
    : _factories = _indexRegistrations(registrations);

  factory ReaderEngineRegistry.defaults() {
    return ReaderEngineRegistry([
      ReaderEngineRegistration(
        formats: const {ReaderFormat.epub},
        factory: EpubReaderEngine.new,
      ),
      ReaderEngineRegistration(
        formats: const {ReaderFormat.pdf},
        factory: PdfReaderEngine.new,
      ),
    ]);
  }

  final Map<ReaderFormat, ReaderEngineFactory> _factories;

  ReaderEngine resolve(ReaderFormat format) {
    final factory = _factories[format];
    if (factory == null) {
      throw ReaderException(
        ReaderErrorCode.engineUnavailable,
        'No reader engine is registered for ${format.name}.',
      );
    }

    final engine = factory();
    if (!engine.supportedFormats.contains(format)) {
      engine.dispose();
      throw ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The registered reader engine does not support ${format.name}.',
      );
    }

    return engine;
  }

  static Map<ReaderFormat, ReaderEngineFactory> _indexRegistrations(
    Iterable<ReaderEngineRegistration> registrations,
  ) {
    final indexed = <ReaderFormat, ReaderEngineFactory>{};

    for (final registration in registrations) {
      for (final format in registration.formats) {
        if (indexed.containsKey(format)) {
          throw ArgumentError(
            'Multiple reader engines are registered for ${format.name}.',
          );
        }

        indexed[format] = registration.factory;
      }
    }

    return Map.unmodifiable(indexed);
  }
}
