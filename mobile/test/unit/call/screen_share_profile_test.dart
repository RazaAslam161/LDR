import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/screen_share_session.dart';

/// The arithmetic behind the share's climb ladder.
///
/// This is the half of the redesign that can be tested without a device:
/// ScreenShareSession's decisions are pure statics, because the session itself
/// cannot be constructed here (createPeerConnection needs the platform
/// plugin). What is NOT covered — that the offer negotiates, that frames flow,
/// that the climb actually walks — needs two handsets.
void main() {
  group('scaleFor', () {
    // getDisplayMedia captures display.getRealSize() and discards every
    // constraint, so the panel size IS the encoder's input. These are the
    // panels that matter.
    test('a 1080x2400 handset reaches each rung by its long edge', () {
      expect(ScreenShareSession.scaleFor(const Size(1080, 2400), 960),
          closeTo(2.5, 0.001),);
      expect(ScreenShareSession.scaleFor(const Size(1080, 2400), 1920),
          closeTo(1.25, 0.001),);
    });

    test('a 1440x3200 flagship scales further, not less', () {
      expect(ScreenShareSession.scaleFor(const Size(1440, 3200), 1920),
          closeTo(3200 / 1920, 0.001),);
    });

    test('a small capture is left alone rather than upscaled', () {
      expect(ScreenShareSession.scaleFor(const Size(720, 1280), 1920), 1.0);
      expect(ScreenShareSession.scaleFor(const Size(540, 960), 1920), 1.0);
    });

    test('orientation does not change the answer — the long edge decides', () {
      expect(
        ScreenShareSession.scaleFor(const Size(1080, 2400), 960),
        ScreenShareSession.scaleFor(const Size(2400, 1080), 960),
      );
    });

    test('a degenerate capture size cannot produce a broken scale', () {
      expect(ScreenShareSession.scaleFor(Size.zero, 960), 1.0);
    });
  });

  group('the climb', () {
    const climb = ScreenShareSession.climb;

    // The redesign's founding rule (BRAIN §180): the first frame goes out at a
    // rate any mobile uplink can fund. The failed design opened at the top and
    // the encoder could never fund frame one. The bound is sized for H.264
    // (roughly a quarter more bits than VP9 for the same text) — and a
    // ceiling is what BWE ramps into, never an opening bid.
    test('the first rung is fundable on a bad mobile uplink', () {
      expect(climb.first.maxKbps, lessThanOrEqualTo(1200));
      expect(climb.first.longEdge, lessThanOrEqualTo(960));
      expect(ScreenShareSession.minKbps,
          lessThanOrEqualTo(climb.first.maxKbps),);
    });

    test('the top rung is full 1920-class sharpness at full motion', () {
      expect(climb.last.longEdge, 1920);
      expect(climb.last.fps, greaterThanOrEqualTo(30));
    });

    // The property the single-integer rung state rests on: walking up must
    // never make anything cheaper, walking down must never make anything more
    // expensive — otherwise "one rung down" could cost more and oscillate.
    test('every rung is strictly richer than the one below it', () {
      for (var i = 1; i < climb.length; i++) {
        expect(climb[i].longEdge, greaterThanOrEqualTo(climb[i - 1].longEdge),
            reason: 'rung $i must not shed pixels on the way up',);
        expect(climb[i].fps, greaterThanOrEqualTo(climb[i - 1].fps),
            reason: 'rung $i must not shed frames on the way up',);
        expect(climb[i].maxKbps, greaterThan(climb[i - 1].maxKbps),
            reason: 'rung $i must fund its extra pixels or frames',);
      }
    });

    // Sanity on the funding itself: a rung that raises the pixel rate without
    // raising the budget proportionally recreates the unfunded-start failure
    // one step later.
    test('a share can climb — the ladder has at least three rungs', () {
      expect(climb.length, greaterThanOrEqualTo(3));
    });
  });

  group('isClean — what counts as a rung-worthy second', () {
    // The defect this gate exists to avoid: Android's capturer produces
    // frames only when the display CHANGES, so a shared document sits at
    // near-zero encoded fps while perfectly healthy — and static text is
    // exactly the content that needs the top rung most.
    test('a static page climbs — zero fps with an idle capturer is clean', () {
      expect(
        ScreenShareSession.isClean(
            limitation: 'none', fps: 0, captureFps: 0, rungFps: 15,),
        isTrue,
      );
    });

    test('moving content must actually keep up', () {
      expect(
        ScreenShareSession.isClean(
            limitation: 'none', fps: 8, captureFps: 30, rungFps: 15,),
        isFalse,
        reason: '8fps against a 15fps rung on moving content is a struggling '
            'encoder, whatever the limitation string says',
      );
      expect(
        ScreenShareSession.isClean(
            limitation: 'none', fps: 13, captureFps: 30, rungFps: 15,),
        isTrue,
      );
    });

    test('slow content is judged against what the capturer produced', () {
      // A page scrolled occasionally: capture 5fps, encode 5fps — clean.
      expect(
        ScreenShareSession.isClean(
            limitation: 'none', fps: 5, captureFps: 5, rungFps: 24,),
        isTrue,
      );
    });

    test('no outbound report yet is not evidence', () {
      expect(
        ScreenShareSession.isClean(
            limitation: '', fps: 20, captureFps: 30, rungFps: 15,),
        isFalse,
      );
    });

    test('cpu and bandwidth are never clean, whatever the fps', () {
      for (final l in ['cpu', 'bandwidth']) {
        expect(
          ScreenShareSession.isClean(
              limitation: l, fps: 30, captureFps: 30, rungFps: 15,),
          isFalse,
          reason: l,
        );
      }
    });
  });

  group('samplesNeeded — how fast a clean link climbs', () {
    test('proven headroom climbs on a single clean second', () {
      expect(
        ScreenShareSession.samplesNeeded(
            bweKbps: 3000, nextRungMaxKbps: 2000, recentFall: false,),
        1,
      );
    });

    test('an unproven link takes two', () {
      expect(
        ScreenShareSession.samplesNeeded(
            bweKbps: 2100, nextRungMaxKbps: 2000, recentFall: false,),
        2,
      );
      expect(
        ScreenShareSession.samplesNeeded(
            bweKbps: 0, nextRungMaxKbps: 2000, recentFall: false,),
        2,
      );
    });

    test('a recent fall disables the fast path — no 1Hz oscillation', () {
      expect(
        ScreenShareSession.samplesNeeded(
            bweKbps: 9000, nextRungMaxKbps: 2000, recentFall: true,),
        2,
      );
    });
  });
}
