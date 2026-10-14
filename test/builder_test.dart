import 'dart:convert';
import 'dart:io';

import 'package:maslosoft_signals/builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Directory.current.resolveSymbolicLinksSync();

  test('generates all injection kinds and inherited provider relations',
      () async {
    final result = await SignalsBuilder(
      packageRoot: root,
      paths: const ['test/fixtures/builder/models.dart'],
      output: 'test/fixtures/builder/signals_definition.dart',
    ).build(write: false);

    expect(result.registrationCount, 9);
    expect(result.scannedPaths, hasLength(1));
    expect(result.source,
        contains('registerConstructor<i0.Event, i0.ConstructorReceiver>'));
    expect(result.source, contains('i0.NamedReceiver.receive(signal)'));
    expect(
        result.source, contains('registerMethod<i0.Event, i0.MethodReceiver>'));
    expect(result.source,
        contains('registerMethod<i0.OtherEvent, i0.MethodReceiver>'));
    expect(result.source, contains('slot.event = signal;'));
    expect(result.source, contains('registerProvider<i0.Provider>'));
    expect(result.source, contains('registerProvider<i0.DirectProvider>'));
    expect(result.source, isNot(contains('_PrivateProvider')));
    expect(result.source,
        isNot(contains('registerProvider<i0.ProviderInterface>')));
  });

  test('writes compilable definitions and keeps preview free of writes',
      () async {
    final fixture = _ProjectFixture(root);
    addTearDown(fixture.dispose);
    final models =
        File(p.join(root, 'test', 'fixtures', 'builder', 'models.dart'))
            .readAsStringSync();
    fixture.write('''
$models
@SlotFor('package:builder_fixture/models.dart#Event')
class CanonicalReceiver {
  CanonicalReceiver(Event event) { event.handledBy.add('canonical'); }
}
''');
    final preview = await fixture.builder.build(write: false);
    expect(File(preview.outputPath).existsSync(), isFalse);
    final written = await fixture.builder.build();
    expect(File(written.outputPath).readAsStringSync(), preview.source);
    File(p.join(fixture.root.path, 'bin', 'check.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:maslosoft_signals/maslosoft_signals.dart';
import '../lib/models.dart';
import '../lib/signals_definition.dart';
void main() {
  final signals = Signal(definition: buildSignalsDefinition());
  final original = Event();
  final result = signals.emit(original);
  if (result.length != 7) throw StateError('Wrong receiver count: \${result.length}');
  if (original.handledBy.isNotEmpty) throw StateError('Modified original');
  final handled = result.expand((event) => event.handledBy).toList()..sort();
  if (handled.join(',') != 'canonical,constructor,inherited constructor,method,named,setter') {
    throw StateError('Wrong dispatch results: \$handled');
  }
  if (signals.emit(OtherEvent()).length != 1) throw StateError('Second target lost');
  if (signals.gather(ProviderSlot()).length != 2) throw StateError('Gather failed');
  if (signals.gather<Provider>(ProviderSlot()).length != 1) throw StateError('Filter failed');
}
''');
    final process = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=${p.join(fixture.root.path, '.dart_tool', 'package_config.json')}',
        'bin/check.dart'
      ],
      workingDirectory: fixture.root.path,
    );
    expect(process.exitCode, 0, reason: '${process.stdout}\n${process.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('ignores annotations from unrelated libraries', () async {
    final fixture = _ProjectFixture(root);
    addTearDown(fixture.dispose);
    fixture.write('''
class SlotFor { const SlotFor(Object target); }
class Event {}
@SlotFor(Event)
class Receiver { Receiver(); }
''');
    final result = await fixture.builder.build(write: false);
    expect(result.registrationCount, 0);
  });

  test('refuses to overwrite an existing source file', () async {
    final fixture = _ProjectFixture(root);
    addTearDown(fixture.dispose);
    const source = 'class ApplicationModel {}\n';
    fixture.write(source);
    final builder = SignalsBuilder(
      packageRoot: fixture.root.path,
      output: 'lib/models.dart',
    );
    await expectLater(
        builder.build(),
        throwsA(isA<SignalsBuildException>().having(
          (error) => error.message,
          'message',
          contains('Refusing to overwrite'),
        )));
    expect(
        File(p.join(fixture.root.path, 'lib', 'models.dart'))
            .readAsStringSync(),
        source);
  });

  for (final prefix in ['', 'definitions.']) {
    test('bootstraps missing output import with "$prefix" prefix', () async {
      final fixture = _ProjectFixture(root);
      addTearDown(fixture.dispose);
      fixture.write('''
import 'package:maslosoft_signals/maslosoft_signals.dart';
import 'signals_definition.dart'${prefix.isEmpty ? '' : ' as definitions'};
class Slot {}
@SignalFor(Slot)
class Provider {}
Signal createSignals() => Signal(definition: ${prefix}buildSignalsDefinition());
void main() {
  if (createSignals().gather<Provider>(Slot()).length != 1) {
    throw StateError('Generated provider was not registered.');
  }
}
''');
      final result = await fixture.builder.build();
      expect(result.registrationCount, 1);
      final check = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${p.join(fixture.root.path, '.dart_tool', 'package_config.json')}',
          'lib/models.dart',
        ],
        workingDirectory: fixture.root.path,
      );
      expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
    });
  }

  test('discovers part declarations once and imports their containing library',
      () async {
    final fixture = _ProjectFixture(root);
    addTearDown(fixture.dispose);
    fixture.write('''
import 'package:maslosoft_signals/maslosoft_signals.dart';
part 'provider.dart';
class Slot {}
''');
    File(p.join(fixture.root.path, 'lib', 'provider.dart'))
        .writeAsStringSync('''
part of 'models.dart';
@SignalFor(Slot)
class Provider {}
''');
    final result = await fixture.builder.build(write: false);
    expect(result.registrationCount, 1);
    expect(result.source, contains('import "models.dart" as i0;'));
    expect(result.source, isNot(contains('import "provider.dart"')));
  });

  final invalid = <String, (String, String)>{
    'asynchronous methods': (
      '''
class Receiver {
  @SlotFor(Event)
  Future<void> handle(Event event) async {}
}
''',
      'must be synchronous'
    ),
    'final properties': (
      '''
class Receiver {
  @SlotFor(Event)
  final Event event = Event();
}
''',
      'writable instance field'
    ),
    'required receiver arguments': (
      '''
class Receiver {
  Receiver(String requiredValue);
  @SlotFor(Event)
  void handle(Event event) {}
}
''',
      'constructor callable with no arguments'
    ),
    'incompatible signal parameters': (
      '''
class Receiver {
  @SlotFor(Event)
  void handle(String event) {}
}
''',
      'cannot be passed'
    ),
    'unknown string targets': (
      '''
@SlotFor('package:builder_fixture/models.dart#Missing')
class Receiver { Receiver(Object event); }
''',
      'Cannot resolve target'
    ),
    'unknown type targets': (
      '''
@SlotFor(Missing)
class Receiver { Receiver(Object event); }
''',
      'Fix source errors'
    ),
    'misplaced provider annotations': (
      '''
class Receiver {
  @SignalFor(Event)
  void method() {}
}
''',
      'SignalFor belongs on a class'
    ),
    'top-level receiver annotations': (
      '''
@SlotFor(Event)
void receive(Event event) {}
''',
      'SlotFor belongs on a receiver class'
    ),
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} with an actionable message', () async {
      final fixture = _ProjectFixture(root);
      addTearDown(fixture.dispose);
      fixture.write('''
import 'package:maslosoft_signals/maslosoft_signals.dart';
class Event {}
${entry.value.$1}
''');
      await expectLater(
        fixture.builder.build(write: false),
        throwsA(isA<SignalsBuildException>().having(
          (error) => error.message,
          'message',
          contains(entry.value.$2),
        )),
      );
    });
  }

  test(
      'reports unrelated missing imports rather than silently losing annotations',
      () async {
    final fixture = _ProjectFixture(root);
    addTearDown(fixture.dispose);
    fixture.write("import 'missing.dart';\n");
    await expectLater(
        fixture.builder.build(write: false),
        throwsA(isA<SignalsBuildException>().having(
          (error) => error.message,
          'message',
          contains('missing.dart'),
        )));
  });
}

class _ProjectFixture {
  _ProjectFixture(String packageRoot)
      : root = Directory.systemTemp.createTempSync('signals_builder_test_') {
    final original =
        File(p.join(packageRoot, '.dart_tool', 'package_config.json'));
    final configuration =
        jsonDecode(original.readAsStringSync()) as Map<String, dynamic>;
    final packages = configuration['packages'] as List<dynamic>;
    for (final entry in packages.cast<Map<String, dynamic>>()) {
      entry['rootUri'] =
          original.uri.resolve(entry['rootUri'] as String).toString();
    }
    packages.add({
      'name': 'builder_fixture',
      'rootUri': root.uri.toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.6',
    });
    File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(configuration));
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: builder_fixture
environment:
  sdk: '>=3.6.0 <4.0.0'
''');
  }

  final Directory root;

  SignalsBuilder get builder => SignalsBuilder(packageRoot: root.path);

  void write(String source) => File(p.join(root.path, 'lib', 'models.dart'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);

  void dispose() => root.deleteSync(recursive: true);
}
