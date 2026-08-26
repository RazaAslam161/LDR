import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/hold_to_confirm.dart';

/// The one behavioural test in this slice, because the thing that matters
/// about this widget is timing and it is fully reachable without a backend.
///
/// The latch is the case worth the most: this fires an irreversible action,
/// and an AnimationController can reach `completed` more than once if the
/// finger stays down across a rebuild.
void main() {
  Future<int> run(
    WidgetTester tester, {
    required Future<void> Function(Offset centre) gesture,
  }) async {
    var fired = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: HoldToConfirm(
                label: 'Hold to end',
                holdingLabel: 'Ending…',
                onConfirmed: () => fired++,
              ),
            ),
          ),
        ),
      ),
    );
    await gesture(tester.getCenter(find.byType(HoldToConfirm)));
    return fired;
  }

  testWidgets('a tap fires nothing', (tester) async {
    final fired = await run(tester, gesture: (centre) async {
      await tester.tapAt(centre);
      await tester.pumpAndSettle();
    });
    expect(fired, 0, reason: 'a rage-mash must not end a relationship');
  });

  testWidgets('a press released early fires nothing', (tester) async {
    final fired = await run(tester, gesture: (centre) async {
      final g = await tester.startGesture(centre);
      // TapGestureRecognizer holds onTapDown until its 100ms deadline when it
      // is the only entrant in the arena, so the fill has not started yet.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 750));
      await g.up();
      await tester.pumpAndSettle();
    });
    expect(fired, 0);
  });

  testWidgets('a press held past the duration fires exactly once',
      (tester) async {
    final fired = await run(tester, gesture: (centre) async {
      final g = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 1300));
      await g.up();
      await tester.pumpAndSettle();
    });
    expect(fired, 1);
  });

  testWidgets('a press held far past the duration still fires exactly once',
      (tester) async {
    final fired = await run(tester, gesture: (centre) async {
      final g = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 3600));
      await tester.pump(const Duration(milliseconds: 1200));
      await g.up();
      await tester.pumpAndSettle();
    });
    expect(fired, 1, reason: 'the latch must hold across rebuilds');
  });

  testWidgets('a second hold after a release fires again', (tester) async {
    // The retry path. _confirm() can fail — the sheet then says "Try again" —
    // and a latch that never cleared would leave that sentence sitting above a
    // control that can no longer do anything.
    final fired = await run(tester, gesture: (centre) async {
      for (var i = 0; i < 2; i++) {
        final g = await tester.startGesture(centre);
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 1300));
        await g.up();
        await tester.pumpAndSettle();
      }
    });
    expect(fired, 2);
  });

  testWidgets('a null callback disables the control', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: HoldToConfirm(
                label: 'Hold to end',
                holdingLabel: 'Ending…',
              ),
            ),
          ),
        ),
      ),
    );
    final g = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirm)),
    );
    await tester.pump(const Duration(milliseconds: 2000));
    await g.up();
    await tester.pumpAndSettle();
    // Nothing to assert but the absence of a throw: a null callback must make
    // the control inert rather than merely unpainted.
    expect(tester.takeException(), isNull);
  });
}
