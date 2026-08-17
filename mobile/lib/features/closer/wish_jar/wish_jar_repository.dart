import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/closer_load_result.dart';

/// Fixed tag taxonomy for Wish Jar entries. Tags are hashed before storage
/// (see §F2 of INTIMACY_LAYER.md) so the server never sees plaintext tags.
///
/// The `kFantasy…` name is the feature's old one and stays: renaming it is a
/// code change, not a doc fix, and it buys nothing.
const List<String> kFantasyTaxonomy = [
  'morning',
  'evening',
  'night',
  'slow',
  'urgent',
  'playful',
  'tender',
  'adventurous',
  'location',
  'role',
  'sensation',
  'surprise',
];

/// Display names for the taxonomy entries whose stored key reads badly on
/// screen. The keys above are hashed into `tag_hashes` by [CryptoCore.hmacTag]
/// and are permanent — every entry already saved, on every shipped client,
/// matches on those exact strings. Anything the user reads goes through here
/// instead. Lowercase to sit beside the untranslated tags in the `#tag` row.
const Map<String, String> _kWishTagLabels = {
  'urgent': 'spontaneous',
  'role': 'make-believe',
  'sensation': 'senses',
};

/// The human-readable name for a taxonomy tag.
String wishTagLabel(String tag) => _kWishTagLabels[tag] ?? tag;

/// One decrypted entry — shown only to its author.
class WishEntry {
  WishEntry({
    required this.id,
    required this.authorId,
    required this.text,
    required this.tags,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String text;
  final List<String> tags;
  final DateTime createdAt;
}

/// DB access for the Wish Jar.
///
/// The table is still `fantasy_jar_entries`: that name is on the wire and in
/// every shipped APK, so it is not renamed — only the words around it are.
///
/// All entry text is XChaCha20-Poly1305 encrypted client-side. Tags are
/// HMAC-SHA256 hashed with the couple-shared key before upload so the server
/// can compare sets without ever learning the plaintext tag.
class WishJarRepository {
  WishJarRepository._();

  static final _c = SupabaseService.client;

  /// Derives the couple-shared key if not already cached. Must run before any
  /// encrypt/decrypt/hmac call.
  static Future<void> ensureSharedKey(SessionState session) async {
    final partner = session.partner;
    if (partner == null) {
      throw StateError('Partner not linked — cannot derive shared key.');
    }
    final partnerPub = await SupabaseRepository.fetchPartnerPublicKey(partner.id);
    if (partnerPub == null) {
      throw StateError(
        'Partner has not published a key yet. Ask them to open Closer once.',
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
        'Partner has not published a key yet. Ask them to open Closer once.',
      );
    }
    // Same pin, same refusal as closer_crypto's ensureSharedKey — two doors
    // into the derive means two pins or the second door is the bypass.
    final me = session.profile;
    if (me == null) throw StateError('Not signed in.');
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

  // ─── Tag hashing ───────────────────────────────────────────────────────

  /// Builds {tag → hmac} for the full taxonomy. Used to de-hash matches back
  /// into human-readable tag names for the "you both seem curious about…" nudge.
  static Future<Map<String, String>> buildTagHashMap() async {
    final out = <String, String>{};
    for (final tag in kFantasyTaxonomy) {
      out[tag] = await CryptoCore.hmacTag(tag);
    }
    return out;
  }

  // ─── Bytea serialization ───────────────────────────────────────────────
  //
  // The DB has separate `ciphertext` and `nonce` bytea columns but no mac
  // column. We append the 16-byte Poly1305 MAC to the ciphertext (libsodium
  // convention) so the full authenticated blob round-trips through one column.

  static String _pack(EncryptedPayload p) {
    final ct = base64Decode(p.ciphertextB64);
    final mac = base64Decode(p.macB64);
    final combined = Uint8List(ct.length + mac.length);
    combined.setRange(0, ct.length, ct);
    combined.setRange(ct.length, combined.length, mac);
    return bytesToBytea(combined);
  }

  static EncryptedPayload _unpack(dynamic cipherVal, dynamic nonceVal) {
    final combined = byteaToBytes(cipherVal);
    final ct = combined.sublist(0, combined.length - 16);
    final mac = combined.sublist(combined.length - 16);
    return EncryptedPayload(
      ciphertextB64: base64Encode(ct),
      nonceB64: base64Encode(byteaToBytes(nonceVal)),
      macB64: base64Encode(mac),
    );
  }

  // ─── CRUD ──────────────────────────────────────────────────────────────

  /// Inserts a new encrypted entry. Returns the created row id.
  static Future<String> addEntry({
    required String coupleId,
    required String authorId,
    required String text,
    required List<String> tags,
  }) async {
    final payload = await CryptoCore.encryptString(text, associatedData: authorId);

    final tagHashes = <String>[];
    for (final t in tags) {
      tagHashes.add(await CryptoCore.hmacTag(t));
    }

    final row = await _c.from('fantasy_jar_entries').insert({
      'couple_id': coupleId,
      'author': authorId,
      'ciphertext': _pack(payload),
      'nonce': bytesToBytea(base64Decode(payload.nonceB64)),
      'tag_hashes': tagHashes,
    }).select('id').single();

    return JsonUtils.parseString(row['id']);
  }

  /// Deletes one of my own entries.
  static Future<void> deleteEntry({required String entryId}) async {
    await _c.from('fantasy_jar_entries').delete().eq('id', entryId);
  }

  /// Fetches and decrypts the current user's own entries.
  static Future<CloserLoadResult<WishEntry>> fetchMyEntries({
    required String coupleId,
    required String myId,
  }) async {
    final rows = await _c
        .from('fantasy_jar_entries')
        .select('id, author, ciphertext, nonce, tag_hashes, created_at')
        .eq('couple_id', coupleId)
        .eq('author', myId)
        .order('created_at', ascending: false);

    final tagHashMap = await buildTagHashMap();
    final hashToTag = {for (final e in tagHashMap.entries) e.value: e.key};

    final out = <WishEntry>[];
    var unreadable = 0;
    for (final row in rows as List) {
      try {
        final plain = await CryptoCore.decryptString(
          _unpack(row['ciphertext'], row['nonce']),
          associatedData: myId,
        );
        final hashes = (row['tag_hashes'] as List? ?? [])
            .map((e) => e.toString())
            .toList();
        final tags = hashes.map((h) => hashToTag[h]).whereType<String>().toList();
        out.add(WishEntry(
          id: JsonUtils.parseString(row['id']),
          authorId: JsonUtils.parseString(row['author']),
          text: plain,
          tags: tags,
          createdAt: JsonUtils.parseDate(row['created_at']).toLocal(),
        ),);
      } catch (e) {
        // Counted, not silent: an entry the partner wrote before publishing
        // their key is legitimately unopenable here, and an empty jar reads
        // as lost data.
        unreadable++;
        // Class only: a decrypt error's message can carry plaintext.
        debugPrint('wish jar: unreadable row: ${e.runtimeType}');
        continue;
      }
    }
    return CloserLoadResult(out, unreadable: unreadable);
  }

  /// Returns the set of tag hashes authored by the partner.
  static Future<Set<String>> fetchPartnerTagHashes({
    required String coupleId,
    required String partnerId,
  }) async {
    final rows = await _c
        .from('fantasy_jar_entries')
        .select('tag_hashes')
        .eq('couple_id', coupleId)
        .eq('author', partnerId);

    final out = <String>{};
    for (final row in rows as List) {
      for (final h in (row['tag_hashes'] as List? ?? [])) {
        out.add(h.toString());
      }
    }
    return out;
  }

  /// Returns the set of tag hashes authored by the current user.
  static Future<Set<String>> fetchMyTagHashes({
    required String coupleId,
    required String myId,
  }) async {
    final rows = await _c
        .from('fantasy_jar_entries')
        .select('tag_hashes')
        .eq('couple_id', coupleId)
        .eq('author', myId);

    final out = <String>{};
    for (final row in rows as List) {
      for (final h in (row['tag_hashes'] as List? ?? [])) {
        out.add(h.toString());
      }
    }
    return out;
  }

}
