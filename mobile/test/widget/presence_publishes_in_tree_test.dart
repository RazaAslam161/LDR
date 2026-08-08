import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/presence_route_observer.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// The observer runs inside a live navigator, which fires its callbacks while
/// the tree is being built — and Riverpod refuses a provider write during that
/// phase. The unit tests drive the observer directly and cannot see this at
/// all; it only shows up with a real router, which is where it bit.
void main() {
  late ProviderContainer container;
  late GoRouter router;

  Widget app() {
    container = ProviderContainer(
      overrides: [currentCoupleProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    router = GoRouter(
      initialLocation: '/app',
      observers: [PresenceRouteObserver(_ContainerRef(container))],
      routes: [
        for (final path in ['/app', '/app/touch'])
          GoRoute(
            path: path,
            builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
          ),
      ],
    );
    addTearDown(router.dispose);

    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('a push from inside a live tree publishes the room',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(container.read(myScreenProvider), 'Home');

    router.push('/app/touch');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // no "modified during build"
    expect(container.read(myScreenProvider), 'Touch');
  });

  testWidgets('popping back republishes the tab underneath', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    router.push('/app/touch');
    await tester.pumpAndSettle();
    expect(container.read(myScreenProvider), 'Touch');

    router.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(container.read(myScreenProvider), 'Home');
  });
}

/// The observer only ever `read`s providers, which a container does.
class _ContainerRef implements Ref {
  _ContainerRef(this._c);
  final ProviderContainer _c;

  @override
  T read<T>(ProviderListenable<T> provider) => _c.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
