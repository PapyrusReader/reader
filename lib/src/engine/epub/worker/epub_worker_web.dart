import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../../../domain/reader_exception.dart';
import 'epub_worker.dart';

Future<EpubWorker> createWorker() async {
  final script = await rootBundle.loadString(
    'packages/papyrus_reader/assets/epub_worker.js',
  );
  final url = web.URL.createObjectURL(
    web.Blob([script.toJS].toJS, web.BlobPropertyBag(type: 'text/javascript')),
  );
  try {
    return _WebEpubWorker(web.Worker(url.toJS));
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

final class _WebEpubWorker implements EpubWorker {
  _WebEpubWorker(this.worker) {
    worker.onmessage = ((web.MessageEvent event) {
      final message =
          jsonDecode((event.data as JSString).toDart) as Map<String, dynamic>;
      final result = _pending.remove(message['id']);
      if (result == null) return;
      if (message['error'] != null) {
        result.completeError(
          ReaderException(
            message['error'] == 'unsupportedFixedLayout'
                ? ReaderErrorCode.unsupportedFixedLayout
                : ReaderErrorCode.invalidDocument,
            message['message'] as String,
          ),
        );
      } else {
        result.complete(Map<String, Object?>.from(message['result'] as Map));
      }
    }).toJS;
    worker.onerror = ((web.Event event) {
      _fail(
        const ReaderException(
          ReaderErrorCode.engineUnavailable,
          'The EPUB worker could not start. Check the application worker assets and Content Security Policy.',
        ),
      );
    }).toJS;
  }
  final web.Worker worker;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _id = 0;
  bool _disposed = false;

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) {
    if (_disposed) {
      return Future.error(
        const ReaderException(
          ReaderErrorCode.engineUnavailable,
          'The document was closed.',
        ),
      );
    }
    final id = ++_id;
    final result = Completer<Map<String, Object?>>();
    _pending[id] = result;
    if (argument is Uint8List) {
      // Own a copy: transferring must not detach the host's cached book bytes.
      final copy = Uint8List.fromList(argument);
      final bytes = copy.toJS;
      worker.postMessage(
        {'id': id, 'command': command, 'bytes': bytes}.jsify(),
        [copy.buffer.toJS].toJS,
      );
    } else {
      worker.postMessage(
        {'id': id, 'command': command, 'argument': argument}.jsify(),
      );
    }
    return result.future;
  }

  void _fail(ReaderException error) {
    if (_disposed) return;
    _disposed = true;
    worker.terminate();
    for (final result in _pending.values) {
      result.completeError(error);
    }
    _pending.clear();
  }

  @override
  void dispose() => _fail(
    const ReaderException(
      ReaderErrorCode.engineUnavailable,
      'The document was closed.',
    ),
  );
}
