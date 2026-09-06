import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted defaults for the retouch layer.
///
/// A static facade, so the camera screen, the call controller and Settings all
/// reach it without threading an instance through three feature packages —
/// the shape MilesSound uses. Storage discipline is VoicePrefs': a `_loaded`
/// guard, validation against the values THIS build ships, and tolerance of a
/// corrupt document.
///
/// Three keys rather than one, because the two booleans are read by paths that
/// must not parse JSON to answer "is this on".
class BeautyPrefs {
  BeautyPrefs._();

  static const enabledKey = 'beauty_enabled';
  static const callsKey = 'beauty_in_calls';
  static const lookKey = 'beauty_look';

  /// Ships OFF, and that is a deliberate departure from MilesSound's
  /// "absent = ON".
  ///
  /// Two reasons. A retouch silently changing what your partner sees of your
  /// face is not a chime; on a couples app turning it on should be an act.
  /// And it is the only default that leaves the capture fast path intact —
  /// rapid_camera_screen ships the sensor's own JPEG untouched when nothing is
  /// selected, and beauty-on-by-default would put every first-run user through
  /// a processing pass they never asked for.
  static bool _enabled = false;

  /// Only consulted when [_enabled]. Having opted in and then finding the look
  /// absent from a video call is the surprising half, so this defaults on.
  static bool _useInCalls = true;

  static BeautySettings _settings = _defaultLook;
  static bool _loaded = false;

  static const BeautySettings _defaultLook = BeautySettings(
    enabled: true,
    amount: 0.5,
    presetId: 'natural',
    retouch: RetouchParams(smooth: 0.45, tone: 0.3, brighten: 0.15),
  );

  static bool get enabled => _enabled;
  static set enabled(bool v) => _enabled = v;

  static bool get useInCalls => _useInCalls;
  static set useInCalls(bool v) => _useInCalls = v;

  static BeautySettings get settings => _settings;
  static set settings(BeautySettings v) => _settings = v;

  /// What the camera should open with — [enabled] and the remote kill folded
  /// in, so no call site has to remember to check either.
  static BeautySettings forCamera() => (_enabled && !ReleaseGate.beautyKilled)
      ? _settings.copyWith(enabled: true)
      : const BeautySettings();

  /// What a call should use. Both switches fold in here.
  static BeautySettings forCall() =>
      (_enabled && _useInCalls) ? forCamera() : const BeautySettings();

  /// Loads once. Never throws — a preference that cannot be read is a default,
  /// not a crash on the boot path.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(enabledKey) ?? false;
      _useInCalls = prefs.getBool(callsKey) ?? true;
      final raw = prefs.getString(lookKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _settings = BeautySettings.fromJson(decoded);
        }
      }
    } on FormatException catch (e) {
      // A half-written document from a kill mid-save. Defaults stand.
      debugPrint('[beauty] stored look was unreadable, using defaults: $e');
      _settings = _defaultLook;
    } catch (e) {
      debugPrint('[beauty] pref load failed, staying off: $e');
    }
  }

  /// Writes the look. Reports failure rather than reverting silently.
  static Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, _enabled);
      await prefs.setBool(callsKey, _useInCalls);
      await prefs.setString(lookKey, jsonEncode(_settings.toJson()));
    } catch (e) {
      debugPrint('[beauty] pref save failed: $e');
    }
  }

  @visibleForTesting
  static void debugReset() {
    _enabled = false;
    _useInCalls = true;
    _settings = _defaultLook;
    _loaded = false;
  }
}
