enum ReaderErrorCode {
  unsupportedFixedLayout,
  invalidDocument,
  encryptedDocument,
  engineUnavailable,
  navigationBoundary,
}

final class ReaderException implements Exception {
  const ReaderException(this.code, this.message, {this.cause});

  final ReaderErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'ReaderException(${code.name}): $message';
}
