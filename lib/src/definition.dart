part of '../maslosoft_signals.dart';

/// How a receiver accepts a signal.
enum InjectionType {
  /// The receiver constructor accepts the signal.
  constructor,

  /// A method on a new receiver accepts the signal.
  method,

  /// A field or setter on a new receiver accepts the signal.
  property,
}

/// Typed factories and relationships used by a [Signal] dispatcher.
///
/// Definitions can be built manually or by generated Dart code. Registering the
/// same relationship again replaces it. Dispatchers snapshot definitions, so
/// later edits do not affect an existing dispatcher until explicitly attached.
class SignalDefinition {
  final Map<Type, _SignalFactory> _signals = {};
  final Map<Type, Map<Type, Map<(InjectionType, String), _Injection>?>>
      _receivers = {};
  final Map<Type, Map<Type, Object Function()?>> _providers = {};

  /// Registers optional default construction and copying of signal type [T].
  ///
  /// A registered [clone] takes precedence over [CloneableSignal.clone]. A
  /// [create] factory enables [Signal.emitType]. Re-registering only one callback
  /// preserves the previously registered other callback.
  void registerSignal<T extends Object>({
    T Function()? create,
    T Function(T signal)? clone,
  }) {
    final previous = _signals[T];
    _signals[T] = _SignalFactory(
      create: create ?? previous?.create,
      clone: clone == null ? previous?.clone : (value) => clone(value as T),
    );
  }

  /// Sends each [T] copy to a fresh [S] via its constructor.
  ///
  /// [name] identifies a named constructor and distinguishes registrations.
  void registerConstructor<T extends Object, S extends Object>(
    S Function(T signal) create, {
    String name = '',
  }) {
    _register<T, S>(
      _Injection(
          InjectionType.constructor, name, (value) => create(value as T)),
    );
  }

  /// Constructs a fresh [S] and invokes a method accepting a copy of [T].
  void registerMethod<T extends Object, S extends Object>(
    S Function() create,
    void Function(S receiver, T signal) invoke, {
    required String name,
  }) {
    _register<T, S>(_Injection(
      InjectionType.method,
      name,
      (_) => create(),
      inject: (receiver, value) => invoke(receiver as S, value as T),
    ));
  }

  /// Constructs a fresh [S] and assigns a copy of [T] to a field or setter.
  void registerProperty<T extends Object, S extends Object>(
    S Function() create,
    void Function(S receiver, T signal) assign, {
    required String name,
  }) {
    _register<T, S>(_Injection(
      InjectionType.property,
      name,
      (_) => create(),
      inject: (receiver, value) => assign(receiver as S, value as T),
    ));
  }

  /// Makes newly constructed [T] instances available when gathering [slot].
  ///
  /// The factory retains its return type so [Signal.gather] can check the
  /// requested interface before running the constructor.
  void registerProvider<T extends Object>(Type slot, T Function() create) {
    (_providers[slot] ??= {})[T] = create;
  }

  /// Disables all injections from signal [T] to receiver [S].
  ///
  /// Attach this definition to override previously registered relationships.
  /// A subsequent registration for the same pair re-enables that receiver.
  void disableSlot<T extends Object, S extends Object>() {
    (_receivers[T] ??= {})[S] = null;
  }

  /// Disables provider [T] for [slot], including when used as an attachment.
  void disableProvider<T extends Object>(Type slot) {
    (_providers[slot] ??= {})[T] = null;
  }

  void _register<T extends Object, S extends Object>(_Injection injection) {
    final receivers = _receivers[T] ??= {};
    final injections = receivers[S] ??= {};
    injections[(injection.type, injection.name)] = injection;
  }

  SignalDefinition _copy() => SignalDefinition().._overlay(this);

  void _overlay(SignalDefinition other) {
    for (final entry in other._signals.entries) {
      final previous = _signals[entry.key];
      _signals[entry.key] = _SignalFactory(
        create: entry.value.create ?? previous?.create,
        clone: entry.value.clone ?? previous?.clone,
      );
    }
    for (final signal in other._receivers.entries) {
      final receivers = _receivers[signal.key] ??= {};
      for (final receiver in signal.value.entries) {
        final injections = receiver.value;
        if (injections == null) {
          receivers[receiver.key] = null;
        } else {
          (receivers[receiver.key] ??= {}).addAll(injections);
        }
      }
    }
    for (final slot in other._providers.entries) {
      (_providers[slot.key] ??= {}).addAll(slot.value);
    }
  }
}

final class _SignalFactory {
  const _SignalFactory({this.create, this.clone});

  final Object Function()? create;
  final Object Function(Object signal)? clone;
}

final class _Injection {
  const _Injection(this.type, this.name, this.create, {this.inject});

  final InjectionType type;
  final String name;
  final Object Function(Object signal) create;
  final void Function(Object receiver, Object signal)? inject;
}
