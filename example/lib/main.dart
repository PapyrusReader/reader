import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:papyrus_reader/papyrus_reader.dart';

void main() {
  runApp(const PapyrusReaderDemoApp());
}

final class PapyrusReaderDemoApp extends StatefulWidget {
  const PapyrusReaderDemoApp({this.memory, super.key});

  final DemoReaderMemory? memory;

  @override
  State<PapyrusReaderDemoApp> createState() => _PapyrusReaderDemoAppState();
}

final class _PapyrusReaderDemoAppState extends State<PapyrusReaderDemoApp> {
  late final DemoReaderMemory _memory;
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory ?? DemoReaderMemory();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Papyrus Reader',
      themeMode: _themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: _DemoLibrary(
        isDark: _themeMode == ThemeMode.dark,
        toggleTheme: () {
          setState(() {
            _themeMode = _themeMode == ThemeMode.dark
                ? ThemeMode.light
                : ThemeMode.dark;
          });
        },
        memory: _memory,
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: brightness == Brightness.light
          ? const Color(0xff2d6455)
          : const Color(0xff91cdb8),
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

final class _DemoLibrary extends StatelessWidget {
  const _DemoLibrary({
    required this.isDark,
    required this.toggleTheme,
    required this.memory,
  });

  static const documents = [
    _DemoDocument(
      id: 'garden-letter',
      title: 'The Garden Letter',
      author: 'Papyrus Studio',
      description:
          'A tiny two-chapter EPUB made for exploring typography and flow.',
      format: ReaderFormat.epub,
      assetPath: 'assets/the_garden_letter.epub',
      icon: Icons.auto_stories_rounded,
      actionLabel: 'Read EPUB',
    ),
    _DemoDocument(
      id: 'tiny-pdf',
      title: 'A Tiny PDF',
      author: 'Papyrus Studio',
      description:
          'One valid, pocket-sized page for trying fixed document reading.',
      format: ReaderFormat.pdf,
      assetPath: 'assets/a_tiny_pdf.pdf',
      icon: Icons.picture_as_pdf_rounded,
      actionLabel: 'Read PDF',
    ),
  ];

  final bool isDark;
  final VoidCallback toggleTheme;
  final DemoReaderMemory memory;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Papyrus Reader'),
        actions: [
          IconButton(
            tooltip: isDark ? 'Use light theme' : 'Use dark theme',
            onPressed: toggleTheme,
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;

          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 40 : 20,
              vertical: 32,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(32),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.menu_book_rounded,
                            size: wide ? 64 : 48,
                            color: colors.onPrimaryContainer,
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'A small library, thoughtfully read.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                        color: colors.onPrimaryContainer,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Choose a sample, tune the page, close it, '
                                  'and return exactly where you left off.',
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: colors.onPrimaryContainer,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      'Demo documents',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (
                            var index = 0;
                            index < documents.length;
                            index++
                          ) ...[
                            if (index > 0) const SizedBox(width: 20),
                            Expanded(
                              child: _DocumentCard(
                                document: documents[index],
                                onOpen: () => _open(context, documents[index]),
                              ),
                            ),
                          ],
                        ],
                      )
                    else
                      Column(
                        children: [
                          for (final document in documents) ...[
                            _DocumentCard(
                              document: document,
                              onOpen: () => _open(context, document),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _open(BuildContext context, _DemoDocument demo) {
    final readerDocument = ReaderDocument(
      id: demo.id,
      format: demo.format,
      title: demo.title,
      author: demo.author,
      loadBytes: () => _loadAsset(demo.assetPath),
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PapyrusReader(
          document: readerDocument,
          initialLocator: memory.locatorFor(demo.id),
          initialPreferences: memory.preferencesFor(demo.id),
          onBack: () => Navigator.of(context).pop(),
          onLocatorChanged: (locator) => memory.saveLocator(demo.id, locator),
          onPreferencesChanged: (updated) =>
              memory.savePreferences(demo.id, updated),
        ),
      ),
    );
  }

  Future<Uint8List> _loadAsset(String path) async {
    final data = await rootBundle.load(path);

    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

final class DemoReaderMemory {
  final Map<String, ReaderLocator> _locators = {};
  final Map<String, ReaderPreferences> _preferences = {};

  ReaderLocator? locatorFor(String documentId) => _locators[documentId];

  ReaderPreferences? preferencesFor(String documentId) {
    return _preferences[documentId];
  }

  void saveLocator(String documentId, ReaderLocator locator) {
    _locators[documentId] = locator;
  }

  void savePreferences(String documentId, ReaderPreferences preferences) {
    _preferences[documentId] = preferences;
  }
}

final class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.document, required this.onOpen});

  final _DemoDocument document;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: colors.secondaryContainer,
              foregroundColor: colors.onSecondaryContainer,
              child: Icon(document.icon, size: 28),
            ),
            const SizedBox(height: 24),
            Text(
              document.title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              document.author,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: colors.primary),
            ),
            const SizedBox(height: 12),
            Text(document.description),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(document.actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _DemoDocument {
  const _DemoDocument({
    required this.id,
    required this.title,
    required this.author,
    required this.description,
    required this.format,
    required this.assetPath,
    required this.icon,
    required this.actionLabel,
  });

  final String id;
  final String title;
  final String author;
  final String description;
  final ReaderFormat format;
  final String assetPath;
  final IconData icon;
  final String actionLabel;
}
