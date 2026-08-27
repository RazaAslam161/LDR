import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';

/// The splash sits on the only way into the app. If it never calls back, the
/// user is locked out of their own account with no way forward — so the thing
/// worth pinning is not what it looks like, it is that it always hands over,
/// exactly once.
void main() {
  Widget host(VoidCallback onComplete) =>
      MaterialApp(home: IntroSplashScreen(onComplete: onComplete));

  testWidgets('hands over on its own', (tester) async {
    var completed = 0;
    await tester.pumpWidget(host(() => completed++));
    await tester.pump();
    expect(completed, 0, reason: 'must not fire before it has been seen');

    // The token plus a frame, not a literal: the splash runs MilesMotion.
    // flicker, and a hardcoded number here silently re-pins whatever the
    // token was the day the test was written.
    await tester.pump(MilesMotion.flicker + const Duration(milliseconds: 50));
    expect(completed, 1);
  });

  testWidgets('a tap skips it', (tester) async {
    var completed = 0;
    await tester.pumpWidget(host(() => completed++));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(IntroSplashScreen));
    await tester.pump();
    expect(completed, 1);
  });

  testWidgets('tapping then finishing still hands over exactly once',
      (tester) async {
    // Otherwise the caller pops twice and takes the screen underneath with it.
    var completed = 0;
    await tester.pumpWidget(host(() => completed++));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(IntroSplashScreen));
    await tester.pump(MilesMotion.flicker + const Duration(milliseconds: 50));
    expect(completed, 1);
  });

  testWidgets('shows the name', (tester) async {
    await tester.pumpWidget(host(() {}));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Miles'), findsOneWidget);
  });

  testWidgets('being disposed mid-animation neither fires nor throws',
      (tester) async {
    var completed = 0;
    await tester.pumpWidget(host(() => completed++));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 1000));
    expect(tester.takeException(), isNull);
    expect(completed, 0);
  });
}
