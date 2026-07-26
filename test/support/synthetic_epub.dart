import 'dart:convert';
import 'dart:typed_data';

Uint8List syntheticEpub({
  bool fixedLayout = false,
  bool malicious = false,
  bool longChapter = false,
  String? firstChapterBody,
  bool corruptSecondChapter = false,
}) {
  final repeated = longChapter
      ? List.generate(
          90,
          (index) =>
              '<p>Paragraph $index contains enough words to occupy '
              'several lines in a narrow reading viewport.</p>',
        ).join()
      : '<p>First chapter body.</p>';
  final hostile = malicious
      ? '''
<script>window.evil = true</script>
<form action="https://evil.example"><input name="secret"/></form>
<iframe src="https://evil.example/frame"></iframe>
<img src="https://evil.example/tracker.png"/>
<img src="//evil.example/tracker.png"/>
<img src="javascript:alert(1)"/>
<img src="data:text/html;base64,ZXZpbA=="/>
<img src="data:image/png;base64,ZXZpbA=="/>
<img src="../images/pixel.png"
 srcset="../images/pixel.png 1x, https://evil.example/tracker.png 2x"
 onerror="window.evil = true"/>
<p id="styled" onclick="window.evil = true"
 style="color: red; background-image: url(https://evil.example/a.png); width: expression(alert(1))">
 Styled content.
</p>
<style>@import "https://evil.example/styles.css";</style>
<link rel="stylesheet" href="https://evil.example/styles.css"/>
<video src="https://evil.example/video.mp4" poster="//evil.example/poster.png">
 <source src="https://evil.example/video.mp4"/>
 <track src="https://evil.example/captions.vtt"/>
</video>
<audio src="https://evil.example/audio.mp3"></audio>
<svg><use href="https://evil.example/icons.svg#icon"></use></svg>
<a id="safe-link" href="https://example.com/chapter">Safe link</a>
<a id="unsafe-link" href="javascript:alert(1)">Unsafe link</a>
'''
      : '<img src="../images/pixel.png"/>';
  final layoutMeta = fixedLayout
      ? '<meta name="rendition:layout" content="pre-paginated"/>'
      : '';

  return _zip({
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
 <rootfiles><rootfile full-path="OEBPS/content.opf"
 media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
    'OEBPS/content.opf': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book-id"
 xmlns="http://www.idpf.org/2007/opf">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:identifier id="book-id">synthetic</dc:identifier>
  <dc:title>Synthetic Book</dc:title>
  <dc:language>en</dc:language>
  $layoutMeta
 </metadata>
 <manifest>
  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  <item id="chapter1" href="text/chapter1.xhtml"
   media-type="application/xhtml+xml"/>
  <item id="chapter2" href="text/chapter2.xhtml"
   media-type="application/xhtml+xml"/>
  <item id="chapter3" href="text/chapter3.xhtml"
   media-type="application/xhtml+xml"/>
  <item id="image" href="images/pixel.png" media-type="image/png"/>
 </manifest>
 <spine toc="ncx">
  <itemref idref="chapter1"/>
  <itemref idref="chapter2"/>
  <itemref idref="chapter3"/>
 </spine>
</package>'''),
    'OEBPS/toc.ncx': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
 <head><meta name="dtb:uid" content="synthetic"/></head>
 <docTitle><text>Synthetic Book</text></docTitle>
 <navMap>
  <navPoint id="one" playOrder="1">
   <navLabel><text>Chapter One</text></navLabel>
   <content src="text/chapter1.xhtml"/>
   <navPoint id="one-a" playOrder="2">
    <navLabel><text>Part A</text></navLabel>
    <content src="text/chapter2.xhtml#part-a"/>
   </navPoint>
  </navPoint>
  <navPoint id="two" playOrder="3">
   <navLabel><text>Chapter Two</text></navLabel>
   <content src="text/chapter3.xhtml"/>
  </navPoint>
 </navMap>
</ncx>'''),
    'OEBPS/text/chapter1.xhtml': utf8.encode(
      '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
<body>${firstChapterBody ?? '<h1>Chapter One</h1>$repeated$hostile'}</body></html>''',
    ),
    if (!corruptSecondChapter)
      'OEBPS/text/chapter2.xhtml': utf8.encode(
        '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head>
<body><h1>Chapter Two</h1>${longChapter ? repeated : '<p>Second chapter body.</p>'}</body></html>''',
      ),
    'OEBPS/text/chapter3.xhtml': utf8.encode(
      '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Three</title></head>
<body><h1>Chapter Three</h1>${longChapter ? repeated : '<p>Third chapter body.</p>'}</body></html>''',
    ),
    'OEBPS/images/pixel.png': Uint8List.fromList(const [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]),
  });
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
