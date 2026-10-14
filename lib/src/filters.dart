part of '../maslosoft_signals.dart';

/// Common marker for [PreFilter] and [PostFilter].
abstract interface class SignalFilter {}

/// Selects receiver/provider types before any instance is created.
abstract interface class PreFilter implements SignalFilter {
  /// Returns whether [target] should handle the original signal or slot [context].
  bool filter(Type target, Object context);
}

/// Selects results after a receiver has run or a provider has been created.
///
/// Rejecting a result does not undo constructor or handler side effects.
abstract interface class PostFilter implements SignalFilter {
  /// Returns whether [result] should be included for the original [context].
  bool filter(Object result, Object context);
}

/// Adapts a function to [PreFilter].
final class PreCallback implements PreFilter {
  /// Creates a filter using [callback].
  const PreCallback(this.callback);

  /// The predicate called before receiver/provider creation.
  final bool Function(Type target, Object context) callback;

  @override
  bool filter(Type target, Object context) => callback(target, context);
}

/// Adapts a function to [PostFilter].
final class PostCallback implements PostFilter {
  /// Creates a filter using [callback].
  const PostCallback(this.callback);

  /// The predicate called on each candidate result.
  final bool Function(Object result, Object context) callback;

  @override
  bool filter(Object result, Object context) => callback(result, context);
}

/// Optional diagnostics callback, for example `logger: print`.
typedef SignalLogger = void Function(String message);
