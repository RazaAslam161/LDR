import 'package:flutter/material.dart';

/// A minimal, abstract human silhouette — a stylized line drawing in the
/// spirit of a fashion croquis or medical diagram. NOT anatomically detailed.
/// Compliance: see INTIMACY_LAYER.md §F7.
class BodySilhouettePainter extends CustomPainter {
  BodySilhouettePainter({
    this.lineColor = const Color(0xFFF5EFE6),
    this.lineAlpha = 0.18,
    this.fillAlpha = 0.04,
  });

  final Color lineColor;
  final double lineAlpha;
  final double fillAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;

    final stroke = Paint()
      ..color = lineColor.withValues(alpha: lineAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final fill = Paint()
      ..color = lineColor.withValues(alpha: fillAlpha)
      ..style = PaintingStyle.fill;

    final path = Path();

    // Head — circle centered slightly above the body.
    final headR = w * 0.085;
    final headCy = h * 0.10;
    path.addOval(Rect.fromCircle(center: Offset(cx, headCy), radius: headR));

    // Neck connects head to shoulders.
    final neckY = headCy + headR;
    final shoulderY = h * 0.205;
    path.moveTo(cx - w * 0.025, neckY);
    path.lineTo(cx - w * 0.025, shoulderY);
    path.moveTo(cx + w * 0.025, neckY);
    path.lineTo(cx + w * 0.025, shoulderY);

    // Torso outline — a single continuous contour from one shoulder down to
    // the hip and back up to the other shoulder. Symmetric and stylized.
    path.moveTo(cx - w * 0.15, shoulderY);
    // Left shoulder → arm joint
    path.quadraticBezierTo(
      cx - w * 0.22, shoulderY + h * 0.005,
      cx - w * 0.205, shoulderY + h * 0.025,
    );
    // Outer arm down to hand
    path.quadraticBezierTo(
      cx - w * 0.22, h * 0.34,
      cx - w * 0.185, h * 0.46,
    );
    // Hand taper
    path.quadraticBezierTo(
      cx - w * 0.175, h * 0.50,
      cx - w * 0.16, h * 0.50,
    );
    // Inner arm back up to waist
    path.quadraticBezierTo(
      cx - w * 0.135, h * 0.40,
      cx - w * 0.105, h * 0.345,
    );
    // Waist curve down to hip
    path.quadraticBezierTo(
      cx - w * 0.135, h * 0.46,
      cx - w * 0.115, h * 0.535,
    );
    // Hip to center crotch
    path.quadraticBezierTo(
      cx - w * 0.115, h * 0.575,
      cx, h * 0.585,
    );
    // Up the right side — mirror.
    path.quadraticBezierTo(
      cx + w * 0.115, h * 0.575,
      cx + w * 0.115, h * 0.535,
    );
    path.quadraticBezierTo(
      cx + w * 0.135, h * 0.46,
      cx + w * 0.105, h * 0.345,
    );
    path.quadraticBezierTo(
      cx + w * 0.135, h * 0.40,
      cx + w * 0.16, h * 0.50,
    );
    path.quadraticBezierTo(
      cx + w * 0.175, h * 0.50,
      cx + w * 0.185, h * 0.46,
    );
    path.quadraticBezierTo(
      cx + w * 0.22, h * 0.34,
      cx + w * 0.205, shoulderY + h * 0.025,
    );
    path.quadraticBezierTo(
      cx + w * 0.22, shoulderY + h * 0.005,
      cx + w * 0.15, shoulderY,
    );
    // Shoulder line across the top
    path.quadraticBezierTo(cx, shoulderY - h * 0.012, cx - w * 0.15, shoulderY);

    // Legs — two tapering cylinders split at center.
    final crotchY = h * 0.585;
    final legTop = crotchY + h * 0.005;

    // Left leg outer
    path.moveTo(cx - w * 0.115, legTop);
    path.quadraticBezierTo(
      cx - w * 0.13, h * 0.72,
      cx - w * 0.105, h * 0.86,
    );
    path.quadraticBezierTo(
      cx - w * 0.09, h * 0.93,
      cx - w * 0.07, h * 0.96,
    );
    // Left foot
    path.quadraticBezierTo(
      cx - w * 0.04, h * 0.985,
      cx - w * 0.015, h * 0.96,
    );
    // Left leg inner back up
    path.quadraticBezierTo(
      cx - w * 0.015, h * 0.86,
      cx, h * 0.745,
    );
    // Back to crotch center
    path.lineTo(cx, crotchY);

    // Right leg — mirror.
    path.moveTo(cx + w * 0.115, legTop);
    path.quadraticBezierTo(
      cx + w * 0.13, h * 0.72,
      cx + w * 0.105, h * 0.86,
    );
    path.quadraticBezierTo(
      cx + w * 0.09, h * 0.93,
      cx + w * 0.07, h * 0.96,
    );
    path.quadraticBezierTo(
      cx + w * 0.04, h * 0.985,
      cx + w * 0.015, h * 0.96,
    );
    path.quadraticBezierTo(
      cx + w * 0.015, h * 0.86,
      cx, h * 0.745,
    );
    path.lineTo(cx, crotchY);

    canvas.drawPath(path, stroke);

    // Soft torso fill for warmth (very subtle).
    final torsoFill = Path()
      ..moveTo(cx - w * 0.135, shoulderY + h * 0.02)
      ..quadraticBezierTo(cx - w * 0.135, h * 0.46, cx - w * 0.115, h * 0.535)
      ..quadraticBezierTo(cx - w * 0.115, h * 0.575, cx, h * 0.585)
      ..quadraticBezierTo(cx + w * 0.115, h * 0.575, cx + w * 0.115, h * 0.535)
      ..quadraticBezierTo(cx + w * 0.135, h * 0.46, cx + w * 0.135, shoulderY + h * 0.02)
      ..quadraticBezierTo(cx, shoulderY - h * 0.01, cx - w * 0.135, shoulderY + h * 0.02)
      ..close();
    canvas.drawPath(torsoFill, fill);
  }

  @override
  bool shouldRepaint(covariant BodySilhouettePainter old) =>
      lineColor != old.lineColor ||
      lineAlpha != old.lineAlpha ||
      fillAlpha != old.fillAlpha;
}
