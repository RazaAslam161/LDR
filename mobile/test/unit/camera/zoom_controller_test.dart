import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/zoom_controller.dart';

/// The zoom curve and the call rate, tested over a real ticker.
///
/// Both are things you cannot see in a code review and cannot feel in a
/// simulator: whether equal finger travel gives equal ratio, and whether a
/// drag that emits a hundred pointer moves makes a hundred platform calls.
void main() {
  late List<double> pushed;

  ZoomController make({double min = 1, double max = 10}) {
    pushed = [];
    return ZoomController(
      apply: (l) async => pushed.add(l),
      vsync: const TestVSync(),
    )..configure(min: min, max: max);
  }

  /// Long enough for a full-range drag to converge and the ticker to stop.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  test('the usable range is capped below what the phone claims', () {
    // Phones report digital maxima they cannot resolve — 10x on hardware good
    // to about 3. Offering it spends the finger's travel budget on a smear.
    final c = make(max: 30);
    expect(c.max, 6.0);
    expect(c.min, 1.0);
    c.dispose();
  });

  test('a sub-1.0 minimum neither lowers the ceiling nor opens the wide lens',
      () {
    // A phone fronting its ultra-wide reports min 0.6. Capped relative to min
    // the ceiling would be 3.6x, and opening at min would frame every shot
    // wider than the user pointed the phone.
    final c = make(min: 0.6, max: 30);
    expect(c.max, 6.0);
    expect(c.value.value, 1.0);
    c.dispose();
  });

  testWidgets('equal finger travel gives equal RATIO, not equal distance',
      (tester) async {
    // The whole reason for the geometric curve. Linear mapping makes a finger
    // race through 1x-2x, where all the useful zoom lives, and then crawl
    // through 5x-6x, where none of it does.
    final c = make(max: 8);
    const span = 220.0; // the shipping calibration, set in configure

    c
      ..beginDrag()
      ..dragBy(span / 3);
    await settle(tester);
    final third = c.value.value;
    c.dragBy(2 * span / 3);
    await settle(tester);
    final twoThirds = c.value.value;
    c.dragBy(span);
    await settle(tester);
    final full = c.value.value;

    final firstRatio = third / 1.0;
    final secondRatio = twoThirds / third;
    final thirdRatio = full / twoThirds;

    expect(secondRatio, closeTo(firstRatio, 0.01),
        reason: 'the second third of the drag zoomed by a different factor '
            'than the first — the curve is not geometric',);
    expect(thirdRatio, closeTo(firstRatio, 0.01));
    c.dispose();
  });

  testWidgets('a drag starts from where the last one ended', (tester) async {
    // Without this every new drag snaps back to whatever the finger's absolute
    // position implies, so a second adjustment jumps before it moves.
    final c = make(max: 8)
      ..beginDrag()
      ..dragBy(100);
    await settle(tester);
    final afterFirst = c.value.value;
    expect(afterFirst, greaterThan(1.0));

    c
      ..beginDrag()
      ..dragBy(0);
    await settle(tester);
    expect(c.value.value, closeTo(afterFirst, 0.001),
        reason: 're-gripping reset the zoom instead of continuing from it',);
    c.dispose();
  });

  testWidgets('the range is honoured at both ends however far the finger '
      'travels', (tester) async {
    final c = make(max: 4)
      ..beginDrag()
      ..dragBy(5000);
    await settle(tester);
    expect(c.value.value, closeTo(4.0, 0.001));
    c
      ..beginDrag()
      ..dragBy(-5000);
    await settle(tester);
    expect(c.value.value, closeTo(1.0, 0.001));
    c.dispose();
  });

  testWidgets('the lens converges toward the target instead of jumping to it',
      (tester) async {
    // The smoothing. A finger that is also holding a shutter down shakes, and
    // an unsmoothed target is that shake applied straight to the lens.
    final c = make(max: 8)
      ..beginDrag()
      ..dragBy(220);
    await tester.pump(const Duration(milliseconds: 16));
    final first = c.value.value;
    expect(first, greaterThan(1.0));
    expect(first, lessThan(c.max), reason: 'the lens took the whole gap in one '
        'frame — there is no smoothing',);

    await tester.pump(const Duration(milliseconds: 16));
    expect(c.value.value, greaterThan(first));
    expect(c.value.value, lessThan(c.max));
    c.dispose();
  });

  testWidgets('the ticker stops once it arrives, and does not idle',
      (tester) async {
    // A ticker left running costs a frame callback for the life of the screen.
    final c = make(max: 8)
      ..beginDrag()
      ..dragBy(220);
    await settle(tester);
    expect(c.value.value, c.max);
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'the ticker is still scheduling frames after converging',);
    c.dispose();
  });

  testWidgets('a burst of frames does not become a burst of platform calls',
      (tester) async {
    // The defect this class exists for. setZoomLevel rebuilds the repeating
    // capture request; asking for the next one before the last has been applied
    // does not zoom faster, it just outruns a pipeline that can only show one
    // crop per preview frame.
    final calls = <double>[];
    final c = ZoomController(
      apply: (l) async {
        calls.add(l);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      },
      vsync: const TestVSync(),
    )
      ..configure(min: 1, max: 8)
      ..beginDrag()
      ..dragBy(220);

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(calls.length, 1, reason: 'more than one call was in flight at once');

    await settle(tester); // converge and stop, then let the replies land
    await tester.pump(const Duration(seconds: 1));
    c.dispose();
  });

  testWidgets('the value the drag ended on is the one the lens is left at',
      (tester) async {
    // The trailing edge. The ticker stops on the same frame as its last push,
    // so a final value dropped by the in-flight gate is never re-sent: the lens
    // sits short of the target while the indicator reads the target.
    final calls = <double>[];
    final c = ZoomController(
      apply: (l) async {
        calls.add(l);
        // Still in flight across the whole convergence.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      },
      vsync: const TestVSync(),
    )
      ..configure(min: 1, max: 8)
      ..beginDrag()
      ..dragBy(220);

    await settle(tester); // 640ms: convergence, then the first reply lands
    expect(calls.last, closeTo(c.max, 0.001),
        reason: 'the last level reached was never pushed to the camera',);

    await tester.pump(const Duration(milliseconds: 600)); // drain
    c.dispose();
  });

  testWidgets('the indicator follows the applied level, never the target',
      (tester) async {
    // If the label read the target it would show 6.0x while the lens was still
    // at 2.0x — a number ahead of the picture reads as lag even when the lens
    // is keeping up.
    final c = make(max: 6)
      ..beginDrag()
      ..dragBy(220);
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.value.value, lessThan(6.0));
    expect(c.value.value, pushed.last);
    c.dispose();
  });
}
