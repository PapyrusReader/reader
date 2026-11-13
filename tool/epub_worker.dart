import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

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
      final response = await processEpubMessage(processor, request);
      final result = response['result'];

      if (result is Map && result['bytes'] is Uint8List) {
        final bytes = result['bytes'] as Uint8List;
        scope.postMessage(
          {
            'id': response['id'],
            'result': {'bytes': bytes.toJS},
          }.jsify(),
          [bytes.buffer.toJS].toJS,
        );
      } else {
        scope.postMessage(jsonEncode(response).toJS);
      }
    });
  }).toJS;
}
