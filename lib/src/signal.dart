part of '../maslosoft_signals.dart';

/// Synchronous signals/slots dispatcher with independent state per instance.
///
/// [emit] returns copies of the signal after handling; [gather] returns provider
/// instances. Both use exact runtime types to look up relationships.
class Signal {
  /// Creates a dispatcher from a snapshot of [definition].
  Signal({
    SignalDefinition? definition,
    Iterable<SignalFilter> filters = const [],
    this.logger,
  })  : filters = List.of(filters),
        _base = (definition ?? SignalDefinition())._copy() {
    _validateFilters(this.filters);
    reload();
  }

  /// Filters applied to every operation, before temporary filters.
  final List<SignalFilter> filters;

  /// Receives diagnostics for unregistered signal/slot types, if configured.
  SignalLogger? logger;

  final SignalDefinition _base;
  final List<SignalDefinition> _attachments = [];
  late SignalDefinition _definition;
  final List<SignalFilter> _pendingFilters = [];
  bool _skipFilters = false;

  /// Ensures initialization; construction already loads the typed definition.
  void init() {}

  /// Reapplies attached definitions to the original definition snapshot.
  void reload() {
    final definition = _base._copy();
    for (final attachment in _attachments) {
      definition._overlay(attachment);
    }
    _definition = definition;
  }

  /// Restores the base definition and all attachments.
  void resetCache() => reload();

  /// Adds or overrides relationships using a snapshot of [definition].
  ///
  /// Set [reload] to false to defer applying this attachment until [reload] or
  /// [resetCache] is called. Changes affect the next operation; an operation
  /// already in progress retains its definition.
  void attach(SignalDefinition definition, {bool reload = true}) {
    _attachments.add(definition._copy());
    if (reload) {
      this.reload();
    }
  }

  /// Adds a [PreFilter] or [PostFilter] for the next emit or gather operation.
  ///
  /// Passing `false` disables all filters for that operation. A subsequent
  /// filter re-enables filtering. Temporary filters are consumed when the
  /// operation starts, including when it has no results or throws, so nested
  /// dispatch does not inherit them.
  Signal filter(Object filter) {
    if (identical(filter, false)) {
      _pendingFilters.clear();
      _skipFilters = true;
      return this;
    }
    if (filter is! PreFilter && filter is! PostFilter) {
      throw ArgumentError.value(
        filter,
        'filter',
        'Must implement PreFilter or PostFilter, or be false',
      );
    }
    _skipFilters = false;
    _pendingFilters.add(filter as SignalFilter);
    return this;
  }

  /// Sends an independent copy of [signal] to every matching injection.
  ///
  /// Each result is the modified copy, and each injection creates a fresh
  /// receiver. The signal must implement [CloneableSignal] or have a registered
  /// copy callback. No copying is needed if there are no accepted receivers.
  /// Handler, copy, and filter exceptions propagate to the caller.
  List<T> emit<T extends Object>(T signal) {
    final activeFilters = _takeFilters();
    return _emit(signal, activeFilters, _definition);
  }

  /// Constructs a signal using its registered factory, then emits it.
  ///
  /// Register the factory with [SignalDefinition.registerSignal].
  List<T> emitType<T extends Object>() {
    final activeFilters = _takeFilters();
    final definition = _definition;
    final create = definition._signals[T]?.create;
    if (create == null) {
      throw StateError('No signal factory registered for $T. '
          'Use registerSignal<$T>(create: ...).');
    }
    return _emit(create() as T, activeFilters, definition);
  }

  List<T> _emit<T extends Object>(
    T signal,
    List<SignalFilter> activeFilters,
    SignalDefinition definition,
  ) {
    final receivers = definition._receivers[signal.runtimeType];
    if (receivers == null || receivers.isEmpty) {
      logger?.call('No slots found for signal ${signal.runtimeType}.');
      return <T>[];
    }
    final results = <T>[];
    for (final receiver in receivers.entries) {
      final injections = receiver.value;
      if (injections == null || injections.isEmpty) continue;
      if (!_preFilter(activeFilters, receiver.key, signal)) continue;
      for (final injection in injections.values) {
        final copy = _clone(signal, definition);
        final slot = injection.create(copy);
        if (copy is SlotAware) copy.setSlot(slot);
        injection.inject?.call(slot, copy);
        if (_postFilter(activeFilters, copy, signal)) results.add(copy);
      }
    }
    return results;
  }

  /// Creates the providers registered for a slot instance or slot [Type].
  ///
  /// Only providers whose declared factory return type is a subtype of [T] are
  /// constructed. Calling `gather<MyInterface>(slot)` therefore avoids side
  /// effects from constructors of unrelated providers. The slot is not injected.
  List<T> gather<T extends Object>(Object slot) {
    final activeFilters = _takeFilters();
    final definition = _definition;
    final type = slot is Type ? slot : slot.runtimeType;
    final providers = definition._providers[type];
    if (providers == null || providers.isEmpty) {
      logger?.call('No signals found for slot $type.');
      return <T>[];
    }
    final results = <T>[];
    for (final provider in providers.entries) {
      final create = provider.value;
      if (create == null) continue;
      if (!_preFilter(activeFilters, provider.key, slot)) continue;
      if (create is! T Function()) continue;
      final instance = create();
      if (_postFilter(activeFilters, instance, slot)) results.add(instance);
    }
    return results;
  }

  T _clone<T extends Object>(T signal, SignalDefinition definition) {
    final clone = definition._signals[signal.runtimeType]?.clone;
    final Object copy;
    if (clone != null) {
      copy = clone(signal);
    } else if (signal is CloneableSignal<Object>) {
      copy = signal.clone();
    } else {
      throw StateError('Signal ${signal.runtimeType} cannot be copied. '
          'Implement CloneableSignal or register a clone callback.');
    }
    if (identical(copy, signal) || copy.runtimeType != signal.runtimeType) {
      throw StateError('A signal clone must be a new instance of '
          '${signal.runtimeType}.');
    }
    return copy as T;
  }

  List<SignalFilter> _takeFilters() {
    final result = _skipFilters
        ? <SignalFilter>[]
        : <SignalFilter>[...filters, ..._pendingFilters];
    _pendingFilters.clear();
    _skipFilters = false;
    _validateFilters(result);
    return result;
  }

  static void _validateFilters(Iterable<SignalFilter> filters) {
    for (final filter in filters) {
      if (filter is! PreFilter && filter is! PostFilter) {
        throw ArgumentError.value(
          filter,
          'filters',
          'Each filter must implement PreFilter or PostFilter',
        );
      }
    }
  }

  static bool _preFilter(
    List<SignalFilter> filters,
    Type target,
    Object context,
  ) {
    for (final filter in filters) {
      if (filter is PreFilter && !filter.filter(target, context)) return false;
    }
    return true;
  }

  static bool _postFilter(
    List<SignalFilter> filters,
    Object result,
    Object context,
  ) {
    for (final filter in filters) {
      if (filter is PostFilter && !filter.filter(result, context)) return false;
    }
    return true;
  }
}
