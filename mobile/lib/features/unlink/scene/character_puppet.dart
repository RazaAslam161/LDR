import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The person on the doorstep — a silhouette that acts with posture.
///
/// Deliberately NOT a face. At the forty-odd pixels a character gets on a
/// phone stage, posture reads emotion and faces read uncanny; every pose
/// below is body language only. The rig is the touch map's silhouette idea
/// grown joints: eight segments (head, torso, two two-part arms, two legs),
/// every length a fraction of the puppet's box, so one rig serves every size
/// and all three variants — male / female / neutral are proportion tables,
/// not separate drawings.
///
/// Poses are const data. The acting is a crossfade across [worry] on the
/// scene's one clock, plus seeded micro-noise so the figure never sits
/// mathematically still. The line this file must never cross: no IK, no
/// foot-planted walk cycles, no features — that is where puppet code becomes
/// unmaintainable code-art.
@immutable
class PuppetPose {
  const PuppetPose({
    this.lean = 0,
    this.headTilt = 0,
    this.weight = 0,
    this.armL = const ArmPose(0.30, 0.12),
    this.armR = const ArmPose(-0.30, -0.12),
    this.faceDoor = false,
  });

  /// Whole-body lean, radians. Positive = toward the door (screen left).
  final double lean;

  /// Head pitch/turn blend, radians. Negative = looking down.
  final double headTilt;

  /// Weight shift, -1 left leg … 1 right leg.
  final double weight;

  /// Shoulder and elbow angles, radians from hanging.
  final ArmPose armL;
  final ArmPose armR;

  /// Whether the figure has turned back toward the door.
  final bool faceDoor;

  /// This pose blended [t] of the way toward [b].
  PuppetPose lerpTo(PuppetPose b, double t) => PuppetPose(
        lean: ui.lerpDouble(lean, b.lean, t)!,
        headTilt: ui.lerpDouble(headTilt, b.headTilt, t)!,
        weight: ui.lerpDouble(weight, b.weight, t)!,
        armL: armL.lerpTo(b.armL, t),
        armR: armR.lerpTo(b.armR, t),
        faceDoor: t < 0.5 ? faceDoor : b.faceDoor,
      );

  // ── The worry loop. Four beats of figuring-it-out, crossfaded slowly:
  // arms crossed → glance back at the door → look down → pace-shift.
  static const List<PuppetPose> worry = [
    // Arms crossed, weight square: holding themselves together.
    PuppetPose(
      armL: ArmPose(0.95, 1.9),
      armR: ArmPose(-0.95, -1.9),
      headTilt: -0.10,
    ),
    // A look back at the door they closed.
    PuppetPose(
      lean: 0.06,
      headTilt: 0.30,
      weight: -0.5,
      armL: ArmPose(0.35, 0.25),
      armR: ArmPose(-0.55, -0.9),
      faceDoor: true,
    ),
    // Looking down at the doorstep.
    PuppetPose(
      headTilt: -0.34,
      weight: 0.3,
      armL: ArmPose(0.2, 0.4),
      armR: ArmPose(-0.2, -0.4),
    ),
    // A half-step's restlessness, hand toward the back of the neck.
    PuppetPose(
      lean: -0.04,
      headTilt: -0.12,
      weight: 0.7,
      armL: ArmPose(0.25, 0.2),
      armR: ArmPose(-1.6, -2.2),
    ),
  ];

}

@immutable
class ArmPose {
  const ArmPose(this.shoulder, this.elbow);

  final double shoulder;
  final double elbow;

  ArmPose lerpTo(ArmPose b, double t) => ArmPose(
        ui.lerpDouble(shoulder, b.shoulder, t)!,
        ui.lerpDouble(elbow, b.elbow, t)!,
      );
}

/// Proportions per variant — the whole difference between the three figures.
@immutable
class PuppetBuild {
  const PuppetBuild({
    required this.shoulder,
    required this.hip,
    required this.hairDepth,
    required this.hairFlow,
  });

  factory PuppetBuild.of(PuppetVariant v) => switch (v) {
        PuppetVariant.male => male,
        PuppetVariant.female => female,
        PuppetVariant.neutral => neutral,
      };

  /// Shoulder half-width as a fraction of puppet height.
  final double shoulder;

  /// Hip half-width, same unit.
  final double hip;

  /// How far the hair silhouette drops below the skull, fraction of height.
  final double hairDepth;

  /// Sideways sweep of the hair silhouette (0 = cropped close).
  final double hairFlow;

  static const male = PuppetBuild(
    shoulder: 0.118,
    hip: 0.082,
    hairDepth: 0.015,
    hairFlow: 0,
  );
  static const female = PuppetBuild(
    shoulder: 0.096,
    hip: 0.104,
    hairDepth: 0.16,
    hairFlow: 0.35,
  );
  static const neutral = PuppetBuild(
    shoulder: 0.106,
    hip: 0.092,
    hairDepth: 0.07,
    hairFlow: 0.15,
  );
}

/// Draws one posed figure into a box. Pure function of its inputs — the
/// caller owns time, poses and placement; this only knows how a body hangs
/// together.
void paintPuppet(
  Canvas canvas, {
  required Rect box,
  required PuppetPose pose,
  required PuppetBuild build,
  required double lampSide,
}) {
  final h = box.height;
  final cx = box.center.dx + pose.weight * h * 0.02;
  final groundY = box.bottom;

  final body = Paint()
    ..color = MilesColors.nightDeep
    ..strokeCap = StrokeCap.round
    ..strokeWidth = h * 0.055
    ..style = PaintingStyle.stroke;
  final fill = Paint()..color = MilesColors.nightDeep;
  // The lamp's rim light: the one thing that separates the figure from the
  // night. A stroke along the lamp-facing edge, no blur anywhere.
  final rim = Paint()
    ..color = MilesColors.gilt.withValues(alpha: 0.38)
    ..strokeCap = StrokeCap.round
    ..strokeWidth = math.max(1.2, h * 0.012)
    ..style = PaintingStyle.stroke;

  canvas
    ..save()
    ..translate(cx, groundY)
    ..rotate(pose.lean * (pose.faceDoor ? -1 : 1));

  final hipY = -h * 0.42;
  final shoulderY = -h * 0.74;
  final headC = Offset(pose.headTilt * h * 0.10, -h * 0.83);
  final headR = h * 0.085;

  // Legs: two straight strokes from the hips, weight-shifted.
  final hipL = Offset(-build.hip * h, hipY);
  final hipR = Offset(build.hip * h, hipY);
  final footL = Offset(-build.hip * h - pose.weight * h * 0.03, 0);
  final footR = Offset(build.hip * h + h * 0.02 - pose.weight * h * 0.03, 0);
  canvas
    ..drawLine(hipL, footL, body)
    ..drawLine(hipR, footR, body);

  // Torso: a tapered quad between shoulders and hips.
  final torso = Path()
    ..moveTo(-build.shoulder * h, shoulderY)
    ..lineTo(build.shoulder * h, shoulderY)
    ..lineTo(build.hip * h * 1.15, hipY)
    ..lineTo(-build.hip * h * 1.15, hipY)
    ..close();
  canvas
    ..drawPath(torso, fill)
    ..drawPath(
      torso,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.02
        ..color = MilesColors.nightDeep,
    );

  // Arms: shoulder→elbow→wrist, two segments each.
  void arm(double sx, ArmPose a) {
    final s = Offset(sx, shoulderY + h * 0.02);
    final upper = h * 0.19;
    final fore = h * 0.17;
    final e = s +
        Offset(math.sin(a.shoulder) * upper, math.cos(a.shoulder) * upper);
    final wr = e +
        Offset(
          math.sin(a.shoulder + a.elbow) * fore,
          math.cos(a.shoulder + a.elbow) * fore,
        );
    canvas
      ..drawLine(s, e, body)
      ..drawLine(e, wr, body);
  }

  arm(-build.shoulder * h, pose.armL);
  arm(build.shoulder * h, pose.armR);

  // Head + hair silhouette.
  canvas.drawCircle(headC, headR, fill);
  if (build.hairDepth > 0.02) {
    final hair = Path()
      ..addArc(
        Rect.fromCircle(center: headC, radius: headR * 1.08),
        math.pi,
        math.pi,
      )
      ..quadraticBezierTo(
        headC.dx + headR * (1 + build.hairFlow),
        headC.dy + h * build.hairDepth * 0.6,
        headC.dx + headR * 0.7,
        headC.dy + h * build.hairDepth,
      )
      ..lineTo(headC.dx - headR * 0.8, headC.dy + h * build.hairDepth * 0.8)
      ..close();
    canvas.drawPath(hair, fill);
  }

  // Rim light on the lamp side: head crown and shoulder line.
  final rimSide = lampSide.sign;
  canvas
    ..drawArc(
      Rect.fromCircle(center: headC, radius: headR),
      rimSide > 0 ? -math.pi * 0.45 : -math.pi * 0.95,
      math.pi * 0.4,
      false,
      rim,
    )
    ..drawLine(
      Offset(build.shoulder * h * rimSide, shoulderY),
      Offset(build.hip * h * rimSide, hipY * 1.02),
      rim,
    )
    ..restore();
}
