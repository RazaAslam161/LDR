import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/main.dart';

/// The cover and the release-gate block screen are plain `MaterialApp`s built
/// with `home:` and no route table, so Android handing Flutter a deep link —
/// a tapped notification, an app link — reaches `_onUnknownRoute`, which has
/// no route to return and throws `_TypeError`. Build 76 reported it from the
/// field, and it is reachable every time the app has been backgrounded.
///
/// Both halves are asserted here because the obvious fix breaks the second
/// one: a transparent route left standing installs a modal barrier that
/// silently swallows every touch meant for the screen underneath, which turns
/// a crash nobody sees into a cover nobody can get past.
void main() {
  Widget host(GlobalKey<NavigatorState> key, VoidCallback onTap) => MaterialApp(
        navigatorKey: key,
        onUnknownRoute: ignoreRoutePush,
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: onTap,
              child: const Text('cover'),
            ),
          ),
        ),
      );

  testWidgets('an OS route push neither crashes nor blocks the screen',
      (tester) async {
    var taps = 0;
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(host(key, () => taps++));

    await tester.tap(find.text('cover'));
    expect(taps, 1, reason: 'baseline: the cover is tappable');

    // Exactly what didPushRouteInformation does with a deep link.
    key.currentState!.pushNamed('/some/deep/link');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'the unknown route must not throw');

    await tester.tap(find.text('cover'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps, 2,
        reason: 'the ignored route must not absorb touches meant for the '
            'screen underneath',);
  });
}
