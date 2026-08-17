import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/key_escrow.dart';
import 'package:miles/core/data/partner_rewrap.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// The halves of the rewrap ceremony that are pure: the commitment to the six
/// digits, the fixed-length key chain, and the walk over the ring.
///
/// Everything else needs a device. FlutterSecureStorage, local_auth and every
/// RLS policy on `partner_rewrap_requests` are unreachable from here, which is
/// exactly why the ring walk lives in [openWithChain] / [ringOrder] as top-level
/// functions rather than inside CryptoCore's storage-bound statics.
void main() {
  final aead = Xchacha20.poly1305Aead();

  /// A 32-byte public key with every byte distinct, so a swapped byte shows.
  final pubA = base64Encode(List.generate(32, (i) => i));
  final pubB = base64Encode(List.generate(32, (i) => 255 - i));

  RewrapRequest req(String pub, Uint8List hash) => RewrapRequest(
        id: '11111111-2222-3333-4444-555555555555',
        fromUser: '66666666-7777-8888-9999-000000000000',
        newPublicKeyB64: pub,
        codeHash: hash,
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );

  String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  group('mintCode', () {
    test('is always six digits, and leading zeros survive', () {
      var sawLeadingZero = false;
      for (var i = 0; i < 10000; i++) {
        final code = PartnerRewrap.mintCode();
        expect(code.length, 6, reason: code);
        expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue, reason: code);
        sawLeadingZero = sawLeadingZero || code.startsWith('0');
      }
      // 10 000 draws with no leading zero is a 1-in-10^458 coincidence, so this
      // failing means padLeft is gone — and a code the two phones spell
      // differently is a ceremony that can never succeed.
      expect(sawLeadingZero, isTrue);
    });
  });

  group('codeHash', () {
    test('is the checked-in vector', () async {
      // Pins the Argon2id parameters and the exact framing (raw key bytes as
      // the salt, the six ASCII characters as the secret). A change to any of
      // them breaks every phone already carrying the other version.
      expect(hex(await PartnerRewrap.codeHash(pubA, '000042')),
          '109c0798390bd9e6ab9c3e511a9d3bd29b3283517234d478788a3b07fdd10064',);
    });

    test('one digit moves it, and so does a swapped key', () async {
      final base = await PartnerRewrap.codeHash(pubA, '000042');
      expect(hex(await PartnerRewrap.codeHash(pubA, '000043')),
          isNot(hex(base)),);
      // The whole point of salting with the key: substituting a public key
      // must invalidate the commitment that was made about the old one.
      expect(hex(await PartnerRewrap.codeHash(pubB, '000042')),
          isNot(hex(base)),);
    });

    test("'000042' and '42' are different inputs", () async {
      expect(hex(await PartnerRewrap.codeHash(pubA, '42')),
          isNot(hex(await PartnerRewrap.codeHash(pubA, '000042'))),);
    });

    test('a key that is not 32 bytes is refused', () async {
      await expectLater(
        PartnerRewrap.codeHash(base64Encode(List.filled(31, 7)), '000042'),
        throwsArgumentError,
      );
    });
  });

  group('argon2idDeriveWith', () {
    final salt = Uint8List.fromList(List.generate(32, (i) => i));

    test("a row's own parameters are what open it", () async {
      // Escrow rows carry their own m/t/p and restore derives at those, not at
      // today's constants. Small values here only to keep the test quick — the
      // point is that a changed parameter is a different key, which is why
      // ignoring the column orphans every existing row the day it is hardened.
      final base = await argon2idDeriveWith(
        (secret: 'hunter2', salt: salt, m: 64, t: 1, p: 1),
      );
      expect(hex(base).length, 64);
      expect(
        hex(await argon2idDeriveWith(
          (secret: 'hunter2', salt: salt, m: 128, t: 1, p: 1),
        ),),
        isNot(hex(base)),
      );
      expect(
        hex(await argon2idDeriveWith(
          (secret: 'hunter2', salt: salt, m: 64, t: 2, p: 1),
        ),),
        isNot(hex(base)),
      );
    });
  });

  group('verifyCode', () {
    late Uint8List hash;
    setUpAll(() async {
      hash = await PartnerRewrap.codeHash(pubA, '314159');
    });

    test('accepts the code it committed to', () async {
      expect(await PartnerRewrap.verifyCode(req(pubA, hash), '314159'), isTrue);
    });

    test('rejects one digit off, and any other length', () async {
      expect(await PartnerRewrap.verifyCode(req(pubA, hash), '314158'), isFalse);
      expect(await PartnerRewrap.verifyCode(req(pubA, hash), '31415'), isFalse);
      expect(await PartnerRewrap.verifyCode(req(pubA, hash), ''), isFalse);
    });

    test('rejects the right code against a swapped public key', () async {
      // The attack the digits exist to stop: a rewritten row carrying somebody
      // else's key. The commitment was made about pubA, so it cannot pass here.
      expect(await PartnerRewrap.verifyCode(req(pubB, hash), '314159'), isFalse);
    });
  });

  group('packChain / unpackChain', () {
    List<List<int>> keys(int n) =>
        [for (var k = 0; k < n; k++) List.generate(32, (i) => (k * 40 + i) % 256)];

    test('round-trips 1..8 keys at a constant 258 bytes', () {
      for (var n = 1; n <= 8; n++) {
        final packed = packChain(keys(n));
        expect(packed.length, 258, reason: 'n=$n leaks the re-key count');
        expect(unpackChain(packed), keys(n));
      }
    });

    test('slots past n are zero', () {
      final packed = packChain(keys(1));
      expect(packed.sublist(34).every((b) => b == 0), isTrue);
    });

    test('rejects a chain of 0 or 9 keys', () {
      expect(() => packChain(const []), throwsArgumentError);
      expect(() => packChain(keys(9)), throwsArgumentError);
    });

    test('rejects a key that is not 32 bytes', () {
      expect(() => packChain([List.filled(31, 1)]), throwsArgumentError);
    });

    test('rejects a wrong version, a bad n and a short buffer', () {
      final packed = packChain(keys(3));
      expect(() => unpackChain(Uint8List.fromList(packed)..[0] = 2),
          throwsArgumentError,);
      expect(() => unpackChain(Uint8List.fromList(packed)..[1] = 0),
          throwsArgumentError,);
      expect(() => unpackChain(Uint8List.fromList(packed)..[1] = 9),
          throwsArgumentError,);
      expect(() => unpackChain(packed.sublist(0, 257)), throwsArgumentError);
    });

    test('the sealed blob is exactly 298 bytes, at the house offsets', () async {
      final box = await aead.encrypt(
        packChain(keys(8)),
        secretKey: await aead.newSecretKey(),
        aad: utf8.encode('rewrap_abc'),
      );
      final blob = packFull(EncryptedPayload(
        ciphertextB64: base64Encode(box.cipherText),
        nonceB64: base64Encode(box.nonce),
        macB64: base64Encode(box.mac.bytes),
      ),);
      // The length the migration's check constraint enforces.
      expect(blob.length, 298);
      expect(blob.sublist(0, 24), box.nonce);
      expect(blob.sublist(24, 40), box.mac.bytes);
      expect(blob.sublist(40), box.cipherText);

      final back = unpackFull(blob);
      expect(base64Decode(back.nonceB64), box.nonce);
      expect(base64Decode(back.macB64), box.mac.bytes);
      expect(base64Decode(back.ciphertextB64), box.cipherText);
    });
  });

  group('ringOrder', () {
    test('puts the remembered index first, then everything else once', () {
      expect(ringOrder(4, 2), [2, 0, 1, 3]);
      expect(ringOrder(4, 2).toSet().length, 4);
    });

    test('an index outside the ring is simply not preferred', () {
      expect(ringOrder(3, -1), [0, 1, 2]);
      expect(ringOrder(3, 7), [0, 1, 2]);
    });

    test('an empty ring has nothing to walk', () {
      expect(ringOrder(0, -1), isEmpty);
      expect(ringOrder(0, 0), isEmpty);
    });
  });

  group('openWithChain', () {
    final aad = utf8.encode('mem_42');

    Future<SecretBox> sealed(SecretKey key, String text) async {
      final box = await aead.encrypt(utf8.encode(text), secretKey: key, aad: aad);
      return SecretBox(box.cipherText, nonce: box.nonce, mac: box.mac);
    }

    test('the current key opens it and reports no ring hit', () async {
      final key = await aead.newSecretKey();
      final ring = [for (var i = 0; i < 3; i++) await aead.newSecretKey()];
      final (clear, hit) = await openWithChain(
          await sealed(key, 'today'), key, ring, aad, -1,);
      expect(utf8.decode(clear), 'today');
      expect(hit, -1);
    });

    test('a retired key opens it and reports which one', () async {
      final ring = [for (var i = 0; i < 4; i++) await aead.newSecretKey()];
      final (clear, hit) = await openWithChain(
        await sealed(ring[2], 'before the reinstall'),
        await aead.newSecretKey(),
        ring,
        aad,
        -1,
      );
      expect(utf8.decode(clear), 'before the reinstall');
      expect(hit, 2);
    });

    test('the remembered index is tried first and still reports itself',
        () async {
      final ring = [for (var i = 0; i < 4; i++) await aead.newSecretKey()];
      final (_, hit) = await openWithChain(
        await sealed(ring[3], 'an older era'),
        await aead.newSecretKey(),
        ring,
        aad,
        3,
      );
      expect(hit, 3);
    });

    test('an exhausted chain rethrows the ORIGINAL failure', () async {
      // memory_failure.dart classifies this exact type as gone-for-good, so a
      // fallback that swallowed it and threw something else would turn a
      // permanent loss into "try again", forever.
      final ring = [for (var i = 0; i < 3; i++) await aead.newSecretKey()];
      await expectLater(
        openWithChain(
          await sealed(await aead.newSecretKey(), 'unreachable'),
          await aead.newSecretKey(),
          ring,
          aad,
          -1,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a wrong associated data never opens under any key in the chain',
        () async {
      final key = await aead.newSecretKey();
      final ring = [key, await aead.newSecretKey()];
      await expectLater(
        openWithChain(await sealed(key, 'bound to mem_42'), key, ring,
            utf8.encode('mem_99'), -1,),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
