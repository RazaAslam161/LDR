import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';
import 'package:miles/features/chat/camera/camera_filters.dart';

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
  static bool _callsArmed = false;

  /// Whether the native effect is currently attached to the camera graph.
  static bool get armed => _armed;

  /// Whether the processor is attached to outgoing call video.
  static bool get callsArmed => _callsArmed;

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
    if (!_armed && !_callsArmed) return;
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

  /// Hands the camera's colour preset to the GPU pipeline as the composite's
  /// last step, or takes it back with null. Camera path only, and only while
  /// armed: with the effect off, the Dart overlay and the CPU bake own colour
  /// exactly as before this feature existed.
  static Future<void> setColour(CameraFilter? f) async {
    if (!_armed && !_callsArmed) return;
    try {
      await channel.invokeMethod<void>(
        'colour',
        f == null
            ? const {'on': false}
            : {
                'on': true,
                'matrix': f.colorMatrix,
                'overlayArgb': f.overlayColor?.toARGB32() ?? 0,
                'overlayScreen': f.overlayBlendMode == BlendMode.screen,
              },
      );
    } on MissingPluginException {
      // No engine on this host.
    } on PlatformException catch (e) {
      debugPrint('[beauty] colour failed: ${e.code} ${e.message}');
    }
  }

  /// One call from an in-call control: arms, updates or disarms so the sheet's
  /// switch and sliders do the right thing mid-call with no rebind. Returns
  /// whether the call is retouched afterwards.
  static Future<bool> applyCall(BeautySettings s) async {
    if (!s.enabled) {
      await disarmCalls();
      return false;
    }
    if (_callsArmed) {
      await update(s);
      return true;
    }
    return armCalls(s);
  }

  /// Arms the retouch on outgoing call video. Unlike [arm] there is no bind to
  /// beat: the processor attaches to the camera track when it is created AND
  /// to one that already exists, so this works before getUserMedia and mid-call
  /// alike, with no renegotiation. A disabled [s] disarms instead.
  static Future<bool> armCalls(BeautySettings s) async {
    if (!s.enabled) {
      await disarmCalls();
      return false;
    }
    try {
      final ok =
          await channel.invokeMethod<bool>('armCalls', s.toChannelMap()) ?? false;
      _callsArmed = ok;
      return ok;
    } on MissingPluginException {
      _callsArmed = false;
      return false;
    } on PlatformException catch (e) {
      debugPrint('[beauty] armCalls failed: ${e.code} ${e.message}');
      _callsArmed = false;
      return false;
    }
  }

  /// Detaches from every live call track. The next frame is the camera's own.
  static Future<void> disarmCalls() async {
    if (!_callsArmed) return;
    _callsArmed = false;
    try {
      await channel.invokeMethod<void>('disarmCalls');
    } on MissingPluginException {
      // Already off on a host without the engine.
    } on PlatformException catch (e) {
      debugPrint('[beauty] disarmCalls failed: ${e.code} ${e.message}');
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
    _callsArmed = false;
  }
}
