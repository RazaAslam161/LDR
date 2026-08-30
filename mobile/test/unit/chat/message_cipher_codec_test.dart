import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// The serialization boundary `messages.body_cipher` / `body_nonce` will cross,
/// pinned before anything writes through it.
///
/// This codec has shipped wrong twice — closer_crypto.dart:114-116 records a
/// base64 decode that threw on Postgres hex and silently dropped every row, and
/// :131-135 records two write styles that stored an int array and an ASCII
/// string instead of bytes. It had no test, and no production row has ever
/// exercised it: memory_threads, fantasy_jar_entries and vault_items are all
/// empty. Chat would be its first real user, on 93 rows, with no update channel
/// to correct a wrong layout afterwards.
///
/// The repo also contains TWO INCOMPATIBLE MAC LAYOUTS — `mac || ciphertext`
/// (packMacAndCiphertext, for tables with a separate nonce column) and
/// `nonce || mac || ciphertext` (packFull, for single-blob columns). Choosing
/// the wrong one is undetectable until decryption fails, so the layout is
/// asserted here by byte offset rather than assumed.
void main() {
  // XChaCha20-Poly1305: 24-byte nonce, 16-byte Poly1305 MAC.
  const nonceLen = 24;
  const macLen = 16;

  // Bytes chosen to break the codecs that were actually shipped: NUL (a C
  // string terminator), 0xff (high bit set), and 0x7f/0x80 either side of the
  // ASCII boundary where a UTF-8 round trip would corrupt them.
  final awkward = Uint8List.fromList([0x00, 0xff, 0x7f, 0x80, 0x00, 0x41]);

  EncryptedPayload payloadOf({
    required List<int> ct,
    required int nonceFill,
    required int macFill,
  }) =>
      EncryptedPayload(
        ciphertextB64: base64Encode(ct),
        nonceB64: base64Encode(Uint8List.fromList(List.filled(nonceLen, nonceFill))),
        macB64: base64Encode(Uint8List.fromList(List.filled(macLen, macFill))),
      );

  test('bytesToBytea emits a Postgres hex literal, not base64', () {
    // Postgres accepts \x<hex> verbatim. base64 was stored as its own ASCII
    // text, which round-tripped to garbage.
    expect(bytesToBytea(awkward), r'\x00ff7f80' '0041');
    expect(bytesToBytea(const []), r'\x');
  });

  test('bytea round-trips through the hex literal byte for byte', () {
    expect(byteaToBytes(bytesToBytea(awkward)), awkward);
  });

  test('byteaToBytes accepts every shape a driver actually returns', () {
    // PostgREST hands back the \x hex literal; the node-postgres driver behind
    // the Supabase MCP hands back a raw byte list; older rows may still be
    // base64. All three must land on the same bytes or a row is dropped.
    expect(byteaToBytes(r'\x00ff7f80' '0041'), awkward);
    expect(byteaToBytes(awkward.toList()), awkward);
    expect(byteaToBytes(base64Encode(awkward)), awkward);
    expect(byteaToBytes(awkward), awkward);
  });

  test('a doubled bytea is refused at the decode, not inside the cipher', () {
    // The shape postgres_changes delivers: the hex literal is itself hex-encoded
    // a second time, prefix intact, so the value still LOOKS like a well-formed
    // \x literal and decodes without complaint — to exactly twice the bytes.
    // Built here the way the wire builds it rather than by hand, so this stays
    // honest if the encoding is ever corrected upstream.
    final nonce = Uint8List.fromList(List.filled(nonceLen, 0x5a));
    final onceEncoded = bytesToBytea(nonce); // \x5a5a…  (48 hex chars)
    final doubled = bytesToBytea(utf8.encode(onceEncoded.substring(2)));

    // Without a length contract this is silently wrong, which is the whole bug:
    // 48 bytes reach XChaCha20 and it raises an ArgumentError about the nonce,
    // indistinguishable from a key that never derived.
    expect(byteaToBytes(doubled).length, nonceLen * 2);

    // With one, it fails where it actually went wrong.
    expect(
      () => byteaToBytes(doubled, expect: nonceLen),
      throwsA(isA<FormatException>()),
    );
    expect(byteaToBytes(onceEncoded, expect: nonceLen), nonce);
  });

  test('the column-pair layout is mac || ciphertext, asserted by offset', () {
    // If this ever becomes ciphertext || mac (wish_jar's layout) every message
    // decrypts to noise and the MAC check fails with no useful error.
    final p = payloadOf(ct: awkward, nonceFill: 9, macFill: 0xAB);
    final blob = packMacAndCiphertext(p);

    expect(blob.length, macLen + awkward.length);
    expect(blob.sublist(0, macLen).every((b) => b == 0xAB), isTrue,
        reason: 'the MAC must come FIRST in a column-pair blob',);
    expect(blob.sublist(macLen), awkward);
  });

  test('pack/unpack survives the full trip through a bytea column', () {
    final p = payloadOf(ct: awkward, nonceFill: 9, macFill: 0xAB);
    final nonce = base64Decode(p.nonceB64);

    // Exactly what the client will do: pack, hex-encode for the column, read
    // the column back, hex-decode, unpack.
    final storedCipher = bytesToBytea(packMacAndCiphertext(p));
    final storedNonce = bytesToBytea(nonce);

    final out = unpackMacAndCiphertext(
      blob: byteaToBytes(storedCipher),
      nonce: byteaToBytes(storedNonce),
    );

    expect(out.ciphertextB64, p.ciphertextB64);
    expect(out.nonceB64, p.nonceB64);
    expect(out.macB64, p.macB64);
  });

  test('a column-pair blob is NOT a packFull blob', () {
    // Guard against someone reaching for the wrong helper: unpackFull would
    // read the first 24 bytes as a nonce, which for a short message runs off
    // the end of the ciphertext entirely.
    final p = payloadOf(ct: awkward, nonceFill: 9, macFill: 0xAB);
    expect(packFull(p).length, nonceLen + macLen + awkward.length);
    expect(packMacAndCiphertext(p).length, macLen + awkward.length);
    expect(packFull(p).length == packMacAndCiphertext(p).length, isFalse);
  });

  test('an all-zero nonce marks a value that was never encrypted', () {
    // CryptoCore's plaintext-v1 sentinel: base64 of the CLEARTEXT with a zero
    // nonce and zero MAC. Writing that into body_cipher would put cleartext in
    // a column named cipher, so the write path has to be able to spot it.
    final sentinel = payloadOf(ct: utf8.encode('hello'), nonceFill: 0, macFill: 0);
    final blob = packMacAndCiphertext(sentinel);
    final nonce = base64Decode(sentinel.nonceB64);

    expect(nonce.every((b) => b == 0), isTrue);
    expect(blob.sublist(0, macLen).every((b) => b == 0), isTrue);
    // The cleartext is sitting in plain sight after the zero MAC.
    expect(utf8.decode(blob.sublist(macLen)), 'hello');

    // The vault's guard checks the FIRST 40 BYTES, which is the packFull
    // layout (nonce24||mac16). Against mac||ct those 40 bytes are 16 zero MAC
    // bytes followed by 24 bytes of message text, so it returns false and
    // reads as protection while protecting nothing.
    final vaultStyleGuardWouldFire =
        blob.length >= 40 && blob.take(40).every((b) => b == 0);
    expect(vaultStyleGuardWouldFire, isFalse,
        reason: 'a mac||ct writer needs its own guard, not the vault copy',);
  });

  test('THE ROUND TRIP: sealed like sendText, opened like hydrate', () async {
    // The one property nothing else proves, and the one whose failure is
    // permanent: that a body sealed on the write path opens on the read path.
    // Every hop the real message takes is here — encrypt, packMacAndCiphertext,
    // bytesToBytea, Message.fromJson's own decoder, unpackMacAndCiphertext,
    // open — with the associated data bound through ChatRepository.bodyAd at
    // BOTH ends, exactly as chat_repository does.
    //
    // Substitution, stated: the AEAD leg uses encryptBytesOffThread /
    // decryptBytesOffThread with an explicit keyOverride, because the shipped
    // path reads CryptoCore._sharedKey and a unit test has no platform keystore
    // to derive one (crypto_core_test.dart documents the same limit). Same
    // cipher, same associated data, same layout — only the key's provenance
    // differs.
    CryptoCore.clearCache();
    final key = Uint8List.fromList(List.filled(32, 42));
    const rowId = '7f3a1c2e-0000-4000-8000-000000000001';
    const text = 'meet me at the usual place at 8 🙂';

    // --- write path, as ChatRepository.sealBody builds it ---
    final p = await CryptoCore.encryptBytesOffThread(
      Uint8List.fromList(utf8.encode(text)),
      associatedData: ChatRepository.bodyAd(rowId),
      keyOverride: key,
    );
    final storedCipher = bytesToBytea(packMacAndCiphertext(p));
    final storedNonce = bytesToBytea(base64Decode(p.nonceB64));

    // The plaintext must not be sitting in the column.
    expect(storedCipher.contains('meet'), isFalse);
    expect(utf8.decode(byteaToBytes(storedCipher), allowMalformed: true),
        isNot(contains('usual')),);

    // --- read path, as Message.fromJson + hydrate do ---
    final m = Message.fromJson({
      'id': rowId,
      'sender_id': 's',
      'created_at': DateTime(2026).toIso8601String(),
      'kind': 'text',
      'body_cipher': storedCipher,
      'body_nonce': storedNonce,
    });
    expect(m.bodyCipher, isNotNull, reason: 'the real decoder must accept it');

    final reopened = unpackMacAndCiphertext(
      blob: m.bodyCipher!,
      nonce: m.bodyNonce!,
    );
    final out = await CryptoCore.decryptBytesOffThread(
      packFull(reopened),
      associatedData: ChatRepository.bodyAd(m.id),
      keyOverride: key,
    );
    expect(utf8.decode(out), text);
  });

  test('a blob sealed for one row will not open as another', () async {
    // bodyAd is load-bearing or it is decoration. If the id the sealer used
    // ever stops matching the id the opener sees, this is the assertion that
    // fails instead of a fleet of unreadable messages.
    CryptoCore.clearCache();
    final key = Uint8List.fromList(List.filled(32, 42));
    final p = await CryptoCore.encryptBytesOffThread(
      Uint8List.fromList(utf8.encode('for row A only')),
      associatedData: ChatRepository.bodyAd('row-A'),
      keyOverride: key,
    );
    await expectLater(
      CryptoCore.decryptBytesOffThread(
        packFull(p),
        associatedData: ChatRepository.bodyAd('row-B'),
        keyOverride: key,
      ),
      throwsA(anything),
    );
  });

  test('a real key produces a blob that is not the plaintext shape', () async {
    // The plumbing check the vault test does, in the column-pair layout.
    CryptoCore.clearCache();
    final key = Uint8List.fromList(List.filled(32, 7));
    final p = await CryptoCore.encryptBytesOffThread(
      Uint8List.fromList(utf8.encode('the quick brown fox')),
      associatedData: 'msg-1',
      keyOverride: key,
    );
    final blob = packMacAndCiphertext(p);
    final nonce = base64Decode(p.nonceB64);

    expect(nonce.every((b) => b == 0), isFalse,
        reason: 'a real encrypt must never emit the zero nonce',);
    expect(blob.sublist(0, macLen).every((b) => b == 0), isFalse,
        reason: 'a real encrypt must never emit a zero MAC',);
    expect(utf8.decode(blob.sublist(macLen), allowMalformed: true),
        isNot(contains('quick')),);

    // And it still survives the column round trip.
    final out = unpackMacAndCiphertext(
      blob: byteaToBytes(bytesToBytea(blob)),
      nonce: byteaToBytes(bytesToBytea(nonce)),
    );
    expect(out.ciphertextB64, p.ciphertextB64);
    expect(out.macB64, p.macB64);
    expect(out.nonceB64, p.nonceB64);
  });
}
