import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Zoom that tracks a finger without spending a frame on it.
///
/// The old path was `onScaleUpdate` → `setState()`. Two costs, both paid on
/// every pointer move: a rebuild of the entire 1518-line camera tree, and a
/// `setZoomLevel` platform round trip. A finger produces well over 60 moves a
/// second, so the UI thread spent its budget rebuilding a tree whose only
/// changed pixel was a "2.4x" label, and the channel queued calls it could not
/// service. That is the lag.
///
/// So the gesture and the zoom run on separate clocks. The finger writes a
/// TARGET, cheaply, as often as it likes. A ticker moves the applied value
/// toward that target once per frame and pushes at most one platform call in
/// the same period. Nothing rebuilds: [value] is a [ValueListenable], so only
/// the indicator that listens to it repaints.
class ZoomController {
  ZoomController({required this.apply, TickerProvider? vsync})
      : _vsync = vsync;

  /// Pushes a level to the camera. Kept injectable so the curve and the damping
  /// can be tested without a camera.
  final Future<void> Function(double level) apply;

  final TickerProvider? _vsync;
  Ticker? _ticker;

  double _min = 1;
  double _max = 1;

  /// What the camera is actually set to. The indicator listens to this rather
  /// than to the target, so the number on screen never runs ahead of the lens.
  final ValueNotifier<double> value = ValueNotifier<double>(1);

  double _target = 1;
  double _applied = 1;
  bool _inFlight = false;

  /// Where the finger was when the drag began, in normalised 0..1 curve space.
  double _dragOrigin = 0;

  double get min => _min;
  double get max => _max;

  /// Digital zoom past a few times optical looks like a smear, and phones
  /// report absurd maxima — 10x on hardware that resolves detail to 3. Offering
  /// it is not generosity, it is a worse picture and a finger travel budget
  /// spent on range nobody uses.
  static const _usableCeiling = 6.0;

  void configure({required double min, required double max}) {
    _min = min;
    _max = math.min(max, min * _usableCeiling);
    if (_max < _min) _max = _min;
    _target = _applied = _min;
    value.value = _min;
  }

  /// Call when a drag begins, so travel is measured from here rather than from
  /// wherever the last one ended.
  void beginDrag() => _dragOrigin = _toCurve(_target);

  /// [dy] is upward finger travel in logical pixels since [beginDrag].
  /// [span] is the distance that should cover the whole range.
  ///
  /// Cheap on purpose: one clamp and one field write. Whatever rate the
  /// platform delivers pointer moves at, this costs the same.
  void dragBy(double dy, {double span = 220}) {
    final t = (_dragOrigin + dy / span).clamp(0.0, 1.0);
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
    if (_vsync == null) {
      // No ticker (tests): apply straight through so behaviour is still
      // observable without pumping frames.
      _applied = _target;
      value.value = _applied;
      _push(_applied);
      return;
    }
    _ticker ??= _vsync.createTicker(_onFrame);
    if (!_ticker!.isActive) _ticker!.start();
  }

  /// Exponential smoothing toward the target, once per frame.
  ///
  /// 0.35 per frame at 60fps closes ~90% of the gap in five frames — 80ms,
  /// which reads as instant while still eating the jitter of a finger that is
  /// also holding a shutter down. Higher and the platform's own latency shows
  /// through as stepping; lower and the lens visibly lags the thumb.
  static const _smoothing = 0.35;

  /// Below this the change is invisible on screen and not worth a channel call.
  static const _epsilon = 0.005;

  void _onFrame(Duration _) {
    final gap = _target - _applied;
    if (gap.abs() < _epsilon) {
      _applied = _target;
      value.value = _applied;
      _push(_applied);
      _ticker?.stop();
      return;
    }
    _applied += gap * _smoothing;
    value.value = _applied;
    _push(_applied);
  }

  /// At most one call in flight. setZoomLevel is a platform round trip; calling
  /// it again before the last returned does not go faster, it queues — and a
  /// queue is what turns a smooth drag into a series of jumps arriving late.
  ///
  /// Dropping frames here is correct rather than lossy: the ticker is still
  /// converging, so the next frame carries a fresher value than the one skipped.
  void _push(double level) {
    if (_inFlight) return;
    _inFlight = true;
    apply(level).catchError((Object _) {}).whenComplete(() => _inFlight = false);
  }

  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    value.dispose();
  }
}
