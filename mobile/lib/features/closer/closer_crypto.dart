import 'dart:convert';
import 'dart:typed_data';

import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/supabase_repository.dart';

/// XChaCha20-Poly1305 always produces a 24-byte nonce and a 16-byte Poly1305 MAC.
const int _nonceLength = 24;
const int _macLength = 16;

/// Ensures the couple-shared symmetric key has been derived before any
/// encrypt/decrypt call in the Closer module.
///
/// Idempotent: [CryptoCore.deriveSharedKey] caches the result, so repeated
/// calls across features are cheap after the first one.
///
/// Throws [StateError] with a user-friendly message if the partner isn't
/// linked or hasn't published their public key yet.
Future<void> ensureSharedKey(SessionState session) async {
  final me = session.profile;
  final partner = session.partner;
  if (me == null || partner == null) {
    throw Exception('Link your partner to use this.');
  }

  // Make sure my own key is published (upsert is idempotent).
  await SupabaseRepository.publishMyPublicKey();

  final partnerPub = await SupabaseRepository.fetchPartnerPublicKey(partner.id);
  if (partnerPub == null) {
    throw Exception(
      "Your partner hasn't enabled Closer yet. Ask them to open it once.",
    );
  }

  // Refuse to proceed until the partner has a REAL key.
    //
    // fetchPartnerPublicKey returns the legacy placeholder rather than null
    // when the partner has never opened Closer, which silently put every
    // write into plaintext mode: intimate notes and photos landed in Postgres
    // as base64 cleartext while the UI promised end-to-end encryption. The
    // "Waiting for your partner" screen was written for exactly this state
    // and had become unreachable.
    if (partnerPub == CryptoCore.legacyPublicKey) {
      throw Exception(
        "Your partner hasn't enabled Closer yet. Ask them to open it once.",
      );
    }

  // The pin stands between the directory and the derive. A server that
  // substitutes a key stops HERE, on every device that has seen the real one
  // — the mismatch surfaces as the key-change sheet, and nothing is derived
  // or decrypted under the imposter key in the meantime.
  final verdict = await PartnerKeyPin.check(
    myUid: me.id,
    partnerId: partner.id,
    partnerPubB64: partnerPub,
  );
  if (verdict == PinCheck.mismatch) {
    throw PartnerKeyChangedException(
      partnerId: partner.id,
      newKeyB64: partnerPub,
    );
  }
  await CryptoCore.deriveSharedKey(partnerPublicKeyB64: partnerPub);
}

/// Packs an [EncryptedPayload] as `mac || ciphertext` for tables that store
/// the nonce in its own column (e.g. `vault_items`, `memory_threads`).
Uint8List packMacAndCiphertext(EncryptedPayload p) {
  final mac = base64Decode(p.macB64);
  final ct = base64Decode(p.ciphertextB64);
  final out = Uint8List(mac.length + ct.length);
  out.setRange(0, mac.length, mac);
  out.setRange(mac.length, out.length, ct);
  return out;
}

/// Inverse of [packMacAndCiphertext]. Accepts the raw bytes read back from a
/// Supabase `bytea` column (decoded from its base64 wire form by the caller).
EncryptedPayload unpackMacAndCiphertext({
  required Uint8List blob,
  required Uint8List nonce,
}) {
  final mac = blob.sublist(0, _macLength);
  final ct = blob.sublist(_macLength);
  return EncryptedPayload(
    ciphertextB64: base64Encode(ct),
    nonceB64: base64Encode(nonce),
    macB64: base64Encode(mac),
  );
}

/// Packs an [EncryptedPayload] as `nonce || mac || ciphertext` for tables
/// that only have a single `bytea` column for the encrypted blob, and for
/// storage objects that are a single opaque file (e.g. a vault item's
/// `.enc` blob).
Uint8List packFull(EncryptedPayload p) {
  final nonce = base64Decode(p.nonceB64);
  final mac = base64Decode(p.macB64);
  final ct = base64Decode(p.ciphertextB64);
  final out = Uint8List(nonce.length + mac.length + ct.length);
  out.setRange(0, nonce.length, nonce);
  out.setRange(nonce.length, nonce.length + mac.length, mac);
  out.setRange(nonce.length + mac.length, out.length, ct);
  return out;
}

/// Inverse of [packFull].
EncryptedPayload unpackFull(Uint8List blob) {
  final nonce = blob.sublist(0, _nonceLength);
  final mac = blob.sublist(_nonceLength, _nonceLength + _macLength);
  final ct = blob.sublist(_nonceLength + _macLength);
  return EncryptedPayload(
    ciphertextB64: base64Encode(ct),
    nonceB64: base64Encode(nonce),
    macB64: base64Encode(mac),
  );
}

/// Decodes a value that came back from a Supabase `bytea` column. PostgREST
/// returns `bytea` as a base64-encoded [String]; this normalises to bytes.
///
/// Pass [expect] wherever the byte count is fixed by the format — a nonce, a
/// MAC. Every branch below decodes SOMETHING from a well-formed string, so a
/// wire that changes shape does not fail here: it returns the wrong number of
/// bytes and fails later inside the cipher, as an ArgumentError about a nonce
/// length that reads like a missing key. That is what made a wire-format bug
/// look like a crypto bug for eleven days. [expect] is what turns it back into
/// a decode error, at the hop where it happened.
Uint8List byteaToBytes(dynamic value, {int? expect}) {
  final out = _decodeBytea(value);
  if (expect != null && out.length != expect) {
    throw FormatException(
      'bytea decoded to ${out.length} bytes, expected $expect. '
      'Exactly double means the value was hex-encoded twice, which is what '
      'postgres_changes delivers — refetch the row through PostgREST rather '
      'than opening a realtime payload.',
    );
  }
  return out;
}

Uint8List _decodeBytea(dynamic value) {
  if (value == null) {
    throw ArgumentError('bytea value was null');
  }
  if (value is Uint8List) return value;
  if (value is String) {
    // PostgREST returns bytea as a Postgres hex literal: `\x<hex>`. THIS is the
    // bug that broke every Closer feature — the value was base64-decoded, which
    // throws on hex and the row was silently dropped. Parse the hex here.
    if (value.startsWith(r'\x')) {
      final hex = value.substring(2);
      final out = Uint8List(hex.length ~/ 2);
      for (var i = 0; i < out.length; i++) {
        out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return out;
    }
    return base64Decode(value); // legacy fallback
  }
  if (value is List) return Uint8List.fromList(value.cast<int>());
  throw ArgumentError('Unsupported bytea encoding: ${value.runtimeType}');
}

/// The nonce byte count every payload in this app uses, exported so decoders
/// can assert it at the boundary instead of discovering it inside the cipher.
const int kNonceLength = _nonceLength;

/// Serializes raw bytes for a Postgres `bytea` column over PostgREST. We send
/// the Postgres hex literal (`\x<hex>`) so the bytes are stored VERBATIM. (Both
/// old write styles were wrong: a raw Uint8List was JSON-encoded as an int
/// array and stored as text; a base64 string was stored as its ASCII text — so
/// neither round-tripped. Always write through this now.)
String bytesToBytea(List<int> bytes) {
  final sb = StringBuffer(r'\x');
  for (final b in bytes) {
    sb.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
