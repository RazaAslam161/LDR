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
  if (value is String) return base64Decode(value);
  if (value is List) return Uint8List.fromList(value.cast<int>());
  throw ArgumentError('Unsupported bytea encoding: ${value.runtimeType}');
}
