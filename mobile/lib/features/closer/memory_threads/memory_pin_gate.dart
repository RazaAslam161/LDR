import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:miles/core/data/secure_storage_options.dart';
import 'package:miles/core/services/app_lock.dart' show AppLock;
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
    iOptions: kMilesKeychain,
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
    await _storage.write(key: _pinKey, value: _encode(pin));
  }

  /// Returns true if [pin] matches the stored hash. If no PIN is set, returns
  /// false (caller should prompt to set one first).
  ///
  /// Verify-then-upgrade: a value the FNV-1a era wrote is verified with the
  /// old arithmetic and — only on SUCCESS — rewritten as salted sha256 under
  /// the same key, so no existing user is ever asked to reset. A wrong PIN
  /// rewrites nothing.
  static Future<bool> verifyAppPin(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    if (stored == null) return false;
    if (stored.startsWith('fnv1a:')) {
      if (_legacyHash(pin) != stored) return false;
      await _storage.write(key: _pinKey, value: _encode(pin));
      return true;
    }
    return _matches(stored, pin);
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

  /// The value the previous build stored: FNV-1a, 32 bits, no salt — one
  /// precomputed table of 10,000 entries read every user's PIN at sight. Kept
  /// only so [verifyAppPin] can recognise and upgrade an existing value;
  /// nothing writes it again.
  static String _legacyHash(String pin) {
    var h = 0x811c9dc5;
    for (final c in pin.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'fnv1a:$h';
  }

  static final _rng = Random.secure();

  /// `sha256:<saltB64>:<hashB64>` under a fresh 16-byte random salt — the same
  /// shape [AppLock] stores. PINs are short, so this still isn't a password
  /// KDF: 10,000 candidates fall instantly to anyone holding the value, and
  /// resistance at rest comes from `flutter_secure_storage`'s hardware-backed
  /// encryption. The hash keeps the raw PIN off disk; the salt stops one
  /// precomputed table (or one shared PIN) covering every install.
  static String _encode(String pin) {
    final salt = List<int>.generate(16, (_) => _rng.nextInt(256));
    final digest = sha256.convert([...salt, ...utf8.encode(pin)]);
    return 'sha256:${base64Encode(salt)}:${base64Encode(digest.bytes)}';
  }

  static bool _matches(String stored, String pin) {
    final parts = stored.split(':');
    if (parts.length != 3 || parts[0] != 'sha256') {
      // Only setAppPin and the upgrade above write this key, so an unreadable
      // value is a defect worth naming, not a silent false.
      debugPrint('MemoryPinGate: stored PIN value in unknown format');
      return false;
    }
    final salt = base64Decode(parts[1]);
    final digest = sha256.convert([...salt, ...utf8.encode(pin)]);
    return base64Encode(digest.bytes) == parts[2];
  }
}
