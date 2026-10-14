part of '../maslosoft_signals.dart';

/// Marks a receiver constructor, method, field, or setter for signal injection.
///
/// A class annotation selects its unnamed constructor. Targets may be a [Type]
/// or a canonical `package:my_app/file.dart#ClassName` string. Use [SlotFor.all]
/// or repeat the annotation to receive several signal types.
class SlotFor {
  /// Receives [targets], a signal type or its canonical name.
  const SlotFor(this.targets);

  /// Receives each of the signal types or canonical names in [targets].
  const SlotFor.all(List<Object> this.targets);

  /// The target type/name, or a list of target types/names.
  final Object targets;
}

/// Registers a class as a provider that [Signal.gather] can instantiate.
///
/// Targets identify slots by [Type] or canonical
/// `package:my_app/file.dart#ClassName` strings. Concrete implementations inherit
/// this metadata from their superclasses, mixins, and interfaces.
class SignalFor {
  /// Provides instances for [targets], a slot type or its canonical name.
  const SignalFor(this.targets);

  /// Provides instances for each slot type/name in [targets].
  const SignalFor.all(List<Object> this.targets);

  /// The target type/name, or a list of target types/names.
  final Object targets;
}

/// Explicit copy contract for signals delivered to independent receivers.
///
/// Implementations must return a new instance of the same runtime type. Copy
/// mutable nested state when receivers should be isolated from each other.
/// Alternatively, register a copy callback with
/// [SignalDefinition.registerSignal].
abstract interface class CloneableSignal<T extends Object> {
  /// Creates an independent signal for one receiver injection.
  T clone();
}

/// Lets a dispatched signal retain the receiver handling its copy.
abstract interface class SlotAware {
  /// Called before method/property injection, or after constructor injection.
  void setSlot(Object slot);
}
