import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;

/// Serializable semantic runs. Offsets refer to this normalized content stream,
/// not screen pages; publisher layout and typography never enter the worker.
Map<String, Object?> collectEpubContent(String html) {
  final body = parser.parse(html).body;
  final blocks = <Map<String, Object?>>[];
  final anchors = <String, int>{};
  var offset = 0;
  final runs = <Map<String, Object?>>[];
  String kind = 'p';
  var preformatted = false;
  final listCounters = <Element, int>{};

  String listMarker(Element item) {
    Element? owner = item.parent;
    while (owner != null &&
        !const {'ol', 'ul', 'menu'}.contains(owner.localName)) {
      owner = owner.parent;
    }
    if (owner == null || owner.localName != 'ol') return '• ';
    final reversed = owner.attributes.containsKey('reversed');
    final number =
        int.tryParse(item.attributes['value']?.trim() ?? '') ??
        listCounters[owner] ??
        int.tryParse(owner.attributes['start']?.trim() ?? '') ??
        (reversed
            ? owner.children.where((child) => child.localName == 'li').length
            : 1);
    listCounters[owner] = number + (reversed ? -1 : 1);
    return '$number. ';
  }

  void flush() {
    if (runs.isEmpty) return;
    final length = runs.fold<int>(
      0,
      (sum, run) => sum + (run['text'] as String).length,
    );
    if (runs.any((run) => (run['text'] as String).trim().isNotEmpty)) {
      final text = runs.map((run) => run['text'] as String).join();
      final boundaries = <int>[0];
      var position = 0;
      for (final grapheme in text.characters) {
        position += grapheme.length;
        boundaries.add(position);
      }
      var start = 0;
      var boundaryIndex = 0;
      while (start < length) {
        var end = math.min(start + 4096, length);
        if (end < length) {
          final space = text.substring(start, end).lastIndexOf(RegExp(r'\s'));
          if (space > 2048) end = start + space + 1;
          while (boundaryIndex + 1 < boundaries.length &&
              boundaries[boundaryIndex + 1] <= end) {
            boundaryIndex++;
          }
          end = boundaries[boundaryIndex];
          if (end <= start) end = boundaries[++boundaryIndex];
        }
        var runOffset = 0;
        final slice = <Map<String, Object?>>[];
        for (final run in runs) {
          final value = run['text'] as String;
          final from = math.max(0, start - runOffset);
          final to = math.min(value.length, end - runOffset);
          if (to > from) slice.add({...run, 'text': value.substring(from, to)});
          runOffset += value.length;
          if (runOffset >= end) break;
        }
        blocks.add({
          'kind': kind,
          'offset': offset + start,
          'length': end - start,
          'runs': slice,
          'paragraphEnd': end == length,
        });
        start = end;
      }
      offset += length + 1;
    }
    runs.clear();
  }

  void text(String value, Map<String, Object?> style) {
    if (!preformatted) value = value.replaceAll(RegExp(r'\s+'), ' ');
    if (runs.isEmpty && !preformatted) value = value.trimLeft();
    if (value.isNotEmpty) runs.add({'text': value, ...style});
  }

  void visit(Node node, Map<String, Object?> inherited) {
    if (node is Text) {
      text(node.data, inherited);
      return;
    }
    if (node is! Element) return;
    final tag = node.localName ?? '';
    final isBlock = const {
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'p',
      'div',
      'li',
      'blockquote',
      'pre',
      'tr',
      'figure',
    }.contains(tag);
    final previousKind = kind;
    final previousPre = preformatted;
    if (isBlock) {
      flush();
      kind = tag;
      preformatted = tag == 'pre';
    }
    final id = node.id.isEmpty ? node.attributes['name'] : node.id;
    if (id != null && id.isNotEmpty) {
      anchors[id] =
          offset +
          runs.fold<int>(0, (sum, run) => sum + (run['text'] as String).length);
    }
    final style = <String, Object?>{...inherited};
    if (const {'strong', 'b', 'th'}.contains(tag)) style['bold'] = true;
    if (const {'em', 'i'}.contains(tag)) style['italic'] = true;
    if (tag == 'u' || tag == 'a') style['underline'] = true;
    if (tag == 's' || tag == 'del') style['strike'] = true;
    if (tag == 'code' || tag == 'pre') style['code'] = true;
    if (tag == 'br') runs.add({'text': '\n', ...style});
    if (tag == 'li') text(listMarker(node), style);
    if (tag == 'td' || tag == 'th') {
      if (runs.isNotEmpty) text('  |  ', style);
    }
    if (tag == 'img') {
      flush();
      final src = node.attributes['src'];
      if (src != null) {
        final width = double.tryParse(node.attributes['width'] ?? '');
        final height = double.tryParse(node.attributes['height'] ?? '');
        blocks.add({
          'kind': 'image',
          'offset': offset,
          'length': 1,
          'src': src,
          'alt': node.attributes['alt'] ?? 'Illustration',
          'aspect': width != null && height != null && width > 0 && height > 0
              ? width / height
              : 1.5,
        });
        offset += 2;
      }
    } else {
      for (final child in node.nodes) {
        visit(child, style);
      }
    }
    if (isBlock) {
      flush();
      kind = previousKind;
      preformatted = previousPre;
    }
  }

  if (body != null) {
    for (final node in body.nodes) {
      visit(node, const {});
    }
  }
  flush();
  return {'blocks': blocks, 'anchors': anchors, 'length': offset};
}
