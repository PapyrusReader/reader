import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:koni_archive_core/koni_archive_core.dart' as rar;
import 'package:koni_rar/koni_rar.dart';
import 'package:pdf/pdf.dart';

/// Build a transient page document inside the worker. Pages retain their
/// original dimensions and JPEG data; no library file or converted copy is saved.
Future<Uint8List> comicToPdf(Uint8List bytes, {required bool isRar}) async {
  final document = PdfDocument();
  var count = 0;

  void addPage(Uint8List bytes) {
    final image = PdfImage.file(document, bytes: bytes);
    final page = PdfPage(
      document,
      pageFormat: PdfPageFormat(
        image.width.toDouble(),
        image.height.toDouble(),
      ),
    );
    page.getGraphics().drawImage(
      image,
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    count++;
  }

  if (isRar) {
    final source = rar.MemoryByteSource(bytes);
    rar.ArchiveReader? archive;

    try {
      archive = await const RarFormat().openReader(
        source,
        const rar.ArchiveReadOptions(),
      );
      final pages =
          archive.entries
              .where(
                (entry) =>
                    entry.type == rar.ArchiveEntryType.file &&
                    isComicPage(entry.path),
              )
              .toList()
            ..sort((left, right) => compareComicPaths(left.path, right.path));

      for (final page in pages) {
        final content = BytesBuilder(copy: false);

        await for (final chunk in archive.openRead(page)) {
          content.add(chunk);
        }

        addPage(content.takeBytes());
      }
    } finally {
      await archive?.close();
      await source.close();
    }
  } else {
    final archive = ZipDecoder().decodeBytes(bytes);

    try {
      final pages =
          archive.files
              .where((entry) => entry.isFile && isComicPage(entry.name))
              .toList()
            ..sort((left, right) => compareComicPaths(left.name, right.name));

      for (final page in pages) {
        addPage(page.content);
        page.clear();
      }
    } finally {
      archive.clear();
    }
  }

  if (count == 0) {
    throw const FormatException('The comic archive has no readable images.');
  }

  return document.save();
}

bool isComicPage(String path) {
  final segments = path.replaceAll('\\', '/').split('/');
  return !segments.any((part) => part.startsWith('.') || part == '__MACOSX') &&
      RegExp(
        r'\.(jpe?g|png|gif|webp|bmp)$',
        caseSensitive: false,
      ).hasMatch(path);
}

/// Natural ordering: page2 precedes page10, including nested chapter folders.
int compareComicPaths(String left, String right) {
  final parts = RegExp(r'\d+|\D+');
  final first = parts
      .allMatches(left.toLowerCase())
      .map((match) => match[0]!)
      .toList();
  final second = parts
      .allMatches(right.toLowerCase())
      .map((match) => match[0]!)
      .toList();

  for (var index = 0; index < first.length && index < second.length; index++) {
    final a = first[index];
    final b = second[index];
    final numeric = int.tryParse(a);
    final other = int.tryParse(b);
    final comparison = numeric != null && other != null
        ? numeric.compareTo(other)
        : a.compareTo(b);

    if (comparison != 0) {
      return comparison;
    }
  }

  final length = first.length.compareTo(second.length);
  return length != 0 ? length : left.compareTo(right);
}
