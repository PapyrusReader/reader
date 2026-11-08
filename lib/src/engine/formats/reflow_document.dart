import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:kindle_unpack/kindle_unpack.dart';

/// Runs exclusively in the document worker. The source file is never replaced.
Uint8List textToEpub(Uint8List bytes) {
  final text = decodeBookText(
    bytes,
  ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  if (text.trim().isEmpty) {
    throw const FormatException('The text document is empty.');
  }

  final parts = <XhtmlPart>[];
  var start = 0;

  // Stable, bounded chapters keep text measurement and seek work manageable.
  while (start < text.length) {
    var end = (start + 32768).clamp(0, text.length);

    if (end < text.length) {
      final boundary = text.lastIndexOf('\n', end);

      if (boundary > start) {
        end = boundary + 1;
      } else if (text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
    }

    final paragraphs = text.substring(start, end).split(RegExp(r'\n[ \t]*\n'));
    final body = paragraphs
        .map(
          (paragraph) =>
              '<p>${const HtmlEscape().convert(paragraph).replaceAll('\n', '<br/>')}</p>',
        )
        .join();
    parts.add(
      XhtmlPart(
        fileNumber: parts.length,
        bytes: utf8.encode('<html><body>$body</body></html>'),
      ),
    );
    start = end;
  }

  return EpubBuilder.build(
    metadata: const EpubMetadata(
      identifier: 'papyrus-text',
      title: 'Text',
      language: 'und',
    ),
    parts: parts,
  );
}

Uint8List kindleToEpub(Uint8List bytes) {
  final book = KindleBook.fromBytes(bytes);
  final images = {for (final image in book.images.all) image.blockIndex: image};
  final parts = <XhtmlPart>[];

  for (final part in book.parts) {
    final source = decodeBookText(
      part.bytes,
      windows1252: book.mobi.textEncoding == 1252,
    );
    final document = html.parse(source);

    for (final image in document.querySelectorAll('img')) {
      final flowLink = RegExp(
        r'^kindle:flow:([0-9A-V]+)',
        caseSensitive: false,
      ).firstMatch(image.attributes['src'] ?? '');
      final index = flowLink == null
          ? null
          : int.tryParse(flowLink.group(1)!, radix: 32);
      final flow = book.flows?.flows
          .where((flow) => flow.index == index && flow.kind == FlowKind.svg)
          .firstOrNull;

      if (flow != null) {
        final svg = html
            .parseFragment(utf8.decode(flow.bytes))
            .querySelector('svg');

        if (svg != null) {
          image.replaceWith(svg);
        }
      }
    }

    for (final image in document.querySelectorAll('img, image')) {
      final source =
          image.attributes['src'] ??
          image.attributes['href'] ??
          image.attributes['xlink:href'] ??
          image.attributes.entries
              .where((entry) => entry.key.toString() == 'xlink:href')
              .map((entry) => entry.value)
              .firstOrNull ??
          '';
      final embedded = RegExp(
        r'^kindle:embed:([0-9A-V]+)',
        caseSensitive: false,
      ).firstMatch(source);
      final number = embedded == null
          ? int.tryParse(image.attributes['recindex'] ?? '')
          : int.tryParse(embedded.group(1)!, radix: 32);
      final resource = number == null ? null : images[number - 1];

      if (resource != null) {
        image.attributes[image.localName == 'img' ? 'src' : 'href'] =
            '../Images/${resource.name}';
      }
    }

    parts.add(
      XhtmlPart(
        fileNumber: part.fileNumber,
        bytes: utf8.encode(document.outerHtml),
      ),
    );
  }

  if (parts.isEmpty) {
    throw const FormatException('The Kindle document has no readable content.');
  }

  return EpubBuilder.build(
    metadata: EpubMetadata(
      identifier: 'papyrus-kindle-${book.mobi.uniqueId}',
      title: book.title,
      language: book.exth?.language ?? 'und',
      creators: book.exth?.authors ?? const [],
    ),
    parts: parts,
    images: book.images.all,
  );
}

String decodeBookText(Uint8List bytes, {bool windows1252 = false}) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Truncated UTF-16 text.');
    }

    final data = ByteData.sublistView(bytes);
    final endian = bytes[0] == 0xff ? Endian.little : Endian.big;
    return String.fromCharCodes([
      for (var offset = 2; offset < bytes.length; offset += 2)
        data.getUint16(offset, endian),
    ]);
  }

  if (!windows1252) {
    try {
      return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
    } on FormatException {
      // Unmarked legacy text files commonly use Windows-1252.
    }
  }

  const controls = [
    0x20ac,
    0x81,
    0x201a,
    0x192,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x2c6,
    0x2030,
    0x160,
    0x2039,
    0x152,
    0x8d,
    0x17d,
    0x8f,
    0x90,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x2dc,
    0x2122,
    0x161,
    0x203a,
    0x153,
    0x9d,
    0x17e,
    0x178,
  ];
  return String.fromCharCodes(
    bytes.map(
      (byte) => byte >= 0x80 && byte <= 0x9f ? controls[byte - 0x80] : byte,
    ),
  );
}
