import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/presence_character.dart' show PresenceArt;
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The partner, standing in the corner of whatever screen you are on.
///
/// Not a circle and not an avatar: a whole person, mounted ONCE above the app
/// rather than placed into twenty AppBars. That is the entire reason this is a
/// painter over an overlay instead of a widget in a layout — it can appear and
/// leave without a single screen reflowing, and no screen has to know it
/// exists.
///
/// The motion is deliberately body motion, not face motion. At the size this
/// draws — 120dp tall is 113x360 real pixels on a 3x handset, which puts each
/// eye at roughly 8px — a blink is invisible and a head turn is a wobble. A
/// breath and a weight shift read clearly. So the figure breathes and shifts
/// its weight, and does nothing with its face.
class PresenceFigure extends StatefulWidget {
  const PresenceFigure({
    required this.variant,
    required this.height,
    required this.here,
    required this.turn,
    required this.arrive,
    this.tint,
    super.key,
  });

  final PuppetVariant variant;

  /// Full standing height in logical pixels.
  final double height;

  /// False = they are somewhere else in the app. Further away, not broken.
  final bool here;

  /// The caller's loop angle in radians. Breath and sway are read off it a
  /// quarter turn apart so a chest and a weight shift never move as one block.
  final double turn;

  /// The entrance, 0 -> 1. They rise into place rather than blinking into it.
  final double arrive;

  /// The mood light already colouring the room.
  final Color? tint;

  @override
  State<PresenceFigure> createState() => _PresenceFigureState();
}

class _PresenceFigureState extends State<PresenceFigure> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PresenceFigure old) {
    super.didUpdateWidget(old);
    if (widget.variant != old.variant) _load();
  }

  void _load() {
    if (PresenceArt.figureFor(widget.variant) != null) return;
    PresenceArt.ensureFigureLoaded(widget.variant).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = PresenceArt.figureFor(widget.variant);
    // No art, no stand-in. A figure is either the person or it is nothing —
    // a letter standing on the carpet would be worse than an empty corner.
    if (img == null) return const SizedBox.shrink();
    return CustomPaint(
      size: Size(widget.height * img.width / img.height, widget.height),
      painter: _FigurePainter(
        figure: img,
        turn: widget.turn,
        arrive: widget.arrive,
        here: widget.here,
        tint: widget.tint ?? MilesColors.ember,
        still: MilesMotion.off(context),
      ),
    );
  }
}

class _FigurePainter extends CustomPainter {
  const _FigurePainter({
    required this.figure,
    required this.turn,
    required this.arrive,
    required this.here,
    required this.tint,
    required this.still,
  });

  final ui.Image figure;
  final double turn;
  final double arrive;
  final bool here;
  final Color tint;
  final bool still;

  /// A chest, not a bounce. The doorstep cast uses the same number and it is
  /// the one figure motion in this app that has been watched on a handset.
  static const _breathDepth = 0.012;

  /// Radians of weight shift, about the FEET. About the centre it reads as a
  /// person swaying in a breeze rather than standing.
  static const _swayDepth = 0.008;

  /// Saturation pulled down, Rec.709 luminance preserved. "Somewhere else in
  /// the app" reads as colour draining; a plain opacity drop reads as a bug.
  static const _away = ColorFilter.matrix(<double>[
    0.56693, 0.39336, 0.03971, 0, 0, //
    0.11693, 0.84336, 0.03971, 0, 0, //
    0.11693, 0.39336, 0.48971, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final breath = still ? 0.0 : (1 - math.cos(turn)) / 2;
    final sway = still ? 0.0 : math.sin(turn);
    final rise = MilesMotion.heroEnter.transform(arrive.clamp(0, 1));

    // They rise into the corner and settle. Translating the whole canvas keeps
    // the feet on the same line at rest, which is what stops the entrance
    // reading as a drop.
    canvas
      ..save()
      ..translate(0, (1 - rise) * size.height * 0.10);

    _paintContactShade(canvas, size, rise);

    // Everything pivots on the feet.
    final pivot = Offset(size.width / 2, size.height);
    canvas
      ..save()
      ..translate(pivot.dx, pivot.dy)
      ..rotate(sway * _swayDepth)
      ..scale(1, 1 + breath * _breathDepth)
      ..translate(-pivot.dx, -pivot.dy)
      ..drawImageRect(
        figure,
        Rect.fromLTWH(0, 0, figure.width.toDouble(), figure.height.toDouble()),
        Offset.zero & size,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..colorFilter = here
              // srcATop, NOT overlay. Overlay paints across the whole
              // destination rect including its transparent pixels, so the
              // figure stood in a visible tinted RECTANGLE — caught by the
              // preview, invisible until the circle came off. srcATop keeps
              // the destination's alpha, so the wash lands on the person and
              // nowhere else.
              ? ColorFilter.mode(
                  tint.withValues(alpha: 0.14),
                  BlendMode.srcATop,
                )
              : _away,
      )
      ..restore()
      ..restore();
  }

  /// The pool under their feet.
  ///
  /// Without it a studio-lit figure hovers over the interface instead of
  /// standing on it — the same defect the Opening's cast had before the film
  /// grew contact shadows. A gradient, not a shadow: `blurRadius` is banned in
  /// the motion set and a radial stop costs nothing.
  void _paintContactShade(Canvas canvas, Size size, double rise) {
    final pool = Rect.fromCenter(
      center: Offset(size.width / 2, size.height - size.height * 0.012),
      width: size.width * 0.95,
      height: size.height * 0.055,
    );
    canvas.drawOval(
      pool,
      Paint()
        ..shader = ui.Gradient.radial(
          pool.center,
          pool.width / 2,
          [
            MilesColors.nightDeep.withValues(alpha: 0.55 * rise),
            MilesColors.nightDeep.withValues(alpha: 0),
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(_FigurePainter old) =>
      old.turn != turn ||
      old.arrive != arrive ||
      old.here != here ||
      old.tint != tint ||
      old.still != still ||
      !identical(old.figure, figure);
}
