import 'package:flutter/material.dart';

/// Motion tokens for the Emberlight system.
///
/// Durations live here rather than in each widget for the reason one duration
/// copied everywhere always fails: a 240ms slide and a 240ms colour change do
/// not feel the same, and once the number is inline in twelve files nobody can
/// retune the app without finding all twelve. Distance and importance pick the
/// token; the token picks the number.
///
/// Everything animated through these is **opacity and transform only**. Both
/// are handled by the compositor without a layout or paint pass, which is what
/// makes them safe on the low-end hardware this app is sideloaded onto — an
/// animated shadow, blur or gradient on those devices drops frames, and blur is
/// banned outright by the repo's own hygiene test.
class MilesMotion {
  MilesMotion._();

  /// A control acknowledging a touch. Anything slower reads as lag.
  static const Duration instant = Duration(milliseconds: 120);

  /// Something appearing or leaving in place — a banner, a hint.
  static const Duration quick = Duration(milliseconds: 220);

  /// A screen's content settling in.
  static const Duration settle = Duration(milliseconds: 420);

  /// The one moment on a screen that is allowed to be slow, because it is the
  /// point of the screen: the invite code arriving.
  static const Duration reveal = Duration(milliseconds: 620);

  /// Entering the screen — decelerate, as if it was already moving.
  static const Curve enter = Curves.easeOutCubic;

  /// A softer settle for the hero moment, with no overshoot: a bounce on a
  /// pairing code reads as a toy, and this screen is asking someone to trust
  /// the app with their relationship.
  static const Curve heroEnter = Curves.easeOutQuart;

  /// How far a thing rises as it fades in. Small on purpose — the eye reads
  /// direction, not distance, and a long travel is what makes an interface
  /// feel slow once you have seen it forty times.
  static const double rise = 14;

  // ── Ambient tempos. Everything below is slower than interaction: these are
  // the room breathing, not the interface responding. They live here so no
  // ambient widget carries a raw Duration — one tempo copied everywhere is
  // the anti-pattern the interaction tokens above already solved.

  /// One breath of a resting glow — calm, roughly a real exhale.
  static const Duration breath = Duration(seconds: 4);

  /// One heartbeat of the Reach pulse.
  static const Duration beat = Duration(milliseconds: 850);

  /// One drift of a floating hero element.
  static const Duration float = Duration(seconds: 6);

  /// The wordmark's candle-catch flicker.
  static const Duration flicker = Duration(milliseconds: 1100);

  /// One digit turning in a countdown.
  static const Duration tick = Duration(milliseconds: 140);

  /// The curve every ambient loop breathes on: symmetric, no edge, because
  /// these run forever and any sharpness becomes a metronome.
  static const Curve breathe = Curves.easeInOutSine;

  // ── The Doorstep. The unlinking ritual's scene has its own tempo family:
  // slower than interaction, more deliberate than ambience, because it is a
  // performance both phones watch together. Same law as everything above —
  // the scene widgets carry no raw Duration; the beat picks the token.

  /// The door closing behind somebody. Fast enough to be final.
  static const Duration slam = Duration(milliseconds: 700);

  /// The breath of camera shake after the slam — one shudder, not an
  /// earthquake. Short, because the stillness after it is the point.
  static const Duration shake = Duration(milliseconds: 480);

  /// The bird's flight in to the lamp post.
  static const Duration birdFlight = Duration(milliseconds: 1400);

  /// One word of the spoken quote arriving in the bird's cloud. The cadence
  /// of somebody saying it, not a block of text appearing.
  static const Duration spokenWord = Duration(milliseconds: 260);

  /// A letter sliding under the door, either direction.
  static const Duration letterSlide = Duration(milliseconds: 800);

  /// The bolt sliding shut — the one moment played with weight.
  static const Duration boltSlide = Duration(milliseconds: 550);

  /// The door opening from inside and light flooding the street.
  static const Duration floodOpen = Duration(milliseconds: 900);

  /// The other ending: the lamp dies and the night takes the street back.
  /// Slower than the flood on purpose — relief is quick, grief is not.
  static const Duration duskFall = Duration(milliseconds: 1400);

  /// One cycle of the scene's ambient loop: the idle acting crossfade, the
  /// lamp's slow warmth, the parallax drift. Everything at rest rides this
  /// one clock, which is what keeps the scene one system instead of seven
  /// widgets.
  static const Duration sceneLoop = Duration(seconds: 8);

  /// Impacts accelerate; arrivals decelerate. The door slam and the bolt use
  /// this — the mirror of [enter], because a thing gaining speed reads as
  /// force and a thing losing speed reads as care.
  static const Curve strike = Curves.easeInQuart;

  /// True when the platform has been asked to stop animating.
  ///
  /// Checked at every call site rather than once at startup: it is a system
  /// setting the user can change while the app is running, and on Android it
  /// is also what "Remove animations" in accessibility settings drives.
  static bool off(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);
}

/// Fades and lifts its children in sequence when the screen first appears.
///
/// One controller drives every child, so the whole page is a single
/// coordinated entrance rather than a dozen widgets each animating on their
/// own schedule — the difference between a screen that composes itself and a
/// screen that flickers. Guidance is explicit that a view should animate one
/// or two things, not everything that moves; this is the one.
///
/// Runs exactly once, on mount. Anything added later — the error banner after
/// a failed sign-in — arrives with the controller already at its end, so it is
/// painted at full opacity immediately and brings its own entrance instead of
/// being dragged through this one a second time.
class EntranceStagger extends StatefulWidget {
  const EntranceStagger({
    required this.children,
    super.key,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<EntranceStagger> createState() => _EntranceStaggerState();
}

class _EntranceStaggerState extends State<EntranceStagger>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MilesMotion.settle,
  );

  bool _started = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A user who has turned animations off gets the finished screen, not a
    // faster version of the animation. Also the correct behaviour when the
    // setting flips mid-session: jump to the end rather than start playing.
    if (MilesMotion.off(context)) {
      if (_c.value != 1) _c.value = 1;
      return Column(
        crossAxisAlignment: widget.crossAxisAlignment,
        mainAxisSize: MainAxisSize.min,
        children: widget.children,
      );
    }

    if (!_started) {
      _started = true;
      _c.forward();
    }

    final n = widget.children.length;
    // The last child must still finish inside the controller's run, so the
    // per-child offset shrinks as the list grows. Without this a long form
    // would have its submit button start animating after the animation ended,
    // i.e. never.
    final step = n <= 1 ? 0.0 : (0.45 / (n - 1)).clamp(0.0, 0.09);

    return Column(
      crossAxisAlignment: widget.crossAxisAlignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          _StaggerItem(
            controller: _c,
            begin: i * step,
            child: widget.children[i],
          ),
      ],
    );
  }
}

class _StaggerItem extends StatelessWidget {
  const _StaggerItem({
    required this.controller,
    required this.begin,
    required this.child,
  });

  final AnimationController controller;
  final double begin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // drive(CurveTween), never CurvedAnimation — route_motion.dart says why:
    // one registers a status listener on the controller that only dispose()
    // removes, and this build runs on every rebuild of the screen it enters.
    final anim = controller.drive(
      CurveTween(
        curve: Interval(begin, (begin + 0.55).clamp(0.0, 1.0),
            curve: MilesMotion.enter,),
      ),
    );
    // The fade rides the render object: FadeTransition listens to the
    // animation itself, so only the lift below re-runs per frame.
    return FadeTransition(
      opacity: anim,
      child: AnimatedBuilder(
        animation: anim,
        // Built once and reused every frame: the subtree does not depend on
        // the animation value, only the wrapper around it does. Rebuilding a
        // form field sixty times a second is how an entrance animation turns
        // into a dropped-frame report on a five-year-old handset.
        child: child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, MilesMotion.rise * (1 - anim.value)),
          child: child,
        ),
      ),
    );
  }
}

/// Fades and lifts a widget in when it first appears, on its own.
///
/// For things that arrive in response to something the user did — a banner, a
/// revealed code — where there is no page entrance to join. Stateless and
/// self-starting: it animates when it is first built and never again, so a
/// parent rebuild does not replay it.
class MotionIn extends StatelessWidget {
  const MotionIn({
    required this.child,
    super.key,
    this.duration = MilesMotion.quick,
    this.curve = MilesMotion.enter,
    this.rise = MilesMotion.rise,
    this.scaleFrom = 1.0,
  });

  final Widget child;
  final Duration duration;
  final Curve curve;
  final double rise;

  /// Start scale. 1.0 disables it — scale is for the hero moment only.
  final double scaleFrom;

  @override
  Widget build(BuildContext context) {
    if (MilesMotion.off(context)) return child;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: curve,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, rise * (1 - t)),
          child: scaleFrom == 1.0
              ? child
              : Transform.scale(
                  scale: scaleFrom + (1 - scaleFrom) * t,
                  child: child,
                ),
        ),
      ),
    );
  }
}
