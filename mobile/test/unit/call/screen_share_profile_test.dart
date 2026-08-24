import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_controller.dart';

/// The arithmetic behind the screen-share encoder profile.
///
/// This is the half of the screen-share fix that can be tested without a
/// device: CallController itself cannot be constructed here (its renderers need
/// the platform plugin), so the decisions were deliberately written as pure
/// statics. What is NOT covered here — that setParameters actually reaches
/// libwebrtc, and that the picture improves — needs two handsets and getStats.
void main() {
  group('screenScaleFor', () {
    // getDisplayMedia captures display.getRealSize() at a fixed 30fps and
    // discards every constraint, so the panel size IS the encoder's input.
    // These are the panels that matter.
    test('a 1080x2400 handset scales to a 720p-class long edge', () {
      expect(CallController.screenScaleFor(const Size(1080, 2400)),
          closeTo(1.875, 0.001),);
      // 2400 / 1.875 == 1280.
      expect(2400 / 1.875, closeTo(1280, 0.001));
    });

    test('a 1440x3200 flagship scales further, not less', () {
      expect(CallController.screenScaleFor(const Size(1440, 3200)),
          closeTo(2.5, 0.001),);
    });

    test('a small panel is left alone rather than upscaled', () {
      expect(CallController.screenScaleFor(const Size(720, 1280)), 1.0);
      expect(CallController.screenScaleFor(const Size(540, 960)), 1.0);
    });

    test('orientation does not change the answer — the long edge decides', () {
      expect(
        CallController.screenScaleFor(const Size(1080, 2400)),
        CallController.screenScaleFor(const Size(2400, 1080)),
      );
    });

    test('absurd panels stay inside the clamp', () {
      expect(CallController.screenScaleFor(const Size(8000, 16000)), 4.0);
      expect(CallController.screenScaleFor(Size.zero), 1.0);
    });
  });

  group('screenProfileFor — the ladder', () {
    const panel = Size(1080, 2400);

    test('rung 0 is the target: full scale, highest framerate', () {
      final p = CallController.screenProfileFor(panel, 0);
      expect(p.scale, closeTo(1.875, 0.001));
      expect(p.fps, 24);
    });

    // The property the whole design rests on. One ladder rather than a cpu
    // branch and a bandwidth branch means the state is a single integer, and
    // that is only safe if every rung is genuinely cheaper than the one above
    // it in BOTH dimensions — otherwise "step down" could cost more.
    test('every rung is cheaper than the one above it, in both dimensions', () {
      var prev = CallController.screenProfileFor(panel, 0);
      for (var rung = 1; rung < 5; rung++) {
        final next = CallController.screenProfileFor(panel, rung);
        expect(next.scale, greaterThanOrEqualTo(prev.scale),
            reason: 'rung $rung must not ask for MORE pixels',);
        expect(next.fps, lessThanOrEqualTo(prev.fps),
            reason: 'rung $rung must not ask for MORE frames',);
        expect(next.scale > prev.scale || next.fps < prev.fps, isTrue,
            reason: 'rung $rung must give something up',);
        prev = next;
      }
    });

    test('out-of-range rungs clamp instead of throwing', () {
      expect(CallController.screenProfileFor(panel, -5).fps,
          CallController.screenProfileFor(panel, 0).fps,);
      expect(CallController.screenProfileFor(panel, 99).fps,
          CallController.screenProfileFor(panel, 4).fps,);
    });

    test('scale never leaves the clamp, on any panel or rung', () {
      const panels = [
        Size(540, 960),
        Size(720, 1280),
        Size(1080, 2400),
        Size(1440, 3200),
        Size(8000, 16000),
      ];
      for (final p in panels) {
        for (var rung = 0; rung < 5; rung++) {
          final profile = CallController.screenProfileFor(p, rung);
          expect(profile.scale, inInclusiveRange(1.0, 4.0),
              reason: '$p rung $rung',);
          // Below 10fps a shared screen stops reading as live at all.
          expect(profile.fps, inInclusiveRange(10, 24),
              reason: '$p rung $rung',);
        }
      }
    });

    // A rung means "how much is being given up", not an absolute size — so the
    // same rung has to be a comparable sacrifice on a 1080p panel and a 1440p
    // one, rather than pinning both to the same pixel count.
    test('a rung costs the same proportion on any panel', () {
      final small = CallController.screenProfileFor(const Size(1080, 2400), 2);
      final large = CallController.screenProfileFor(const Size(1440, 3200), 2);
      expect(small.scale / CallController.screenScaleFor(const Size(1080, 2400)),
          closeTo(
            large.scale / CallController.screenScaleFor(const Size(1440, 3200)),
            0.001,
          ),);
    });
  });
}
