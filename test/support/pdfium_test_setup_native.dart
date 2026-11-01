import 'dart:convert';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

Future<void> initializePdfiumForTest() async {
  // Flutter tests emit a host asset manifest here. pdfrx's Dart initializer
  // instead looks for .dart_tool/native_assets.yaml, which a clean checkout lacks.
  final manifest = File(
    'build/native_assets/${Platform.operatingSystem}/native_assets.json',
  );
  final json = jsonDecode(await manifest.readAsString()) as Map;
  final targets = json['native-assets'] as Map;
  final assets = targets.values.single as Map;
  final module = assets['package:pdfium_dart/libpdfium'] as List;

  if (module.first != 'absolute') {
    throw StateError('Expected an absolute PDFium path in ${manifest.path}.');
  }

  final modulePath = module.last as String;
  if (!File(modulePath).existsSync()) {
    throw StateError('PDFium test library is missing: $modulePath');
  }

  Pdfrx.pdfiumModulePath = modulePath;
  // The dependency's worker does not forward initialization errors to its caller.
  await pdfrxInitialize().timeout(const Duration(seconds: 15));
}
