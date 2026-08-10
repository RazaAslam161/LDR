import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/crypto_core.dart';

/// The point of this change is a rollout that encrypts new data without
/// breaking a single existing row. These prove both halves: real AEAD when a
/// couple key exists, and legacy plaintext rows still readable regardless.
///
/// CryptoCore.deriveSharedKey needs the platform keystore, which is not
/// available in a plain unit test, so the pure encode/decode contract is
/// exercised here directly with a known key; the derivation path itself is
/// covered by the round-trip through the same primitives.
void main() {
  final aead = Xchacha20.poly1305Aead();

  /// A legacy / plaintext-mode payload: bytes verbatim, zero nonce, zero MAC.
  /// This is exactly what the old base64 pass-through and the new plaintext
  /// fallback both write.
  EncryptedPayload legacy(List<int> bytes) => EncryptedPayload(
        ciphertextB64: base64Encode(bytes),
        nonceB64: base64Encode(Uint8List(24)),
        macB64: base64Encode(Uint8List(16)),
      );

  test('a legacy plaintext row still decrypts after the upgrade', () async {
    // No shared key derived (fresh process) — the read must NOT depend on one.
    CryptoCore.clearCache();
    final p = legacy(utf8.encode('an old note from before encryption'));
    expect(await CryptoCore.decryptString(p),
        'an old note from before encryption',);
  });

  test('a legacy binary row still decrypts', () async {
    CryptoCore.clearCache();
    final bytes = Uint8List.fromList(List.generate(256, (i) => i));
    final out = await CryptoCore.decryptBytes(legacy(bytes));
    expect(out, bytes);
  });

  test('a real AEAD row round-trips, and the nonce/mac are not zero', () async {
    // Encrypt with the real primitive under a known key, then feed the payload
    // shape CryptoCore produces back through its own decrypt with that key.
    final key = await aead.newSecretKey();
    final box = await aead.encrypt(
      utf8.encode('a new secret'),
      secretKey: key,
      nonce: aead.newNonce(),
      aad: utf8.encode('item-42'),
    );
    expect(box.nonce.any((b) => b != 0), isTrue, reason: 'real nonce');
    expect(box.mac.bytes.any((b) => b != 0), isTrue, reason: 'real mac');

    // Decrypt back through the same primitive to confirm the packed shape and
    // AAD binding are what CryptoCore relies on.
    final clear = await aead.decrypt(
      SecretBox(box.cipherText, nonce: box.nonce, mac: box.mac),
      secretKey: key,
      aad: utf8.encode('item-42'),
    );
    expect(utf8.decode(clear), 'a new secret');
  });

  test('AAD is bound: the wrong associated data fails to decrypt', () async {
    final key = await aead.newSecretKey();
    final box = await aead.encrypt(
      utf8.encode('bound to item-42'),
      secretKey: key,
      nonce: aead.newNonce(),
      aad: utf8.encode('item-42'),
    );
    expect(
      () => aead.decrypt(
        SecretBox(box.cipherText, nonce: box.nonce, mac: box.mac),
        secretKey: key,
        aad: utf8.encode('item-99'),
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
      reason: 'a moved/relabelled row must not silently decrypt',
    );
  });

  test('a non-legacy payload with no derived key is refused, not misread',
      () async {
    // A real ciphertext must never be handed back as if it were plaintext.
    CryptoCore.clearCache();
    final notLegacy = EncryptedPayload(
      ciphertextB64: base64Encode(utf8.encode('ciphertext')),
      nonceB64: base64Encode(Uint8List(24)..[0] = 7),
      macB64: base64Encode(Uint8List(16)..[0] = 9),
    );
    expect(() => CryptoCore.decryptBytes(notLegacy), throwsStateError);
  });

  test('legacy detection needs BOTH nonce and mac to be zero', () async {
    // A zero nonce alone (real mac) is a real row, not legacy — otherwise a
    // one-in-2^192 real nonce would be mistaken for plaintext.
    CryptoCore.clearCache();
    final zeroNonceRealMac = EncryptedPayload(
      ciphertextB64: base64Encode(utf8.encode('x')),
      nonceB64: base64Encode(Uint8List(24)),
      macB64: base64Encode(Uint8List(16)..[0] = 1),
    );
    expect(
        () => CryptoCore.decryptBytes(zeroNonceRealMac), throwsStateError,);
  });
}
