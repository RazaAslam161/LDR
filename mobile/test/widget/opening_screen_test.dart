import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/opening/opening_screen.dart';

/// The Opening's contracts — all of them about NOT trapping anyone.
///
/// The app deleted its last intro video because it "meant nobody could open the
/// app without waiting out a clip they had already seen"
/// (intro_splash_screen.dart). These pin the three ways this one refuses to
/// become that: it hands control back on every exit, it hands it back even when
/// the film cannot play at all, and it never starts for someone who asked their
/// phone to stop animating.
void main() {
  Widget host(void Function(bool) onDone, {bool animationsOff = false}) =>
      MediaQuery(
        data: MediaQueryData(disableAnimations: animationsOff),
        child: MaterialApp(home: OpeningScreen(onDone: onDone)),
      );

  testWidgets('animations off: never plays, hands control straight back',
      (tester) async {
    var done = 0;
    bool? completed;
    await tester.pumpWidget(host((c) {
      done++;
      completed = c;
    }, animationsOff: true,),);
    await tester.pump();

    expect(done, 1, reason: 'a phone asked to stop animating must not be made '
        'to sit through a film');
    expect(completed, isFalse,
        reason: 'skipping it is not the same as having watched it');
  });

  testWidgets('the skip is on screen from the first frame', (tester) async {
    await tester.pumpWidget(host((_) {}));
    await tester.pump();
    // Not after a delay, not once the video is ready: immediately, because the
    // frame where a user most wants out is the first one.
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('tapping skip reports NOT completed', (tester) async {
    bool? completed;
    await tester.pumpWidget(host((c) => completed = c));
    await tester.pump();
    await tester.tap(find.text('Skip'));
    await tester.pump();
    expect(completed, isFalse);
  });

  testWidgets('a film that cannot decode still hands control back',
      (tester) async {
    // No video plugin is registered in a widget test, so initialize() throws —
    // which is exactly the on-device case of a corrupt or missing asset. The
    // screen must swallow it and pop, never strand the user on a black frame.
    var done = 0;
    await tester.pumpWidget(host((_) => done++));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(done, 1,
        reason: 'a broken film must never block entry to the app');
  });

  testWidgets('onDone fires at most once, however it ends', (tester) async {
    var done = 0;
    await tester.pumpWidget(host((_) => done++));
    await tester.pump();
    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.tap(find.text('Skip'), warnIfMissed: false);
    await tester.pump();
    expect(done, 1, reason: 'a double tap must not pop two routes');
  });
}
