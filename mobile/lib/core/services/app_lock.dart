import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  /// Where the PIN hash used to live: SharedPreferences, sha256 over one
  /// CONSTANT salt. allowBackup=false keeps that file off cloud backups, but
  /// backups were never the exposure — the file is plain XML on the
  /// filesystem, so anything that reads the app's files (root, a forensic
  /// image of the partition) gets the hash, and 10,000 candidates against a
  /// salt every install shares is a millisecond of work. Kept only so PINs
  /// set before the move keep verifying; see [verifyPin] for the upgrade.
  static const _legacyPinKey = 'app_lock_pin_hash';

  /// Today's home: the platform keystore via `flutter_secure_storage`, same
  /// idiom as CryptoCore's key material, holding [_encode]'s
  /// `sha256:<saltB64>:<hashB64>` under a per-install random salt.
  static const _pinKey = 'app_lock_pin_v2';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

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
  /// The pre-migration hash. Only [verifyPin]'s legacy branch may call this;
  /// nothing writes it again.
  static String _legacyHash(String pin) =>
      sha256.convert(utf8.encode('miles-applock::$pin')).toString();

  static final _rng = Random.secure();

  /// `sha256:<saltB64>:<hashB64>` under a fresh 16-byte random salt. The salt
  /// buys no brute-force resistance for four digits — 10,000 candidates fall
  /// instantly to anyone holding the value — it stops one precomputed table
  /// covering every install, and stops two users with the same PIN sharing a
  /// hash. Resistance comes from WHERE the value lives: the keystore-encrypted
  /// store, not a prefs file any filesystem reader can lift.
  static String _encode(String pin) {
    final salt = List<int>.generate(16, (_) => _rng.nextInt(256));
    final digest = sha256.convert([...salt, ...utf8.encode(pin)]);
    return 'sha256:${base64Encode(salt)}:${base64Encode(digest.bytes)}';
  }

  static bool _matches(String stored, String pin) {
    final parts = stored.split(':');
    if (parts.length != 3 || parts[0] != 'sha256') {
      // Only setPin writes this key, so an unreadable value is a defect worth
      // naming, not a silent false.
      debugPrint('AppLock: stored PIN value in unknown format');
      return false;
    }
    final salt = base64Decode(parts[1]);
    final digest = sha256.convert([...salt, ...utf8.encode(pin)]);
    return base64Encode(digest.bytes) == parts[2];
  }

  /// True when a PIN exists in EITHER home. The legacy check is load-bearing:
  /// the lock screen only offers the PIN pad when this is true, so reporting
  /// false for a not-yet-migrated user would leave a failed biometric with no
  /// way in at all.
  static Future<bool> hasPin() async {
    // The keystore can throw where prefs never could, and this is the answer
    // the lock screen uses to decide whether to OFFER the pad — a throw here
    // would leave a legacy-PIN user with a single dead Unlock button. Fall
    // through to the legacy check instead; a dead keystore must not also
    // silence the one record that a way in exists.
    try {
      if (await _storage.read(key: _pinKey) != null) return true;
    } catch (e) {
      debugPrint('[applock] secure read failed: ${e.runtimeType}');
    }
    return (await SharedPreferences.getInstance()).getString(_legacyPinKey) !=
        null;
  }

  static Future<void> setPin(String pin) async {
    await _storage.write(key: _pinKey, value: _encode(pin));
    // Remove the legacy hash only AFTER the v2 write lands: this order means
    // a process death between the two leaves both present, and verifyPin
    // reads v2 first — the stale legacy copy is swept on the next verified
    // unlock, and a keystore that later loses the v2 record still finds no
    // retired hash to fall back to once this line has run.
    await (await SharedPreferences.getInstance()).remove(_legacyPinKey);
  }

  /// Verify-then-upgrade. The new home is checked first; a PIN still in the
  /// legacy prefs is verified against the old constant-salt hash and — only
  /// on SUCCESS — rewritten in the new format and deleted from prefs. A wrong
  /// PIN migrates nothing, so a typo can never move or corrupt the stored
  /// secret, and no existing user is ever locked out by the format change.
  static Future<bool> verifyPin(String pin) async {
    // Same guard as hasPin, same reason: a throwing keystore must degrade to
    // the legacy branch, not to a lockout.
    String? stored;
    try {
      stored = await _storage.read(key: _pinKey);
    } catch (e) {
      debugPrint('[applock] secure read failed: ${e.runtimeType}');
    }
    if (stored != null) {
      final ok = _matches(stored, pin);
      if (ok) {
        // A process death between setPin's two writes can leave the retired
        // constant-salt hash sitting in prefs; sweep it whenever a verified
        // unlock proves the new record is the live one.
        final prefs = await SharedPreferences.getInstance();
        if (prefs.containsKey(_legacyPinKey)) {
          await prefs.remove(_legacyPinKey);
        }
      }
      return ok;
    }
    final legacy =
        (await SharedPreferences.getInstance()).getString(_legacyPinKey);
    if (legacy == null || legacy != _legacyHash(pin)) return false;
    await setPin(pin);
    return true;
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

  /// Whether this device can put up ANY system unlock at all. False means no
  /// screen lock is enrolled — a state where [authenticate] can only ever
  /// return false, and telling the user "that needs your unlock" is advice
  /// that cannot be followed.
  static Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      // Logged, not swallowed: "no lock is enrolled" and "the platform call
      // failed" both surface here as false, and every caller reads the first.
      // Without this line a broken local_auth binding looks to the whole app
      // like a phone with no screen lock, which is the one diagnosis nobody
      // would think to question.
      debugPrint('AppLock available error: $e');
      return false;
    }
  }

  /// True from the moment the OS prompt is requested until it resolves.
  ///
  /// Lives HERE, not on MilesApp, because `answer()`-style callers demand the
  /// unlock deep inside core code where no widget can set a guard for them —
  /// and the one call site that didn't (partner_rewrap.dart) is how the cover
  /// tore down the ceremony screen mid-prompt and ate the typed code. Setting
  /// it inside [authenticate] means no future call site can reintroduce that.
  static bool authInProgress = false;

  /// Prompt biometrics (with device-credential fallback). Returns true on
  /// success. On any failure returns false (caller falls back to the PIN) — and
  /// logs the real reason instead of swallowing it.
  static Future<bool> authenticate() async {
    authInProgress = true;
    try {
      final ok = await _auth.authenticate(
        // Deliberately nameless. This prompt is drawn by the system on top of
        // whatever cover is showing — News, Calculator, Notes, Weather — and
        // naming the app here hands the whole disguise away at the one moment
        // someone is most likely to be watching over a shoulder.
        localizedReason: "Verify it's you",
        options: const AuthenticationOptions(
          stickyAuth: true, // survive the app backgrounding mid-prompt
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
    } finally {
      // A finally, so a stuck-true flag is impossible — stuck true would
      // disable the disguise until process death.
      authInProgress = false;
    }
  }
}
