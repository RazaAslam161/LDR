import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/partner_key_pin.dart';

/// Same harness as pin_migration_test.dart: `setMockInitialValues` swaps in a
/// map-backed platform, so every read and write below is the production
/// storage path, not a restatement of it. What these tests pin down is the
/// TOFU contract itself — first sight writes, a mismatch never writes, and
/// only repin moves the stored value — because a check() that quietly
/// re-pinned on mismatch would delete the entire point of the class and no
/// screen would ever notice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A syntactically valid 32-byte X25519-shaped key, distinct per seed.
  String keyOf(int seed) =>
      base64Encode(List<int>.generate(32, (i) => (i + seed) & 0xff));

  final keyA = keyOf(0);
  final keyB = keyOf(1);
  final keyC = keyOf(7);

  // The map handed to setMockInitialValues IS the backing store, mutated in
  // place, so holding the reference lets each test read the writes back.
  late Map<String, String> secure;

  setUp(() {
    secure = {};
    FlutterSecureStorage.setMockInitialValues(secure);
  });

  group('check', () {
    test('first sight pins and reports firstUse; the same key then matches',
        () async {
      expect(
        await PartnerKeyPin.check(
          myUid: 'me',
          partnerId: 'them',
          partnerPubB64: keyA,
        ),
        PinCheck.firstUse,
      );
      expect(secure, isNotEmpty, reason: 'first sight must write the pin');
      expect(
        await PartnerKeyPin.check(
          myUid: 'me',
          partnerId: 'them',
          partnerPubB64: keyA,
        ),
        PinCheck.match,
      );
    });

    test('a different key mismatches and does NOT move the pin', () async {
      await PartnerKeyPin.check(
        myUid: 'me',
        partnerId: 'them',
        partnerPubB64: keyA,
      );
      final pinned = Map<String, String>.of(secure);
      expect(
        await PartnerKeyPin.check(
          myUid: 'me',
          partnerId: 'them',
          partnerPubB64: keyB,
        ),
        PinCheck.mismatch,
      );
      expect(secure, pinned,
          reason: 'a mismatch must leave the stored pin untouched',);
      // The original key is still the remembered one — the refusal did not
      // become an acceptance.
      expect(
        await PartnerKeyPin.check(
          myUid: 'me',
          partnerId: 'them',
          partnerPubB64: keyA,
        ),
        PinCheck.match,
      );
    });
  });

  group('repin', () {
    test('moves the pin to the new key', () async {
      await PartnerKeyPin.check(
        myUid: 'me',
        partnerId: 'them',
        partnerPubB64: keyA,
      );
      await PartnerKeyPin.repin(
        myUid: 'me',
        partnerId: 'them',
        partnerPubB64: keyB,
      );
      expect(
        await PartnerKeyPin.check(
          myUid: 'me',
          partnerId: 'them',
          partnerPubB64: keyB,
        ),
        PinCheck.match,
      );
      // And the OLD key is now the imposter.
      expect(
        await PartnerKeyPin.check(
          myUid: 'me',
          partnerId: 'them',
          partnerPubB64: keyA,
        ),
        PinCheck.mismatch,
      );
    });
  });

  group('expect', () {
    test('an expected key repins silently, exactly once', () async {
      // The ceremony's answering phone announces the rotation before the
      // partner publishes it: the first fetch carrying that exact key must
      // repin without the change alarm, and the authorisation must not
      // survive to bless a second change.
      FlutterSecureStorage.setMockInitialValues({});
      await PartnerKeyPin.check(
          myUid: 'me', partnerId: 'them', partnerPubB64: keyA,);
      await PartnerKeyPin.expect(
          myUid: 'me', partnerId: 'them', partnerPubB64: keyB,);
      expect(
        await PartnerKeyPin.check(
            myUid: 'me', partnerId: 'them', partnerPubB64: keyB,),
        PinCheck.match,
        reason: 'the announced rotation must arrive as a match',
      );
      expect(
        await PartnerKeyPin.check(
            myUid: 'me', partnerId: 'them', partnerPubB64: keyC,),
        PinCheck.mismatch,
        reason: 'the consumed expectation must not bless a second change',
      );
    });

    test('an expectation never blesses a key it did not name', () async {
      FlutterSecureStorage.setMockInitialValues({});
      await PartnerKeyPin.check(
          myUid: 'me', partnerId: 'them', partnerPubB64: keyA,);
      await PartnerKeyPin.expect(
          myUid: 'me', partnerId: 'them', partnerPubB64: keyB,);
      expect(
        await PartnerKeyPin.check(
            myUid: 'me', partnerId: 'them', partnerPubB64: keyC,),
        PinCheck.mismatch,
        reason: 'a third key is an alarm even while a rotation is expected',
      );
      expect(
        await PartnerKeyPin.check(
            myUid: 'me', partnerId: 'them', partnerPubB64: keyA,),
        PinCheck.match,
        reason: 'the pin itself must be untouched by the refused key',
      );
    });
  });

  group('safetyCode', () {
    test('symmetric, key-sensitive, four groups of five digits', () {
      final code = PartnerKeyPin.safetyCode(keyA, keyB);
      // Swapped argument order gives the identical string — the property the
      // change sheet and the Settings dialog both lean on, since neither
      // phone knows whose key "goes first".
      expect(PartnerKeyPin.safetyCode(keyB, keyA), code);
      expect(PartnerKeyPin.safetyCode(keyA, keyC), isNot(code),
          reason: 'a different key must change the code',);
      expect(
        RegExp(r'^\d{5} \d{5} \d{5} \d{5}$').hasMatch(code),
        isTrue,
        reason: code,
      );
    });
  });
}
