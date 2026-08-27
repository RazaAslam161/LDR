import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

/// The app's magical signature: a warm candle-glow gradient with slowly
/// drifting embers and a faint two-layer starfield. Subtle and slow — it sits
/// behind content and never competes with it.
///
/// Usage: EmberBackground(child: YourScreen())
///
/// Nesting is free: `main.dart` mounts one app-wide, and a screen that wraps
/// itself in another gets a pass-through instead of a second painter.
///
/// This is the rewrite of PERF_PLAN hotspot #1. The original painted ~50
/// primitives per vsync forever: a RadialGradient shader rebuilt every frame,
/// 34 `drawCircle` stars, 14 embers each through a `MaskFilter.blur`. Now:
///
///  * The glow is rendered ONCE per canvas size into a [ui.Image] and drawn
///    per frame under a canvas transform — its drift and pulse are transform,
///    not re-shading. (That transform IS the spec's CandleBreath.)
///  * Stars and embers are two `drawAtlas` calls over two tiny pre-rendered
///    sprites; twinkle and fade ride the atlas color list. The ember's halo
///    is baked into its sprite — no MaskFilter at paint time.
///  * The field repaints at most 24fps (nothing here moves fast enough for
///    more), quantized off the 36s controller.
///  * A screen that fully covers the app can mount [EmberBackgroundHidden]
///    to stop the root ticker outright — the root instance lives above the
///    Navigator, where route-scoped TickerMode cannot reach it.
///  * `MilesMotion.off()` is honored: one fixed frame, zero tickers.
///
/// The starfield's two half-fields drift at different speeds (60s / 120s
/// wrap) — the spec's StarfieldDrift, still transform-only.
class EmberBackground extends StatefulWidget {
  const EmberBackground({
    required this.child, super.key,
    this.embers = 14,
    this.stars = 34,
  });

  final Widget child;
  final int embers;
  final int stars;

  /// How many [EmberBackgroundHidden] markers are mounted. Above zero, the
  /// painting instance stops its ticker: a camera, a call, a fullscreen
  /// viewer draws over every pixel of the field, and a background nobody can
  /// see must not keep a vsync loop warm.
  static final ValueNotifier<int> covered = ValueNotifier<int>(0);

  /// How many [EmberBackgroundWishes] markers are mounted. Above zero, the
  /// field lets one shooting star cross per loop.
  ///
  /// A marker rather than a constructor flag, for the same reason [covered]
  /// is one: the painting instance is the ROOT, wrapping the whole app, so a
  /// screen cannot ask for a wish by passing an argument to a wrapper of its
  /// own — every screen-level wrapper is a pass-through now.
  static final ValueNotifier<int> wishing = ValueNotifier<int>(0);

  @override
  State<EmberBackground> createState() => _EmberBackgroundState();
}

/// Mount this on the one screen that may wish (Home). While it lives, the
/// ember field crosses a single slow shooting star once per ambient loop.
///
/// PLACEMENT MATTERS: put it in the screen's body (a [Stack] child, an
/// overlay), never inside a [ListView] or any lazily-built sliver. A list
/// destroys the elements of children scrolled past its cache extent, so a
/// marker living there would release its claim the moment the user scrolled
/// down and re-take it on the way back — the wish would blink in and out
/// with the scroll position instead of belonging to the screen.
class EmberBackgroundWishes extends StatefulWidget {
  const EmberBackgroundWishes({super.key});

  @override
  State<EmberBackgroundWishes> createState() => _EmberBackgroundWishesState();
}

class _EmberBackgroundWishesState extends State<EmberBackgroundWishes> {
  bool _claimed = false;

  /// VISIBILITY-scoped, not mount-scoped. Home stays mounted underneath
  /// every route pushed over it, so a claim taken in initState followed the
  /// user into the vault, the settings screen and the capsule ceremony — a
  /// wish is Home's, and only while Home is what you are looking at.
  /// [TickerMode] is exactly that signal: the Navigator turns it off for
  /// routes covered by an opaque one, and (since the root builder wraps the
  /// tree) the app's own lock and stealth covers turn it off too.
  void _sync() {
    final want = TickerMode.of(context);
    if (want == _claimed) return;
    _claimed = want;
    EmberBackground.wishing.value += want ? 1 : -1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    if (_claimed) EmberBackground.wishing.value--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Mount this inside any screen that covers the app edge-to-edge with its own
/// opaque surface. Costs nothing, renders nothing; its presence pauses the
/// root ember field until it is disposed.
class EmberBackgroundHidden extends StatefulWidget {
  const EmberBackgroundHidden({super.key});

  @override
  State<EmberBackgroundHidden> createState() => _EmberBackgroundHiddenState();
}

class _EmberBackgroundHiddenState extends State<EmberBackgroundHidden> {
  @override
  void initState() {
    super.initState();
    EmberBackground.covered.value++;
  }

  @override
  void dispose() {
    EmberBackground.covered.value--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Marks that an ancestor is already painting the backdrop.
class _EmberBackgroundScope extends InheritedWidget {
  const _EmberBackgroundScope({required super.child});

  @override
  bool updateShouldNotify(_EmberBackgroundScope oldWidget) => false;
}

class _EmberBackgroundState extends State<EmberBackground>
    with SingleTickerProviderStateMixin {
  /// Null while nested — a pass-through must not run a ticker.
  AnimationController? _c;
  bool _nested = false;
  bool _off = false;

  /// The quantizer: bumped only when the 24fps frame index changes, and the
  /// painter repaints off THIS, not the controller — that is the frame cap.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  static const int _fps = 24;
  static const int _loopSeconds = 36;

  late final _EmberPainter _painter;

  @override
  void initState() {
    super.initState();
    _painter = _EmberPainter(
      repaint: _frame,
      frame: _frame,
      embers: widget.embers,
      stars: widget.stars,
    );
    EmberBackground.covered.addListener(_syncTicker);
  }

  void _tick() {
    final f = (_c!.value * _loopSeconds * _fps).floor();
    if (f != _frame.value) _frame.value = f;
  }

  /// One place decides whether the ticker runs: not nested, not covered, not
  /// animations-off. Everything that can change those calls back here.
  void _syncTicker() {
    final c = _c;
    if (c == null) return;
    final shouldRun =
        !_nested && !_off && EmberBackground.covered.value == 0;
    if (shouldRun && !c.isAnimating) {
      c.repeat();
    } else if (!shouldRun && c.isAnimating) {
      c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _nested =
        context.getInheritedWidgetOfExactType<_EmberBackgroundScope>() != null;
    _off = MilesMotion.off(context);
    if (_nested) {
      _c?.dispose();
      _c = null;
      return;
    }
    if (_c == null) {
      _c = AnimationController(
        vsync: this,
        duration: const Duration(seconds: _loopSeconds),
      )..addListener(_tick);
      if (_off) {
        // One presentable fixed frame — mid-drift, embers visible.
        _c!.value = 0.3;
        _tick();
      }
    }
    _syncTicker();
  }

  @override
  void dispose() {
    EmberBackground.covered.removeListener(_syncTicker);
    _c?.dispose();
    // The glow image is deliberately NOT disposed here — it is a static,
    // process-lifetime cache shared by every instance (its first per-painter
    // incarnation leaked one multi-MB GPU image per screen visit). The frame
    // notifier is this instance's own.
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // An ancestor already paints it — anything we drew here would be hidden
    // behind our own opaque fill anyway.
    if (_nested || _c == null) return widget.child;

    return _EmberBackgroundScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
              decoration: BoxDecoration(color: MilesColors.night),),
          RepaintBoundary(
            child: CustomPaint(painter: _painter, size: Size.infinite),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _EmberPainter extends CustomPainter {
  _EmberPainter({
    required Listenable repaint,
    required this.frame,
    required int embers,
    required int stars,
  }) : super(repaint: repaint) {
    final rnd = math.Random(11);
    _embers = List.generate(
      embers,
      (_) => _Ember(
        x: rnd.nextDouble(),
        y0: rnd.nextDouble(),
        speed: 0.4 + rnd.nextDouble() * 0.9,
        size: 1.0 + rnd.nextDouble() * 2.2,
        sway: 0.01 + rnd.nextDouble() * 0.03,
        phase: rnd.nextDouble(),
      ),
    );
    _stars = List.generate(
      stars,
      (_) => _Star(
        x: rnd.nextDouble(),
        y: rnd.nextDouble() * 0.7,
        size: 0.6 + rnd.nextDouble() * 1.3,
        base: 0.2 + rnd.nextDouble() * 0.5,
        speed: 0.4 + rnd.nextDouble() * 1.4,
        phase: rnd.nextDouble(),
        violet: rnd.nextDouble() < 0.25,
      ),
    );
  }

  final ValueNotifier<int> frame;
  late final List<_Ember> _embers;
  late final List<_Star> _stars;

  static const int _fps = _EmberBackgroundState._fps;
  static const int _loopSeconds = _EmberBackgroundState._loopSeconds;

  /// Where in the 36s loop the wish crosses, and how long it takes — about
  /// 900ms of flight, once per loop, late enough that it is never the first
  /// thing a screen does.
  static const double _wishStart = 0.62;
  static const double _wishSpan = 0.025;

  // ── Sprites, rendered once per process. White star so the atlas color can
  // both tint (violet vs starlight) and twinkle it; the ember carries its own
  // colour and a baked halo — the raster the MaskFilter used to redo every
  // frame, done once.
  static ui.Image? _starSprite;
  static ui.Image? _emberSprite;
  static const double _starRadius = 4;
  static const double _emberRadius = 10;

  static ui.Image _renderRadialSprite(
      double radius, List<Color> colors, List<double> stops,) {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final paint = Paint()
      ..shader = RadialGradient(colors: colors, stops: stops).createShader(
        Rect.fromCircle(
            center: Offset(radius, radius), radius: radius,),
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, radius * 2, radius * 2), paint);
    return rec
        .endRecording()
        .toImageSync((radius * 2).ceil(), (radius * 2).ceil());
  }

  static void _ensureSprites() {
    _starSprite ??= _renderRadialSprite(
      _starRadius,
      const [Colors.white, Colors.white, Color(0x00FFFFFF)],
      const [0, 0.35, 1],
    );
    _emberSprite ??= _renderRadialSprite(
      _emberRadius,
      const [
        MilesColors.emberSoft,
        Color(0xB3F2956F), // the old blur's soft shoulder, baked in
        Color(0x00F2956F),
      ],
      const [0, 0.4, 1],
    );
  }

  // ── The candle glow. SHARED across every instance and rendered at DEVICE
  // resolution: the first cut baked per-painter at logical pixels, which (a)
  // leaked a multi-MB GPU image on every screen unmount, (b) re-baked every
  // frame of a keyboard resize (the canvas height changes per IME frame,
  // bypassing the quantizer), and (c) upscaled a 1/DPR bake ~3x on real
  // handsets, magnifying its 8-bit banding. Now: one process-lifetime image,
  // grow-only (keyed to the largest canvas seen, so IME shrink reuses it as
  // a crop), baked with a 10% margin so the drift/pulse transform never
  // exposes an uncovered edge, at devicePixelRatio.
  static ui.Image? _glow;
  static Size _glowFor = Size.zero;

  /// Margin factor on each side; must exceed drift (3%) + pulse (6%) reach.
  static const double _glowMargin = 0.1;

  static void _ensureGlow(Size size) {
    if (_glow != null &&
        size.width <= _glowFor.width &&
        size.height <= _glowFor.height) {
      return;
    }
    final grown = Size(
      math.max(size.width, _glowFor.width),
      math.max(size.height, _glowFor.height),
    );
    _glow?.dispose();
    final dpr =
        ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
    final w = grown.width * (1 + 2 * _glowMargin);
    final h = grown.height * (1 + 2 * _glowMargin);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(dpr);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF3A1622), Color(0xFF1C0A10), MilesColors.nightDeep],
          stops: [0.0, 0.55, 1.0],
        ).createShader(
          Rect.fromCircle(
            // The gradient's anchor in MARGIN space: the same 0.5/0.32 of the
            // content area, shifted by the margin band around it.
            center: Offset(
              w * 0.5,
              grown.height * (_glowMargin + 0.32),
            ),
            radius: grown.height,
          ),
        ),
    );
    _glow = rec
        .endRecording()
        .toImageSync((w * dpr).ceil(), (h * dpr).ceil());
    _glowFor = grown;
  }

  static final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.low;
  static final Paint _glowPaint =
      Paint()..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    _ensureSprites();
    _ensureGlow(size);

    final t = frame.value / (_loopSeconds * _fps);
    final w = size.width;
    final h = size.height;

    // CandleBreath: the spec's ~7s pulse (7.2s here — the loop's fifth, and
    // the spec's 1.0→1.06 swing) as a transform of the cached glow. Drift
    // ±3%/±2%. The image carries a 10% margin band, so the transform is
    // anchored at the glow's content center and the drawn rect is inflated
    // by the margin — no edge strip ever shows through.
    final breathe = math.sin(t * 2 * math.pi * 5);
    final cx = w * 0.5 + w * 0.03 * math.sin(t * 2 * math.pi);
    final cy = h * 0.32 + h * 0.02 * math.cos(t * 2 * math.pi);
    final pulse = 1.0 + 0.06 * (0.5 + 0.5 * breathe);
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(pulse);
    canvas.translate(-w * 0.5, -h * 0.32);
    // Top-left crop of the grow-only shared bake. When the canvas is
    // temporarily shorter than the bake (the IME is up), the glow reads a
    // touch lower than its true anchor — a small, keyboard-hidden drift that
    // buys never re-baking a multi-MB image per IME frame.
    final dprX = _glow!.width / (_glowFor.width * (1 + 2 * _glowMargin));
    canvas.drawImageRect(
      _glow!,
      Rect.fromLTWH(
        0,
        0,
        w * (1 + 2 * _glowMargin) * dprX,
        h * (1 + 2 * _glowMargin) * dprX,
      ),
      Rect.fromLTWH(
        -w * _glowMargin,
        -h * _glowMargin,
        w * (1 + 2 * _glowMargin),
        h * (1 + 2 * _glowMargin),
      ),
      _glowPaint,
    );
    canvas.restore();

    // Stars: one atlas call. Two half-fields sway on gentle sine offsets
    // (StarfieldDrift) — an OSCILLATION, not a conveyor: a wrap-around drift
    // jumped every star sideways when the 36s loop restarted, because 60s
    // and 120s periods are not integer divisors of the loop. Sine offsets
    // with integer cycle counts are continuous at the wrap by construction.
    final starTransforms = <RSTransform>[];
    final starRects = <Rect>[];
    final starColors = <Color>[];
    const starRect =
        Rect.fromLTWH(0, 0, _starRadius * 2, _starRadius * 2);
    for (var i = 0; i < _stars.length; i++) {
      final s = _stars[i];
      final drift = (i.isEven ? 0.03 : 0.015) *
          math.sin(2 * math.pi * (t + s.phase) * (i.isEven ? 1 : 2));
      final x = ((s.x + drift) % 1) * w;
      final tw =
          0.45 + 0.55 * math.sin((t * s.speed + s.phase) * 2 * math.pi);
      starTransforms.add(RSTransform.fromComponents(
        rotation: 0,
        scale: s.size / _starRadius * 1.6,
        anchorX: _starRadius,
        anchorY: _starRadius,
        translateX: x,
        translateY: h * s.y,
      ),);
      starRects.add(starRect);
      final tint = s.violet ? MilesColors.star : MilesColors.starlight;
      starColors
          .add(tint.withValues(alpha: (s.base * tw).clamp(0.0, 1.0)));
    }

    // ShootingStarWish: one slow streak per ambient loop, on the one screen
    // that mounts EmberBackgroundWishes. It rides the star atlas — head plus
    // a short trail appended to the SAME lists — so a wish costs no extra
    // draw call, only a few more transforms during its ~900ms window. Pure
    // function of t: no timer, no ticker, nothing to dispose.
    if (EmberBackground.wishing.value > 0 &&
        t >= _wishStart &&
        t <= _wishStart + _wishSpan) {
      final u = (t - _wishStart) / _wishSpan; // 0 → 1 across the flight
      const trail = 6;
      for (var k = 0; k < trail; k++) {
        // Each trail dot is the head, slightly earlier in the flight.
        final uk = u - k * 0.07;
        if (uk < 0) continue;
        // A shallow arc down and to the right, entering high-left.
        final x = w * (0.12 + 0.62 * uk);
        final y = h * (0.10 + 0.26 * uk * uk);
        // Fade the whole streak in and out (sin), and dim along the trail.
        final fade = math.sin(u * math.pi) * (1 - k / trail) * 0.9;
        if (fade <= 0.01) continue;
        starTransforms.add(RSTransform.fromComponents(
          rotation: 0,
          scale: (1.5 - k * 0.16).clamp(0.2, 1.5),
          anchorX: _starRadius,
          anchorY: _starRadius,
          translateX: x,
          translateY: y,
        ),);
        starRects.add(starRect);
        starColors.add(MilesColors.starlight.withValues(alpha: fade));
      }
    }

    canvas.drawAtlas(_starSprite!, starTransforms, starRects, starColors,
        BlendMode.modulate, null, _atlasPaint,);

    // Embers: the second atlas call. The sprite already carries colour and
    // halo, so the color list only rides the fade.
    final emberTransforms = <RSTransform>[];
    final emberRects = <Rect>[];
    final emberColors = <Color>[];
    const emberRect =
        Rect.fromLTWH(0, 0, _emberRadius * 2, _emberRadius * 2);
    for (final e in _embers) {
      final prog = (e.y0 + 1 - (t * e.speed) % 1) % 1; // 1 → 0 upward
      final fade = math.sin(prog * math.pi).clamp(0.0, 1.0);
      emberTransforms.add(RSTransform.fromComponents(
        rotation: 0,
        scale: e.size / _emberRadius * 2.2,
        anchorX: _emberRadius,
        anchorY: _emberRadius,
        translateX:
            w * (e.x + e.sway * math.sin((t * 4 + e.phase) * 2 * math.pi)),
        translateY: h * prog,
      ),);
      emberRects.add(emberRect);
      emberColors.add(Colors.white.withValues(alpha: 0.5 * fade));
    }
    canvas.drawAtlas(_emberSprite!, emberTransforms, emberRects, emberColors,
        BlendMode.modulate, null, _atlasPaint,);
  }

  @override
  bool shouldRepaint(_EmberPainter old) => false;
}

class _Ember {
  _Ember({
    required this.x,
    required this.y0,
    required this.speed,
    required this.size,
    required this.sway,
    required this.phase,
  });
  final double x;
  final double y0;
  final double speed;
  final double size;
  final double sway;
  final double phase;
}

class _Star {
  _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.base,
    required this.speed,
    required this.phase,
    required this.violet,
  });
  final double x;
  final double y;
  final double size;
  final double base;
  final double speed;
  final double phase;
  final bool violet;
}
