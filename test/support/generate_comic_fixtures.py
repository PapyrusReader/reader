"""Generate owned PNG pages, CBZ, and stored RAR4 fixtures (stdlib only).

For a compressed RAR5 fixture, run RAR against the generated pages:
  rar a -ep -m5 -s pages-rar5.cbr page10.png page2.png page1.png
"""
import binascii
from pathlib import Path
import struct
import zlib
import zipfile

root = Path(__file__).resolve().parents[1] / 'fixtures' / 'comics'
root.mkdir(exist_ok=True)


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data))


def header(kind, flags, body):
    value = struct.pack('<BHH', kind, flags, 7 + len(body)) + body
    return struct.pack('<H', binascii.crc32(value) & 0xffff) + value


pages = {}
for name, color in [('page10.png', (0, 0, 220)), ('page2.png', (0, 180, 0)), ('page1.png', (220, 0, 0))]:
    width, height = 320, 480
    raw = b''.join(b'\0' + bytes(color) * width for _ in range(height))
    data = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    data += png_chunk(b'IDAT', zlib.compress(raw)) + png_chunk(b'IEND', b'')
    pages[name] = data
    (root / name).write_bytes(data)

with zipfile.ZipFile(root / 'pages.cbz', 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, data in pages.items():
        archive.writestr(name, data)
    archive.writestr('__MACOSX/._page0.png', b'not an image')
    archive.writestr('ComicInfo.xml', '<ComicInfo><Title>Test comic</Title></ComicInfo>')

rar = b'Rar!\x1a\x07\0' + header(0x73, 0, b'\0' * 6)
for name, data in pages.items():
    encoded = name.encode()
    body = struct.pack('<IIBIIBBHI', len(data), len(data), 3, binascii.crc32(data), 0, 20, 0x30, len(encoded), 0x81a4)
    rar += header(0x74, 0x8000, body + encoded) + data
rar += header(0x7b, 0, b'')
(root / 'pages-rar4.cbr').write_bytes(rar)
