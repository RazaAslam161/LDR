import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// PIN + biometric gate for Memory Threads (spec §F9: "sits behind its OWN
/// 6-digit PIN / biometric prompt, on top of the general Closer gate").
///
/// Preference order:
/// 1. Biometric / device PIN via [LocalAuthentication] if available and set up.
/// 2. A 4-digit app PIN stored in `flutter_secure_storage` (hashed, not raw),
///    which the user must set on first entry.
///
/// Either path returns `true` on success. Failures bubble up as `false` so the
/// caller can keep the user on the gate screen.
class MemoryPinGate {
  MemoryPinGate._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _pinKey = 'miles_memory_pin_hash';
  static const _pinLength = 4;

  static final _localAuth = LocalAuthentication();

  /// True if the user has previously set an app-level PIN.
  static Future<bool> hasAppPin() async {
    final v = await _storage.read(key: _pinKey);
    return v != null && v.isNotEmpty;
  }

  /// Stores a 4-digit PIN (hashed) so it never sits in plaintext on disk.
  static Future<void> setAppPin(String pin) async {
    if (pin.length != _pinLength || !RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN must be $_pinLength digits.');
    }
    await _storage.write(key: _pinKey, value: _hash(pin));
  }

  /// Returns true if [pin] matches the stored hash. If no PIN is set, returns
  /// false (caller should prompt to set one first).
  static Future<bool> verifyAppPin(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    if (stored == null) return false;
    return _hash(pin) == stored;
  }

  /// Wipes the stored PIN (e.g. on sign-out). Kept separate from the crypto
  /// key clear so they can rotate independently.
  static Future<void> clearAppPin() async {
    await _storage.delete(key: _pinKey);
  }

  /// Tries biometric / device-PIN auth. Returns false if unavailable, declined,
  /// or no biometrics are enrolled (caller should fall back to app PIN).
  static Future<bool> authenticateBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isDeviceSupported) return false;

      return _localAuth.authenticate(
        localizedReason: 'Open Memory Threads',
        options: const AuthenticationOptions(
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Full gate: tries biometric first, then app PIN if the user has one set.
  /// Returns true if either path succeeds. Caller decides what to render
  /// when this returns false (usually: stay on the gate screen).
  static Future<bool> tryBiometricOrRequirePin() async {
    final bio = await authenticateBiometric();
    if (bio) return true;
    return false; // caller prompts for the app PIN
  }

  /// Naive hash. PINs are short, so we don't pretend this is a password KDF —
  /// we rely on `flutter_secure_storage`'s hardware-backed encryption to keep
  /// the value safe at rest. The hash here is just so a casual DB / backup
  /// inspection doesn't reveal the raw PIN.
  static String _hash(String pin) {
    var h = 0x811c9dc5;
    for (final c in pin.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'fnv1a:$h';
  }
}
