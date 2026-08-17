import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// The private vault used to encrypt with the COUPLE key, which nothing on the
/// vault path ever derived. Every save after a cold start threw 'no shared key'
/// before uploading a byte, and production held zero vault objects for it.
///
/// The fix gives the vault its own key, passed explicitly as `keyOverride`.
/// These cover the parts of that seam that can regress silently.
///
/// `exportVaultKeyBytes` itself is not exercised here: it reads the private
/// seed from the platform keystore, which a plain unit test has no access to —
/// the same limitation crypto_core_test.dart documents for deriveSharedKey. So
/// these use a known key and prove the PLUMBING, which is what changed.
void main() {
  final aead = Xchacha20.poly1305Aead();

  Future<List<int>> knownKey(int fill) async {
    final k = await aead.newSecretKeyFromBytes(
      Uint8List.fromList(List.filled(32, fill)),
    );
    return k.extractBytes();
  }

  test('the vault round-trips with NO couple key derived', () async {
    // Exactly the state a cold start leaves behind: bindAccount has nulled the
    // shared key and no screen has re-derived it. This threw before the fix.
    CryptoCore.clearCache();
    final key = await knownKey(7);
    final plain = Uint8List.fromList(List.generate(1024, (i) => i % 256));

    final packed = packFull(
      await CryptoCore.encryptBytesOffThread(
        plain,
        associatedData: 'item-1_vault_full',
        keyOverride: key,
      ),
    );

    // Not the plaintext shape: a zero nonce and zero MAC is what the legacy
    // pass-through writes, and a vault that fell back to it would be storing
    // its contents in the clear.
    expect(packed.take(40).every((b) => b == 0), isFalse,
        reason: 'vault media must never be written in the legacy plaintext shape',);

    final out = await CryptoCore.decryptBytesOffThread(
      packed,
      associatedData: 'item-1_vault_full',
      keyOverride: key,
    );
    expect(out, plain);
  });

  test('a small payload honours keyOverride', () async {
    // The regression this exists to catch. encryptBytesOffThread short-circuits
    // payloads under 256KB to avoid an isolate spawn, and that branch used to
    // call encryptBytes — which reads _sharedKey and would ignore the override
    // entirely, encrypting the vault with the couple key again while every
    // test that only checked "it round-trips" still passed.
    CryptoCore.clearCache();
    final vaultKey = await knownKey(9);
    final plain = Uint8List.fromList(List.generate(64, (i) => i));

    final packed = packFull(
      await CryptoCore.encryptBytesOffThread(
        plain,
        associatedData: 'small_vault_full',
        keyOverride: vaultKey,
      ),
    );

    expect(
      await CryptoCore.decryptBytesOffThread(
        packed,
        associatedData: 'small_vault_full',
        keyOverride: vaultKey,
      ),
      plain,
    );
  });

  test('another key cannot open vault media', () async {
    // The promise the gate screen makes in words: "Your partner can never open
    // this." Until this change it was enforced by RLS alone, and the partner
    // held the identical key.
    CryptoCore.clearCache();
    final mine = await knownKey(1);
    final theirs = await knownKey(2);
    final plain = Uint8List.fromList(List.generate(2048, (i) => i % 251));

    final packed = packFull(
      await CryptoCore.encryptBytesOffThread(
        plain,
        associatedData: 'item-2_vault_full',
        keyOverride: mine,
      ),
    );

    await expectLater(
      CryptoCore.decryptBytesOffThread(
        packed,
        associatedData: 'item-2_vault_full',
        keyOverride: theirs,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('the associated data binds a blob to its row', () async {
    // fullAdFor/thumbAdFor carry the item id, so a blob lifted from one row
    // cannot be replayed into another.
    CryptoCore.clearCache();
    final key = await knownKey(3);
    final plain = Uint8List.fromList(List.generate(512, (i) => i % 97));

    final packed = packFull(
      await CryptoCore.encryptBytesOffThread(
        plain,
        associatedData: 'item-A_vault_full',
        keyOverride: key,
      ),
    );

    await expectLater(
      CryptoCore.decryptBytesOffThread(
        packed,
        associatedData: 'item-B_vault_full',
        keyOverride: key,
      ),
      throwsA(isA<Exception>()),
    );
  });
}
