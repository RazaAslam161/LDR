import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// The ceremony's clock, as an object in the scene rather than a readout on
/// the chrome.
///
/// The owner's call, and the right one: everything else on the stage became
/// scene-language, and the one remaining number floated centre-screen like a
/// subtitle from another app. Now time hangs in the corner the way a clock
/// hangs in a room.
///
/// ART GIVES THE BODY, CODE GIVES THE HANDS — the §228 lantern precedent.
/// The owner's 3D casing ships with a blank dial; the hands and the
/// depleting arc are painted here from the row's own timestamps, so the
/// object can never disagree with the gate logic it depicts. Until the 3D
/// body arrives, [body] is null and a drawn casing stands in.
///
/// Two temperaments, one object:
///  * COOLING — no ticking anything. The arc quietly depletes gilt→ember
///    across the 24 hours; the hands show what is left. Glanceable, never
///    nagging: this is the design law "no countdown manufactures urgency",
///    kept, in analog.
///  * LAST CALL — the clock wakes: slightly larger, arc burning ember, a
///    second hand appears. The urgency of five real minutes lives in the
///    object, in its corner, over nobody's face.
/// Where a body's dial actually sits — measured off the shipped asset on a
/// grid, never guessed. [squashX] carries a render that arrived slightly
/// three-quarter: hands and arc are drawn in a horizontally-squashed space
/// about the dial centre, so they foreshorten WITH the dial instead of
/// floating flat on top of it.
@immutable
class DialSpec {
  const DialSpec(this.cx, this.cy, this.r, {this.squashX = 1});

  /// Fractions of the body image (cx, cy) and of its width (r).
  final double cx;
  final double cy;
  final double r;
  final double squashX;

  /// The drawn stand-in body: a perfect circle in the middle.
  static const drawn = DialSpec(0.5, 0.5, 0.43);

  /// clock_porch.webp (395x512): dial x .13-.87, y .14-.90 on the grid — a
  /// real ellipse (the render is slightly three-quarter), carried by squashX
  /// rather than bounced a third time.
  static const porch = DialSpec(0.50, 0.52, 0.37, squashX: 0.76);

  /// clock_room.webp (238x256, re-cropped below the lamp): face-on.
  static const room = DialSpec(0.52, 0.55, 0.35);
}

class DoorstepClock extends StatelessWidget {
  const DoorstepClock({
    required this.remaining,
    required this.total,
    required this.lastCall,
    this.body,
    this.dial = DialSpec.drawn,
    this.dimension,
    super.key,
  });

  /// Edge length in logical pixels. The stage's corner asks for a small one:
  /// at 64 the plate around it grew tall enough to cover the conversation it
  /// was timing, which is what the owner saw on the handset.
  final double? dimension;

  final DialSpec dial;

  /// Time left in the current window, clamped to >= zero by the caller.
  final Duration remaining;

  /// The window's full span, for the arc.
  final Duration total;

  final bool lastCall;

  /// The owner's 3D casing (blank dial). Null draws the built-in body.
  final ui.Image? body;

  @override
  Widget build(BuildContext context) {
    final size = dimension ?? (lastCall ? 76.0 : 64.0);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _ClockPainter(
          remaining: remaining,
          total: total,
          lastCall: lastCall,
          body: body,
          dial: dial,
        ),
      ),
    );
  }
}

class _ClockPainter extends CustomPainter {
  const _ClockPainter({
    required this.remaining,
    required this.total,
    required this.lastCall,
    required this.body,
    required this.dial,
  });

  final Duration remaining;
  final Duration total;
  final bool lastCall;
  final ui.Image? body;
  final DialSpec dial;

  @override
  void paint(Canvas canvas, Size size) {
    var c = size.center(Offset.zero);
    var r = size.shortestSide / 2;

    // ── The body ──
    final img = body;
    if (img != null) {
      // Aspect-fit: a clock with a base or a hanging ring is not a circle,
      // and squeezing it into one turns a prop into an icon.
      final scale = (size.width / img.width < size.height / img.height)
          ? size.width / img.width
          : size.height / img.height;
      final w = img.width * scale;
      final h = img.height * scale;
      final box = Rect.fromLTWH(
        (size.width - w) / 2,
        (size.height - h) / 2,
        w,
        h,
      );
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        box,
        Paint()..filterQuality = FilterQuality.medium,
      );
      // Hands and arc live where the MEASURED dial is, not where the image
      // centre is — and a slightly three-quarter body squashes the drawing
      // space with it.
      c = Offset(
        box.left + box.width * dial.cx,
        box.top + box.height * dial.cy,
      );
      r = box.width * dial.r;
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..scale(dial.squashX, 1)
        ..translate(-c.dx, -c.dy);
    } else {
      // The drawn stand-in: warm dark casing, cream dial, hour marks.
      canvas
        ..drawCircle(
          c,
          r,
          Paint()..color = const Color(0xFF3A2A22),
        )
        ..drawCircle(
          c,
          r * 0.86,
          Paint()..color = MilesColors.cream100.withValues(alpha: 0.92),
        );
      final mark = Paint()
        ..color = const Color(0xFF6B5344)
        ..strokeWidth = math.max(1, r * 0.05)
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 12; i++) {
        final a = i * math.pi / 6;
        canvas.drawLine(
          c + Offset(math.sin(a), -math.cos(a)) * r * 0.76,
          c + Offset(math.sin(a), -math.cos(a)) * r * 0.68,
          mark,
        );
      }
    }

    // ── The arc: how much of the window is left ──
    final frac = total.inSeconds <= 0
        ? 0.0
        : (remaining.inSeconds / total.inSeconds).clamp(0.0, 1.0);
    final arcColor = lastCall
        ? MilesColors.ember
        : Color.lerp(MilesColors.ember, MilesColors.gilt, frac)!;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.97),
      -math.pi / 2,
      2 * math.pi * frac,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, r * 0.075)
        ..strokeCap = StrokeCap.round
        ..color = arcColor.withValues(alpha: lastCall ? 0.95 : 0.75),
    );

    // ── The hands: what is left, told as time ──
    void hand(double turns, double length, double width, Color color) {
      final a = 2 * math.pi * turns;
      canvas.drawLine(
        c,
        c + Offset(math.sin(a), -math.cos(a)) * r * length,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }

    const dark = Color(0xFF2E211B);
    final hoursLeft = remaining.inMinutes / 60.0;
    // Hour hand: a 12-hour dial of what remains.
    hand((hoursLeft % 12) / 12, 0.42, math.max(2, r * 0.09), dark);
    // Minute hand.
    hand((remaining.inMinutes % 60) / 60, 0.60, math.max(1.5, r * 0.06), dark);
    // Second hand, ONLY when the last five minutes are real urgency.
    if (lastCall) {
      hand(
        (remaining.inSeconds % 60) / 60,
        0.66,
        math.max(1, r * 0.035),
        MilesColors.ember,
      );
    }
    canvas.drawCircle(c, math.max(1.5, r * 0.06), Paint()..color = dark);
    if (body != null) canvas.restore();
  }

  @override
  bool shouldRepaint(_ClockPainter old) =>
      old.remaining.inSeconds != remaining.inSeconds ||
      old.lastCall != lastCall ||
      old.dial != dial ||
      !identical(old.body, body);
}
