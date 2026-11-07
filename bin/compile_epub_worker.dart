import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Flutter asset transformer, using the host application's package resolution.
Future<void> main(List<String> arguments) async {
  final options = {
    for (final argument in arguments)
      if (argument.startsWith('--') && argument.contains('='))
        argument.substring(2, argument.indexOf('=')): argument.substring(
          argument.indexOf('=') + 1,
        ),
  };
  final input = options['input'];
  final output = options['output'];
  final config = await Isolate.packageConfig;

  if (input == null || output == null || config == null) {
    stderr.writeln(
      'Expected --input=MANIFEST --output=WORKER and a package config.',
    );
    exitCode = 64;
    return;
  }

  final temporary = await Directory.systemTemp.createTemp(
    'papyrus-epub-worker-',
  );

  try {
    final packageConfig =
        jsonDecode(await File.fromUri(config).readAsString())
            as Map<String, dynamic>;
    final packages =
        (packageConfig['packages'] as List).cast<Map<String, dynamic>>()..sort(
          (left, right) =>
              (left['name'] as String).compareTo(right['name'] as String),
        );
    final reader = packages.singleWhere(
      (package) => package['name'] == 'papyrus_reader',
    );
    final root = Directory.fromUri(
      config.resolve(reader['rootUri'] as String),
    ).uri;
    final entrypoint = root.resolve((await File(input).readAsString()).trim());
    final compiled = File('${temporary.path}/worker.js');
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      '-O2',
      '--no-source-maps',
      '--packages=${config.toFilePath()}',
      '-o',
      compiled.path,
      entrypoint.toFilePath(),
    ]);

    if (result.exitCode != 0) {
      stderr.write(result.stdout);
      stderr.write(result.stderr);
      exitCode = result.exitCode;
      return;
    }

    final dependencies = (await File(
      '${compiled.path}.deps',
    ).readAsLines()).where((line) => line.isNotEmpty).map(Uri.parse).toList();
    final inputs = <Uri>{
      config,
      ...dependencies.where((uri) => uri.scheme == 'file'),
    };
    final notices = StringBuffer('Licenses for the compiled EPUB worker.\n');

    for (final package in packages) {
      final root = Directory.fromUri(
        config.resolve(package['rootUri'] as String),
      ).uri;
      final library = root.resolve(package['packageUri'] as String? ?? 'lib/');

      if (!dependencies.any(
        (uri) => uri.toString().startsWith(library.toString()),
      )) {
        continue;
      }

      final manifestUri = root.resolve('pubspec.yaml');
      inputs.add(manifestUri);

      if (package['name'] == 'papyrus_reader') {
        inputs.add(root.resolve('bin/compile_epub_worker.dart'));
      }

      final manifest = await File.fromUri(manifestUri).readAsString();
      final version = RegExp(
        r'^version:\s*(.+)$',
        multiLine: true,
      ).firstMatch(manifest)?.group(1)?.trim();
      notices.writeln(
        '\n${package['name']}${version == null ? '' : ' $version'}',
      );
      final licenses = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING']
          .map((name) => File.fromUri(root.resolve(name)))
          .where((file) => file.existsSync());

      if (licenses.isEmpty) {
        throw StateError('No license file found for ${package['name']}.');
      }

      for (final license in licenses) {
        inputs.add(license.uri);
        notices.writeln(await license.readAsString());
      }
    }

    final sdkLicense = File.fromUri(
      File(Platform.resolvedExecutable).uri.resolve('../LICENSE'),
    );
    inputs.add(sdkLicense.uri);
    notices.writeln('\nDart SDK\n${await sdkLicense.readAsString()}');
    final destination = File(output);
    await destination.parent.create(recursive: true);
    await destination.writeAsString(
      '${await compiled.readAsString()}\n'
      '${const LineSplitter().convert(notices.toString()).map((line) => '// $line').join('\n')}\n',
    );
    // Flutter consumes this companion depfile to invalidate transformed assets.
    await File('$output.d').writeAsString(
      '${escapeDepfilePath(destination.absolute.path)}: '
      '${inputs.map((uri) => escapeDepfilePath(uri.toFilePath())).join(' ')}\n',
    );
  } finally {
    await temporary.delete(recursive: true);
  }
}

String escapeDepfilePath(String path) =>
    path.replaceAll(r'\', r'\\').replaceAll(' ', r'\ ');
