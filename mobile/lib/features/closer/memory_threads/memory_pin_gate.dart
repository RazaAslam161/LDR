import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:miles/main.dart' show MilesApp;

/// PIN + biometric gate for Memory Threads.
///
/// **Four digits, not the six §F9 asks for, and that is a decision rather than
/// drift.** Widening the length invalidates every PIN already set: the stored
/// hash is of whatever string was typed, so an existing user would be asked for
/// six digits and could never enter their four. That was unrecoverable until
/// this session — the gate now has a Forgot-PIN path — so widening is finally
/// SAFE to do, but it still forces a reset on everyone who has one, which is a
/// call to make deliberately rather than as a side effect of a doc comment.
/// The doc used to claim six while the code did four; this is the code.
///
/// Preference order:
/// 1. Biometric / device PIN via [LocalAuthentication] if available and set up.
/// 2. A 4-digit app PIN stored in `flutter_secure_storage` (hashed, not raw),
///    which the user must set — and confirm — on first entry.
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

      MilesApp.authInProgress = true;
      final result = await _localAuth.authenticate(
        localizedReason: 'Open Memory Threads',
        options: const AuthenticationOptions(
          stickyAuth: true,
        ),
      );
      MilesApp.authInProgress = false;
      return result;
    } catch (_) {
      MilesApp.authInProgress = false;
      return false;
    }
  }

  // tryBiometricOrRequirePin lived here: it called authenticateBiometric and
  // returned its result unchanged, behind a name promising it also handled the
  // PIN. Zero call sites — the gate calls authenticateBiometric directly.

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
