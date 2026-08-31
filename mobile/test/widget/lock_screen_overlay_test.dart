import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/lock_screen.dart';

/// The app lock is a security control, and it kept throwing when it raised.
///
/// Round one: [LockScreen] returned a `Positioned.fill`, main.dart mounted it
/// under a `RepaintBoundary`, and the Positioned's nearest ancestor render
/// object was the boundary rather than the Stack — "Incorrect use of
/// ParentDataWidget", which (per the CallPip note in main.dart) greys out the
/// whole app and swallows every touch. That was fixed by mounting it directly,
/// and this file pinned the rule from both sides.
///
/// Round two, and the reason the contract MOVED: `cover_gate` also pushes this
/// screen as a `MaterialPageRoute`, where the parent is the route's Semantics
/// and no Stack exists at all. A widget that IS a Positioned cannot satisfy
/// both mount sites. Every launch from build 68 filed a `_TypeError` out of
/// `Positioned.applyParentData` (release skips the assert that makes it a
/// readable FlutterError in debug) — six a launch, unexplained for two days.
///
/// So LockScreen is no longer a Positioned: it fills whatever it is given, and
/// the ONE mount site that needs positioning does it there. The old tripwire
/// test asked to be relaxed "deliberately rather than by accident" if this
/// ever happened — this is that, deliberately.
void main() {
  testWidgets('mounts clean as a direct Stack child', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Stack(children: [LockScreen()]),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a render object between it and the Stack is now FINE',
      (tester) async {
    // The inversion of round one's rule, and the proof the class is closed:
    // there is no ParentDataWidget left to misplace, so no ancestor between
    // this screen and a Stack can break it.
    await tester.pumpWidget(const MaterialApp(
      home: Stack(children: [
        RepaintBoundary(child: LockScreen()),
      ],),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'LockScreen stopped being a Positioned; an ancestor render '
            'object between it and the Stack must no longer matter',);
  });

  testWidgets('survives being pushed as a route, with no Stack above it',
      (tester) async {
    // cover_gate.dart's mount site — the one that was throwing in the field.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => const LockScreen(),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull,
        reason: 'cover_gate pushes this as a route; it may not assume a Stack',);
  });

  testWidgets('still covers the app at main.dart mount site', (tester) async {
    // The half that must not regress: the lock has to cover everything, not
    // shrink to its own column.
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            SizedBox.expand(child: ColoredBox(color: Color(0xFF000000))),
            Positioned.fill(child: LockScreen()),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(LockScreen)),
      tester.getSize(find.byType(Stack).first),
      reason: 'the lock screen must cover the app',
    );
  });
}
