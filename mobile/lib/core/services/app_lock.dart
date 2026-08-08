import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide biometric + PIN lock.
///
/// Root cause of the old "locks but can't unlock": [MainActivity] extended
/// FlutterActivity, so local_auth threw `no_fragment_activity` and the prompt
/// never showed. Fixed by extending FlutterFragmentActivity. On top of that this
/// now ALWAYS has a non-biometric way in: a 4-digit app-lock PIN, required when
/// the lock is enabled — so the user can never get stuck.
class AppLock {
  AppLock._();

  static const _enabledKey = 'app_lock_enabled';
  static const _pinKey = 'app_lock_pin_hash';
  static final _auth = LocalAuthentication();

  /// Whether the lock overlay should currently cover the app.
  static final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  // ── Enabled flag ──────────────────────────────────────────────────────────
  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    if (!value) locked.value = false;
  }

  // ── App-lock PIN (local, hashed) ──────────────────────────────────────────
  static String _hash(String pin) =>
      sha256.convert(utf8.encode('miles-applock::$pin')).toString();

  static Future<bool> hasPin() async =>
      (await SharedPreferences.getInstance()).getString(_pinKey) != null;

  static Future<void> setPin(String pin) async =>
      (await SharedPreferences.getInstance()).setString(_pinKey, _hash(pin));

  static Future<bool> verifyPin(String pin) async {
    final stored = (await SharedPreferences.getInstance()).getString(_pinKey);
    return stored != null && stored == _hash(pin);
  }

  // ── Capability ────────────────────────────────────────────────────────────
  /// Device can do biometric OR device-credential (PIN/pattern/passcode) auth.
  static Future<bool> canAuthenticate() async {
    try {
      return await _auth.isDeviceSupported() || await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  static Future<List<BiometricType>> availableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  /// Human label for the unlock button, based on enrolled biometrics.
  static String biometricLabel(List<BiometricType> types) {
    if (types.contains(BiometricType.face)) return 'Face';
    if (types.contains(BiometricType.fingerprint)) return 'fingerprint';
    if (types.contains(BiometricType.iris)) return 'iris';
    return 'biometrics';
  }

  // ── Lock / unlock ─────────────────────────────────────────────────────────
  static Future<void> lockIfEnabled() async {
    if (await isEnabled()) locked.value = true;
  }

  static void unlock() => locked.value = false;

  /// Prompt biometrics (with device-credential fallback). Returns true on
  /// success. On any failure returns false (caller falls back to the PIN) — and
  /// logs the real reason instead of swallowing it.
  static Future<bool> authenticate() async {
    try {
      final ok = await _auth.authenticate(
        // Deliberately nameless. This prompt is drawn by the system on top of
        // whatever cover is showing — News, Calculator, Notes, Weather — and
        // naming the app here hands the whole disguise away at the one moment
        // someone is most likely to be watching over a shoulder.
        localizedReason: "Verify it's you",
        options: const AuthenticationOptions(
          biometricOnly:
              false, // allow device PIN/passcode as a system fallback
          stickyAuth: true, // survive the app backgrounding mid-prompt
          useErrorDialogs: true,
        ),
      );
      if (ok) locked.value = false;
      return ok;
    } on PlatformException catch (e) {
      debugPrint('AppLock auth PlatformException: ${e.code} — ${e.message}');
      return false;
    } catch (e, st) {
      debugPrint('AppLock auth error: $e\n$st');
      return false;
    }
  }
}
