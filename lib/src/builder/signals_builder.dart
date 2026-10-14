import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

/// An actionable error in a signal annotation or injection declaration.
class SignalsBuildException implements Exception {
  /// Creates a build failure with a human-readable [message].
  const SignalsBuildException(this.message);

  /// The declaration and the reason code generation cannot continue.
  final String message;

  @override
  String toString() => 'SignalsBuildException: $message';
}

/// The generated definition and the source files examined during discovery.
class SignalsBuildResult {
  SignalsBuildResult._({
    required this.source,
    required this.outputPath,
    required List<String> scannedPaths,
    required this.registrationCount,
  }) : scannedPaths = List.unmodifiable(scannedPaths);

  /// Complete Dart source defining `buildSignalsDefinition()`.
  final String source;

  /// Absolute destination of the generated definition.
  final String outputPath;

  /// Absolute source paths, in deterministic order.
  final List<String> scannedPaths;

  /// Number of constructor, method, property, and provider registrations.
  final int registrationCount;
}

/// Discovers annotations with the Dart analyzer and generates typed callbacks.
///
/// Generation requires `dart pub get` in the target project. The resulting
/// definition has no dependency on the analyzer or runtime reflection.
class SignalsBuilder {
  /// Configures source roots and the generated file, relative to [packageRoot].
  SignalsBuilder({
    Iterable<String> paths = const ['lib'],
    this.output = 'lib/signals_definition.dart',
    String? packageRoot,
    Iterable<String> ignoreDirectories = const [
      'build',
      'generated',
      'runtime',
      'vendor',
      'node_modules',
    ],
  })  : paths = List.unmodifiable(paths),
        packageRoot = Directory(packageRoot ?? Directory.current.path)
            .resolveSymbolicLinksSync(),
        ignoreDirectories = Set.unmodifiable(ignoreDirectories);

  /// Directories or individual Dart files to scan.
  final List<String> paths;

  /// Destination relative to [packageRoot], or an absolute path.
  final String output;

  /// Absolute project root containing `.dart_tool/package_config.json`.
  final String packageRoot;

  /// Directory names omitted during source discovery; hidden paths are omitted.
  final Set<String> ignoreDirectories;

  /// Generates a definition, writing it unless [write] is false.
  Future<SignalsBuildResult> build({bool write = true}) async {
    final outputPath = p.normalize(p.absolute(packageRoot, output));
    if (write) _checkOutput(outputPath);
    final files = _sourceFiles(outputPath);
    if (!File(p.join(packageRoot, '.dart_tool', 'package_config.json'))
        .existsSync()) {
      throw const SignalsBuildException(
        'Package configuration is missing. Run dart pub get before building.',
      );
    }
    if (files.isEmpty) {
      return _finish(_emptySource, outputPath, files, 0, write);
    }

    final collection = AnalysisContextCollection(includedPaths: files);
    try {
      final classes = <String, ClassElement2>{};
      final session = collection.contextFor(files.first).currentSession;
      final runtime = await session.getLibraryByUri(
        'package:maslosoft_signals/maslosoft_signals.dart',
      );
      if (runtime is! LibraryElementResult) {
        throw const SignalsBuildException(
          'Cannot resolve package:maslosoft_signals/maslosoft_signals.dart. '
          'Add maslosoft_signals to pubspec.yaml and run dart pub get.',
        );
      }
      final slotFor = runtime.element2.exportNamespace.get2('SlotFor');
      final signalFor = runtime.element2.exportNamespace.get2('SignalFor');
      if (slotFor is! ClassElement2 || signalFor is! ClassElement2) {
        throw const SignalsBuildException(
          'The maslosoft_signals library must export SlotFor and SignalFor.',
        );
      }
      for (final file in files) {
        final result = await collection
            .contextFor(file)
            .currentSession
            .getResolvedUnit(file);
        if (result is! ResolvedUnitResult) {
          throw SignalsBuildException('Cannot analyze $file: $result');
        }
        final errors = result.errors.where(
          (error) =>
              error.errorCode.errorSeverity == ErrorSeverity.ERROR &&
              !_isBootstrapError(error, result, outputPath),
        );
        if (errors.isNotEmpty) {
          final messages = errors.map((error) {
            final location = result.lineInfo.getLocation(error.offset);
            return '$file:${location.lineNumber}:${location.columnNumber}: '
                '${error.message}';
          }).join('\n');
          throw SignalsBuildException(
              'Fix source errors before generation:\n$messages');
        }
        _validateAnnotationPlacement(
            result.libraryElement2, slotFor, signalFor);
        for (final element in result.libraryElement2.classes) {
          classes[_classKey(element)] = element;
        }
      }

      final registrations = <String, _Registration>{};
      final signals = <String, ClassElement2>{};
      final ordered = classes.values.toList()
        ..sort((a, b) => _classKey(a).compareTo(_classKey(b)));
      for (final receiver in ordered) {
        if (receiver.isPrivate || receiver.isAbstract) continue;
        final hierarchy = <InterfaceElement2>[
          receiver,
          ...receiver.allSupertypes.map((type) => type.element3),
        ];

        for (final ancestor in hierarchy) {
          for (final annotation in _annotations(ancestor, signalFor)) {
            _requireConcretePublicClass(receiver, 'SignalFor provider');
            _requireZeroArgumentConstructor(receiver, receiver);
            for (final target
                in await _targets(annotation, receiver, session)) {
              final registration = _Registration('provider', receiver, target);
              registrations[registration.key] = registration;
              signals[_classKey(receiver)] = receiver;
            }
          }
        }

        for (final ancestor in hierarchy) {
          for (final annotation in _annotations(ancestor, slotFor)) {
            final constructor = receiver.unnamedConstructor2;
            if (constructor == null) {
              _fail(receiver,
                  'Class-level SlotFor requires an unnamed constructor.');
            }
            await _addInjection(
              registrations,
              signals,
              receiver,
              constructor,
              annotation,
              'constructor',
              '',
              session,
            );
          }
        }
        for (final constructor in receiver.constructors2) {
          for (final annotation in _annotations(constructor, slotFor)) {
            await _addInjection(
              registrations,
              signals,
              receiver,
              constructor,
              annotation,
              'constructor',
              constructor.name3 == 'new' ? '' : constructor.name3!,
              session,
            );
          }
        }
        for (final ancestor in hierarchy) {
          for (final method in ancestor.methods2) {
            for (final annotation in _annotations(method, slotFor)) {
              final effective = receiver.lookUpMethod2(
                name: method.displayName,
                library: receiver.library2,
              );
              await _addInjection(
                registrations,
                signals,
                receiver,
                effective ?? method,
                annotation,
                'method',
                method.displayName,
                session,
              );
            }
          }
          for (final field in ancestor.fields2) {
            if (field.isSynthetic) continue;
            for (final annotation in _annotations(field, slotFor)) {
              final setter = receiver.lookUpSetter2(
                name: field.displayName,
                library: receiver.library2,
              );
              if (field.isStatic || field.isPrivate || setter == null) {
                _fail(field,
                    'SlotFor requires a public writable instance field.');
              }
              await _addInjection(
                registrations,
                signals,
                receiver,
                setter,
                annotation,
                'property',
                field.displayName,
                session,
              );
            }
          }
          for (final accessor in [...ancestor.getters2, ...ancestor.setters2]) {
            if (accessor.isSynthetic) continue;
            for (final annotation in _annotations(accessor, slotFor)) {
              if (accessor is! SetterElement) {
                _fail(accessor,
                    'Place SlotFor on a writable field or setter, not a getter.');
              }
              final name = accessor.displayName;
              final effective = receiver.lookUpSetter2(
                name: name,
                library: receiver.library2,
              );
              await _addInjection(
                registrations,
                signals,
                receiver,
                effective ?? accessor,
                annotation,
                'property',
                name,
                session,
              );
            }
          }
        }
      }
      final sorted = registrations.values.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final source = _render(signals.values, sorted, outputPath);
      return _finish(source, outputPath, files, sorted.length, write);
    } finally {
      await collection.dispose();
    }
  }

  List<String> _sourceFiles(String outputPath) {
    final files = <String>{};
    void visit(String path) {
      final kind = FileSystemEntity.typeSync(path, followLinks: false);
      if (kind == FileSystemEntityType.directory) {
        for (final entry in Directory(path).listSync(followLinks: false)) {
          final name = p.basename(entry.path);
          if (name.startsWith('.') || ignoreDirectories.contains(name)) {
            continue;
          }
          visit(entry.path);
        }
      } else if (kind == FileSystemEntityType.file &&
          path.endsWith('.dart') &&
          path != outputPath &&
          !path.endsWith('.g.dart') &&
          !path.endsWith('.freezed.dart')) {
        files.add(path);
      }
    }

    for (final path in paths) {
      final resolved = p.normalize(p.absolute(packageRoot, path));
      if (!FileSystemEntity.isDirectorySync(resolved) &&
          !FileSystemEntity.isFileSync(resolved)) {
        throw SignalsBuildException('Source path does not exist: $resolved');
      }
      visit(resolved);
    }
    return files.toList()..sort();
  }

  Iterable<DartObject> _annotations(
      Element2 element, ClassElement2 marker) sync* {
    if (element is! Annotatable) return;
    for (final metadata in (element as Annotatable).metadata2.annotations) {
      final value = metadata.computeConstantValue();
      final type = value?.type;
      if (type is InterfaceType &&
          _classKey(type.element3) == _classKey(marker)) {
        yield value!;
      }
    }
  }

  // A source may import its generated definition before the first build. Ignore
  // only that missing import and calls to the function this builder supplies.
  bool _isBootstrapError(
    AnalysisError error,
    ResolvedUnitResult result,
    String outputPath,
  ) {
    if (File(outputPath).existsSync()) return false;
    final imports = result.unit.directives.whereType<ImportDirective>().where(
      (directive) {
        final value = directive.uri.stringValue;
        if (value == null) return false;
        final uri = Uri.parse(value);
        final target = uri.hasScheme
            ? result.session.uriConverter.uriToPath(uri)
            : p.normalize(p.join(p.dirname(result.path), uri.toFilePath()));
        return target == outputPath;
      },
    ).toList();
    if (imports.isEmpty) return false;
    if (error.errorCode.name == 'URI_DOES_NOT_EXIST') {
      return imports.any((directive) =>
          error.offset >= directive.uri.offset &&
          error.offset < directive.uri.end);
    }
    if (error.errorCode.name != 'UNDEFINED_FUNCTION' &&
        error.errorCode.name != 'UNDEFINED_METHOD') {
      return false;
    }
    final node = _nodeAt(result.unit, error.offset);
    final invocation = node.parent;
    if (invocation is! MethodInvocation ||
        invocation.methodName.name != 'buildSignalsDefinition') {
      return false;
    }
    final target = invocation.target;
    return imports.any(
      (directive) =>
          (target == null && directive.prefix == null) ||
          (target is SimpleIdentifier && target.name == directive.prefix?.name),
    );
  }

  AstNode _nodeAt(AstNode node, int offset) {
    for (final child in node.childEntities.whereType<AstNode>()) {
      if (child.offset <= offset && offset < child.end) {
        return _nodeAt(child, offset);
      }
    }
    return node;
  }

  void _validateAnnotationPlacement(
    Element2 element,
    ClassElement2 slotFor,
    ClassElement2 signalFor,
  ) {
    if (element is ClassElement2 && element.isPrivate) return;
    if (!element.isSynthetic) {
      final canProvide = element is ClassElement2 || element is MixinElement2;
      if (!canProvide && _annotations(element, signalFor).isNotEmpty) {
        _fail(element, 'SignalFor belongs on a class or mixin.');
      }
      final canReceive = canProvide ||
          element is ConstructorElement2 ||
          element is MethodElement2 ||
          element is FieldElement2 ||
          element is SetterElement ||
          element is GetterElement;
      if (!canReceive && _annotations(element, slotFor).isNotEmpty) {
        _fail(element,
            'SlotFor belongs on a receiver class, constructor, method, field, or setter.');
      }
    }
    for (final child in element.children2) {
      _validateAnnotationPlacement(child, slotFor, signalFor);
    }
  }

  Future<List<ClassElement2>> _targets(
    DartObject annotation,
    Element2 owner,
    AnalysisSession session,
  ) async {
    final raw = annotation.getField('targets');
    if (raw == null) _fail(owner, 'The annotation has no targets.');
    final values = raw.toListValue() ?? [raw];
    if (values.isEmpty) {
      _fail(owner, 'At least one annotation target is required.');
    }
    final targets = <ClassElement2>[];
    for (final value in values) {
      final type = value.toTypeValue();
      ClassElement2? target;
      if (type is InterfaceType && type.element3 is ClassElement2) {
        target = type.element3 as ClassElement2;
      } else {
        final name = value.toStringValue();
        if (name == null || !name.contains('#')) {
          _fail(owner,
              'Targets must be class types or canonical "package:app/file.dart#Class" strings.');
        }
        final delimiter = name.lastIndexOf('#');
        final uri = name.substring(0, delimiter);
        final className = name.substring(delimiter + 1);
        if (!uri.startsWith('package:') || className.isEmpty) {
          _fail(owner,
              'Invalid target "$name"; use "package:app/file.dart#Class".');
        }
        final library = await session.getLibraryByUri(uri);
        if (library is LibraryElementResult) {
          final element = library.element2.exportNamespace.get2(className);
          if (element is ClassElement2) target = element;
        }
        if (target == null) _fail(owner, 'Cannot resolve target "$name".');
      }
      if (target.isPrivate || target.typeParameters2.isNotEmpty) {
        _fail(owner,
            'Target ${target.displayName} must be a public, non-generic class.');
      }
      targets.add(target);
    }
    return targets;
  }

  Future<void> _addInjection(
    Map<String, _Registration> registrations,
    Map<String, ClassElement2> signals,
    ClassElement2 receiver,
    ExecutableElement2 member,
    DartObject annotation,
    String kind,
    String name,
    AnalysisSession session,
  ) async {
    _requireConcretePublicClass(receiver, 'SlotFor receiver');
    if (member.isPrivate || member.isStatic || member.isAbstract) {
      _fail(member, 'SlotFor requires a public concrete instance member.');
    }
    if (kind != 'constructor') {
      _requireZeroArgumentConstructor(receiver, member);
    }
    if (member.firstFragment.isAsynchronous ||
        member.firstFragment.isGenerator ||
        member.returnType.isDartAsyncFuture ||
        member.returnType.isDartAsyncFutureOr ||
        member.returnType.isDartAsyncStream) {
      _fail(member, 'SlotFor handlers must be synchronous.');
    }
    if (member.typeParameters2.isNotEmpty) {
      _fail(member, 'Generic SlotFor handlers are not supported.');
    }
    final positional =
        member.formalParameters.where((p) => p.isPositional).toList();
    if (positional.isEmpty ||
        positional.skip(1).any((p) => p.isRequiredPositional) ||
        member.formalParameters.any((p) => p.isRequiredNamed)) {
      _fail(member,
          'Injection requires one positional signal argument and no other required arguments.');
    }
    for (final target in await _targets(annotation, member, session)) {
      if (!receiver.library2.typeSystem.isAssignableTo(
        target.thisType,
        positional.first.type,
      )) {
        _fail(member,
            '${target.displayName} cannot be passed to parameter ${positional.first.displayName} (${positional.first.type}).');
      }
      final registration = _Registration(kind, target, receiver, name);
      registrations[registration.key] = registration;
      signals[_classKey(target)] = target;
    }
  }

  void _requireConcretePublicClass(ClassElement2 type, String role) {
    if (type.typeParameters2.isNotEmpty) {
      _fail(type, '$role must be non-generic; use a concrete subclass.');
    }
  }

  void _requireZeroArgumentConstructor(ClassElement2 type, Element2 owner) {
    if (!_hasZeroArgumentConstructor(type)) {
      _fail(owner,
          '${type.displayName} needs a public unnamed constructor callable with no arguments.');
    }
  }

  bool _hasZeroArgumentConstructor(ClassElement2 type) =>
      !type.isAbstract &&
      type.unnamedConstructor2 != null &&
      !type.unnamedConstructor2!.formalParameters.any((p) => p.isRequired);

  Never _fail(Element2 owner, String message) => throw SignalsBuildException(
        '${owner.firstFragment.libraryFragment?.source.fullName}: '
        '${owner.displayName}: $message',
      );

  String _render(
    Iterable<ClassElement2> signals,
    List<_Registration> registrations,
    String outputPath,
  ) {
    final types = <String, ClassElement2>{};
    for (final signal in signals) {
      types[_classKey(signal)] = signal;
    }
    for (final registration in registrations) {
      types[_classKey(registration.signal)] = registration.signal;
      types[_classKey(registration.receiver)] = registration.receiver;
    }
    String importFor(ClassElement2 type) {
      final uri = type.library2.firstFragment.source.uri;
      if (uri.scheme == 'dart' ||
          (uri.scheme == 'package' &&
              !p.isWithin(
                  packageRoot, type.library2.firstFragment.source.fullName))) {
        return uri.toString();
      }
      return p
          .relative(type.library2.firstFragment.source.fullName,
              from: p.dirname(outputPath))
          .split(p.separator)
          .join('/');
    }

    final imports = types.values.map(importFor).toSet().toList()..sort();
    final prefixes = <String, String>{
      for (var index = 0; index < imports.length; index++)
        imports[index]: 'i$index',
    };
    String ref(ClassElement2 type) =>
        '${prefixes[importFor(type)]}.${type.displayName}';
    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
      ..writeln(
          '// Generated by maslosoft_signals. Rebuild after annotation changes.')
      ..writeln()
      ..writeln("import 'package:maslosoft_signals/maslosoft_signals.dart';");
    for (final uri in imports) {
      buffer.writeln('import ${_literal(uri)} as ${prefixes[uri]};');
    }
    buffer
      ..writeln()
      ..writeln(
          '/// Creates the signal relations discovered in the source files.')
      ..writeln('SignalDefinition buildSignalsDefinition() {')
      ..writeln('  final definition = SignalDefinition();');
    final orderedSignals = signals.toList()
      ..sort((a, b) => _classKey(a).compareTo(_classKey(b)));
    for (final signal in orderedSignals) {
      final type = ref(signal);
      final arguments =
          _hasZeroArgumentConstructor(signal) ? 'create: () => $type()' : '';
      buffer.writeln('  definition.registerSignal<$type>($arguments);');
    }
    for (final registration in registrations) {
      final signal = ref(registration.signal);
      final receiver = ref(registration.receiver);
      final name = registration.name;
      final quoted = _literal(name);
      switch (registration.kind) {
        case 'constructor':
          final constructor = name.isEmpty ? receiver : '$receiver.$name';
          buffer
              .writeln('  definition.registerConstructor<$signal, $receiver>(');
          buffer
              .writeln('    (signal) => $constructor(signal), name: $quoted,');
        case 'method':
          buffer.writeln('  definition.registerMethod<$signal, $receiver>(');
          buffer.writeln(
              '    () => $receiver(), (slot, signal) { slot.$name(signal); }, name: $quoted,');
        case 'property':
          buffer.writeln('  definition.registerProperty<$signal, $receiver>(');
          buffer.writeln(
              '    () => $receiver(), (slot, signal) { slot.$name = signal; }, name: $quoted,');
        case 'provider':
          buffer.writeln('  definition.registerProvider<$signal>(');
          buffer.writeln('    $receiver, () => $signal(),');
      }
      buffer.writeln('  );');
    }
    buffer
      ..writeln('  return definition;')
      ..writeln('}');
    return buffer.toString();
  }

  SignalsBuildResult _finish(String source, String outputPath,
      List<String> files, int count, bool write) {
    if (write) {
      _checkOutput(outputPath);
      final file = File(outputPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(source);
    }
    return SignalsBuildResult._(
      source: source,
      outputPath: outputPath,
      scannedPaths: files,
      registrationCount: count,
    );
  }

  void _checkOutput(String outputPath) {
    final file = File(outputPath);
    if (file.existsSync() &&
        !file.readAsStringSync().startsWith(
              '// GENERATED CODE - DO NOT MODIFY BY HAND.\n'
              '// Generated by maslosoft_signals.',
            )) {
      throw SignalsBuildException(
        'Refusing to overwrite a file not generated by maslosoft_signals: '
        '$outputPath. Choose a different --output path.',
      );
    }
  }
}

String _classKey(InterfaceElement2 element) =>
    '${element.library2.firstFragment.source.fullName}#${element.displayName}';

String _literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

class _Registration {
  const _Registration(this.kind, this.signal, this.receiver, [this.name = '']);
  final String kind;
  final ClassElement2 signal;
  final ClassElement2 receiver;
  final String name;
  String get key => '${_classKey(signal)}|${_classKey(receiver)}|$kind|$name';
}

const _emptySource = '''// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated by maslosoft_signals. Rebuild after annotation changes.

import 'package:maslosoft_signals/maslosoft_signals.dart';

/// Creates an empty definition; no annotated classes were discovered.
SignalDefinition buildSignalsDefinition() => SignalDefinition();
''';
