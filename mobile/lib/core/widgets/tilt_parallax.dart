import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// The hero surface leans a few pixels as the phone tilts — the depth cue a
/// flat dark screen otherwise has no way to give.
///
/// Deliberately small: [depth] is clamped hard, because past a few pixels a
/// card stops reading as "sitting under glass" and starts reading as loose.
/// Transform only.
///
/// Three things make it cheap enough to justify at all:
///  * the ACCELEROMETER (gravity), not the gyroscope — absolute tilt with no
///    drift and no integration, so there is nothing to recalibrate;
///  * a low-pass filter, so a hand's tremor never reaches the screen;
///  * setState only while the target and the current offset actually differ.
///    A phone lying still on a table settles and then costs nothing.
///
/// The subscription is the part that must not leak: it lives only while this
/// widget is mounted, its route is current ([TickerMode], which the Navigator
/// turns off for covered routes), and the app is resumed. Anything else
/// cancels it — a parallax that keeps sampling sensors behind a cover is both
/// a battery cost and a thing the disguise cannot afford.
///
/// With animations off there is no subscription at all and the child is
/// returned as it is.
class TiltParallax extends StatefulWidget {
  const TiltParallax({
    required this.child,
    this.depth = 4,
    this.invert = false,
    this.debugSource,
    super.key,
  });

  /// Stands in for the handset's accelerometer so the clamp, the filter and
  /// the subscription's lifecycle can be proven on a machine with no sensors.
  @visibleForTesting
  final Stream<AccelerometerEvent>? debugSource;

  final Widget child;

  /// Maximum travel in logical pixels, clamped to 6.
  final double depth;

  /// Move against the tilt instead of with it — for a foreground layer over
  /// a background that uses the same widget, which is what reads as depth.
  final bool invert;

  @override
  State<TiltParallax> createState() => _TiltParallaxState();
}

class _TiltParallaxState extends State<TiltParallax>
    with WidgetsBindingObserver {
  StreamSubscription<AccelerometerEvent>? _sub;
  Offset _offset = Offset.zero;
  Offset _target = Offset.zero;
  bool _resumed = true;

  /// The posture the phone is actually being held in, learned from the
  /// gravity vector itself and drifting toward it slowly.
  ///
  /// The first version measured tilt against a FIXED neutral — gravity on
  /// the device's y axis — which is only true for a phone held bolt upright
  /// in portrait. Every other real posture railed the effect at its clamp:
  /// flat on a table read 99% of full travel and stayed there, a normal
  /// ~45° hold carried a permanent bias, and in landscape (this app rotates
  /// freely) BOTH axes saturated, so tilting moved the card 0.2px out of 4.
  /// Learning the rest posture instead means "level" is wherever the phone
  /// has been sitting, and the lean is the deviation from it — which is what
  /// the effect was always trying to express.
  double _restX = 0;
  double _restY = 0;
  bool _hasRest = false;

  double get _depth => widget.depth.clamp(0, 6).toDouble();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  /// One place decides whether the sensor is listened to at all.
  void _sync() {
    final want = _resumed &&
        !MilesMotion.off(context) &&
        TickerMode.of(context); // false under a covered/inactive route
    if (want && _sub == null) {
      _sub = (widget.debugSource ??
              accelerometerEventStream(
                samplingPeriod: SensorInterval.uiInterval,
              ))
          .listen(_onSample, onError: (_) {});
    } else if (!want && _sub != null) {
      unawaited(_sub!.cancel());
      _sub = null;
      if (_offset != Offset.zero && mounted) {
        setState(() {
          _offset = Offset.zero;
          _target = Offset.zero;
        });
      }
    }
  }

  void _onSample(AccelerometerEvent e) {
    if (!mounted) return;

    // Learn where "level" is. The first sample defines it outright (so the
    // card never jumps on arrival); after that the rest posture creeps
    // toward the current gravity at 0.5% per sample — slow enough that a
    // deliberate tilt reads as a lean, fast enough that setting the phone
    // down re-centres within a few seconds.
    if (!_hasRest) {
      _restX = e.x;
      _restY = e.y;
      _hasRest = true;
      return;
    }
    const learn = 0.005;
    _restX += (e.x - _restX) * learn;
    _restY += (e.y - _restY) * learn;

    // The lean is the deviation from that posture, in DEVICE axes. Android's
    // sensor frame is fixed to the handset's natural orientation and never
    // rotates with the display (verified in sensors_plus: the raw values are
    // forwarded with no remapCoordinateSystem), so in landscape the device's
    // x is the screen's y. MediaQuery gives us the two cases that matter.
    final dxDev = (e.x - _restX) / 4.0; // ~4 m/s² of lean = full travel
    final dyDev = (e.y - _restY) / 4.0;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // Landscape swaps the axes. Which of the two landscape rotations we are
    // in is not knowable from MediaQuery, so the horizontal lean may answer
    // mirrored there — at ±4px that reads as a different but equally valid
    // parallax, never as a stuck or absent one, which is what matters.
    final tx = (landscape ? dyDev : -dxDev).clamp(-1.0, 1.0);
    final ty = (landscape ? dxDev : dyDev).clamp(-1.0, 1.0);
    final sign = widget.invert ? -1.0 : 1.0;
    final next = Offset(tx * _depth * sign, ty * _depth * sign);
    // Low-pass: the screen follows the hand, it does not copy it.
    final smoothed = Offset(
      _target.dx + (next.dx - _target.dx) * 0.12,
      _target.dy + (next.dy - _target.dy) * 0.12,
    );
    _target = smoothed;
    // A deadzone, so a still phone stops rebuilding entirely.
    if ((smoothed - _offset).distance < 0.1) return;
    setState(() => _offset = smoothed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MilesMotion.off(context)) return widget.child;
    return Transform.translate(offset: _offset, child: widget.child);
  }
}
