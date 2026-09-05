import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';

/// The Dart side of `miles/beauty` — the retouch engine that sits between the
/// sensor and every consumer of the camera (preview, photo, video).
///
/// Ordering is the whole contract: [arm] must complete BEFORE the camera
/// controller initialises, because CameraX captures the effect list at bind
/// time. Arming afterwards does nothing until the next bind.
///
/// Every failure path here degrades to "camera exactly as before": a device
/// that cannot run the engine, a platform without it (tests, other hosts), or
/// a native error all leave the hook disarmed and return false. No path throws
/// into the camera's boot.
class BeautyEngine {
  BeautyEngine._();

  @visibleForTesting
  static const channel = MethodChannel('miles/beauty');

  static bool _armed = false;

  /// Whether the native effect is currently attached to the camera graph.
  static bool get armed => _armed;

  /// Arms the engine with [s]. Returns whether the effect will be attached at
  /// the next bind. A disabled [s] disarms instead.
  static Future<bool> arm(BeautySettings s) async {
    if (!s.enabled) {
      await disarm();
      return false;
    }
    try {
      final ok = await channel.invokeMethod<bool>('arm', s.toChannelMap()) ?? false;
      _armed = ok;
      if (!ok) {
        debugPrint('[beauty] engine unavailable on this device; camera unchanged');
      }
      return ok;
    } on MissingPluginException {
      _armed = false;
      return false;
    } on PlatformException catch (e) {
      debugPrint('[beauty] arm failed: ${e.code} ${e.message}');
      _armed = false;
      return false;
    }
  }

  /// Live edit; takes effect on the next frame. No-op when not armed.
  static Future<void> update(BeautySettings s) async {
    if (!_armed) return;
    try {
      await channel.invokeMethod<void>('update', s.toChannelMap());
    } on MissingPluginException {
      // Nothing to update on a host without the engine.
    } on PlatformException catch (e) {
      debugPrint('[beauty] update failed: ${e.code} ${e.message}');
    }
  }

  /// Detaches at the next bind. Idempotent.
  static Future<void> disarm() async {
    if (!_armed) return;
    _armed = false;
    try {
      await channel.invokeMethod<void>('disarm');
    } on MissingPluginException {
      // Already off on a host without the engine.
    } on PlatformException catch (e) {
      debugPrint('[beauty] disarm failed: ${e.code} ${e.message}');
    }
  }

  /// Whether the camera accepted the face analyzer beside its own use cases.
  /// Only knowable after the camera has bound, which is why [arm] cannot say.
  /// False means retouch is colour-only on this camera: no reshape, no makeup.
  static Future<bool> faceTracking() async {
    try {
      final m = await channel.invokeMethod<Map<Object?, Object?>>('status');
      return m?['faceTracking'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[beauty] status failed: ${e.code} ${e.message}');
      return false;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _armed = false;
  }
}
