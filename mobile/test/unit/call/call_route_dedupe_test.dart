import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/router.dart';

/// The duplicated, self-overlapping call video came from here.
///
/// Two places push `/call` — the shell's call-state listener and the floating
/// window's tap — and the only guard was `_AppShellState._lastCallState`, which
/// is per-State-instance. Android's screen-capture consent dialog drives the app
/// through paused, the disguise cover swaps the whole MaterialApp, and the
/// rebuilt shell starts again at `idle` while the GoRouter (a plain Provider,
/// never invalidated) still has /call on its stack. Every trip out of the app
/// therefore read as a fresh call and mounted another CallScreen — each one
/// drawing the SAME textureId, once more per cycle.
///
/// The router is the one thing no remount can lie about, so that is what is
/// asked. These tests use a throwaway router rather than the app's, because the
/// property under test is about GoRouter's stack, not about Miles's routes.
GoRouter _router() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, __) => const Placeholder(key: ValueKey('home')),
        ),
        GoRoute(
          path: kCallRoute,
          builder: (_, __) => const Placeholder(key: ValueKey('call')),
        ),
      ],
    );

Future<void> _pump(WidgetTester t, GoRouter r) async {
  await t.pumpWidget(MaterialApp.router(routerConfig: r));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('pushes the call route when it is not already on top',
      (t) async {
    final r = _router();
    addTearDown(r.dispose);
    await _pump(t, r);
    expect(isOnCallRoute(r), isFalse);

    pushCallRoute(r);
    await t.pumpAndSettle();

    expect(isOnCallRoute(r), isTrue);
    expect(find.byKey(const ValueKey('call')), findsOneWidget);
  });

  // The regression itself. Before the fix this left two CallScreens stacked,
  // and a real session added one more on every cover cycle.
  testWidgets('a second push while already on the call route is a no-op',
      (t) async {
    final r = _router();
    addTearDown(r.dispose);
    await _pump(t, r);

    pushCallRoute(r);
    await t.pumpAndSettle();
    final afterFirst =
        r.routerDelegate.currentConfiguration.matches.length;

    // Every way it used to happen: the shell's listener firing again after a
    // remount, and the floating window's tap.
    pushCallRoute(r);
    pushCallRoute(r);
    pushCallRoute(r);
    await t.pumpAndSettle();

    expect(r.routerDelegate.currentConfiguration.matches.length, afterFirst);
    expect(find.byKey(const ValueKey('call')), findsOneWidget);
  });

  testWidgets('popping the call route leaves nothing behind, and it can be '
      're-pushed', (t) async {
    final r = _router();
    addTearDown(r.dispose);
    await _pump(t, r);

    pushCallRoute(r);
    await t.pumpAndSettle();
    r.pop();
    await t.pumpAndSettle();

    expect(isOnCallRoute(r), isFalse);
    expect(find.byKey(const ValueKey('call')), findsNothing);

    // Minimising and reopening a live call must still work — the guard is
    // against duplicates, not against returning.
    pushCallRoute(r);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('call')), findsOneWidget);
  });
}
