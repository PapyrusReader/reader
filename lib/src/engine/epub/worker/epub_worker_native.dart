import 'dart:async';
import 'dart:isolate';

import '../../../domain/reader_exception.dart';
import 'epub_processor.dart';
import 'epub_worker.dart';

Future<EpubWorker> createWorker() async {
  final messages = ReceivePort();
  final worker = _NativeEpubWorker(messages);
  try {
    worker.isolate = await Isolate.spawn(
      _run,
      messages.sendPort,
      onError: messages.sendPort,
      onExit: messages.sendPort,
      debugName: 'papyrus-epub',
    );
    await worker._ready.future;
    return worker;
  } catch (_) {
    worker.dispose();
    rethrow;
  }
}

void _run(SendPort host) {
  final requests = ReceivePort();
  final processor = EpubProcessor();
  host.send(requests.sendPort);
  Future<void> queue = Future<void>.value();
  requests.listen((dynamic message) {
    queue = queue.then((_) async {
      host.send(
        await processEpubMessage(
          processor,
          Map<String, Object?>.from(message as Map),
        ),
      );
    });
  });
}

final class _NativeEpubWorker implements EpubWorker {
  _NativeEpubWorker(this.messages) {
    messages.listen(_receive);
  }
  final ReceivePort messages;
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  Isolate? isolate;
  int _id = 0;
  bool _disposed = false;

  void _receive(dynamic message) {
    if (message is SendPort) {
      _ready.complete(message);
      return;
    }
    if (message is! Map) {
      dispose();
      return;
    }
    final pending = _pending.remove(message['id']);
    if (pending == null) return;
    if (message['error'] != null) {
      pending.completeError(
        ReaderException(
          message['error'] == 'unsupportedFixedLayout'
              ? ReaderErrorCode.unsupportedFixedLayout
              : ReaderErrorCode.invalidDocument,
          message['message'] as String,
        ),
      );
    } else {
      pending.complete(Map<String, Object?>.from(message['result'] as Map));
    }
  }

  @override
  Future<Map<String, Object?>> request(String command, Object? argument) async {
    if (_disposed) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The document was closed.',
      );
    }
    final port = await _ready.future;
    if (_disposed) {
      throw const ReaderException(
        ReaderErrorCode.engineUnavailable,
        'The document was closed.',
      );
    }
    final id = ++_id;
    final result = Completer<Map<String, Object?>>();
    _pending[id] = result;
    port.send({'id': id, 'command': command, 'argument': argument});
    return result.future;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    isolate?.kill(priority: Isolate.immediate);
    messages.close();
    const error = ReaderException(
      ReaderErrorCode.engineUnavailable,
      'The document was closed.',
    );
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }
}
