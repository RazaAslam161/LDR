import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// The one warm, hopeful thing in the frame — and it SPEAKS.
///
/// A small round bird, the single `ember` accent the composition allows.
/// Three wing positions baked as sprites once per process (the EmberBackground
/// law: paint time is an atlas stamp, never a re-shade), a flight curve in,
/// and a two-frame perch loop with an occasional hop. The quote is the bird's
/// thought cloud — a real Text widget in the stage, because painted text
/// neither scales with the user's settings nor obeys the measure law, and the
/// words arrive one at a time once the bird has landed.
///
/// Drawn LARGE enough to be seen. The first cut rendered ~11px wide on a
/// 344px stage and the owner reported "there is no bird" — an actor nobody
/// can see is a defect, not subtlety.
class BirdPainter {
  BirdPainter._();

  /// Wing up / mid / down, baked at 48px and stamped at any scale.
  static final List<ui.Image> _frames = _bake();

  static List<ui.Image> _bake() {
    return List.generate(3, (i) {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      const s = 48.0;
      final body = Paint()..color = MilesColors.ember;
      final wing = Paint()..color = MilesColors.emberDeep;
      final belly = Paint()..color = MilesColors.emberSoft;

      // Body: one plump circle, slightly egg-shaped.
      const bodyC = Offset(s * 0.46, s * 0.58);
      c
        ..drawOval(
          Rect.fromCenter(center: bodyC, width: s * 0.52, height: s * 0.46),
          body,
        )
        // Belly patch — the "bright-eyed, cute" half of the brief lives in
        // these two touches: the lighter chest and the oversized head.
        ..drawOval(
          Rect.fromCenter(
            center: bodyC + const Offset(s * 0.04, s * 0.08),
            width: s * 0.34,
            height: s * 0.28,
          ),
          belly,
        );
      // Head, big relative to body.
      const headC = Offset(s * 0.62, s * 0.36);
      c
        ..drawCircle(headC, s * 0.17, body)
        // Eye: starlight ring, night pupil — reads bright at any size.
        ..drawCircle(
          headC + const Offset(s * 0.05, -s * 0.02),
          s * 0.05,
          Paint()..color = MilesColors.starlight,
        )
        ..drawCircle(
          headC + const Offset(s * 0.06, -s * 0.02),
          s * 0.025,
          Paint()..color = MilesColors.nightDeep,
        );
      // Beak.
      final beak = Path()
        ..moveTo(headC.dx + s * 0.15, headC.dy + s * 0.01)
        ..lineTo(headC.dx + s * 0.24, headC.dy + s * 0.05)
        ..lineTo(headC.dx + s * 0.14, headC.dy + s * 0.08)
        ..close();
      c.drawPath(beak, Paint()..color = MilesColors.gilt);
      // Tail.
      final tail = Path()
        ..moveTo(bodyC.dx - s * 0.24, bodyC.dy - s * 0.02)
        ..lineTo(bodyC.dx - s * 0.40, bodyC.dy - s * 0.12)
        ..lineTo(bodyC.dx - s * 0.36, bodyC.dy + s * 0.04)
        ..close();
      c.drawPath(tail, wing);
      // The wing, in its three baked positions.
      final lift = (i - 1) * s * 0.16; // -0.16s, 0, +0.16s
      final w = Path()
        ..moveTo(bodyC.dx - s * 0.06, bodyC.dy - s * 0.04)
        ..quadraticBezierTo(
          bodyC.dx - s * 0.20,
          bodyC.dy - s * 0.10 - lift,
          bodyC.dx - s * 0.30,
          bodyC.dy - s * 0.02 - lift,
        )
        ..quadraticBezierTo(
          bodyC.dx - s * 0.16,
          bodyC.dy + s * 0.10,
          bodyC.dx - s * 0.04,
          bodyC.dy + s * 0.06,
        )
        ..close();
      c
        ..drawPath(w, wing)
        // Feet tucked: two gilt dots.
        ..drawCircle(
          bodyC + const Offset(-s * 0.04, s * 0.24),
          s * 0.025,
          Paint()..color = MilesColors.gilt,
        )
        ..drawCircle(
          bodyC + const Offset(s * 0.06, s * 0.24),
          s * 0.025,
          Paint()..color = MilesColors.gilt,
        );
      return rec.endRecording().toImageSync(s.toInt(), s.toInt());
    });
  }

  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  /// Stamps the bird.
  ///
  /// [flight] 0..1 animates the approach along a settling arc to [perch]; at
  /// 1 the bird sits. [loop] drives the perch life: a slow breath, an
  /// occasional hop, wing flutter mid-flight. [dir] flips the approach side —
  /// the street bird comes in from the right, the window bird from the left.
  static void paint(
    Canvas canvas, {
    required Offset perch,
    required double size,
    required double flight,
    required double loop,
    double dir = 1,
  }) {
    Offset at;
    int frame;
    if (flight < 1) {
      final t = flight;
      // An arc that overshoots slightly downward then lifts to the perch —
      // how a bird actually lands.
      final sx = perch.dx + dir * size * 7 * (1 - t);
      final sy = perch.dy -
          size * 3.2 * math.sin(t * math.pi) +
          size * 1.4 * (1 - t);
      at = Offset(sx, sy);
      // Wingbeat: cycle the three frames quickly while flying.
      frame = ((t * 10) % 3).floor();
    } else {
      // Perched: breath bob, and one hop per loop at a fixed phase.
      final hop = _hopLift(loop);
      at = perch +
          Offset(0, -size * 0.04 * math.sin(loop * 2 * math.pi) - hop * size);
      frame = 1; // wing folded (mid)
    }
    final img = _frames[frame];
    final src =
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final dst = Rect.fromCenter(
      center: at,
      width: size * 1.6,
      height: size * 1.6,
    );
    canvas.drawImageRect(img, src, dst, _paint);
  }

  /// A small hop in a narrow window of the loop; zero elsewhere.
  static double _hopLift(double loop) {
    const start = 0.72;
    const span = 0.06;
    if (loop < start || loop > start + span) return 0;
    final t = (loop - start) / span;
    return 0.35 * math.sin(t * math.pi);
  }
}
