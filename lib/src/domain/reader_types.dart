enum ReaderFormat {
  epub,
  pdf,
  mobi,
  azw3,
  txt,
  cbr,
  cbz;

  bool get isReflowable => switch (this) {
    epub || mobi || azw3 || txt => true,
    pdf || cbr || cbz => false,
  };
}

enum ReaderLayoutMode { paginated, scroll }

enum ReaderColumnMode { automatic, single, double }

enum ReaderStatus { idle, loading, ready, error }
