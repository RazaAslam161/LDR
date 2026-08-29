import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The note's seal, held to chat's laws. CryptoCore cannot derive a couple
/// key in a plain unit test (platform keystore), so the packed layout and the
/// AAD binding are exercised with the real primitive under a known key, and
/// the repository's FAIL-CLOSED contract — null, never a throw, never a
/// plaintext render — is exercised through openNote itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final aead = Xchacha20.poly1305Aead();

  UnlinkRow rowWith({String? cipher, String? nonce}) => UnlinkRow.fromRow({
        'couple_id': 'cccccccc-0000-0000-0000-000000000003',
        'initiated_by': 'aaaaaaaa-0000-0000-0000-000000000001',
        'state': 'cooling',
        'started_at': '2026-08-29T00:00:00Z',
        'cooling_ends_at': '2026-09-05T00:00:00Z',
        'last_look_ends_at': null,
        'accepted_at': null,
        'note_cipher': cipher,
        'note_nonce': nonce,
        'note_author': null,
        'note_updated_at': null,
      });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ErrorReporter.resetForTest();
    CryptoCore.clearCache();
  });

  test('one AAD builder, bound to the couple', () {
    expect(UnlinkRepository.noteAd('c1'), 'unlink_note:c1');
    expect(UnlinkRepository.noteAd('c1'),
        isNot(UnlinkRepository.noteAd('c2')),);
  });

  test('the packed layout round-trips under the real primitive', () async {
    final key = await aead.newSecretKey();
    final ad = utf8.encode(UnlinkRepository.noteAd('c1'));
    final box = await aead.encrypt(
      utf8.encode('come home'),
      secretKey: key,
      nonce: aead.newNonce(),
      aad: ad,
    );
    final payload = EncryptedPayload(
      ciphertextB64: base64Encode(box.cipherText),
      nonceB64: base64Encode(box.nonce),
      macB64: base64Encode(box.mac.bytes),
    );
    final blob = packMacAndCiphertext(payload);
    final back = unpackMacAndCiphertext(
      blob: blob,
      nonce: Uint8List.fromList(box.nonce),
    );
    final clear = await aead.decrypt(
      SecretBox(
        base64Decode(back.ciphertextB64),
        nonce: base64Decode(back.nonceB64),
        mac: Mac(base64Decode(back.macB64)),
      ),
      secretKey: key,
      aad: ad,
    );
    expect(utf8.decode(clear), 'come home');

    // The wrong AAD — another couple's binding — must refuse, not decode.
    await expectLater(
      aead.decrypt(
        SecretBox(
          base64Decode(back.ciphertextB64),
          nonce: base64Decode(back.nonceB64),
          mac: Mac(base64Decode(back.macB64)),
        ),
        secretKey: key,
        aad: utf8.encode(UnlinkRepository.noteAd('c2')),
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('openNote on a rowless note is null, quietly', () async {
    expect(await UnlinkRepository.openNote(rowWith()), isNull);
  });

  test('the zero-MAC plaintext sentinel is refused before any crypto runs',
      () async {
    final rows = <Map<String, Object?>>[];
    ErrorReporter.insertRow = (row) async => rows.add(row);
    // mac(16 zeros) || ciphertext, zero nonce — the forgeable shape.
    final zeroBlob = '\\x${'00' * 16}deadbeef';
    final zeroNonce = '\\x${'00' * 24}';
    final out = await UnlinkRepository.openNote(
      rowWith(cipher: zeroBlob, nonce: zeroNonce),
    );
    expect(out, isNull);
    expect(rows, isEmpty,
        reason: 'a refused sentinel is a policy, not an error to report',);
  });

  test('a real-shaped note with no derivable key fails CLOSED and is filed',
      () async {
    final rows = <Map<String, Object?>>[];
    ErrorReporter.insertRow = (row) async => rows.add(row);
    final out = await UnlinkRepository.openNote(
      rowWith(cipher: '\\x${'ab' * 40}', nonce: '\\x${'cd' * 24}'),
    );
    expect(out, isNull, reason: 'never a throw, never a plaintext guess');
    await Future<void>.delayed(Duration.zero);
    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'unlink');
  });
}
