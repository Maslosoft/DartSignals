import 'package:maslosoft_signals/maslosoft_signals.dart';
import 'package:test/test.dart';

void main() {
  group('emit', () {
    test('returns a modified clone for every injection, preserving the input',
        () {
      final definition = SignalDefinition();
      var instances = 0;
      definition.registerConstructor<_Message, _Receiver>((message) {
        instances++;
        message.values.add('constructor');
        return _Receiver();
      });
      definition.registerMethod<_Message, _Receiver>(
        () {
          instances++;
          return _Receiver();
        },
        (receiver, message) => message.values.add('method'),
        name: 'receive',
      );
      definition.registerProperty<_Message, _Receiver>(
        () {
          instances++;
          return _Receiver();
        },
        (receiver, message) => receiver.message = message,
        name: 'message',
      );

      final original = _Message(['original']);
      final result = Signal(definition: definition).emit(original);

      expect(instances, 3);
      expect(original.values, ['original']);
      expect(result.map((message) => message.values), [
        ['original', 'constructor'],
        ['original', 'method'],
        ['original', 'property'],
      ]);
      expect(result.every((message) => !identical(message, original)), isTrue);
      expect(identical(result[0], result[1]), isFalse);
      expect(identical(result[1], result[2]), isFalse);
      expect(result.toList(), result.toList());
    });

    test('constructs a new receiver for every method and every emission', () {
      final receivers = <_Receiver>[];
      final definition = SignalDefinition();
      for (final name in ['first', 'second']) {
        definition.registerMethod<_Message, _Receiver>(
          () {
            final receiver = _Receiver();
            receivers.add(receiver);
            return receiver;
          },
          (receiver, message) => message.values.add(name),
          name: name,
        );
      }
      final signal = Signal(definition: definition);

      expect(signal.emit(_Message()).length, 2);
      expect(signal.emit(_Message()).length, 2);
      expect(receivers.toSet(), hasLength(4));
    });

    test('dispatches only the exact runtime signal type', () {
      final signal = Signal(definition: _definition());

      expect(signal.emit(_SpecialMessage()), isEmpty);
      expect(signal.emit<_Message>(_SpecialMessage()), isEmpty);
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('an unregistered signal needs no cloning capability', () {
      expect(Signal().emit(Object()), isEmpty);
    });

    test('slot awareness runs after construction for constructor injection',
        () {
      final definition = SignalDefinition();
      _Receiver? receiver;
      definition.registerConstructor<_AwareMessage, _Receiver>((message) {
        expect(message.slot, isNull);
        message.steps.add('constructor');
        return receiver = _Receiver();
      });

      final original = _AwareMessage();
      final result = Signal(definition: definition).emit(original).single;

      expect(result.steps, ['constructor', 'setSlot']);
      expect(result.slot, same(receiver));
      expect(original.slot, isNull);
      expect(original.steps, isEmpty);
    });

    test('slot awareness precedes method and property injection', () {
      final definition = SignalDefinition();
      void inject(_Receiver receiver, _AwareMessage message) {
        expect(message.slot, same(receiver));
        expect(message.steps, ['setSlot']);
        message.steps.add('injected');
      }

      definition.registerMethod<_AwareMessage, _Receiver>(
        _Receiver.new,
        inject,
        name: 'receive',
      );
      definition.registerProperty<_AwareMessage, _Receiver>(
        _Receiver.new,
        inject,
        name: 'message',
      );

      final results = Signal(definition: definition).emit(_AwareMessage());

      expect(results, hasLength(2));
      expect(results.map((result) => result.steps), [
        ['setSlot', 'injected'],
        ['setSlot', 'injected'],
      ]);
      expect(identical(results[0].slot, results[1].slot), isFalse);
    });

    test('emitType uses its registered factory', () {
      final definition = _definition();
      var created = 0;
      definition.registerSignal<_Message>(create: () {
        created++;
        return _Message(['created']);
      });

      final results = Signal(definition: definition).emitType<_Message>();

      expect(created, 1);
      expect(results.single.values, ['created', 'received']);
    });

    test('emitType reports an unregistered factory', () {
      expect(() => Signal().emitType<_Message>(), throwsStateError);
    });
  });

  group('cloning', () {
    test('an explicit cloner takes priority over CloneableSignal', () {
      final definition = _definition();
      var cloned = 0;
      definition.registerSignal<_Message>(clone: (original) {
        cloned++;
        return _Message([...original.values, 'custom']);
      });
      final original = _Message(['original']);

      final result = Signal(definition: definition).emit(original).single;

      expect(cloned, 1);
      expect(original.values, ['original']);
      expect(result.values, ['original', 'custom', 'received']);
    });

    test('supports plain objects when an explicit cloner is registered', () {
      final definition = SignalDefinition();
      definition.registerSignal<_PlainMessage>(
        clone: (original) => _PlainMessage(original.value),
      );
      definition.registerMethod<_PlainMessage, _Receiver>(
        _Receiver.new,
        (receiver, message) => message.value++,
        name: 'receive',
      );
      final original = _PlainMessage(2);

      final result = Signal(definition: definition).emit(original).single;

      expect(original.value, 2);
      expect(result.value, 3);
    });

    test('rejects a cloner returning the original instance', () {
      final definition = _definition();
      definition.registerSignal<_Message>(clone: (original) => original);
      final original = _Message();

      expect(
        () => Signal(definition: definition).emit(original),
        throwsStateError,
      );
      expect(original.values, isEmpty);
    });

    test('rejects a cloner changing the runtime type', () {
      final definition = _definition();
      definition.registerSignal<_Message>(clone: (_) => _SpecialMessage());

      expect(
        () => Signal(definition: definition).emit(_Message()),
        throwsStateError,
      );
    });

    test('reports missing cloning support before constructing a receiver', () {
      final definition = SignalDefinition();
      var created = false;
      definition.registerConstructor<_PlainMessage, _Receiver>((message) {
        created = true;
        return _Receiver();
      });

      expect(
        () => Signal(definition: definition).emit(_PlainMessage(0)),
        throwsStateError,
      );
      expect(created, isFalse);
    });
  });

  group('filters', () {
    test('a pre-filter rejects a receiver before cloning or construction', () {
      final definition = SignalDefinition();
      var created = false;
      definition.registerConstructor<_PlainMessage, _Receiver>((message) {
        created = true;
        return _Receiver();
      });
      final original = _PlainMessage(0);
      final signal = Signal(
        definition: definition,
        filters: [
          PreCallback((target, context) {
            expect(target, _Receiver);
            expect(context, same(original));
            return false;
          }),
        ],
      );

      expect(signal.emit(original), isEmpty);
      expect(created, isFalse);
    });

    test('pre-filter runs once per receiver class, post-filter per injection',
        () {
      final definition = _definition();
      definition.registerMethod<_Message, _Receiver>(
        _Receiver.new,
        (receiver, message) => message.values.add('second'),
        name: 'second',
      );
      definition.registerConstructor<_Message, _OtherReceiver>(
        (message) => _OtherReceiver(),
      );
      final targets = <Type>[];
      final postResults = <Object>[];
      final original = _Message();
      final signal = Signal(
        definition: definition,
        filters: [
          PreCallback((target, context) {
            targets.add(target);
            expect(context, same(original));
            return true;
          }),
          PostCallback((result, context) {
            postResults.add(result);
            expect(context, same(original));
            expect(identical(result, original), isFalse);
            return true;
          }),
        ],
      );

      final result = signal.emit(original);

      expect(targets, [_Receiver, _OtherReceiver]);
      expect(postResults, result);
      expect(result, hasLength(3));
    });

    test('post-filter excludes results after receiver side effects', () {
      var calls = 0;
      final definition = SignalDefinition();
      definition.registerConstructor<_Message, _Receiver>((message) {
        calls++;
        message.values.add('handled');
        return _Receiver();
      });
      final signal = Signal(
        definition: definition,
        filters: [
          PostCallback((result, context) {
            expect((result as _Message).values, ['handled']);
            return false;
          }),
        ],
      );

      expect(signal.emit(_Message()), isEmpty);
      expect(calls, 1);
    });

    test('defaults precede temporary filters and rejection short-circuits', () {
      final calls = <String>[];
      final signal = Signal(
        definition: _definition(),
        filters: [
          PreCallback((_, context) {
            calls.add('default');
            return true;
          }),
        ],
      );
      signal.filter(PreCallback((_, context) {
        calls.add('temporary');
        return false;
      }));
      signal.filter(PreCallback((_, context) {
        calls.add('unreachable');
        return true;
      }));

      expect(signal.emit(_Message()), isEmpty);
      expect(calls, ['default', 'temporary']);
      expect(signal.emit(_Message()), hasLength(1));
      expect(calls, ['default', 'temporary', 'default']);
    });

    test('temporary filters are consumed even when no signal matches', () {
      final signal = Signal(definition: _definition());
      signal.filter(PreCallback((_, context) => false));

      expect(signal.emit(Object()), isEmpty);
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('temporary filters are consumed even when a handler throws', () {
      var fail = true;
      var filterCalls = 0;
      final definition = SignalDefinition();
      definition.registerConstructor<_Message, _Receiver>((message) {
        if (fail) throw StateError('handler failed');
        return _Receiver();
      });
      final signal = Signal(definition: definition);
      signal.filter(PreCallback((_, context) {
        filterCalls++;
        return true;
      }));

      expect(() => signal.emit(_Message()), throwsStateError);
      fail = false;
      expect(signal.emit(_Message()), hasLength(1));
      expect(filterCalls, 1);
    });

    test('filter(false) disables default and temporary filters for one call',
        () {
      final signal = Signal(
        definition: _definition(),
        filters: [PreCallback((_, context) => false)],
      );
      signal.filter(PostCallback((_, context) => false));
      signal.filter(false);

      expect(signal.emit(_Message()), hasLength(1));
      expect(signal.emit(_Message()), isEmpty);
    });

    test('configured filters can be changed between calls', () {
      final signal = Signal(definition: _definition());
      signal.filters.add(PreCallback((_, context) => false));
      expect(signal.emit(_Message()), isEmpty);
      signal.filters.clear();
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('invalid temporary filters are rejected', () {
      final signal = Signal();
      for (final invalid in [true, 'filter', Object()]) {
        expect(() => signal.filter(invalid), throwsArgumentError);
      }
    });

    test('marker-only filters fail validation at construction and dispatch',
        () {
      expect(
        () => Signal(filters: [_InvalidFilter()]),
        throwsArgumentError,
      );
      final signal = Signal(definition: _definition());
      signal.filters.add(_InvalidFilter());
      expect(() => signal.emit(_Message()), throwsArgumentError);
    });

    test('temporary filters are consumed when a filter itself throws', () {
      final signal = Signal(definition: _definition());
      signal.filter(PreCallback((_, context) => throw StateError('filter')));

      expect(() => signal.emit(_Message()), throwsStateError);
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('failed emitType also consumes its temporary filters', () {
      final signal = Signal(definition: _definition());
      signal.filter(PreCallback((_, context) => false));

      expect(() => signal.emitType<_Message>(), throwsStateError);
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('nested emissions do not inherit the outer temporary filters', () {
      final definition = SignalDefinition();
      late Signal signal;
      var nested = false;
      var postCalls = 0;
      List<_Message>? nestedResults;
      definition.registerConstructor<_Message, _Receiver>((message) {
        if (!nested) {
          nested = true;
          nestedResults = signal.emit(_Message(['nested']));
        }
        return _Receiver();
      });
      signal = Signal(definition: definition);
      signal.filter(PostCallback((_, context) {
        postCalls++;
        return false;
      }));

      expect(signal.emit(_Message(['outer'])), isEmpty);
      expect(nestedResults, hasLength(1));
      expect(nestedResults!.single.values, ['nested']);
      expect(postCalls, 1);
    });
  });

  group('gather', () {
    test('returns new provider instances for both slot objects and types', () {
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, _FirstPlugin.new);
      definition.registerProvider<_SecondPlugin>(_Collect, _SecondPlugin.new);
      final signal = Signal(definition: definition);

      final first = signal.gather<Object>(_Collect());
      final second = signal.gather<Object>(_Collect);

      expect(first.map((provider) => provider.runtimeType), [
        _FirstPlugin,
        _SecondPlugin,
      ]);
      expect(second, hasLength(2));
      expect(identical(first[0], second[0]), isFalse);
      expect(identical(first[1], second[1]), isFalse);
    });

    test('filters by interface before constructing unrelated providers', () {
      var unrelatedCreated = 0;
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, _FirstPlugin.new);
      definition.registerProvider<_SecondPlugin>(_Collect, _SecondPlugin.new);
      definition.registerProvider<_Unrelated>(_Collect, () {
        unrelatedCreated++;
        return _Unrelated();
      });

      final result = Signal(definition: definition).gather<_Plugin>(_Collect());

      expect(result, hasLength(2));
      expect(result, everyElement(isA<_Plugin>()));
      expect(unrelatedCreated, 0);
    });

    test('can select one concrete provider class', () {
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, _FirstPlugin.new);
      definition.registerProvider<_SecondPlugin>(_Collect, _SecondPlugin.new);

      expect(
        Signal(definition: definition).gather<_FirstPlugin>(_Collect()),
        [isA<_FirstPlugin>()],
      );
    });

    test('pre-filter skips construction and sees the original slot', () {
      var created = 0;
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, () {
        created++;
        return _FirstPlugin();
      });
      final slot = _Collect();
      final signal = Signal(definition: definition);
      signal.filter(PreCallback((target, context) {
        expect(target, _FirstPlugin);
        expect(context, same(slot));
        return false;
      }));

      expect(signal.gather<Object>(slot), isEmpty);
      expect(created, 0);
      expect(signal.gather<Object>(slot), hasLength(1));
      expect(created, 1);
    });

    test('post-filter runs after construction and lasts for one gather', () {
      var created = 0;
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, () {
        created++;
        return _FirstPlugin();
      });
      final slot = _Collect();
      final signal = Signal(definition: definition);
      signal.filter(PostCallback((result, context) {
        expect(result, isA<_FirstPlugin>());
        expect(context, same(slot));
        return false;
      }));

      expect(signal.gather<Object>(slot), isEmpty);
      expect(created, 1);
      expect(signal.gather<Object>(slot), hasLength(1));
      expect(created, 2);
    });

    test('unknown slots return an empty list and consume temporary filters',
        () {
      final signal = Signal(definition: _definition());
      signal.filter(PreCallback((_, context) => false));

      expect(signal.gather<Object>(Object()), isEmpty);
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('registering the same provider replaces its factory', () {
      final definition = SignalDefinition();
      var oldCalls = 0;
      definition.registerProvider<_FirstPlugin>(_Collect, () {
        oldCalls++;
        return _FirstPlugin();
      });
      definition.registerProvider<_FirstPlugin>(_Collect, _FirstPlugin.new);

      final result = Signal(definition: definition).gather<Object>(_Collect());

      expect(result, hasLength(1));
      expect(oldCalls, 0);
    });

    test('a failing provider does not leave temporary filters active', () {
      var fail = true;
      var filtered = 0;
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, () {
        if (fail) throw StateError('provider');
        return _FirstPlugin();
      });
      final signal = Signal(definition: definition);
      signal.filter(PreCallback((_, context) {
        filtered++;
        return true;
      }));

      expect(() => signal.gather<Object>(_Collect), throwsStateError);
      fail = false;
      expect(signal.gather<Object>(_Collect), hasLength(1));
      expect(filtered, 1);
    });
  });

  group('definitions and attachments', () {
    test('separate Signal instances have independent definitions', () {
      final first = Signal(definition: _definition());
      final second = Signal();

      expect(first.emit(_Message()), hasLength(1));
      expect(second.emit(_Message()), isEmpty);
    });

    test('construction takes a snapshot of a mutable definition', () {
      final definition = _definition();
      final signal = Signal(definition: definition);
      definition.disableSlot<_Message, _Receiver>();

      expect(signal.emit(_Message()), hasLength(1));
      expect(Signal(definition: definition).emit(_Message()), isEmpty);
    });

    test('attachment overrides an injection having the same kind and name', () {
      final signal = Signal(definition: _definition());
      final attached = SignalDefinition();
      attached.registerMethod<_Message, _Receiver>(
        _Receiver.new,
        (receiver, message) => message.values.add('replacement'),
        name: 'receive',
      );
      signal.attach(attached);

      final result = signal.emit(_Message());

      expect(result, hasLength(1));
      expect(result.single.values, ['replacement']);
    });

    test('attachments are copied before the original builder changes', () {
      final signal = Signal();
      final attached = _definition();
      signal.attach(attached);
      attached.disableSlot<_Message, _Receiver>();

      expect(signal.emit(_Message()), hasLength(1));
      signal.resetCache();
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('an attachment can disable and then re-enable a receiver', () {
      final signal = Signal(definition: _definition());
      final disabled = SignalDefinition();
      disabled.disableSlot<_Message, _Receiver>();
      signal.attach(disabled);
      expect(signal.emit(_Message()), isEmpty);

      signal.attach(_definition());
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('an attachment can disable and then re-enable a provider', () {
      final definition = SignalDefinition();
      definition.registerProvider<_FirstPlugin>(_Collect, _FirstPlugin.new);
      final signal = Signal(definition: definition);
      final disabled = SignalDefinition();
      disabled.disableProvider<_FirstPlugin>(_Collect);
      signal.attach(disabled);
      expect(signal.gather<Object>(_Collect), isEmpty);

      signal.attach(definition);
      expect(signal.gather<Object>(_Collect), hasLength(1));
    });

    test('reload false defers an attachment until resetCache', () {
      final signal = Signal(definition: _definition());
      final disabled = SignalDefinition();
      disabled.disableSlot<_Message, _Receiver>();
      signal.attach(disabled, reload: false);

      expect(signal.emit(_Message()), hasLength(1));
      signal.resetCache();
      expect(signal.emit(_Message()), isEmpty);
    });

    test('an attachment made during dispatch affects the next operation', () {
      late Signal signal;
      final definition = SignalDefinition();
      definition.registerConstructor<_Message, _Receiver>((message) {
        final disabled = SignalDefinition();
        disabled.disableSlot<_Message, _OtherReceiver>();
        signal.attach(disabled);
        return _Receiver();
      });
      definition.registerConstructor<_Message, _OtherReceiver>(
        (message) => _OtherReceiver(),
      );
      signal = Signal(definition: definition);

      expect(signal.emit(_Message()), hasLength(2));
      expect(signal.emit(_Message()), hasLength(1));
    });

    test('registering a factory preserves an existing custom copy callback',
        () {
      final definition = _definition();
      definition.registerSignal<_Message>(
        clone: (original) => _Message(['custom']),
      );
      definition.registerSignal<_Message>(create: _Message.new);

      final result = Signal(definition: definition).emitType<_Message>();

      expect(result.single.values, ['custom', 'received']);
    });
  });
}

SignalDefinition _definition() {
  final definition = SignalDefinition();
  definition.registerMethod<_Message, _Receiver>(
    _Receiver.new,
    (receiver, message) => message.values.add('received'),
    name: 'receive',
  );
  return definition;
}

class _Message implements CloneableSignal<_Message> {
  _Message([Iterable<String> values = const []]) : values = [...values];

  final List<String> values;

  @override
  _Message clone() => _Message(values);
}

class _SpecialMessage extends _Message {}

class _PlainMessage {
  _PlainMessage(this.value);

  int value;
}

class _AwareMessage implements CloneableSignal<_AwareMessage>, SlotAware {
  Object? slot;
  final steps = <String>[];

  @override
  _AwareMessage clone() => _AwareMessage();

  @override
  void setSlot(Object slot) {
    this.slot = slot;
    steps.add('setSlot');
  }
}

class _Receiver {
  set message(_Message message) => message.values.add('property');
}

class _OtherReceiver {}

class _Collect {}

abstract interface class _Plugin {}

class _FirstPlugin implements _Plugin {}

class _SecondPlugin implements _Plugin {}

class _Unrelated {}

class _InvalidFilter implements SignalFilter {}
