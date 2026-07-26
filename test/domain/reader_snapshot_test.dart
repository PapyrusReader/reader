import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  final locator = EpubReaderLocator(
    cfi: 'epubcfi(/6/2)',
    spineIndex: 0,
    localProgression: 0,
    totalProgression: 0,
  );
  final document = ReaderDocument(
    id: 'book',
    format: ReaderFormat.epub,
    loadBytes: () async => Uint8List(0),
  );

  test('ReaderReadySnapshot defensively copies its TOC source list', () {
    final entry = ReaderTocEntry(title: 'Chapter', locator: locator);
    final source = <ReaderTocEntry>[entry];
    final snapshot = ReaderReadySnapshot(
      document: document,
      preferences: const ReaderPreferences(),
      capabilities: const ReaderCapabilities(),
      toc: source,
    );

    source.clear();

    expect(snapshot.toc, [entry]);
    expect(() => snapshot.toc.add(entry), throwsUnsupportedError);
  });

  test('ReaderTocEntry defensively copies nested child source lists', () {
    final child = ReaderTocEntry(title: 'Section', locator: locator);
    final source = <ReaderTocEntry>[child];
    final parent = ReaderTocEntry(
      title: 'Chapter',
      locator: locator,
      children: source,
    );

    source.clear();

    expect(parent.children, [child]);
    expect(() => parent.children.add(child), throwsUnsupportedError);
  });
}
