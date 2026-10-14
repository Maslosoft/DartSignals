/// Signals and slots for wireless communication between application components.
///
/// Use [SignalDefinition] to register handlers explicitly, or generate a
/// definition from [SlotFor] and [SignalFor] annotations with the `signals` CLI.
/// This library has no runtime dependency on reflection or source analysis.
library;

part 'src/annotations.dart';
part 'src/definition.dart';
part 'src/filters.dart';
part 'src/signal.dart';
