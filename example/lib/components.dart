import 'package:maslosoft_signals/maslosoft_signals.dart';

/// A request whose responses are collected as independently modified clones.
class MenuRequest implements CloneableSignal<MenuRequest>, SlotAware {
  MenuRequest([Iterable<String> items = const []]) : items = List.of(items);

  final List<String> items;
  Object? receiver;

  @override
  MenuRequest clone() => MenuRequest(items);

  @override
  void setSlot(Object slot) {
    receiver = slot;
  }
}

class AccountMenu {
  @SlotFor(MenuRequest)
  void contribute(MenuRequest request) {
    request.items.add('Account');
  }
}

class HelpMenu {
  @SlotFor(MenuRequest)
  void contribute(MenuRequest request) {
    request.items.add('Help');
  }
}

/// Identifies the group of providers to gather.
class MenuSlot {}

@SignalFor(MenuSlot)
class WelcomeEntry {
  String get label => 'Welcome';
}
