import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'package:papyrus_reader/src/engine/epub/worker/epub_processor.dart';

@JS('self')
external web.DedicatedWorkerGlobalScope get scope;

void main() {
  final processor = EpubProcessor();
  Future<void> queue = Future<void>.value();
  scope.onmessage = ((web.MessageEvent event) {
    final request = (event.data.dartify() as Map).cast<String, Object?>();
    if (request['bytes'] case final bytes?) request['argument'] = bytes;
    queue = queue.then((_) async {
      scope.postMessage(
        jsonEncode(await processEpubMessage(processor, request)).toJS,
      );
    });
  }).toJS;
}
