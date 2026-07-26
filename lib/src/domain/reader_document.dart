import 'dart:typed_data';

import 'reader_types.dart';

typedef ReaderBytesLoader = Future<Uint8List> Function();

final class ReaderDocument {
  const ReaderDocument({
    required this.id,
    required this.format,
    required this.loadBytes,
    this.title,
    this.author,
  });

  final String id;
  final ReaderFormat format;
  final String? title;
  final String? author;
  final ReaderBytesLoader loadBytes;
}
