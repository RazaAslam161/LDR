import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/key_escrow.dart';

/// A row as `key_escrow` holds it: `wrapped_seed` is ciphertext with the MAC
/// on its tail, the salt and nonce beside it.
typedef _SealedRow = ({Uint8List sealed, List<int> nonce, Uint8List salt});

/// The write flip of 2026-08-18: [KeyEscrow.backup] now seals under the
/// labelled v2 secret, and every row sealed before the flip must still open.
///
/// backup() and restore() themselves need a signed-in Supabase client and the
/// platform keystore, neither of which a plain unit test can reach — the same
/// wall crypto_core_test.dart names. So the sealing and opening are exercised
/// here byte-for-byte as those methods perform them: the v1 fixture below is
/// built the way backup() sealed BEFORE the flip (kept in this test and
/// nowhere in lib), the v2 seal the way it seals now, and the open the way
/// restore() opens a fetched row. The wiring that cannot run from here — which
/// discriminator backup() writes, which secret _wrapKey feeds each one — is
/// pinned against the source, with the usual honesty debt: a source pin proves
/// the line is still written, not that it still fires.
void main() {
  final aead = Xchacha20.poly1305Aead();

  /// The parameters every real escrow row is sealed at (KeyEscrow._argon*),
  /// unreduced so these fixtures are the rows actually in the field. They are
  /// what makes this file slow.
  const m = 19456;
  const t = 2;
  const p = 1;

  /// KeyEscrow._wrapLabel. Restated rather than exported because changing it
  /// in lib must FAIL here — a new label orphans every v2 row already written.
  const wrapLabel = 'miles/key-escrow/wrap/v2';

  const password = 'correct horse battery staple';
  final seed = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) % 256));

  /// KeyEscrow._escrowSecret, step for step: the v2 secret is the base64 of
  /// one HMAC-SHA256 over the password, keyed with the label.
  Future<String> v2Secret(String pw) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(pw),
      secretKey: SecretKey(utf8.encode(wrapLabel)),
    );
    return base64Encode(mac.bytes);
  }

  /// Seals the seed the way backup() does once it holds a wrap key:
  /// XChaCha20-Poly1305, MAC appended to the ciphertext. Fed the raw password
  /// this IS the v1 seal backup() performed until 2026-08-18; fed the labelled
  /// secret it is today's.
  Future<_SealedRow> seal(String secret, Uint8List salt) async {
    final key = SecretKey(
      await argon2idDeriveWith((secret: secret, salt: salt, m: m, t: t, p: p)),
    );
    final box =
        await aead.encrypt(seed, secretKey: key, nonce: aead.newNonce());
    return (
      sealed: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      nonce: box.nonce,
      salt: salt,
    );
  }

  /// Opens a row the way restore() does: derive at the row's own parameters,
  /// split the MAC off the tail, decrypt. The discriminator is applied exactly
  /// as _wrapKey applies it — v1 derives over the password itself, v2 over
  /// the labelled secret.
  Future<List<int>> open(_SealedRow row, String kdf, String pw) async {
    final secret = kdf == KeyEscrow.kdfArgon2id ? pw : await v2Secret(pw);
    final key = SecretKey(
      await argon2idDeriveWith(
        (secret: secret, salt: row.salt, m: m, t: t, p: p),
      ),
    );
    final cipher = row.sealed.sublist(0, row.sealed.length - 16);
    final mac = row.sealed.sublist(row.sealed.length - 16);
    return aead.decrypt(
      SecretBox(cipher, nonce: row.nonce, mac: Mac(mac)),
      secretKey: key,
    );
  }

  group('a v1 row already in the field', () {
    late _SealedRow row;
    setUpAll(() async {
      row = await seal(
        password,
        Uint8List.fromList(List.generate(16, (i) => i + 1)),
      );
    });

    test('still opens at its own discriminator after the write flip', () async {
      expect(await open(row, KeyEscrow.kdfArgon2id, password), seed);
    });

    test('the wrong password does not open it', () async {
      await expectLater(
        open(row, KeyEscrow.kdfArgon2id, 'correct horse battery stapler'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('the v2 write', () {
    late _SealedRow row;
    setUpAll(() async {
      row = await seal(
        await v2Secret(password),
        Uint8List.fromList(List.generate(16, (i) => 255 - i)),
      );
    });

    test('a fresh seal opens at the v2 discriminator', () async {
      expect(await open(row, KeyEscrow.kdfArgon2idV2, password), seed);
    });

    test('the wrong password does not open it', () async {
      await expectLater(
        open(row, KeyEscrow.kdfArgon2idV2, 'correct horse battery stapler'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('the v1 derivation never opens a v2 row', () async {
      // The separation the flip exists for: same password, and still a MAC
      // failure, because the string GoTrue sees and the wrap secret are no
      // longer the same bytes.
      await expectLater(
        open(row, KeyEscrow.kdfArgon2id, password),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('source pins', () {
    String read(String path) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: 'moved or renamed: $path');
      return f.readAsStringSync();
    }

    test('backup seals AND labels v2, and nothing seals v1 any more', () {
      final src = read('lib/core/data/key_escrow.dart');
      final body = src.substring(
        src.indexOf('static Future<bool> backup('),
        src.indexOf('static Future<bool> restore('),
      );
      expect(body.contains('kdf: kdfArgon2idV2'), isTrue,
          reason: 'the seal reverted to v1:\n$body',);
      expect(body.contains("'kdf': kdfArgon2idV2"), isTrue,
          reason: 'the row label reverted to v1:\n$body',);
      // The v1 token followed by its delimiter, so the v2 constant — of which
      // v1 is a prefix — cannot satisfy the match.
      expect(body.contains('kdf: kdfArgon2id)'), isFalse,
          reason: 'backup derives at v1 again:\n$body',);
      expect(body.contains("'kdf': kdfArgon2id,"), isFalse,
          reason: 'backup labels rows v1 again:\n$body',);
    });

    test('each discriminator is fed the secret these fixtures assume', () {
      final src = read('lib/core/data/key_escrow.dart');
      expect(
        src.contains(
          'kdf == kdfArgon2id ? password : await _escrowSecret(password)',
        ),
        isTrue,
        reason: 'v1 opens over the raw password, v2 over the labelled secret',
      );
      expect(src.contains("'$wrapLabel'"), isTrue,
          reason: 'a changed wrap label orphans every v2 row already written',);
    });

    test('the blob is ciphertext THEN mac, split at a 16-byte tail', () {
      // The seal and the open above are this file's own, so lib could invert
      // its layout in both halves at once and stay green here while every row
      // already written became unopenable — on a fleet with no update channel
      // and no second copy of the seed. Nothing else pins it, and lib itself
      // is the bait: key_escrow's own comment calls this "the same packing the
      // rest of the app uses", which is false — closer_crypto's
      // packMacAndCiphertext writes the MAC FIRST, and escrow is the one site
      // with the opposite order. A maintainer unifying the two would find
      // nothing red.
      final src = read('lib/core/data/key_escrow.dart');
      final backup = src.substring(
        src.indexOf('static Future<bool> backup('),
        src.indexOf('static Future<bool> restore('),
      );
      final restore = src.substring(src.indexOf('static Future<bool> restore('));
      expect(
        backup.contains('[...box.cipherText, ...box.mac.bytes]'),
        isTrue,
        reason: 'the seal packs ciphertext then MAC:\n$backup',
      );
      expect(restore.contains('sealed.sublist(0, sealed.length - 16)'), isTrue,
          reason: 'the open takes the ciphertext off the head',);
      expect(restore.contains('sealed.sublist(sealed.length - 16)'), isTrue,
          reason: 'the open takes the 16-byte MAC off the tail',);
    });

    test('restore re-wraps every row that is not the current write format', () {
      // The path that upgrades an HKDF or v1 row the moment its password
      // opens it — the only moment the material to do so exists. The
      // comparison must name the CURRENT write format: keyed on v1 it skipped
      // upgrading the raw-password rows the flip exists to retire, and paid a
      // full Argon2id re-seal on every already-current v2 restore.
      final src = read('lib/core/data/key_escrow.dart');
      expect(
        src.contains('if (kdf != kdfArgon2idV2) await backup(password);'),
        isTrue,
        reason: 'the re-wrap on successful open must target the write format',
      );
    });
  });
}
