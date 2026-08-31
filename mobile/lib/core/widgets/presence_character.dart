import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The owner's cast, cut to the shoulders and decoded on demand.
///
/// Deliberately NOT `SceneArt`. That loader is all-twelve-or-nothing — one
/// `_load()` decodes the whole doorstep (~400KB) before `ready` flips, which
/// is the right trade for the one screen that shows all of it and the wrong
/// one for a badge the AppBar mounts on twenty-odd. This decodes ONE bust,
/// for the one gender on screen, and never touches the other.
///
/// Decoded small on purpose: the largest circle that draws it is 64dp, so
/// 256px covers a 4x handset with nothing left over. The 512px asset exists
/// so the crop survives a future bigger stage, not so every phone holds a
/// megabyte of face.
class PresenceArt {
  PresenceArt._();

  // Literal paths, one per line: the asset-hygiene orphan rule matches on
  // them, and a path built from a variant would read as two unreferenced
  // files. (scene_assets.dart learned this the same way.)
  static const malePath = 'assets/presence/m_bust.webp';
  static const femalePath = 'assets/presence/f_bust.webp';
  static const maleShutPath = 'assets/presence/m_bust_shut.webp';
  static const femaleShutPath = 'assets/presence/f_bust_shut.webp';

  static const _decodeWidth = 256;

  static final Map<PuppetVariant, ui.Image> _busts = {};
  static final Map<PuppetVariant, ui.Image> _shuts = {};
  static final Map<PuppetVariant, Future<void>> _loading = {};

  /// The decoded bust, or null while it loads, if it failed, or for a variant
  /// with no art. Null is a designed state at every call site — the caller
  /// draws the letter it drew before this file existed.
  static ui.Image? bustFor(PuppetVariant v) => _busts[v];

  /// The same face with its eyes closed. Null means no blink — the figure
  /// simply keeps them open, which is what a missing frame should cost.
  static ui.Image? shutFor(PuppetVariant v) => _shuts[v];

  static String? shutPathFor(PuppetVariant v) => switch (v) {
        PuppetVariant.male => maleShutPath,
        PuppetVariant.female => femaleShutPath,
        PuppetVariant.neutral => null,
      };

  static String? pathFor(PuppetVariant v) => switch (v) {
        PuppetVariant.male => malePath,
        PuppetVariant.female => femalePath,
        // No neutral bust, and none should be generated: a third face in a
        // different hand beside the owner's two would read worse than the
        // letter. `gender` is genuinely null for accounts that took
        // role-setup's sign-out escape, so this path is live, not dead.
        PuppetVariant.neutral => null,
      };

  /// Idempotent and safe to race — every mounted screen may ask at once.
  ///
  /// A failure is remembered rather than retried: the only way a bundle
  /// decode fails is that the asset is not in the APK, which no amount of
  /// asking again will change. Retrying it once per screen would be twenty
  /// throws for one missing file.
  static Future<void> ensureLoaded(PuppetVariant v) =>
      _loading[v] ??= _load(v);

  static Future<void> _load(PuppetVariant v) async {
    final path = pathFor(v);
    if (path == null) return;
    try {
      _busts[v] = await _decode(path);
    } catch (e) {
      // The letter is the designed fallback; the failure still gets named.
      debugPrint('presence: $path failed to decode, the letter stays: $e');
      return;
    }
    // The blink frame is loaded SECOND and its failure is survivable on its
    // own: a face that cannot blink is a smaller loss than a face that never
    // appears, so it must not be able to take the open frame down with it.
    final shut = shutPathFor(v);
    if (shut == null) return;
    try {
      _shuts[v] = await _decode(shut);
    } catch (e) {
      debugPrint('presence: $shut failed to decode, the eyes stay open: $e');
    }
  }

  static Future<ui.Image> _decode(String path) async {
    final bytes = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(
      bytes.buffer.asUint8List(),
      targetWidth: _decodeWidth,
    );
    return (await codec.getNextFrame()).image;
  }

  @visibleForTesting
  static void resetForTest() {
    _busts.clear();
    _shuts.clear();
    _loading.clear();
  }
}

/// Where each figure's neck sits inside its bust, as a fraction of the image.
///
/// MEASURED off the shipped 512px assets on a coordinate grid, not guessed:
/// this is the point everything turns about, and a few percent out swings the
/// head from the chest instead of from the neck. Re-measure if the busts are
/// ever re-cropped.
///
/// The blink is NOT done here, and the history is worth keeping: it was first
/// built by pulling a strip of the character's own forehead down over the eyes
/// — the standard 2D puppet trick — and across three attempts every filmstrip
/// read as a smear rather than an eye closing. A blink needs eyelid geometry a
/// still does not contain, so it is a second rendered frame instead
/// ([PresenceArt.shutFor]) and the rig simply swaps to it.
double _pivotFor(PuppetVariant v) => v == PuppetVariant.female ? 0.70 : 0.72;

/// Where the face's own axis sits across the bust, as a fraction of width.
///
/// NOT 0.5 for either of them, and it matters: the cylinder turns about this
/// line, so a centre taken from the image instead of from the face swings the
/// head about a point beside its own neck. Measured from pupil midpoints —
/// male 261.5/512, female 229.5/512 (she is framed three-quarters, so her
/// face sits left of the frame's centre).
double _faceCentreFor(PuppetVariant v) =>
    v == PuppetVariant.female ? 0.448 : 0.511;

/// The partner, alive inside the mark that says they are here.
///
/// Draws into a circle the caller owns — the disc, its gradient and its ring
/// stay the caller's, and this only fills the window with a person. It holds
/// no clock: [turn] comes from whatever is already ticking at the call site,
/// because the one thing this must never do is add a second ticker to twenty
/// screens. A caller with nothing ticking leaves [turn] at rest and the
/// figure simply stands there.
class PresenceCharacter extends StatefulWidget {
  const PresenceCharacter({
    required this.variant,
    required this.diameter,
    required this.fallback,
    this.turn = 0,
    this.arrive = 1,
    this.here = true,
    this.tint,
    super.key,
  });

  final PuppetVariant variant;

  /// The circle being filled, in logical pixels.
  final double diameter;

  /// Drawn while the bust decodes, if it fails, and for [PuppetVariant.neutral].
  final Widget fallback;

  /// The caller's loop angle in radians, monotonic. Breath and sway are read
  /// off it ninety degrees apart, which is what keeps a chest and a weight
  /// shift from moving as one block.
  final double turn;

  /// A one-shot arrival, 0 → 1. At 1 the figure has settled.
  final double arrive;

  /// False = they are in another room. Further away, not broken.
  final bool here;

  /// The mood light already tinting the disc. The face is graded toward it so
  /// a studio render sits in a near-black warm UI instead of on top of it.
  final Color? tint;

  @override
  State<PresenceCharacter> createState() => _PresenceCharacterState();
}

class _PresenceCharacterState extends State<PresenceCharacter> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PresenceCharacter old) {
    super.didUpdateWidget(old);
    if (widget.variant != old.variant) _load();
  }

  void _load() {
    if (PresenceArt.bustFor(widget.variant) != null) return;
    PresenceArt.ensureLoaded(widget.variant).then((_) {
      // The decode lands after the first frame on a cold start, and on a
      // phone with animations off nothing else would ever ask for a repaint.
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final bust = PresenceArt.bustFor(widget.variant);
    if (bust == null) return widget.fallback;

    return CustomPaint(
      size: Size.square(widget.diameter),
      painter: _BustPainter(
        bust: bust,
        shut: PresenceArt.shutFor(widget.variant),
        pivotY: _pivotFor(widget.variant),
        faceCentre: _faceCentreFor(widget.variant),
        turn: widget.turn,
        arrive: widget.arrive,
        here: widget.here,
        tint: widget.tint ?? MilesColors.ember,
        // A phone asked to stop animating gets the figure at rest, not a
        // figure held mid-breath at whatever angle the caller's clock stopped
        // on.
        still: MilesMotion.off(context),
      ),
    );
  }
}

class _BustPainter extends CustomPainter {
  const _BustPainter({
    required this.bust,
    required this.shut,
    required this.pivotY,
    required this.faceCentre,
    required this.turn,
    required this.arrive,
    required this.here,
    required this.tint,
    required this.still,
  });

  final ui.Image bust;

  /// The eyes-closed frame, or null when there is none to swap to.
  final ui.Image? shut;
  final double pivotY;

  /// The face's own axis, as a fraction of the bust's width.
  final double faceCentre;
  final double turn;
  final double arrive;
  final bool here;
  final Color tint;
  final bool still;

  /// The figure is drawn wider than its window so the parallax and the sway
  /// can never walk an edge into view. The doorstep's world layer uses the
  /// same trick at +2%; a face moves further, so it gets more.
  static const _overscale = 1.09;

  /// A chest, not a bounce: ±1.2% on the vertical only, anchored at the
  /// shoulders. Lifted straight off the doorstep cast, which is the one place
  /// in the app this motion has already been watched on a handset.
  static const _breathDepth = 0.012;

  /// Radians. A weight shift, not a wobble.
  static const _swayDepth = 0.010;

  /// How far the figure turns to look around, in radians of real Y rotation.
  /// Past about this the projected plane starts to read as a flat card being
  /// swung rather than a person turning.
  static const _gazeDepth = 0.30;

  /// The nod is deliberately shallower than the turn: heads shake more than
  /// they nod, and X rotation on a projected plane loses the illusion first.
  static const _nodDepth = 0.11;

  /// How far the hair trails the head, as a share of the turn it missed.
  static const _hairDrag = 0.55;

  /// How wide the turning cylinder is, as a fraction of the bust. Its CENTRE
  /// is per-figure ([faceCentre]); the radius is shared, because both busts
  /// are cropped to the same head size.
  static const _faceHalf = 0.21;

  /// A grid fine enough that a cylinder reads as curved and coarse enough to
  /// be free — 99 points and 160 triangles, at 30 logical pixels across.
  static const _cols = 9;
  static const _rows = 11;

  /// Fixed for the life of the process: the topology never changes, only
  /// where the points are.
  static final List<int> _indices = _buildIndices();

  static List<int> _buildIndices() {
    final out = <int>[];
    for (var r = 0; r < _rows - 1; r++) {
      for (var c = 0; c < _cols - 1; c++) {
        final a = r * _cols + c;
        final b = a + 1;
        final d = a + _cols;
        final e = d + 1;
        out..addAll([a, b, d])..addAll([b, e, d]);
      }
    }
    return out;
  }

  /// Loops between blinks, and the share of one loop an eye stays shut.
  /// Neither is a round number: a blink landing on the same beat as the breath
  /// is the tell that something is on a timer rather than alive. At the
  /// badge's 2.6s loop this is a blink roughly every eleven seconds, held for
  /// about 140ms — the cadence of a face at rest.
  static const _blinkEvery = 4.3;
  static const _blinkFor = 0.055;

  /// Where in the blink cycle a fresh clock starts. Without it `turn == 0`
  /// falls inside the window, so every badge in the app mounted with its eyes
  /// already shut and opened them a breath later — a wink at the world on
  /// every screen change. Caught by the filmstrip's first frame.
  static const _blinkPhase = 1.7;

  /// Which frame the eyes are on. Two frames, so the blink is a cut rather
  /// than a fade — which is also what a real eyelid does at this speed.
  bool get _eyesShut =>
      !still &&
      shut != null &&
      (turn / (2 * math.pi) + _blinkPhase) % _blinkEvery < _blinkFor;

  /// A gaze that holds, then moves. Two waves whose periods do not divide
  /// each other, so the figure never repeats a pattern the eye can learn —
  /// the cheapest honest substitute for a real idle animation.
  double _gaze(double t) =>
      math.sin(t * 0.37) * 0.62 + math.sin(t * 0.23 + 1.1) * 0.38;

  double _nod(double t) =>
      math.sin(t * 0.19 + 2.3) * 0.55 + math.sin(t * 0.31 + 0.4) * 0.45;

  /// Saturation pulled down, luminance preserved — the standard Rec.709
  /// weights. "They are in another room" reads as colour draining, where a
  /// plain opacity drop reads as a rendering bug.
  static const _away = ColorFilter.matrix(<double>[
    0.56693, 0.39336, 0.03971, 0, 0, //
    0.11693, 0.84336, 0.03971, 0, 0, //
    0.11693, 0.39336, 0.48971, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.shortestSide;
    if (d <= 0) return;
    final centre = Offset(size.width / 2, size.height / 2);
    final r = d / 2;

    canvas
      ..save()
      ..clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: r)));

    _paintContactShade(canvas, centre, r);

    final breath = still ? 0.0 : (1 - math.cos(turn)) / 2;
    final sway = still ? 0.0 : math.sin(turn);
    final dolly = ui.lerpDouble(
      0.88,
      1,
      MilesMotion.heroEnter.transform(arrive.clamp(0, 1)),
    )!;

    final side = d * _overscale;
    final dst = Rect.fromCenter(center: centre, width: side, height: side);

    // Body sway and the arrival dolly stay whole-figure transforms; only the
    // head's own motion needs the mesh.
    final pivot = Offset(centre.dx, dst.top + side * pivotY);
    canvas
      ..save()
      ..translate(pivot.dx, pivot.dy)
      ..rotate(sway * _swayDepth)
      ..scale(dolly)
      ..translate(-pivot.dx, -pivot.dy);

    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = here
          // A warm wash toward the mood already lighting the disc. Overlay
          // rather than a flat tint so the face keeps its own modelling.
          ? ColorFilter.mode(
              tint.withValues(alpha: 0.16),
              BlendMode.overlay,
            )
          : _away;

    final face = _eyesShut ? shut! : bust;
    if (still) {
      // At rest there is nothing to deform, and a mesh drawing an undeformed
      // grid is strictly more work than the blit it would produce.
      canvas.drawImageRect(
        face,
        Rect.fromLTWH(0, 0, face.width.toDouble(), face.height.toDouble()),
        dst,
        paint,
      );
    } else {
      _drawDeformed(canvas, dst, face, breath, paint);
    }

    canvas
      ..restore()
      ..restore();
  }

  /// The figure, warped over a turning cylinder.
  ///
  /// The head is not a card. A card rotated in perspective keeps every feature
  /// the same distance apart; a head does not — as it turns, the far side
  /// foreshortens and the near side opens out, and that redistribution is the
  /// whole cue. So each mesh column is given the depth it would have on a
  /// cylinder (`z = sqrt(1 - x²)`) and rotated about the neck, which moves the
  /// nose across the face by more than it moves the ear. It is the same trick
  /// Live2D uses, and it needs no asset a still does not already contain.
  ///
  /// Everything is weighted by [_rig] so the shoulders stay planted: a bust
  /// that turns as one block reads as a bust on a turntable.
  void _drawDeformed(
    Canvas canvas,
    Rect dst,
    ui.Image face,
    double breath,
    Paint paint,
  ) {
    final yaw = _gaze(turn) * _gazeDepth;
    final nod = _nod(turn) * _nodDepth;
    // Hair and the ends of a turn arrive late. Sampling the same gaze a
    // little earlier in its own history is a free spring: no state to carry
    // between frames, and it still lags.
    final drag = (_gaze(turn - 0.85) * _gazeDepth) - yaw;

    final w = face.width.toDouble();
    final h = face.height.toDouble();
    final positions = <Offset>[];
    final texture = <Offset>[];

    for (var row = 0; row < _rows; row++) {
      final v = row / (_rows - 1);
      // 1 over the skull, easing to 0 by the shoulders.
      final rig = _rig(v);
      // The chest, and only the chest, takes the breath.
      final chest = _smooth(pivotY - 0.10, 1, v);

      for (var col = 0; col < _cols; col++) {
        final u = col / (_cols - 1);
        texture.add(Offset(u * w, v * h));

        // Where this column sits across the head, -1 … 1.
        final xr = ((u - faceCentre) / _faceHalf).clamp(-1.0, 1.0);
        final z = math.sqrt(math.max(0, 1 - xr * xr));
        final turned = xr * math.cos(yaw) + z * math.sin(yaw);
        var du = (turned - xr) * _faceHalf * rig;

        // Hair is the outside of the silhouette, so it is the part that
        // trails. Nothing near the face centre drags.
        final outer = _smooth(0.45, 1, xr.abs());
        du += drag * _faceHalf * rig * outer * _hairDrag;

        // A nod lifts the chin and shortens the face, which on a flat sheet
        // is a vertical squeeze about the brow.
        var dv = nod * _faceHalf * rig;
        dv -= breath * _breathDepth * chest;

        positions.add(Offset(
          dst.left + (u + du) * dst.width,
          dst.top + (v + dv) * dst.height,
        ),);
      }
    }

    canvas.drawVertices(
      ui.Vertices(
        VertexMode.triangles,
        positions,
        textureCoordinates: texture,
        indices: _indices,
      ),
      BlendMode.dstOver,
      Paint()
        ..colorFilter = paint.colorFilter
        ..filterQuality = FilterQuality.medium
        ..shader = ui.ImageShader(
          face,
          TileMode.clamp,
          TileMode.clamp,
          Matrix4.identity().storage,
          filterQuality: FilterQuality.medium,
        ),
    );
  }

  /// How much of the head's motion a point at height [v] takes. Flat across
  /// the skull, then eased to nothing by the shoulder line.
  double _rig(double v) => 1 - _smooth(0.50, pivotY + 0.06, v);

  static double _smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// The one thing that stops a studio-lit face floating on a night screen:
  /// something dark pooling under the shoulders.
  ///
  /// A gradient, not a shadow. `blurRadius` is banned in the motion set —
  /// it is the per-frame raster cost the whole motion law was written around
  /// — and a radial stop costs nothing to draw.
  ///
  /// Weighted by size, because a shadow needs room to be one. On the 64dp
  /// circle the falloff reads as light; on the 30dp mark the same alpha had
  /// nowhere to fade across and just sat there as a dark band under the chin.
  void _paintContactShade(Canvas canvas, Offset centre, double r) {
    final depth = ui.lerpDouble(0.30, 0.52, ((r * 2 - 30) / 34).clamp(0, 1))!;
    final pool = Rect.fromCenter(
      center: Offset(centre.dx, centre.dy + r * 0.78),
      width: r * 2.1,
      height: r * 0.95,
    );
    canvas.drawOval(
      pool,
      Paint()
        ..shader = ui.Gradient.radial(
          pool.center,
          pool.width / 2,
          [
            MilesColors.nightDeep.withValues(alpha: depth),
            MilesColors.nightDeep.withValues(alpha: 0),
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(_BustPainter old) =>
      old.turn != turn ||
      old.arrive != arrive ||
      old.here != here ||
      old.tint != tint ||
      old.still != still ||
      old.pivotY != pivotY ||
      old.faceCentre != faceCentre ||
      !identical(old.shut, shut) ||
      !identical(old.bust, bust);
}
