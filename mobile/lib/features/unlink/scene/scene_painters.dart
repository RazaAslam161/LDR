import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';

/// Cover-fit of one backdrop onto the canvas, plus the mapping from image
/// fractions to canvas coordinates that every sprite placement goes through.
///
/// The geometry constants below were MEASURED on the owner's art (grid
/// overlays, 2026-08-30), not guessed: the door leaf must land in the
/// backdrop's empty doorway to the pixel or the whole trick shows.
class _Cover {
  _Cover(ui.Image img, Size size)
      : scale = math.max(
          size.width / img.width,
          size.height / img.height,
        ),
        iw = img.width.toDouble(),
        ih = img.height.toDouble(),
        _size = size;

  final double scale;
  final double iw;
  final double ih;
  final Size _size;

  double get dx => (_size.width - iw * scale) / 2;
  double get dy => (_size.height - ih * scale) / 2;

  Rect get dst => Rect.fromLTWH(dx, dy, iw * scale, ih * scale);

  /// An image-fraction rect, in canvas coordinates.
  Rect rect(double x, double y, double w, double h) =>
      Rect.fromLTWH(dx + x * iw * scale, dy + y * ih * scale, w * iw * scale,
          h * ih * scale,);

  Offset at(double x, double y) =>
      Offset(dx + x * iw * scale, dy + y * ih * scale);
}

/// Shared anchor points of the bitmap world — the actor painter needs the
/// same lamp arm and window sill the world painter draws, and one function
/// each keeps the two from drifting apart.
class SceneGeom {
  SceneGeom._();

  static final Paint bmp = Paint()..filterQuality = FilterQuality.low;

  /// Where the street bird lands: the lamp's crossarm, between arm tip and
  /// pole. Must match [DoorstepPainter]'s lamp placement.
  static Offset lampPerch(Size size) {
    final d = lampDst(size);
    return Offset(d.left + d.width * 0.47, d.top + d.height * 0.145);
  }

  /// The lamp sprite's destination. Pole at x0.61 of the sprite stands at
  /// 0.82w; base near the frame's bottom edge, in front of the grass line.
  static Rect lampDst(Size size) {
    final lampH = size.height * 0.68;
    final lampW = lampH * 516 / 900;
    return Rect.fromLTWH(
      size.width * 0.82 - lampW * 0.61,
      size.height * 0.98 - lampH,
      lampW,
      lampH,
    );
  }

  /// The lantern the matting ate: it hung at the crossarm's tip. Painted in
  /// code instead — which is also what lets it flicker.
  static Offset lanternAt(Size size) {
    final d = lampDst(size);
    return Offset(d.left + d.width * 0.33, d.top + d.height * 0.185);
  }

  /// The window-sill perch of the inside view's bird.
  static Offset sillPerch(Size size) =>
      _Cover(SceneArt.backdropIn!, size).at(0.155, 0.575);

  /// A source slice of the door sprite whose aspect matches [dstAspect]
  /// exactly, anchored to the KNOB side so nothing stretches and the handle
  /// — the way back — survives the crop.
  static Rect doorSrc(ui.Image door, double dstAspect) {
    final iw = door.width.toDouble();
    final ih = door.height.toDouble();
    final sw = math.min(iw, ih * dstAspect);
    return Rect.fromLTWH(iw - sw, 0, sw, ih);
  }

  /// The knob's x, as a fraction of the [doorSrc] slice (it sits at 0.87 of
  /// the full sprite).
  static double knobRelX(ui.Image door, Rect src) =>
      (door.width * 0.87 - src.left) / src.width;

  /// The hearth view's slice: same aspect-match, but CENTERED on the knob —
  /// its leaf is a sliver at the frame's edge, and a right-anchored slice
  /// would stop 7px short of the brass.
  static Rect doorSrcKnobCentered(ui.Image door, double dstAspect) {
    final iw = door.width.toDouble();
    final ih = door.height.toDouble();
    final sw = math.min(iw, ih * dstAspect);
    final left = (iw * 0.87 - sw / 2).clamp(0.0, iw - sw);
    return Rect.fromLTWH(left, 0, sw, ih);
  }
}

/// The Doorstep's world: sky, house, street — everything that is not alive.
///
/// One painter, because the world is one drawing. It follows EmberBackground's
/// laws to the letter: `shouldRepaint => false` with every repaint coming from
/// the `repaint:` listenable the stage owns; the star field baked into a
/// sprite once per process and stamped with `drawAtlas`; nothing blurred,
/// nothing re-shaded — light is gradients painted once into shapes, and
/// motion is transforms over them.
///
/// Every coordinate is a fraction of the canvas, so the same drawing holds on
/// any stage size, and every colour is MilesColors — the warm law (nothing
/// bluer than red) is true by construction.
class DoorstepPainter extends CustomPainter {
  DoorstepPainter({
    required Listenable repaint,
    required this.frame,
  }) : super(repaint: repaint);

  /// The stage's clock, written by its one ticker. The painter reads, never
  /// drives.
  final SceneFrame frame;

  /// Star sprite, baked once per process — a soft point of starlight with its
  /// halo IN the sprite, so paint time is a plain atlas stamp.
  static ui.Image? _star;

  /// Deterministic field so the golden previews are byte-stable.
  static final List<_Star> _stars = _seedStars();

  static List<_Star> _seedStars() {
    final r = math.Random(11);
    return List.generate(46, (_) {
      return _Star(
        x: r.nextDouble(),
        y: r.nextDouble() * 0.42,
        scale: 0.5 + r.nextDouble() * 0.8,
        phase: r.nextDouble(),
      );
    });
  }

  static ui.Image _bakeStar() {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const s = 24.0;
    final p = Paint()
      ..shader = const RadialGradient(
        colors: [MilesColors.starlight, Color(0x00FBEFD6)],
      ).createShader(const Rect.fromLTWH(0, 0, s, s));
    c.drawRect(const Rect.fromLTWH(0, 0, s, s), p);
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  static final Paint _atlasPaint = Paint()
    ..filterQuality = FilterQuality.low;

  /// Six fireflies over the grass line — seeded, so the goldens hold still.
  static final List<_Drifter> _fireflies = _Drifter.seed(6, 21);

  @override
  void paint(Canvas canvas, Size size) {
    if (SceneArt.ready) {
      _paintStreet(canvas, size);
      return;
    }
    final w = size.width;
    final h = size.height;
    final t = frame.loop; // 0..1, one sceneLoop cycle
    final dawn = frame.dawn;

    // ── Sky. Night walks toward pre-dawn as the deadline nears: the night
    // stays Emberlight-warm, the horizon picks up the first ember of morning.
    final skyTop = Color.lerp(MilesColors.nightDeep, MilesColors.night, dawn)!;
    final skyLow = Color.lerp(
      MilesColors.night,
      MilesColors.tint(MilesColors.emberDeep, 0.35),
      dawn,
    )!;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [skyTop, skyLow],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // ── Stars: one atlas call. Twinkle rides the atlas colours; the slow
    // sideways breath of the whole field is this canvas transform — a sine,
    // not a conveyor, so the loop's restart never jumps.
    _star ??= _bakeStar();
    final drift = math.sin(t * 2 * math.pi) * w * 0.006;
    final transforms = <RSTransform>[];
    final rects = <Rect>[];
    final colors = <Color>[];
    final sRect = Rect.fromLTWH(
      0,
      0,
      _star!.width.toDouble(),
      _star!.height.toDouble(),
    );
    for (final s in _stars) {
      final tw =
          0.35 + 0.65 * (0.5 + 0.5 * math.sin((t + s.phase) * 2 * math.pi));
      // Stars thin out as dawn comes up.
      final a = (tw * (1.0 - dawn * 0.7) * 255).round();
      transforms.add(
        RSTransform.fromComponents(
          rotation: 0,
          scale: s.scale * (w / 900),
          anchorX: 12,
          anchorY: 12,
          translateX: s.x * w + drift,
          translateY: s.y * h,
        ),
      );
      rects.add(sRect);
      colors.add(Color.fromARGB(a, 255, 255, 255));
    }
    canvas.drawAtlas(
      _star!,
      transforms,
      rects,
      colors,
      BlendMode.modulate,
      null,
      _atlasPaint,
    );

    // ── The house: facade filling the left two-thirds, gable roofline.
    final housePaint = Paint()..color = MilesColors.surface1;
    final houseTop = h * 0.18;
    final houseRight = w * 0.62;
    final ground = h * 0.86;
    final house = Path()
      ..moveTo(-2, ground)
      ..lineTo(-2, houseTop + h * 0.06)
      ..lineTo(w * 0.20, houseTop)
      ..lineTo(houseRight, houseTop + h * 0.05)
      ..lineTo(houseRight, ground)
      ..close();
    canvas
      ..drawPath(house, housePaint)
      // Roof edge catches a hair of lamplight.
      ..drawPath(
        house,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = MilesColors.hairline,
      );

    // The window: lit while somebody is inside, and it dims as dawn takes
    // over — the story's second light source, kept subordinate to the lamp.
    final win = Rect.fromLTWH(w * 0.10, h * 0.34, w * 0.115, h * 0.115);
    final winGlow = (1.0 - dawn * 0.45) * frame.windowLit;
    canvas.drawRRect(
      RRect.fromRectAndRadius(win, Radius.circular(w * 0.008)),
      Paint()
        ..color = MilesColors.tint(
          MilesColors.gilt,
          0.16 + 0.34 * winGlow,
          over: MilesColors.surface2,
        ),
    );
    // Muntins, so it reads as a window and not a screen.
    final mun = Paint()
      ..color = MilesColors.surface1
      ..strokeWidth = math.max(1.5, w * 0.006);
    canvas
      ..drawLine(win.topCenter, win.bottomCenter, mun)
      ..drawLine(win.centerLeft, win.centerRight, mun);

    // ── The door. Angle 0 = shut; the slam animates this; the flood opens
    // it. Hinged at its left edge, swung with a horizontal squeeze — the
    // 2.5D read of a door turning toward the viewer.
    final doorW = w * 0.135;
    final doorH = h * 0.30;
    final doorL = w * 0.335;
    final doorTop = ground - doorH;
    final openness = frame.doorOpen; // 0 shut .. 1 wide
    canvas
      ..save()
      ..translate(doorL, 0)
      ..scale(1 - 0.82 * openness, 1);
    final door = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, doorTop, doorW, doorH),
      topLeft: Radius.circular(w * 0.006),
      topRight: Radius.circular(w * 0.006),
    );
    canvas
      ..drawRRect(door, Paint()..color = MilesColors.surface2)
      ..drawRRect(
        door,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = MilesColors.hairline,
      );
    // The handle — and, when the way back opens, its glow. The glow is a
    // baked-style radial inside a fixed rect: painted, not blurred.
    final knob = Offset(doorW * 0.82, doorTop + doorH * 0.52);
    if (frame.handleGlow > 0) {
      final gr = doorW * 0.42 * (0.85 + 0.15 * math.sin(t * 4 * math.pi));
      canvas.drawCircle(
        knob,
        gr,
        Paint()
          ..shader = RadialGradient(
            colors: [
              MilesColors.gilt.withValues(alpha: 0.55 * frame.handleGlow),
              MilesColors.gilt.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: knob, radius: gr)),
      );
    }
    canvas.drawCircle(knob, w * 0.008, Paint()..color = MilesColors.gilt);
    // The bolt: slides across the seam during the last call.
    if (frame.bolt > 0) {
      final boltY = doorTop + doorH * 0.36;
      final len = doorW * 0.30 * frame.bolt;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(doorW - len, boltY, len, h * 0.012),
          Radius.circular(h * 0.006),
        ),
        Paint()..color = MilesColors.taupe,
      );
    }
    // Light spilling through the opening door.
    if (openness > 0.02) {
      canvas.drawRect(
        Rect.fromLTWH(doorW * (1.0 - 0.1), doorTop, doorW * 2.2, doorH),
        Paint()
          ..shader = LinearGradient(
            colors: [
              MilesColors.starlight.withValues(alpha: 0.5 * openness),
              MilesColors.starlight.withValues(alpha: 0),
            ],
          ).createShader(
            Rect.fromLTWH(doorW, doorTop, doorW * 2.2, doorH),
          ),
      );
    }
    canvas
      ..restore()
      // ── The street.
      ..drawRect(
        Rect.fromLTWH(0, ground, w, h - ground),
        Paint()..color = MilesColors.nightDeep,
      )
      ..drawLine(
        Offset(0, ground),
        Offset(w, ground),
        Paint()
          ..color = MilesColors.hairline
          ..strokeWidth = 1.2,
      );

    // ── The lamp post, right third, with its cone crossing the doorstep.
    final postX = w * 0.82;
    final postTop = h * 0.24;
    final flicker = frame.lampFlicker; // 1 = steady
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            postX - w * 0.006,
            postTop,
            w * 0.012,
            ground - postTop,
          ),
          Radius.circular(w * 0.006),
        ),
        Paint()..color = MilesColors.surface2,
      )
      // Crossarm the bird lands on.
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(postX - w * 0.085, postTop, w * 0.10, h * 0.010),
          Radius.circular(h * 0.005),
        ),
        Paint()..color = MilesColors.surface2,
      );
    final lampAt = Offset(postX - w * 0.062, postTop + h * 0.028);
    // The cone: one gradient path, breathing with the loop, dimming into dawn.
    final coneAlpha =
        (0.14 + 0.03 * math.sin(t * 2 * math.pi)) * flicker * (1 - dawn * 0.5);
    final cone = Path()
      ..moveTo(lampAt.dx, lampAt.dy)
      ..lineTo(w * 0.30, ground)
      ..lineTo(w * 1.02, ground)
      ..close();
    canvas
      ..drawPath(
        cone,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              MilesColors.gilt.withValues(alpha: coneAlpha),
              MilesColors.gilt.withValues(alpha: coneAlpha * 0.25),
            ],
          ).createShader(Rect.fromLTWH(w * 0.3, lampAt.dy, w * 0.7, ground)),
      )
      // The lamp head itself.
      ..drawCircle(
        lampAt,
        w * 0.016,
        Paint()
          ..color = MilesColors.starlight.withValues(alpha: 0.9 * flicker),
      )
      // Pool of light on the road.
      ..drawOval(
        Rect.fromCenter(
          center: Offset(w * 0.62, ground + (h - ground) * 0.45),
          width: w * 0.5,
          height: (h - ground) * 0.7,
        ),
        Paint()
          ..color = MilesColors.tint(MilesColors.gilt, 0.10 * flicker)
              .withValues(alpha: 0.35 * flicker * (1 - dawn * 0.4)),
      );
  }

  /// The owner's street. Backdrop cover-fit, the door leaf composited into
  /// the backdrop's empty doorway (measured: x 0.362–0.612, y 0.565–0.945),
  /// the lamp sprite with its lantern painted back in code, fireflies over
  /// the grass, and dawn as one warm wash — all motion still transforms and
  /// alpha over stills.
  void _paintStreet(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = frame.loop;
    final dawn = frame.dawn;
    final flicker = frame.lampFlicker;
    final cover = _Cover(SceneArt.backdropOut!, size);

    canvas.drawImageRect(
      SceneArt.backdropOut!,
      Rect.fromLTWH(0, 0, cover.iw, cover.ih),
      cover.dst,
      SceneGeom.bmp,
    );

    // ── The door, hinged at the doorway's left edge; the slam's squeeze is
    // the same 2.5D read the painted leaf used. The doorway behind it is
    // baked dark in the backdrop, so an opening leaf reveals the hall for
    // free.
    final leaf = cover.rect(0.362, 0.565, 0.250, 0.380);
    final door = SceneArt.door!;
    final src = SceneGeom.doorSrc(door, leaf.width / leaf.height);
    final openness = frame.doorOpen;
    canvas
      ..save()
      ..translate(leaf.left, 0)
      ..scale(1 - 0.82 * openness, 1)
      ..drawImageRect(
        door,
        src,
        Rect.fromLTWH(0, leaf.top, leaf.width, leaf.height),
        SceneGeom.bmp,
      );
    // The handle's glow — the way back, on the sprite's own brass knob.
    final knob = Offset(
      leaf.width * SceneGeom.knobRelX(door, src),
      leaf.top + leaf.height * 0.47,
    );
    if (frame.handleGlow > 0) {
      final gr = leaf.width * 0.42 * (0.85 + 0.15 * math.sin(t * 4 * math.pi));
      canvas.drawCircle(
        knob,
        gr,
        Paint()
          ..shader = RadialGradient(
            colors: [
              MilesColors.gilt.withValues(alpha: 0.55 * frame.handleGlow),
              MilesColors.gilt.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: knob, radius: gr)),
      );
    }
    // The bolt, sliding across the knob-side seam during the last call — at
    // hand height, just under the brass, where bolts live.
    if (frame.bolt > 0) {
      final len = leaf.width * 0.30 * frame.bolt;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            leaf.width - len,
            leaf.top + leaf.height * 0.55,
            len,
            h * 0.012,
          ),
          Radius.circular(h * 0.006),
        ),
        Paint()..color = MilesColors.taupe,
      );
    }
    // Light through the opening leaf.
    if (openness > 0.02) {
      canvas.drawRect(
        Rect.fromLTWH(leaf.width * 0.9, leaf.top, leaf.width * 2.2,
            leaf.height,),
        Paint()
          ..shader = LinearGradient(
            colors: [
              MilesColors.starlight.withValues(alpha: 0.5 * openness),
              MilesColors.starlight.withValues(alpha: 0),
            ],
          ).createShader(
            Rect.fromLTWH(leaf.width, leaf.top, leaf.width * 2.2,
                leaf.height,),
          ),
      );
    }
    // ── The lamp, and the lantern the matting ate — painted at the
    // crossarm's tip, which is also what lets it flicker with the slam.
    canvas
      ..restore()
      ..drawImageRect(
        SceneArt.lamp!,
        Rect.fromLTWH(
          0,
          0,
          SceneArt.lamp!.width.toDouble(),
          SceneArt.lamp!.height.toDouble(),
        ),
        SceneGeom.lampDst(size),
        SceneGeom.bmp,
      );
    final lantern = SceneGeom.lanternAt(size);
    final glowR = w * 0.085 * (0.92 + 0.08 * math.sin(t * 2 * math.pi));
    canvas
      ..drawCircle(
        lantern,
        glowR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              MilesColors.gilt.withValues(alpha: 0.55 * flicker),
              MilesColors.gilt.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: lantern, radius: glowR)),
      )
      ..drawCircle(
        lantern,
        w * 0.016,
        Paint()
          ..color = MilesColors.starlight.withValues(alpha: 0.95 * flicker),
      );
    // Its cone across the doorstep, and the pool on the road.
    final ground = h * 0.93;
    final coneAlpha =
        (0.12 + 0.03 * math.sin(t * 2 * math.pi)) * flicker * (1 - dawn * 0.5);
    final cone = Path()
      ..moveTo(lantern.dx, lantern.dy)
      ..lineTo(w * 0.30, ground)
      ..lineTo(w * 1.02, ground)
      ..close();
    canvas
      ..drawPath(
        cone,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              MilesColors.gilt.withValues(alpha: coneAlpha),
              MilesColors.gilt.withValues(alpha: coneAlpha * 0.25),
            ],
          ).createShader(
            Rect.fromLTWH(w * 0.3, lantern.dy, w * 0.7, ground),
          ),
      )
      ..drawOval(
        Rect.fromCenter(
          center: Offset(w * 0.62, h * 0.965),
          width: w * 0.5,
          height: h * 0.07,
        ),
        Paint()
          ..color = MilesColors.tint(MilesColors.gilt, 0.10 * flicker)
              .withValues(alpha: 0.30 * flicker * (1 - dawn * 0.4)),
      );

    // ── Fireflies in the grass — the small warm life the owner asked for.
    for (final fly in _fireflies) {
      fly.paintFirefly(canvas, size, t);
    }

    // ── Dawn: one warm wash over the whole street as the deadline nears —
    // strong enough to READ at twenty hours, which 0.16 was not.
    if (dawn > 0.01) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..color = MilesColors.emberDeep.withValues(alpha: 0.22 * dawn),
      );
    }
  }

  @override
  bool shouldRepaint(DoorstepPainter oldDelegate) => false;
}

/// One seeded drifting light — a firefly over the street's grass, or a dust
/// mote riding the window shaft indoors. Position and breath are pure
/// functions of the loop, so the goldens are byte-stable and the loop's
/// restart never jumps.
class _Drifter {
  const _Drifter(this.x, this.y, this.phase, this.speed);

  final double x;
  final double y;
  final double phase;
  final double speed;

  static List<_Drifter> seed(int n, int key) {
    final r = math.Random(key);
    return List.generate(
      n,
      (_) => _Drifter(
        0.08 + r.nextDouble() * 0.84,
        r.nextDouble(),
        r.nextDouble(),
        0.5 + r.nextDouble(),
      ),
    );
  }

  void paintFirefly(Canvas canvas, Size size, double t) {
    final w = size.width;
    final at = Offset(
      (x + 0.020 * math.sin((t * speed + phase) * 2 * math.pi)) * w,
      (0.885 + y * 0.075 +
              0.010 * math.cos((t * speed * 0.7 + phase) * 2 * math.pi)) *
          size.height,
    );
    final a = 0.20 + 0.55 * (0.5 + 0.5 * math.sin((t * 2 + phase) * 2 * math.pi));
    canvas
      ..drawCircle(
        at,
        w * 0.011,
        Paint()..color = MilesColors.gilt.withValues(alpha: 0.35 * a),
      )
      ..drawCircle(
        at,
        w * 0.004,
        Paint()..color = MilesColors.starlight.withValues(alpha: a),
      );
  }

  /// Motes rise through the window's light and fade at both ends of the
  /// climb.
  void paintMote(Canvas canvas, Size size, double t) {
    final p = (t * speed + phase) % 1.0;
    final at = Offset(
      (0.16 + x * 0.42 + 0.012 * math.sin((t + phase) * 2 * math.pi)) *
          size.width,
      (0.84 - p * 0.46) * size.height,
    );
    final a = math.sin(p * math.pi) * 0.30;
    canvas.drawCircle(
      at,
      size.width * 0.004,
      Paint()..color = MilesColors.cream50.withValues(alpha: a),
    );
  }
}

/// The same night, from inside the house — the partner's camera.
///
/// One world, two views: the door they are both living around sits right of
/// frame here (its outside face was left-of-centre), the window left shows
/// the street lamp's glow coming IN, and the bolt is on THIS side, where the
/// partner's hand would be. Same laws as the street painter: repaint only by
/// the notifier, fractions of the canvas, MilesColors only.
class HearthPainter extends CustomPainter {
  HearthPainter({
    required Listenable repaint,
    required this.frame,
  }) : super(repaint: repaint);

  final SceneFrame frame;

  /// Dust motes riding the window's shaft of light — seeded, byte-stable.
  static final List<_Drifter> _motes = _Drifter.seed(7, 33);

  @override
  void paint(Canvas canvas, Size size) {
    if (SceneArt.ready) {
      _paintRoom(canvas, size);
      return;
    }
    final w = size.width;
    final h = size.height;
    final t = frame.loop;
    final dawn = frame.dawn;
    final ground = h * 0.86;

    // ── The room. Warm-dark walls, floor a shade deeper. The whole palette
    // sits one tint warmer than the street: this is the inside of a home.
    canvas
      ..drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              MilesColors.night,
              MilesColors.tint(MilesColors.gilt, 0.06),
            ],
          ).createShader(Rect.fromLTWH(0, 0, w, h)),
      )
      ..drawRect(
        Rect.fromLTWH(0, ground, w, h - ground),
        Paint()..color = MilesColors.surface1,
      )
      ..drawLine(
        Offset(0, ground),
        Offset(w, ground),
        Paint()
          ..color = MilesColors.hairline
          ..strokeWidth = 1.2,
      );

    // ── The window, left: the street lamp seen from indoors — the room's
    // main light, breathing with the same loop the lamp outside breathes on.
    final win = Rect.fromLTWH(w * 0.10, h * 0.30, w * 0.17, h * 0.17);
    final glow = (0.75 + 0.06 * (0.5 + 0.5 * (t * 2 - 1).abs())) *
        (1 - dawn * 0.4) *
        frame.lampFlicker;
    canvas.drawRRect(
      RRect.fromRectAndRadius(win, Radius.circular(w * 0.008)),
      Paint()
        ..color = MilesColors.tint(
          MilesColors.gilt,
          0.30 + 0.35 * glow,
          over: MilesColors.surface2,
        ),
    );
    // Light spilling into the room: one gradient wedge onto the floor.
    final spill = Path()
      ..moveTo(win.left, win.bottom)
      ..lineTo(win.right, win.bottom)
      ..lineTo(win.right + w * 0.20, ground + (h - ground) * 0.7)
      ..lineTo(win.left - w * 0.06, ground + (h - ground) * 0.7)
      ..close();
    canvas.drawPath(
      spill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            MilesColors.gilt.withValues(alpha: 0.14 * glow),
            MilesColors.gilt.withValues(alpha: 0.03 * glow),
          ],
        ).createShader(
          Rect.fromLTWH(win.left, win.bottom, w * 0.4, h * 0.5),
        ),
    );
    // Muntins over the glow.
    final mun = Paint()
      ..color = MilesColors.surface1
      ..strokeWidth = math.max(1.5, w * 0.007);
    canvas
      ..drawLine(win.topCenter, win.bottomCenter, mun)
      ..drawLine(win.centerLeft, win.centerRight, mun);

    // ── The door, right of frame, seen from inside. It never opens in this
    // view (the flood plays above the router); the slam reaches it as the
    // stage's shake. The BOLT lives here — this is the side a hand slides it
    // from.
    final doorW = w * 0.16;
    final doorL = w * 0.62;
    final doorH = h * 0.34;
    final doorTop = ground - doorH;
    final door = RRect.fromRectAndCorners(
      Rect.fromLTWH(doorL, doorTop, doorW, doorH),
      topLeft: Radius.circular(w * 0.006),
      topRight: Radius.circular(w * 0.006),
    );
    canvas
      ..drawRRect(door, Paint()..color = MilesColors.surface2)
      ..drawRRect(
        door,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = MilesColors.hairline,
      )
      // The inside handle.
      ..drawCircle(
        Offset(doorL + doorW * 0.14, doorTop + doorH * 0.52),
        w * 0.008,
        Paint()..color = MilesColors.gilt,
      );

    // The bolt: a plate on the frame and the bar that crosses the seam.
    // f.bolt 0 = drawn back (their hand has not moved), 1 = shut.
    final boltY = doorTop + doorH * 0.30;
    final plate = Rect.fromLTWH(
      doorL - w * 0.030,
      boltY - h * 0.006,
      w * 0.030,
      h * 0.024,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(plate, Radius.circular(h * 0.004)),
      Paint()..color = MilesColors.surface1,
    );
    final barLen = w * 0.052;
    final travel = w * 0.034 * frame.bolt;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          doorL - w * 0.052 + travel,
          boltY,
          barLen,
          h * 0.012,
        ),
        Radius.circular(h * 0.006),
      ),
      Paint()..color = MilesColors.taupe,
    );
    // When their own gate opens, the bolt catches the light — the same
    // invitation the outside handle gives the initiator.
    if (frame.handleGlow > 0) {
      final gc = Offset(doorL - w * 0.026, boltY + h * 0.006);
      final gr = w * 0.05 * (0.85 + 0.15 * math.sin(t * 4 * math.pi));
      canvas.drawCircle(
        gc,
        gr,
        Paint()
          ..shader = RadialGradient(
            colors: [
              MilesColors.gilt.withValues(alpha: 0.5 * frame.handleGlow),
              MilesColors.gilt.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: gc, radius: gr)),
      );
    }

    // A small warm pool where the lamp inside the room would sit — enough to
    // say somebody kept the lights on.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.45, ground + (h - ground) * 0.4),
        width: w * 0.42,
        height: (h - ground) * 0.6,
      ),
      Paint()
        ..color = MilesColors.tint(MilesColors.gilt, 0.10)
            .withValues(alpha: 0.30 * (1 - dawn * 0.3)),
    );
  }

  /// The owner's room. The doorway sits at the frame's right edge in this
  /// backdrop (measured: x 0.905→, y 0.145–0.870), so the leaf hangs there —
  /// MIRRORED, knob toward the room, the side a hand reaches from. The
  /// window's lamplight breathes, motes ride its shaft, and the bolt is
  /// painted on this side of the door because this is the hand that slides
  /// it.
  void _paintRoom(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = frame.loop;
    final dawn = frame.dawn;
    final cover = _Cover(SceneArt.backdropIn!, size);

    canvas.drawImageRect(
      SceneArt.backdropIn!,
      Rect.fromLTWH(0, 0, cover.iw, cover.ih),
      cover.dst,
      SceneGeom.bmp,
    );

    // ── The window's glow, breathing on the same loop the street lamp
    // breathes on — one world, one light.
    final win = cover.rect(0.02, 0.08, 0.27, 0.52);
    final glow =
        (0.05 + 0.04 * math.sin(t * 2 * math.pi)) * frame.lampFlicker;
    canvas.drawRect(
      win,
      Paint()..color = MilesColors.gilt.withValues(alpha: glow),
    );

    // ── The door leaf, filling the dark opening at the right edge.
    final leaf = cover.rect(0.905, 0.145, 0.115, 0.725);
    final door = SceneArt.door!;
    final src = SceneGeom.doorSrcKnobCentered(door, leaf.width / leaf.height);
    canvas
      ..save()
      ..translate(leaf.center.dx, 0)
      ..scale(-1, 1)
      ..translate(-leaf.center.dx, 0)
      ..drawImageRect(door, src, leaf, SceneGeom.bmp)
      ..restore();

    // The bolt: a plate on the jamb and the bar a hand slides across the
    // seam. frame.bolt 0 = drawn back, 1 = shut.
    final boltY = leaf.top + leaf.height * 0.45;
    final plate = Rect.fromLTWH(
      leaf.left - w * 0.032,
      boltY - h * 0.006,
      w * 0.032,
      h * 0.026,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(plate, Radius.circular(h * 0.004)),
      Paint()..color = MilesColors.surface1,
    );
    final barLen = w * 0.055;
    final travel = w * 0.036 * frame.bolt;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          leaf.left - w * 0.055 + travel,
          boltY,
          barLen,
          h * 0.013,
        ),
        Radius.circular(h * 0.006),
      ),
      Paint()..color = MilesColors.taupe,
    );
    // Their gate open: the bolt catches the light, the same invitation the
    // outside handle gives.
    if (frame.handleGlow > 0) {
      final gc = Offset(leaf.left - w * 0.02, boltY + h * 0.006);
      final gr = w * 0.055 * (0.85 + 0.15 * math.sin(t * 4 * math.pi));
      canvas.drawCircle(
        gc,
        gr,
        Paint()
          ..shader = RadialGradient(
            colors: [
              MilesColors.gilt.withValues(alpha: 0.5 * frame.handleGlow),
              MilesColors.gilt.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: gc, radius: gr)),
      );
    }

    // ── Motes in the light.
    for (final m in _motes) {
      m.paintMote(canvas, size, t);
    }

    // ── Dawn reaches indoors more gently.
    if (dawn > 0.01) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..color = MilesColors.emberDeep.withValues(alpha: 0.14 * dawn),
      );
    }
  }

  @override
  bool shouldRepaint(HearthPainter oldDelegate) => false;
}

/// One star of the seeded field.
class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.scale,
    required this.phase,
  });

  final double x;
  final double y;
  final double scale;
  final double phase;
}

/// Everything the painters read, written only by the stage's ticker.
///
/// A plain mutable bag rather than immutable state on purpose: it changes 24
/// times a second and exists to be READ during paint — allocating a new one
/// per frame would be churn with no reader who could tell the difference.
class SceneFrame {
  /// 0..1 across one `MilesMotion.sceneLoop` cycle.
  double loop = 0;

  /// 0..1, ceremony start → deadline.
  double dawn = 0;

  /// 0 shut … 1 wide open (the flood).
  double doorOpen = 0;

  /// 0 hidden … 1 fully slid (the last call).
  double bolt = 0;

  /// 0 none … 1 full glow on the handle (the way back).
  double handleGlow = 0;

  /// 1 steady; dips during the slam's flicker.
  double lampFlicker = 1;

  /// 1 lit (somebody home) … 0 dark.
  double windowLit = 1;

  /// Camera shake offset, applied by the stage as a transform.
  Offset shake = Offset.zero;

  /// The letter beat's progress, 0..1 while it plays; -1 otherwise.
  double letterT = -1;

  /// A letter rests on the doorstep (outside view, steady state).
  bool letterRest = false;

  /// What the character's face and hands are doing (bitmap cast only): the
  /// pose arriving, the pose leaving, and the crossfade between them.
  CharMood mood = CharMood.worried;
  CharMood moodPrev = CharMood.worried;
  double moodFade = 1;
}
