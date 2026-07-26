import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void main() {
  final assets = Directory('example/assets')..createSync(recursive: true);
  File('${assets.path}/the_garden_letter.epub').writeAsBytesSync(_epub());
  File('${assets.path}/a_tiny_pdf.pdf').writeAsBytesSync(_pdf());
}

Uint8List _epub() {
  return _zip({
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container version="1.0"
 xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
 <rootfiles><rootfile full-path="OEBPS/content.opf"
  media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
    'OEBPS/content.opf': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book-id"
 xmlns="http://www.idpf.org/2007/opf">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:identifier id="book-id">papyrus-garden-letter</dc:identifier>
  <dc:title>The Garden Letter</dc:title>
  <dc:creator>Papyrus Studio</dc:creator>
  <dc:language>en</dc:language>
  <dc:rights>Public domain dedication (CC0)</dc:rights>
 </metadata>
 <manifest>
  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  <item id="one" href="text/one.xhtml" media-type="application/xhtml+xml"/>
  <item id="two" href="text/two.xhtml" media-type="application/xhtml+xml"/>
 </manifest>
 <spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine>
</package>'''),
    'OEBPS/toc.ncx': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
 <head><meta name="dtb:uid" content="papyrus-garden-letter"/></head>
 <docTitle><text>The Garden Letter</text></docTitle>
 <navMap>
  <navPoint id="one" playOrder="1">
   <navLabel><text>At the Gate</text></navLabel>
   <content src="text/one.xhtml"/>
  </navPoint>
  <navPoint id="two" playOrder="2">
   <navLabel><text>After the Rain</text></navLabel>
   <content src="text/two.xhtml"/>
  </navPoint>
 </navMap>
</ncx>'''),
    'OEBPS/text/one.xhtml': utf8.encode('''
<html xmlns="http://www.w3.org/1999/xhtml">
 <head><title>At the Gate</title></head>
 <body>
  <h1>At the Gate</h1>
  <p>Dear friend, the first green shoots have reached the old garden gate.</p>
  <p>I left a chair beneath the pear tree, where the afternoon gathers slowly.</p>
  <p>This little demo text is dedicated to the public domain.</p>
 </body>
</html>'''),
    'OEBPS/text/two.xhtml': utf8.encode('''
<html xmlns="http://www.w3.org/1999/xhtml">
 <head><title>After the Rain</title></head>
 <body>
  <h1>After the Rain</h1>
  <p>The path shone silver this morning, and every leaf held a small sky.</p>
  <p>Come when you can. The book and the quiet corner will be waiting.</p>
 </body>
</html>'''),
  });
}

Uint8List _pdf() {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 420] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  const stream =
      'BT\n/F1 22 Tf\n40 340 Td\n(A Tiny PDF) Tj\n'
      '/F1 12 Tf\n0 -34 Td\n(A valid one-page Papyrus demo.) Tj\nET\n';
  objects[3] =
      '<< /Length ${ascii.encode(stream).length} >>\n'
      'stream\n$stream'
      'endstream';

  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(ascii.encode(output.toString()).length);
    output
      ..writeln('${index + 1} 0 obj')
      ..writeln(objects[index])
      ..writeln('endobj');
  }
  final xrefOffset = ascii.encode(output.toString()).length;
  output
    ..writeln('xref')
    ..writeln('0 ${objects.length + 1}')
    ..writeln('0000000000 65535 f ');
  for (final offset in offsets.skip(1)) {
    output.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
  }
  output
    ..writeln('trailer')
    ..writeln('<< /Size ${objects.length + 1} /Root 1 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..writeln('%%EOF');

  return Uint8List.fromList(ascii.encode(output.toString()));
}

Uint8List _zip(Map<String, List<int>> files) {
  final output = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;

  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = entry.value;
    final crc = _crc32(data);
    final local = BytesBuilder(copy: false)
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(name)
      ..add(data);
    final localBytes = local.takeBytes();
    output.add(localBytes);

    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(offset))
      ..add(name);
    offset += localBytes.length;
  }

  final centralBytes = central.takeBytes();
  output
    ..add(centralBytes)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(files.length))
    ..add(_u16(files.length))
    ..add(_u32(centralBytes.length))
    ..add(_u32(offset))
    ..add(_u16(0));

  return output.takeBytes();
}

List<int> _u16(int value) {
  final data = ByteData(2)..setUint16(0, value, Endian.little);

  return data.buffer.asUint8List();
}

List<int> _u32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);

  return data.buffer.asUint8List();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }

  return (crc ^ 0xffffffff) & 0xffffffff;
}
