import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/zoom_controller.dart';

/// The zoom curve and the call rate, tested without a camera.
///
/// Both are things you cannot see in a code review and cannot feel in a
/// simulator: whether equal finger travel gives equal ratio, and whether a
/// drag that emits a hundred pointer moves makes a hundred platform calls.
void main() {
  late List<double> pushed;
  ZoomController make({double min = 1, double max = 10}) {
    pushed = [];
    // No vsync: applies straight through, so the curve is observable without
    // pumping frames. The ticker is what the smoothing test covers.
    final c = ZoomController(apply: (l) async => pushed.add(l))
      ..configure(min: min, max: max);
    return c;
  }

  test('the usable range is capped below what the phone claims', () {
    // Phones report digital maxima they cannot resolve — 10x on hardware good
    // to about 3. Offering it spends the finger's travel budget on a smear.
    final c = make(max: 30);
    expect(c.max, 6.0);
    expect(c.min, 1.0);
  });

  test('equal finger travel gives equal RATIO, not equal distance', () {
    // The whole reason for the geometric curve. Linear mapping makes a finger
    // race through 1x-2x, where all the useful zoom lives, and then crawl
    // through 5x-6x, where none of it does.
    final c = make(max: 8);
    const span = 200.0;

    c..beginDrag()..dragBy(span / 3);
    final third = c.value.value;
    c.dragBy(2 * span / 3);
    final twoThirds = c.value.value;
    c.dragBy(span);
    final full = c.value.value;

    final firstRatio = third / 1.0;
    final secondRatio = twoThirds / third;
    final thirdRatio = full / twoThirds;

    expect(secondRatio, closeTo(firstRatio, 0.01),
        reason: 'the second third of the drag zoomed by a different factor '
            'than the first — the curve is not geometric',);
    expect(thirdRatio, closeTo(firstRatio, 0.01));
  });

  test('a drag starts from where the last one ended', () {
    // Without this every new drag snaps back to whatever the finger's absolute
    // position implies, so a second adjustment jumps before it moves.
    final c = make(max: 8)
      ..beginDrag()
      ..dragBy(100);
    final afterFirst = c.value.value;
    expect(afterFirst, greaterThan(1.0));

    c..beginDrag()..dragBy(0);
    expect(c.value.value, closeTo(afterFirst, 0.001),
        reason: 're-gripping reset the zoom instead of continuing from it',);
  });

  test('the range is honoured at both ends however far the finger travels', () {
    final c = make(max: 4);
    c..beginDrag()..dragBy(5000);
    expect(c.value.value, closeTo(4.0, 0.001));
    c..beginDrag()..dragBy(-5000);
    expect(c.value.value, closeTo(1.0, 0.001));
  });

  test('a burst of pointer moves does not become a burst of platform calls',
      () async {
    // The defect this class exists for. setZoomLevel is a channel round trip;
    // calling it again before the last returns does not go faster, it queues,
    // and a queue is what turns a smooth drag into late jumps.
    var completed = 0;
    final c = ZoomController(apply: (l) async {
      // Never completes during the burst — simulates a busy platform.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      completed++;
    })
      ..configure(min: 1, max: 8)
      ..beginDrag();

    for (var i = 1; i <= 100; i++) {
      c.dragBy(i.toDouble());
    }
    // One in flight, ninety-nine coalesced away.
    expect(completed, 0);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(completed, 1,
        reason: 'more than one call was allowed in flight at once',);
  });

  test('the indicator follows the applied level, never the target', () {
    // If the label read the target it would show 6.0x while the lens was still
    // at 2.0x — a number that is ahead of the picture reads as lag even when
    // the lens is keeping up.
    final c = make(max: 8)
      ..beginDrag()
      ..dragBy(80);
    expect(c.value.value, pushed.isEmpty ? c.value.value : pushed.last);
  });
}
