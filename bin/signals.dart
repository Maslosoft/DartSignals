import 'dart:io';

import 'package:args/args.dart';
import 'package:maslosoft_signals/builder.dart';

/// Builds a typed signal definition from source annotations.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addMultiOption('path',
        abbr: 'p', help: 'Source file or directory (repeatable; default: lib).')
    ..addOption('output',
        abbr: 'o',
        defaultsTo: 'lib/signals_definition.dart',
        help: 'Generated Dart definition path.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag('version', negatable: false, help: 'Print the package version.');
  try {
    final options = parser.parse(arguments);
    if (options['version'] as bool) {
      stdout.writeln('maslosoft_signals 0.1.0');
      return;
    }
    if (options['help'] as bool || options.rest.isEmpty) {
      stdout.writeln(
          'Usage: dart run maslosoft_signals:signals <build|preview> [options]');
      stdout.writeln(parser.usage);
      return;
    }
    if (options.rest.length != 1 ||
        !const ['build', 'preview'].contains(options.rest.single)) {
      throw FormatException('Expected the command build or preview.');
    }
    final paths = options['path'] as List<String>;
    final preview = options.rest.single == 'preview';
    final result = await SignalsBuilder(
      paths: paths.isEmpty ? const ['lib'] : paths,
      output: options['output'] as String,
    ).build(write: !preview);
    if (preview) {
      stdout.write(result.source);
    } else {
      stdout.writeln('Generated ${result.outputPath} '
          '(${result.registrationCount} registrations from '
          '${result.scannedPaths.length} files).');
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Use --help for usage.');
    exitCode = 64;
  } on SignalsBuildException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 74;
  }
}
