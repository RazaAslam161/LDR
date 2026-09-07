import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The owner's cast, cut to the shoulders, in every mood — decoded on demand.
///
/// Deliberately NOT `SceneArt`. That loader is all-twelve-or-nothing — one
/// `_load()` decodes the whole doorstep (~400KB) before `ready` flips, which
/// is the right trade for the one screen that shows all of it and the wrong
/// one for a face the AppBar mounts on twenty-odd. This decodes ONE
/// expression pair, for the one person on screen, and keeps the last few so
/// a mood that flips back does not pay for the decode twice.
///
/// Decoded small on purpose: the largest circle that draws it is 64dp, so
/// 256px covers a 4x handset with nothing left over.
class PresenceArt {
  PresenceArt._();

  /// One expression per line, literally: the asset-hygiene orphan rule and
  /// the "every named asset exists" rule both read these as TEXT, so a path
  /// built from a variant and a mood would count as eighty unreferenced
  /// files. Keys are `<m|f>_<artName>` and `<m|f>_<artName>_shut` — the
  /// same stems the mood emoji use (`MoodData.artName`), so nothing here
  /// names what the app is for. Forty open-eyed frames today; the `_shut`
  /// blink pass doubles it when the owner generates it.
  static const _paths = <String, String>{
    'm_neutral': 'assets/presence/m_neutral.webp',
    'm_joyful': 'assets/presence/m_joyful.webp',
    'm_loving': 'assets/presence/m_loving.webp',
    'm_cozy': 'assets/presence/m_cozy.webp',
    'm_missing_you': 'assets/presence/m_missing_you.webp',
    'm_excited': 'assets/presence/m_excited.webp',
    'm_calm': 'assets/presence/m_calm.webp',
    'm_playful': 'assets/presence/m_playful.webp',
    'm_romantic': 'assets/presence/m_romantic.webp',
    'm_tired': 'assets/presence/m_tired.webp',
    'm_anxious': 'assets/presence/m_anxious.webp',
    'm_grateful': 'assets/presence/m_grateful.webp',
    'm_sad': 'assets/presence/m_sad.webp',
    'm_angry': 'assets/presence/m_angry.webp',
    'm_annoyed': 'assets/presence/m_annoyed.webp',
    'm_yearning': 'assets/presence/m_yearning.webp',
    'm_flirty': 'assets/presence/m_flirty.webp',
    'm_mischief': 'assets/presence/m_mischief.webp',
    'm_kiss': 'assets/presence/m_kiss.webp',
    'm_lipstick': 'assets/presence/m_lipstick.webp',
    'f_neutral': 'assets/presence/f_neutral.webp',
    'f_joyful': 'assets/presence/f_joyful.webp',
    'f_loving': 'assets/presence/f_loving.webp',
    'f_cozy': 'assets/presence/f_cozy.webp',
    'f_missing_you': 'assets/presence/f_missing_you.webp',
    'f_excited': 'assets/presence/f_excited.webp',
    'f_calm': 'assets/presence/f_calm.webp',
    'f_playful': 'assets/presence/f_playful.webp',
    'f_romantic': 'assets/presence/f_romantic.webp',
    'f_tired': 'assets/presence/f_tired.webp',
    'f_anxious': 'assets/presence/f_anxious.webp',
    'f_grateful': 'assets/presence/f_grateful.webp',
    'f_sad': 'assets/presence/f_sad.webp',
    'f_angry': 'assets/presence/f_angry.webp',
    'f_annoyed': 'assets/presence/f_annoyed.webp',
    'f_yearning': 'assets/presence/f_yearning.webp',
    'f_flirty': 'assets/presence/f_flirty.webp',
    'f_mischief': 'assets/presence/f_mischief.webp',
    'f_kiss': 'assets/presence/f_kiss.webp',
    'f_lipstick': 'assets/presence/f_lipstick.webp',
  };

  static const _decodeWidth = 256;

  /// Expression pairs kept decoded. Two faces can be on screen at once (the
  /// AppBar and Home's card), each mid-fade between two moods — four keys.
  /// 4 × 2 × 256² × 4B ≈ 2MB resident, worst case. Not const: the preview
  /// golden holds all forty at once, and says so.
  @visibleForTesting
  static int keep = 4;

  static final Map<String, ui.Image> _busts = {};
  static final Map<String, ui.Image> _shuts = {};
  static final Map<String, Future<void>> _loading = {};
  static final List<String> _recent = [];

  static String? _prefix(PuppetVariant v) => switch (v) {
        PuppetVariant.male => 'm',
        PuppetVariant.female => 'f',
        // No neutral bust, and none should be generated: a third face in a
        // different hand beside the owner's two would read worse than the
        // letter. `gender` is genuinely null for accounts that took
        // role-setup's sign-out escape, so this path is live, not dead.
        PuppetVariant.neutral => null,
      };

  static String? _key(PuppetVariant v, String expr) {
    final p = _prefix(v);
    return p == null ? null : '${p}_$expr';
  }

  /// Which expression [v] can wear for [mood]: the mood's own frame when it
  /// has shipped, `neutral` otherwise — so a mood this build has no art for
  /// still shows a face. Null only for a variant with no art at all.
  static String? exprFor(PuppetVariant v, String? mood) {
    if (_prefix(v) == null) return null;
    if (mood != null && _paths.containsKey(_key(v, mood))) return mood;
    return 'neutral';
  }

  /// The decoded open-eyed frame, or null while it loads, if it failed, or
  /// for a variant with no art. Null is a designed state at every call site.
  static ui.Image? bustFor(PuppetVariant v, String expr) {
    final k = _key(v, expr);
    if (k == null) return null;
    final img = _busts[k];
    if (img != null) _touch(k);
    return img;
  }

  /// The same expression with its eyes closed. Null means no blink — the
  /// figure simply keeps them open, which is what a missing frame should cost.
  static ui.Image? shutFor(PuppetVariant v, String expr) {
    final k = _key(v, expr);
    return k == null ? null : _shuts[k];
  }

  /// Idempotent and safe to race — every mounted screen may ask at once.
  ///
  /// A failure is remembered rather than retried: the only way a bundle
  /// decode fails is that the asset is not in the APK, which no amount of
  /// asking again will change.
  static Future<void> ensureLoaded(PuppetVariant v, String expr) {
    final k = _key(v, expr);
    if (k == null) return Future<void>.value();
    return _loading[k] ??= _load(k);
  }

  static Future<void> _load(String k) async {
    final path = _paths[k];
    if (path == null) return;
    try {
      _busts[k] = await _decode(path);
    } catch (e) {
      // The letter is the designed fallback; the failure still gets named.
      debugPrint('presence: $path failed to decode, the letter stays: $e');
      return;
    }
    _touch(k);
    // The blink frame is loaded SECOND and its failure is survivable on its
    // own: a face that cannot blink is a smaller loss than a face that never
    // appears, so it must not be able to take the open frame down with it.
    final shut = _paths['${k}_shut'];
    if (shut == null) return;
    try {
      _shuts[k] = await _decode(shut);
    } catch (e) {
      debugPrint('presence: $shut failed to decode, the eyes stay open: $e');
    }
  }

  /// Most-recently-used last. Past [keep] the oldest pair's REFERENCES are
  /// dropped — never `dispose()`d, because a painter mid-crossfade may still
  /// be holding it — and its load future with them, so it can be asked for
  /// again later.
  static void _touch(String k) {
    _recent
      ..remove(k)
      ..add(k);
    while (_recent.length > keep) {
      final old = _recent.removeAt(0);
      _busts.remove(old);
      _shuts.remove(old);
      _loading.remove(old);
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
    _recent.clear();
  }
}

/// Where each figure's neck sits inside its bust, as a fraction of the image.
///
/// READ OFF THE GRID, not computed: `tool/presence_cut.py` draws every
/// measurement on a 5% grid over the 256px neutral, and the numbers that ship
/// are the ones confirmed there by eye. Its own automatic guess is printed
/// beside them and was wrong both times — the "darkest pixels in the eye
/// band" are hair, and the narrowest silhouette row is nowhere near a neck
/// under hers. Re-measured 2026-09-02 for the expression cast's framing
/// (male collar at 0.76, female at 0.66). This is the point everything turns
/// about, and a few percent out swings the head from the chest instead of
/// from the neck.
///
/// The blink is NOT done here, and the history is worth keeping: it was first
/// built by pulling a strip of the character's own forehead down over the eyes
/// — the standard 2D puppet trick — and across three attempts every filmstrip
/// read as a smear rather than an eye closing. A blink needs eyelid geometry a
/// still does not contain, so it is a second rendered frame instead
/// ([PresenceArt.shutFor]) and the rig simply swaps to it.
double _pivotFor(PuppetVariant v) => v == PuppetVariant.female ? 0.66 : 0.76;

/// Where the face's own axis sits across the bust, as a fraction of width.
///
/// NOT 0.5 for her, and it matters: the cylinder turns about this line, so a
/// centre taken from the image instead of from the face swings the head about
/// a point beside its own neck. Pupil midpoints off the grid, 2026-09-02 —
/// male 0.41/0.59, female 0.35/0.53 (she is framed three-quarters, so her
/// face sits left of the frame's centre).
double _faceCentreFor(PuppetVariant v) =>
    v == PuppetVariant.female ? 0.443 : 0.50;

/// The partner, alive, wearing their mood.
///
/// Draws either into a circle the caller owns ([disc]) or free-standing, and
/// only ever fills that window with a person. It holds no CLOCK: [turn] comes
/// from whatever is already ticking at the call site, because the one thing
/// this must never do is add a permanent second ticker to twenty screens. It
/// does own one ONE-SHOT — the cross-fade when [mood] changes — which runs
/// for 420ms on an event and then is idle; that is not what the rule was
/// written against.
class PresenceCharacter extends StatefulWidget {
  const PresenceCharacter({
    required this.variant,
    required this.size,
    required this.fallback,
    this.mood,
    this.turn = 0,
    this.arrive = 1,
    this.here = true,
    this.tint,
    this.disc = true,
    super.key,
  });

  final PuppetVariant variant;

  /// The square being filled, in logical pixels.
  final double size;

  /// Drawn while the bust decodes, if it fails, and for [PuppetVariant.neutral].
  final Widget fallback;

  /// The partner's mood as `MoodData.artName`. Null, or a mood with no
  /// shipped frame, wears the neutral face. Changing it cross-fades.
  final String? mood;

  /// The caller's loop angle in radians, monotonic. Breath and sway are read
  /// off it ninety degrees apart, which is what keeps a chest and a weight
  /// shift from moving as one block.
  final double turn;

  /// A one-shot arrival, 0 → 1. At 1 the figure has settled.
  final double arrive;

  /// False = they are away. Colour drains; the face stays.
  final bool here;

  /// The mood light. The face is graded toward it so a studio render sits in
  /// a near-black warm UI instead of on top of it.
  final Color? tint;

  /// True clips to a circle and pools shade under the shoulders the way
  /// Home's card wants; false stands the matted bust free, the way the AppBar
  /// wants — a person beside the title, not a badge.
  final bool disc;

  @override
  State<PresenceCharacter> createState() => _PresenceCharacterState();
}

class _PresenceCharacterState extends State<PresenceCharacter>
    with SingleTickerProviderStateMixin {
  /// The cross-fade between two expressions. Starts at 1 (nothing fading).
  ///
  /// Built in initState and NOT as a lazy `late final`: a face with no art
  /// (a genderless profile) never builds the painter, so the initialiser
  /// would run for the first time inside dispose() — constructing a ticker
  /// on an already-deactivated element and throwing out of the tree's own
  /// teardown. The standing figure died of exactly this.
  late final AnimationController _swap;

  /// The expression on stage, and the one on its way out.
  String? _expr;
  String? _prev;

  @override
  void initState() {
    super.initState();
    _swap = AnimationController(
      vsync: this,
      duration: MilesMotion.settle,
      value: 1,
    )..addStatusListener(_onSwap);
    _expr = PresenceArt.exprFor(widget.variant, widget.mood);
    _load(_expr);
  }

  @override
  void didUpdateWidget(PresenceCharacter old) {
    super.didUpdateWidget(old);
    final next = PresenceArt.exprFor(widget.variant, widget.mood);
    if (widget.variant != old.variant) {
      // A different person: a cut, never a fade from one face into another.
      _prev = null;
      _expr = next;
      _swap.value = 1;
      _load(next);
      return;
    }
    if (next == _expr) return;
    final from = _expr;
    _expr = next;
    if (MilesMotion.off(context) ||
        from == null ||
        next == null ||
        PresenceArt.bustFor(widget.variant, from) == null) {
      // Reduce-motion, or nothing decoded to fade from: swap the frame.
      _prev = null;
      _swap.value = 1;
      _load(next);
      return;
    }
    _prev = from;
    if (PresenceArt.bustFor(widget.variant, next) != null) {
      // Already decoded — the common case, since the LRU keeps the last few
      // moods — so the fade starts NOW, on this frame. Not through a future:
      // a `.then` on an already-complete decode is a microtask hop the eye
      // does not need, and one that never delivers inside a test's zone.
      _swap.forward(from: 0);
      return;
    }
    // Not decoded yet: hold on the old face until the new one is, THEN fade
    // — so it never fades into nothing while a frame loads. ~10-20ms; the
    // state (and the semantics) changed instantly regardless.
    _swap.value = 0;
    PresenceArt.ensureLoaded(widget.variant, next).then((_) {
      if (!mounted || _expr != next) return;
      setState(() {});
      _swap.forward(from: 0);
    });
  }

  void _onSwap(AnimationStatus s) {
    if (s == AnimationStatus.completed && _prev != null && mounted) {
      setState(() => _prev = null);
    }
  }

  void _load(String? expr) {
    if (expr == null) return;
    if (PresenceArt.bustFor(widget.variant, expr) != null) return;
    PresenceArt.ensureLoaded(widget.variant, expr).then((_) {
      // The decode lands after the first frame on a cold start, and on a
      // phone with animations off nothing else would ever ask for a repaint.
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _swap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.variant;
    final expr = _expr;
    if (expr == null) return widget.fallback;

    final cur = PresenceArt.bustFor(v, expr);
    final prevKey = _prev;
    final prevImg = prevKey == null ? null : PresenceArt.bustFor(v, prevKey);
    // The face to draw: the current expression, or — while it decodes — the
    // one it is replacing. Only when BOTH are decoded is there a fade.
    final face = cur ?? prevImg;
    if (face == null) return widget.fallback;
    final fading = cur != null && prevImg != null && !identical(cur, prevImg);
    final faceKey = cur == null ? prevKey! : expr;

    return AnimatedBuilder(
      animation: _swap,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _BustPainter(
          bust: face,
          shut: PresenceArt.shutFor(v, faceKey),
          prev: fading ? prevImg : null,
          prevShut: fading ? PresenceArt.shutFor(v, prevKey!) : null,
          swap: fading ? _swap.value : 1.0,
          pivotY: _pivotFor(v),
          faceCentre: _faceCentreFor(v),
          turn: widget.turn,
          arrive: widget.arrive,
          here: widget.here,
          tint: widget.tint ?? MilesColors.ember,
          disc: widget.disc,
          // A phone asked to stop animating gets the figure at rest, not a
          // figure held mid-breath at whatever angle the caller's clock
          // stopped on.
          still: MilesMotion.off(context),
        ),
      ),
    );
  }
}

class _BustPainter extends CustomPainter {
  const _BustPainter({
    required this.bust,
    required this.shut,
    required this.prev,
    required this.prevShut,
    required this.swap,
    required this.pivotY,
    required this.faceCentre,
    required this.turn,
    required this.arrive,
    required this.here,
    required this.tint,
    required this.disc,
    required this.still,
  });

  final ui.Image bust;

  /// The eyes-closed frame, or null when there is none to swap to.
  final ui.Image? shut;

  /// The expression on its way out, with its own blink frame, or null when
  /// nothing is fading. [swap] is 0 (all previous) to 1 (all current).
  final ui.Image? prev;
  final ui.Image? prevShut;
  final double swap;

  final double pivotY;

  /// The face's own axis, as a fraction of the bust's width.
  final double faceCentre;
  final double turn;
  final double arrive;
  final bool here;
  final Color tint;
  final bool disc;
  final bool still;

  /// Inside a disc the figure is drawn wider than its window so the parallax
  /// and the sway can never walk an edge into view. Free-standing there is no
  /// window to hide an edge behind, so it is drawn at size.
  double get _overscale => disc ? 1.09 : 1.0;

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

  /// One shader per face image, kept exactly as long as the image itself is
  /// reachable. Its only input is the image — clamp tiling, identity matrix,
  /// medium quality — so a fresh one per frame was the same object allocated
  /// on every vsync of every screen that wears the badge. An Expando rather
  /// than a map so a face the LRU has dropped takes its shader with it,
  /// instead of the shader pinning the pixels the drop was meant to free.
  static final Expando<ui.ImageShader> _shaders = Expando<ui.ImageShader>();
  static final _identity = Matrix4.identity().storage;
  static final Paint _facePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  static ui.ImageShader _shaderFor(ui.Image face) =>
      _shaders[face] ??= ui.ImageShader(
        face,
        TileMode.clamp,
        TileMode.clamp,
        _identity,
        filterQuality: FilterQuality.medium,
      );

  /// The pool of shadow under the figure: one gradient per (rect, depth).
  /// Two sizes of figure exist in the app, so two entries — plus a few more
  /// while a Hero flight paints the figure at in-between sizes, which is what
  /// the cap is for.
  static final Map<(Rect, double), ui.Gradient> _shades = {};
  static const _shadesKeep = 16;

  /// Loops between blinks, and the share of one loop an eye stays shut.
  /// Neither is a round number: a blink landing on the same beat as the breath
  /// is the tell that something is on a timer rather than alive. The host's
  /// loop is `MilesMotion.breath` (4s), so this is a blink roughly every
  /// eleven seconds, held for about 220ms — the cadence of a face at rest.
  static const _blinkEvery = 2.8;
  static const _blinkFor = 0.055;

  /// Where in the blink cycle a fresh clock starts. Without it `turn == 0`
  /// falls inside the window, so every face in the app mounted with its eyes
  /// already shut and opened them a breath later — a wink at the world on
  /// every screen change. Caught by the filmstrip's first frame.
  static const _blinkPhase = 1.7;

  /// Which frame the eyes are on. Two frames, so the blink is a cut rather
  /// than a fade — which is also what a real eyelid does at this speed. One
  /// decision for both faces mid-fade, so a blink cuts them together.
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
  /// weights. "They are away" reads as colour draining, where a plain opacity
  /// drop reads as a rendering bug. Row four is identity, so a matte's alpha
  /// survives it.
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

    canvas.save();
    if (disc) {
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: r)));
    }
    _paintContactShade(canvas, centre, r);

    final breath = still ? 0.0 : (1 - math.cos(turn)) / 2;
    final sway = still ? 0.0 : math.sin(turn);
    final dolly = ui.lerpDouble(
      0.88,
      1,
      MilesMotion.heroEnter.transform(arrive.clamp(0, 1)),
    )!;
    // The reactive beat: a mood landing lifts the whole figure a touch and
    // settles it, 0 at both ends of the fade so it rides on nothing else.
    final react = prev == null || still ? 0.0 : math.sin(math.pi * swap);

    final side = d * _overscale;
    final dst = Rect.fromCenter(center: centre, width: side, height: side);

    // Body sway, the arrival dolly and the beat stay whole-figure transforms;
    // only the head's own motion needs the mesh.
    final pivot = Offset(centre.dx, dst.top + side * pivotY);
    canvas
      ..save()
      ..translate(pivot.dx, pivot.dy)
      ..rotate(sway * _swayDepth)
      ..scale(dolly * (1 + 0.05 * react))
      ..translate(-pivot.dx, -pivot.dy);

    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = here
          // A warm wash toward the mood light. Inside a disc, overlay keeps
          // the face's own modelling; free-standing, overlay paints the
          // transparent rectangle (presence_figure learned this the hard
          // way), so the matte gets srcATop instead.
          ? ColorFilter.mode(
              tint.withValues(alpha: 0.16),
              disc ? BlendMode.overlay : BlendMode.srcATop,
            )
          : _away;

    // Free-standing, the figure gets its own layer so the shoulders can be
    // faded out beneath it: the busts are square crops that end in a hard
    // horizontal edge, and a person cut off flat at the chest reads as a
    // sticker. The fade is a dstIn gradient over the layer's bottom, so it
    // costs one small offscreen and touches nothing behind the figure.
    if (!disc) canvas.saveLayer(dst.inflate(side * 0.1), Paint());

    final shutNow = _eyesShut;
    final face = shutNow ? shut! : bust;
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
      final vertices = _mesh(dst, breath, react);
      final old = prev;
      if (old != null && swap < 1) {
        // The face on its way out, drawn first at full; the new one composited
        // over it through a layer carrying the fade's alpha. A layer, not the
        // paint's colour: paint alpha under an ImageShader is backend-defined
        // and this has to look the same on Skia and Impeller.
        final oldFace = shutNow ? (prevShut ?? old) : old;
        _drawFace(canvas, vertices, oldFace, paint);
        canvas.saveLayer(
          dst.inflate(side * 0.1),
          Paint()
            ..color = Color.fromRGBO(
              255,
              255,
              255,
              MilesMotion.enter.transform(swap.clamp(0.0, 1.0)),
            ),
        );
        _drawFace(canvas, vertices, face, paint);
        canvas.restore();
      } else {
        _drawFace(canvas, vertices, face, paint);
      }
    }

    if (!disc) {
      final fade = Rect.fromLTRB(
        dst.left,
        dst.top + dst.height * 0.80,
        dst.right,
        dst.bottom,
      );
      canvas
        ..drawRect(
          fade,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = ui.Gradient.linear(
              fade.topCenter,
              fade.bottomCenter,
              [const Color(0xFFFFFFFF), const Color(0x00FFFFFF)],
            ),
        )
        ..restore();
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
  /// that turns as one block reads as a bust on a turntable. Computed ONCE per
  /// paint and shared by both faces of a fade, so they deform as one head.
  ui.Vertices _mesh(Rect dst, double breath, double react) {
    final yaw = _gaze(turn) * _gazeDepth;
    final nod = _nod(turn) * _nodDepth;
    // Hair and the ends of a turn arrive late. Sampling the same gaze a
    // little earlier in its own history is a free spring: no state to carry
    // between frames, and it still lags.
    final drag = (_gaze(turn - 0.85) * _gazeDepth) - yaw;

    final w = bust.width.toDouble();
    final h = bust.height.toDouble();
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
        // is a vertical squeeze about the brow. The beat is a small chin-lift
        // on the same axis.
        var dv = nod * _faceHalf * rig;
        dv -= breath * _breathDepth * chest;
        dv -= react * 0.03 * rig;

        positions.add(Offset(
          dst.left + (u + du) * dst.width,
          dst.top + (v + dv) * dst.height,
        ),);
      }
    }

    return ui.Vertices(
      VertexMode.triangles,
      positions,
      textureCoordinates: texture,
      indices: _indices,
    );
  }

  void _drawFace(
    Canvas canvas,
    ui.Vertices vertices,
    ui.Image face,
    Paint paint,
  ) {
    canvas.drawVertices(
      vertices,
      BlendMode.dstOver,
      _facePaint
        ..colorFilter = paint.colorFilter
        ..shader = _shaderFor(face),
    );
    // The draw has copied the paint; left set, the shader would hold the
    // last face's pixels after the LRU let the image go.
    _facePaint.shader = null;
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
  /// Inside a disc it is weighted by size, because a shadow needs room to be
  /// one: on the 64dp circle the falloff reads as light; on a 30dp mark the
  /// same alpha just sat there as a dark band under the chin. Free-standing
  /// it is a smaller, lighter pool at the shoulder line — a person standing
  /// on a surface, not a portrait in a frame.
  void _paintContactShade(Canvas canvas, Offset centre, double r) {
    final Rect pool;
    final double depth;
    if (disc) {
      depth = ui.lerpDouble(0.30, 0.52, ((r * 2 - 30) / 34).clamp(0, 1))!;
      pool = Rect.fromCenter(
        center: Offset(centre.dx, centre.dy + r * 0.78),
        width: r * 2.1,
        height: r * 0.95,
      );
    } else {
      depth = 0.22;
      pool = Rect.fromCenter(
        center: Offset(centre.dx, centre.dy + r * 0.88),
        width: r * 1.6,
        height: r * 0.5,
      );
    }
    if (_shades.length >= _shadesKeep) _shades.clear();
    canvas.drawOval(
      pool,
      Paint()
        ..shader = _shades.putIfAbsent(
          (pool, depth),
          () => ui.Gradient.radial(
            pool.center,
            pool.width / 2,
            [
              MilesColors.nightDeep.withValues(alpha: depth),
              MilesColors.nightDeep.withValues(alpha: 0),
            ],
          ),
        ),
    );
  }

  @override
  bool shouldRepaint(_BustPainter old) =>
      old.turn != turn ||
      old.arrive != arrive ||
      old.swap != swap ||
      old.here != here ||
      old.tint != tint ||
      old.still != still ||
      old.disc != disc ||
      old.pivotY != pivotY ||
      old.faceCentre != faceCentre ||
      !identical(old.shut, shut) ||
      !identical(old.prev, prev) ||
      !identical(old.prevShut, prevShut) ||
      !identical(old.bust, bust);
}
