import 'dart:async';
import 'dart:math' show sqrt;

import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Panic lock: either trigger instantly drops the app back to the News cover.
///   A) shake the phone 3× within 1.5s
///   B) volume-up + volume-down within 1s
///
/// Detection is gated by [shouldDetect] so it only runs while the real app is
/// visible (and not already covered by the stealth scrim).
class EmergencyLockService {
  EmergencyLockService._();

  static StreamSubscription<AccelerometerEvent>? _accelSub;
  static VoidCallback? _onLock;
  static bool Function()? _shouldDetect;

  // Shake state.
  static final List<DateTime> _shakeTimes = [];
  static DateTime? _lastShake;

  // Volume-combo state.
  static DateTime? _lastVolUp;
  static DateTime? _lastVolDown;

  static const double _shakeThreshold = 15; // m/s² above gravity
  static const int _shakesRequired = 3;
  static const int _shakeWindowMs = 1500;
  static const int _volumeWindowMs = 1000;

  static void init({
    required VoidCallback onLock,
    required bool Function() shouldDetect,
  }) {
    _onLock = onLock;
    _shouldDetect = shouldDetect;
    _accelSub ??= accelerometerEventStream(
      
    ).listen(_onAccelerometer, onError: (_) {});
  }

  static void dispose() {
    _accelSub?.cancel();
    _accelSub = null;
    _onLock = null;
    _shouldDetect = null;
    _shakeTimes.clear();
    _lastShake = null;
    _lastVolUp = null;
    _lastVolDown = null;
  }

  static bool get _active => _shouldDetect?.call() ?? false;

  // ── Shake ──────────────────────────────────────────────────────────────────
  static void _onAccelerometer(AccelerometerEvent e) {
    // Paused while the News cover or the stealth scrim is showing.
    if (!_active) return;

    final magnitude = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final delta = (magnitude - 9.8).abs(); // remove gravity baseline
    if (delta <= _shakeThreshold) return;

    final now = DateTime.now();
    // One physical shake fires many samples — debounce 200ms.
    if (_lastShake != null &&
        now.difference(_lastShake!).inMilliseconds < 200) {
      return;
    }
    _lastShake = now;
    _shakeTimes.add(now);
    _shakeTimes.removeWhere(
        (t) => now.difference(t).inMilliseconds > _shakeWindowMs,);
    if (_shakeTimes.length >= _shakesRequired) {
      _shakeTimes.clear();
      _lastShake = null;
      _trigger();
    }
  }

  // ── Volume combo ───────────────────────────────────────────────────────────
  /// Fed a 'up' / 'down' volume key-DOWN from the native `miles/volume_keys`
  /// bridge (Android consumes volume keys before Flutter's key pipeline). When
  /// both fire within the window, the panic lock triggers. Callers gate this on
  /// "real app showing AND stealth not active" so it never records stale presses.
  static void handleVolumeDirection(String dir) {
    final now = DateTime.now();
    if (dir == 'up') {
      _lastVolUp = now;
    } else if (dir == 'down') {
      _lastVolDown = now;
    } else {
      return;
    }
    if (_lastVolUp != null && _lastVolDown != null) {
      final diff = _lastVolUp!.difference(_lastVolDown!).abs();
      if (diff.inMilliseconds <= _volumeWindowMs) {
        _lastVolUp = null;
        _lastVolDown = null;
        _trigger();
      }
    }
  }

  static void _trigger() {
    final cb = _onLock;
    if (cb == null) return;
    // Run on the main isolate after the current frame — and ASK for that frame.
    // addPostFrameCallback only appends to _postFrameCallbacks; it schedules
    // nothing. The panic gesture is pressed on a screen that is sitting still,
    // which is exactly when no frame is pending, so the cover never came up:
    // the one control whose whole purpose is to work immediately was the one
    // waiting on something that was never going to happen.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => cb())
      ..scheduleFrame();
  }
}
