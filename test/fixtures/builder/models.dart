import 'package:maslosoft_signals/maslosoft_signals.dart';

class Event implements CloneableSignal<Event> {
  Event([Iterable<String> handledBy = const []])
      : handledBy = List.of(handledBy);

  final List<String> handledBy;

  @override
  Event clone() => Event(handledBy);
}

class OtherEvent implements CloneableSignal<OtherEvent> {
  @override
  OtherEvent clone() => OtherEvent();
}

@SlotFor(Event)
class ConstructorReceiver {
  ConstructorReceiver(Event event) {
    event.handledBy.add('constructor');
  }
}

@SlotFor(Event)
abstract class ConstructorBase {
  ConstructorBase(Event event);
}

class InheritedConstructorReceiver extends ConstructorBase {
  // ignore: use_super_parameters
  InheritedConstructorReceiver(Event event) : super(event) {
    event.handledBy.add('inherited constructor');
  }
}

class NamedReceiver {
  @SlotFor(Event)
  NamedReceiver.receive(Event event) {
    event.handledBy.add('named');
  }
}

abstract class ReceiverBase {
  @SlotFor.all([Event, OtherEvent])
  void accept(Object event) {
    if (event is Event) event.handledBy.add('method');
  }
}

class MethodReceiver extends ReceiverBase {}

class PropertyReceiver {
  @SlotFor(Event)
  late Event event;
}

class SetterReceiver {
  @SlotFor(Event)
  set event(Event value) {
    value.handledBy.add('setter');
  }
}

class ProviderSlot {}

@SignalFor(ProviderSlot)
abstract interface class ProviderInterface {}

class Provider implements ProviderInterface {}

@SignalFor(ProviderSlot)
class DirectProvider {}

// Deliberately unused: private providers must not appear in generated code.
// ignore: unused_element
class _PrivateProvider implements ProviderInterface {}
