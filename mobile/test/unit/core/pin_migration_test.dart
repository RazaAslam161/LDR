import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/features/closer/memory_threads/memory_pin_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The PIN hashes moved home on 2026-08-18: AppLock's out of SharedPreferences
/// (sha256 over a CONSTANT salt, readable by anything that reads the prefs
/// file) and MemoryPinGate's off unsalted 32-bit FNV-1a, both onto
/// `sha256:<saltB64>:<hashB64>` under a per-install random salt in secure
/// storage. The one hard constraint is that no existing user may be locked
/// out, so verification is verify-then-upgrade — and these tests exercise that
/// arithmetic for real: `FlutterSecureStorage.setMockInitialValues` swaps in a
/// map-backed platform, so every read and write below is the production code
/// path, not a restatement of it.
///
/// The LEGACY formats are restated here rather than exported from lib —
/// deliberately, the same bargain key_escrow_test.dart strikes with its wrap
/// label: values in these shapes are already sitting on users' phones, so a
/// change to either legacy branch in lib must FAIL here, not be absorbed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// AppLock's pre-migration hash, exactly as every shipped build wrote it
  /// into SharedPreferences under 'app_lock_pin_hash'.
  String legacyAppLockHash(String pin) =>
      sha256.convert(utf8.encode('miles-applock::$pin')).toString();

  /// MemoryPinGate's pre-migration hash, exactly as every shipped build wrote
  /// it into secure storage under 'miles_memory_pin_hash'.
  String legacyMemoryHash(String pin) {
    var h = 0x811c9dc5;
    for (final c in pin.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'fnv1a:$h';
  }

  /// Asserts [stored] is the new format AND that its hash really is sha256
  /// over `salt || pin` with a full-length random salt — the property the
  /// migration exists to establish.
  void expectSaltedSha256(String? stored, String pin) {
    expect(stored, isNotNull, reason: 'no new-format value was written');
    final parts = stored!.split(':');
    expect(parts, hasLength(3), reason: stored);
    expect(parts[0], 'sha256', reason: stored);
    final salt = base64Decode(parts[1]);
    expect(salt, hasLength(16), reason: stored);
    expect(
      base64Encode(sha256.convert([...salt, ...utf8.encode(pin)]).bytes),
      parts[2],
      reason: 'hash is not sha256(salt || pin)',
    );
  }

  // The map handed to setMockInitialValues IS the backing store, mutated in
  // place, so holding the reference lets each test read the writes back.
  late Map<String, String> secure;

  setUp(() {
    secure = {};
    FlutterSecureStorage.setMockInitialValues(secure);
    SharedPreferences.setMockInitialValues({});
  });

  group('AppLock', () {
    test('new-format roundtrip, with a fresh salt per set', () async {
      await AppLock.setPin('1234');
      expectSaltedSha256(secure['app_lock_pin_v2'], '1234');
      expect(await AppLock.hasPin(), isTrue);
      expect(await AppLock.verifyPin('1234'), isTrue);
      expect(await AppLock.verifyPin('0000'), isFalse);

      // Same PIN, different stored value: the salt is random per write, so
      // two installs (or two set-ups) never share a hash to precompute.
      final first = secure['app_lock_pin_v2'];
      await AppLock.setPin('1234');
      expect(secure['app_lock_pin_v2'], isNot(first));
      expect(await AppLock.verifyPin('1234'), isTrue);
    });

    test('a legacy prefs hash verifies, then upgrades and clears', () async {
      SharedPreferences.setMockInitialValues(
        {'app_lock_pin_hash': legacyAppLockHash('4321')},
      );

      // Load-bearing for the lock screen: a not-yet-migrated PIN must still
      // count, or a failed biometric leaves no way in.
      expect(await AppLock.hasPin(), isTrue);

      expect(await AppLock.verifyPin('4321'), isTrue);
      expectSaltedSha256(secure['app_lock_pin_v2'], '4321');
      expect(
        (await SharedPreferences.getInstance()).getString('app_lock_pin_hash'),
        isNull,
        reason: 'the migrated hash must leave the prefs file',
      );

      // And the next unlock reads the new home.
      expect(await AppLock.verifyPin('4321'), isTrue);
    });

    test('a wrong PIN migrates nothing', () async {
      final legacy = legacyAppLockHash('4321');
      SharedPreferences.setMockInitialValues({'app_lock_pin_hash': legacy});

      expect(await AppLock.verifyPin('9999'), isFalse);
      expect(secure, isEmpty,
          reason: 'a failed verify must not write secure storage',);
      expect(
        (await SharedPreferences.getInstance()).getString('app_lock_pin_hash'),
        legacy,
        reason: 'a failed verify must not touch the legacy hash',
      );

      // The right PIN still works after the failed attempt.
      expect(await AppLock.verifyPin('4321'), isTrue);
    });

    test('setPin retires the legacy hash with the PIN it hashed', () async {
      SharedPreferences.setMockInitialValues(
        {'app_lock_pin_hash': legacyAppLockHash('4321')},
      );

      await AppLock.setPin('5678');
      expect(
        (await SharedPreferences.getInstance()).getString('app_lock_pin_hash'),
        isNull,
        reason: 'a retired PIN left in prefs would keep unlocking',
      );
      expect(await AppLock.verifyPin('4321'), isFalse);
      expect(await AppLock.verifyPin('5678'), isTrue);
    });

    // The app lock is the whole of what stands between somebody holding an
    // unlocked phone and the conversation. Four digits is 10 000 guesses, the
    // check is local, and until this existed there was no counter, no delay
    // and no ceiling anywhere on the path.
    test('the pad shuts after repeated wrong PINs, and a success clears it',
        () async {
      await AppLock.setPin('1234');

      // Four wrong is still free. A mistyped PIN is the ordinary case and must
      // not cost the owner a wait.
      for (var i = 0; i < 4; i++) {
        expect(await AppLock.verifyPin('0000'), isFalse);
      }
      expect(await AppLock.pinLockRemaining(), 0);
      expect(await AppLock.verifyPin('1234'), isTrue,
          reason: 'the owner must not be locked out below the threshold',);

      // ...and getting in resets the tally, so the count is CONSECUTIVE
      // failures rather than a lifetime total.
      for (var i = 0; i < 5; i++) {
        expect(await AppLock.verifyPin('0000'), isFalse);
      }
      expect(await AppLock.pinLockRemaining(), greaterThan(0),
          reason: 'the fifth consecutive miss starts the penalty',);
      expect(await AppLock.verifyPin('1234'), isFalse,
          reason: 'while the penalty runs even the correct PIN is refused — '
              'otherwise the guess rate is never actually capped',);
    });
  });

  group('MemoryPinGate', () {
    test('new-format roundtrip', () async {
      await MemoryPinGate.setAppPin('1234');
      expectSaltedSha256(secure['miles_memory_pin_hash'], '1234');
      expect(await MemoryPinGate.hasAppPin(), isTrue);
      expect(await MemoryPinGate.verifyAppPin('1234'), isTrue);
      expect(await MemoryPinGate.verifyAppPin('0000'), isFalse);
    });

    test('a legacy fnv1a value verifies, then upgrades in place', () async {
      secure['miles_memory_pin_hash'] = legacyMemoryHash('2580');

      expect(await MemoryPinGate.verifyAppPin('2580'), isTrue);
      expectSaltedSha256(secure['miles_memory_pin_hash'], '2580');

      // And keeps verifying out of the new shape.
      expect(await MemoryPinGate.verifyAppPin('2580'), isTrue);
      expect(await MemoryPinGate.verifyAppPin('0000'), isFalse);
    });

    test('a wrong PIN leaves the fnv1a value untouched', () async {
      final legacy = legacyMemoryHash('2580');
      secure['miles_memory_pin_hash'] = legacy;

      expect(await MemoryPinGate.verifyAppPin('0000'), isFalse);
      expect(secure['miles_memory_pin_hash'], legacy,
          reason: 'a failed verify must not rewrite the stored value',);
      expect(await MemoryPinGate.verifyAppPin('2580'), isTrue);
    });
  });
}
