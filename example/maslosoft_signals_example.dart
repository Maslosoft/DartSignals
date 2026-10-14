import 'package:maslosoft_signals/maslosoft_signals.dart';

import 'lib/components.dart';

void main() {
  final definition = SignalDefinition()
    ..registerMethod<MenuRequest, AccountMenu>(
      AccountMenu.new,
      (receiver, request) => receiver.contribute(request),
      name: 'contribute',
    )
    ..registerMethod<MenuRequest, HelpMenu>(
      HelpMenu.new,
      (receiver, request) => receiver.contribute(request),
      name: 'contribute',
    )
    ..registerProvider<WelcomeEntry>(MenuSlot, WelcomeEntry.new);

  final signals = Signal(definition: definition);
  final request = MenuRequest(['Home']);
  final responses = signals.emit(request);

  for (final response in responses) {
    print(response.items.join(', '));
  }
  print('Original: ${request.items.join(', ')}');

  final entries = signals.gather<WelcomeEntry>(MenuSlot());
  print(entries.single.label);
}
