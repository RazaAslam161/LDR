import 'dart:convert';
import 'dart:typed_data';

import 'package:miles/core/crypto_core.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';

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
/// that only have a single `bytea` column for the encrypted blob
/// (e.g. `afterglow_entries.photo_a`).
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
Uint8List byteaToBytes(dynamic value) {
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
