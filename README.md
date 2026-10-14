# Maslosoft Signals for Dart

Cross-component communication through signals, receivers, and providers. This is
a Dart port of [Maslosoft Signals](https://maslosoft.com/signals/), with the PHP
and Python implementations used as behavioral references.

Emitting a signal creates an independent copy for each receiver and returns the
modified copies. Gathering creates provider objects associated with a slot.
Applications can register components
explicitly or generate registrations from annotations.

Requires Dart 3.6 or later. Dispatch is synchronous and uses exact runtime types
to look up relationships. The runtime uses typed callbacks and works without
runtime reflection. Source discovery runs as a separate development command.

## Installation

```sh
dart pub add maslosoft_signals
```

```dart
import 'package:maslosoft_signals/maslosoft_signals.dart';
```

## Emit a signal

Define the signal's copy behavior explicitly. Each receiver gets its own copy;
the original remains available to the caller.

```dart
class MenuRequest implements CloneableSignal<MenuRequest> {
  MenuRequest([Iterable<String> items = const []]) : items = List.of(items);

  final List<String> items;

  @override
  MenuRequest clone() => MenuRequest(items);
}

class AccountMenu {
  @SlotFor(MenuRequest)
  void contribute(MenuRequest request) {
    request.items.add('Account');
  }
}

void main() {
  final definition = SignalDefinition()
    ..registerMethod<MenuRequest, AccountMenu>(
      AccountMenu.new,
      (receiver, request) => receiver.contribute(request),
      name: 'contribute',
    );

  final signals = Signal(definition: definition);
  final original = MenuRequest(['Home']);
  final responses = signals.emit(original);
  print(responses.single.items); // [Home, Account]
  print(original.items); // [Home]
}
```

An annotation describes a relationship for the generator. It does not register
the component by itself. The example above registers it explicitly; generated
definitions replace that registration code in larger applications.

The clone method controls copying of nested mutable state. Copy any lists,
maps, or other objects that receivers must modify independently. Dart cannot
clone arbitrary objects automatically. A signal can instead supply a clone
callback through `registerSignal`:

```dart
final definition = SignalDefinition()
  ..registerSignal<MenuRequest>(
    create: MenuRequest.new,
    clone: (request) => MenuRequest(request.items),
  );
```

## Constructor, method, and property receivers

Receivers may accept a signal in their constructor, a method, or a writable
property. For generated registrations, use `@SlotFor` on the receiver class,
method, field, or setter respectively:

```dart
@SlotFor(MenuRequest)
class ConstructorMenu {
  ConstructorMenu(MenuRequest request) {
    request.items.add('Settings');
  }
}

class PropertyMenu {
  @SlotFor(MenuRequest)
  set request(MenuRequest request) {
    request.items.add('Support');
  }
}
```

The equivalent explicit registrations are:

```dart
final definition = SignalDefinition()
  ..registerConstructor<MenuRequest, ConstructorMenu>(ConstructorMenu.new)
  ..registerProperty<MenuRequest, PropertyMenu>(
    PropertyMenu.new,
    (receiver, request) => receiver.request = request,
    name: 'request',
  );
```

Factories make dependency injection possible: a factory can close over services
needed by a receiver. Generated method/property receivers and providers require
public constructors callable without arguments. Use explicit registrations for
custom construction.

Signals may implement `SlotAware` to receive their receiver through
`setSlot(Object slot)`. For method and property injection, this happens before
the method call or property assignment. For constructor injection, it happens
after the receiver constructor returns. It applies to the emitted clone.

## Gather providers

A provider is associated with a slot using `@SignalFor`:

```dart
class MenuSlot {}

@SignalFor(MenuSlot)
class WelcomeEntry {
  String get label => 'Welcome';
}

void main() {
  final definition = SignalDefinition()
    ..registerProvider<WelcomeEntry>(MenuSlot, WelcomeEntry.new);
  final signals = Signal(definition: definition);

  final entries = signals.gather<WelcomeEntry>(MenuSlot());
  print(entries.single.label); // Welcome
}
```

Each gather operation creates fresh provider instances; it does not inject the
slot into them. The generic argument
selects the result type; use a common base class or interface when gathering
several implementations.

## Generate registrations

Put annotated public classes in your application's `lib/` directory, then run:

```sh
dart run maslosoft_signals:signals build \
  --path lib \
  --output lib/signals_definition.dart
```

Import the generated file and attach its definition:

```dart
import 'package:maslosoft_signals/maslosoft_signals.dart';
import 'signals_definition.dart';

final signals = Signal(definition: buildSignalsDefinition());
```

Run generation again when annotations or component signatures change. The
generated Dart file contains imports and typed registrations and should be
included in your application build. Runtime imports do not depend on the source
scanner or on `dart:mirrors`.

Preview the registrations without writing a file:

```sh
dart run maslosoft_signals:signals preview --path lib
```

An annotation can name multiple targets:

```dart
@SlotFor.all([MenuRequest, AnotherRequest])
```

`SignalFor.all` works similarly. Relationships declared on base classes and
interfaces are inherited by concrete components. Prefer Dart type references;
the generator also accepts canonical strings such as
`'package:my_app/models.dart#MenuRequest'` when a direct type reference is
inconvenient.

For programmatic generation, import
`package:maslosoft_signals/builder.dart`. Keep this tooling import in development
scripts, separate from application runtime imports.

The generator supports public, non-generic classes and synchronous handlers.
Use concrete subclasses for generic models, and explicit registrations when
receivers or providers need custom construction. Invalid annotations and
incompatible handler signatures produce build errors. Existing handwritten
output files are protected from being overwritten.

## Filters and shared definitions

Pre-filters decide whether a receiver or provider should be constructed.
Post-filters decide whether a result should be included. Both receive the
original emitted signal or gathering slot as the second argument:

```dart
final responses = signals
    .filter(PreCallback((target, original) => target != AccountMenu))
    .emit(MenuRequest());

final entries = signals
    .filter(PostCallback((result, original) => result is WelcomeEntry))
    .gather<WelcomeEntry>(MenuSlot());
```

Filters passed to `filter(...)` apply only to the next operation. Use
`signals.filter(false).emit(request)` to disable filtering for one operation.

Pass the same `SignalDefinition` to multiple `Signal` instances to reuse the
same registrations. Each dispatcher takes a snapshot at construction. `attach`
adds or overrides relationships from another definition snapshot; it preserves
unrelated registrations. `attach(definition, reload: false)` defers applying the
attachment until `reload()` or `resetCache()` reapplies the base definition and
all attachments. Later edits to the original definition objects do not change
these snapshots. Receiver and provider instances are created per operation.

## Run the example and checks

```sh
dart pub get
dart run example/maslosoft_signals_example.dart
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
```

Use the current stable Dart SDK for publication dry-runs and publishing from a
checkout with the local `php-signals` and `py-signals` links. Dart 3.6.1's pub
[rejects even ignored directory symlinks](https://github.com/dart-lang/pub/pull/3298);
with that SDK, use a clean checkout without the reference links.

The example prints independent responses and a gathered provider:

```text
Home, Account
Home, Help
Original: Home
Welcome
```

To try annotation generation with the example components:

```sh
dart run maslosoft_signals:signals build \
  --path example/lib \
  --output example/lib/signals_definition.dart
```

Replace the example's explicit `SignalDefinition()` registrations with
`buildSignalsDefinition()` and import the generated file to use that definition.

## License and attribution

Original project by Maslosoft / Peter Maselkowski (Piotr Masełkowski).
The original licensing is preserved: GNU Affero General Public License version
3 only (`AGPL-3.0-only`), with a separate proprietary licensing option from
Maslosoft. See [LICENSE](LICENSE), [the original AGPL text](LICENSE-AGPL.mkd),
and [the proprietary agreement](LICENSE-PROPRIETARY.mkd).
