import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Zoom that tracks a finger without spending a frame on it.
///
/// The old path was `onScaleUpdate` → `setState()`. Two costs, both paid on
/// every pointer move: a rebuild of the entire 1518-line camera tree, and a
/// `setZoomLevel` platform round trip. A finger produces well over 60 moves a
/// second, so the UI thread spent its budget rebuilding a tree whose only
/// changed pixel was a "2.4x" label, and the channel was asked for more than it
/// could service. That is the lag.
///
/// So the gesture and the zoom run on separate clocks. The finger writes a
/// TARGET, cheaply, as often as it likes. A ticker moves the applied value
/// toward that target once per frame and pushes at most one platform call in
/// the same period. Nothing rebuilds: [value] is a [ValueListenable], so only
/// the indicator that listens to it repaints.
class ZoomController {
  ZoomController({required this.apply, required TickerProvider vsync})
      : _vsync = vsync;

  /// Pushes a level to the camera. Kept injectable so the curve and the damping
  /// can be tested without a camera.
  final Future<void> Function(double level) apply;

  final TickerProvider _vsync;
  Ticker? _ticker;

  double _min = 1;
  double _max = 1;

  /// Finger travel, in logical pixels, that covers the whole range. A
  /// calibration of the device, set once — not an argument to a method the
  /// gesture calls sixty times a second.
  double _span = 220;

  /// What the camera is actually set to. The indicator listens to this rather
  /// than to the target, so the number on screen never runs ahead of the lens.
  final ValueNotifier<double> value = ValueNotifier<double>(1);

  double _target = 1;
  double _applied = 1;
  bool _inFlight = false;
  double? _pendingLevel;

  /// Where the finger was when the drag began, in normalised 0..1 curve space.
  double _dragOrigin = 0;

  double get min => _min;
  double get max => _max;

  /// Digital zoom past a few times optical looks like a smear, and phones
  /// report absurd maxima — 10x on hardware that resolves detail to 3. Offering
  /// it is not generosity, it is a worse picture and a finger travel budget
  /// spent on range nobody uses.
  static const _usableCeiling = 6.0;

  void configure({
    required double min,
    required double max,
    double span = 220,
  }) {
    _min = min;
    // Against 1.0, not against min. A device that reports a sub-1.0 minimum is
    // describing its ultra-wide: relative to min the ceiling would collapse to
    // 3.6x, and the camera would open on the wide lens instead of the field of
    // view the user framed the shot in.
    _max = math.min(max, _usableCeiling);
    if (_max < _min) _max = _min;
    _span = span;
    _target = _applied = 1.0.clamp(_min, _max);
    value.value = _applied;
  }

  /// Call when a drag begins, so travel is measured from here rather than from
  /// wherever the last one ended.
  void beginDrag() => _dragOrigin = _toCurve(_target);

  /// [dy] is upward finger travel in logical pixels since [beginDrag].
  ///
  /// Cheap on purpose: one clamp and one field write. Whatever rate the
  /// platform delivers pointer moves at, this costs the same.
  void dragBy(double dy) {
    final t = (_dragOrigin + dy / _span).clamp(0.0, 1.0);
    _target = _fromCurve(t);
    _ensureTicking();
  }

  void setLevel(double level) {
    _target = level.clamp(_min, _max);
    _ensureTicking();
  }

  void reset() => setLevel(_min);

  // ── the curve ─────────────────────────────────────────────────────────────
  //
  // Linear interpolation between min and max feels wrong, and the reason is
  // that zoom is a RATIO, not a distance. Going 1x→2x doubles the subject;
  // 5x→6x barely moves it. Mapped linearly, a finger races through the useful
  // range and then crawls through the useless one.
  //
  // Geometric mapping fixes it: equal finger travel is equal RATIO, so the
  // subject grows at a constant rate the whole way down the screen and the
  // control feels the same everywhere.
  //
  //   zoom = min * (max/min)^t
  //   t    = ln(zoom/min) / ln(max/min)

  double _fromCurve(double t) => _min * math.pow(_max / _min, t).toDouble();

  double _toCurve(double z) {
    if (_max <= _min) return 0;
    return math.log(z / _min) / math.log(_max / _min);
  }

  // ── the clock ─────────────────────────────────────────────────────────────

  void _ensureTicking() {
    _ticker ??= _vsync.createTicker(_onFrame);
    if (!_ticker!.isActive) {
      _last = Duration.zero; // Ticker restarts elapsed from zero on start()
      _ticker!.start();
    }
  }

  /// Time constant of the smoothing, in seconds.
  ///
  /// A per-frame constant would not survive this fleet: the OnePlus 8 runs a
  /// 90Hz panel and the OnePlus 7 and Vivo run 60Hz, so the same 0.35/frame
  /// settled 1.5x faster on one phone and passed ~40% more thumb tremor
  /// through to the lens. Deriving alpha from the frame's own dt makes the
  /// FEEL the constant: 0.341 at 60Hz, 0.243 at 90Hz, same 40ms either way.
  static const _tau = 0.040;

  /// Below this the change is invisible on screen and not worth a channel call.
  static const _epsilon = 0.005;

  Duration _last = Duration.zero;

  void _onFrame(Duration elapsed) {
    // Clamped both ends. TickerMode mutes the ticker while a route sits over
    // the camera without clearing isActive, so the frame after it pops can
    // carry an arbitrary dt — and an unclamped alpha of ~1 is exactly the jump
    // the smoothing exists to prevent.
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.001, 0.050);
    _last = elapsed;

    final gap = _target - _applied;
    if (gap.abs() < _epsilon) {
      _applied = _target;
      value.value = _applied;
      _push(_applied);
      _ticker?.stop();
      return;
    }
    _applied += gap * (1 - math.exp(-dt / _tau));
    value.value = _applied;
    _push(_applied);
  }

  /// At most one call in flight, and the newest dropped level fired on release.
  ///
  /// Each setZoomLevel rebuilds the repeating capture request and CameraX
  /// cancels the previous pending signal, so this is a rate limit matched to
  /// the capture pipeline rather than a defence against a queue. Dropping
  /// intermediate levels costs nothing — the ticker is still converging, so the
  /// next sample is fresher than the one skipped — but dropping the LAST one
  /// costs everything: the ticker stops on the same frame it makes its final
  /// push, so a lost trailing value leaves the lens short of the target with
  /// nothing left to correct it.
  ///
  /// [Future.sync] because a synchronous throw out of `setZoomLevel` would
  /// otherwise escape into the ticker callback and wedge the gate shut for the
  /// rest of the session. The timeout covers the same failure from the other
  /// side: a platform reply that never arrives.
  void _push(double level) {
    if (_inFlight) {
      _pendingLevel = level;
      return;
    }
    _inFlight = true;
    Future.sync(() => apply(level))
        .timeout(const Duration(seconds: 1), onTimeout: () {})
        .catchError((Object _) {})
        .whenComplete(() {
      _inFlight = false;
      final pending = _pendingLevel;
      if (pending != null) {
        _pendingLevel = null;
        _push(pending);
      }
    });
  }

  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    value.dispose();
  }
}
