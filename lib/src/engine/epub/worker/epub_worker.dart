import 'dart:typed_data';

import 'epub_worker_native.dart'
    if (dart.library.js_interop) 'epub_worker_web.dart'
    as platform;

abstract interface class EpubWorker {
  Future<Map<String, Object?>> request(String command, Object? argument);
  void dispose();
}

Future<EpubWorker> createEpubWorker() => platform.createWorker();

extension EpubWorkerCommands on EpubWorker {
  Future<Map<String, Object?>> open(Uint8List bytes) => request('open', bytes);
  Future<Map<String, Object?>> chapter(int index) => request('chapter', index);
}
