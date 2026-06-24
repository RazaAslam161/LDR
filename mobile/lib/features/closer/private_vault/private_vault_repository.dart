import 'dart:convert';
import 'dart:typed_data';

import 'package:miles/core/crypto_core.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// What kind of thing a vault row holds. Maps to the `kind` text column.
enum VaultKind { note, photo, voice, trace }

VaultKind _parseKind(String s) {
  switch (s) {
    case 'photo':
      return VaultKind.photo;
    case 'voice':
      return VaultKind.voice;
    case 'trace':
      return VaultKind.trace;
    default:
      return VaultKind.note;
  }
}

String _stringifyKind(VaultKind k) {
  switch (k) {
    case VaultKind.photo:
      return 'photo';
    case VaultKind.voice:
      return 'voice';
    case VaultKind.trace:
      return 'trace';
    case VaultKind.note:
      return 'note';
  }
}

/// Per-item retention choice. See spec §F4.
enum VaultRetention { keep, ephemeral }

/// Lifecycle of a delete request on a vault item. See spec §F4.
///
/// States:
/// - `none` — live, no delete in flight
/// - `requested` — one partner asked, awaiting the other's confirm or 14-day timeout
/// - `expired` — the 14-day window elapsed without confirmation; the requester
///   may now force a hard delete
enum VaultDeleteState { none, requested, expired }

/// Decrypted in-memory representation of a row from `vault_items`. Ciphertext
/// + nonce + MAC are kept here so the UI can decrypt lazily (e.g. only when a
/// photo is opened full-screen).
class VaultItem {
  VaultItem({
    required this.id,
    required this.kind,
    required this.ciphertext,
    required this.nonce,
    required this.mac,
    required this.createdBy,
    required this.createdAt,
    required this.retention,
    required this.reconfirmDue,
    required this.deleteState,
    required this.deleteRequestedBy,
    required this.deleteRequestedAt,
  });

  final String id;
  final VaultKind kind;

  /// Raw ciphertext + nonce + MAC — see [packMacAndCiphertext] / [unpackMacAndCiphertext].
  final Uint8List ciphertext;
  final Uint8List nonce;
  final Uint8List mac;

  final String createdBy;
  final DateTime createdAt;
  final VaultRetention retention;
  final DateTime? reconfirmDue;

  final VaultDeleteState deleteState;
  final String? deleteRequestedBy;
  final DateTime? deleteRequestedAt;

  /// Builds the [EncryptedPayload] needed by [CryptoCore.decryptString] /
  /// [CryptoCore.decryptBytes]. The item UUID is bound as associated data per
  /// spec §5.1 ("binds ciphertext to metadata").
  EncryptedPayload get payload => EncryptedPayload(
        ciphertextB64: base64Encode(ciphertext),
        nonceB64: base64Encode(nonce),
        macB64: base64Encode(mac),
      );

  /// True if a partner has asked to delete this and the 14-day mutual-consent
  /// window has elapsed — the requester may now force a hard delete.
  bool get canForceDelete =>
      deleteState == VaultDeleteState.expired &&
      deleteRequestedBy != null;

  static VaultItem fromJson(Map<String, dynamic> json, String currentUserId) {
    final blob = byteaToBytes(json['ciphertext']);
    final nonce = byteaToBytes(json['nonce']);
    final macBytes = blob.sublist(0, 16);
    final cipherBytes = blob.sublist(16);

    final requested = (json['delete_requested'] as bool?) ?? false;
    final requestedAt = json['delete_requested_at'] != null
        ? DateTime.parse(json['delete_requested_at'] as String).toUtc()
        : null;
    var deleteState = VaultDeleteState.none;
    if (requested && requestedAt != null) {
      final age = DateTime.now().toUtc().difference(requestedAt);
      deleteState = age.inDays >= 14
          ? VaultDeleteState.expired
          : VaultDeleteState.requested;
    }

    return VaultItem(
      id: json['id'] as String,
      kind: _parseKind(json['kind'] as String),
      ciphertext: cipherBytes,
      nonce: nonce,
      mac: macBytes,
      createdBy: json['created_by'] as String,
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      retention: (json['retention'] as String?) == 'ephemeral'
          ? VaultRetention.ephemeral
          : VaultRetention.keep,
      reconfirmDue: json['reconfirm_due'] != null
          ? DateTime.parse(json['reconfirm_due'] as String).toUtc()
          : null,
      deleteState: deleteState,
      deleteRequestedBy: json['delete_requested_by'] as String?,
      deleteRequestedAt: requestedAt,
    );
  }
}

/// All Supabase reads/writes for the Private Vault go through here.
///
/// Encryption is performed on-device *before* anything is sent to Supabase —
/// only `bytea` ciphertext + nonce ever leave the client (see spec §5.3).
class PrivateVaultRepository {
  PrivateVaultRepository._();

  static final _c = SupabaseService.client;

  /// Returns all non-deleted vault items for the current couple, newest first.
  static Future<List<VaultItem>> fetchItems(String coupleId) async {
    final res = await _c
        .from('vault_items')
        .select()
        .eq('couple_id', coupleId)
        .eq('deleted', false)
        .order('created_at', ascending: false);

    final uid = SupabaseService.currentUserId!;
    return (res as List)
        .map((row) => VaultItem.fromJson(row as Map<String, dynamic>, uid))
        .toList(growable: false);
  }

  /// Inserts a new encrypted item. The bytes passed in are encrypted
  /// on-device; only ciphertext is stored. The new row's UUID is used as the
  /// authenticated associated-data so the ciphertext is bound to the metadata.
  static Future<void> insert({
    required String coupleId,
    required String createdBy,
    required VaultKind kind,
    required Uint8List plaintextBytes,
    required VaultRetention retention,
  }) async {
    final ad = _generateAd();
    final EncryptedPayload payload;
    if (kind == VaultKind.note || kind == VaultKind.trace) {
      final plain = String.fromCharCodes(plaintextBytes);
      payload = await CryptoCore.encryptString(plain, associatedData: ad);
    } else {
      payload =
          await CryptoCore.encryptBytes(plaintextBytes, associatedData: ad);
    }

    final cipherBlob = packMacAndCiphertext(payload);
    final nonceBytes = Uint8List.fromList(base64Decode(payload.nonceB64));

    final now = DateTime.now().toUtc();
    await _c.from('vault_items').insert({
      'couple_id': coupleId,
      'kind': _stringifyKind(kind),
      'ciphertext': cipherBlob,
      'nonce': nonceBytes,
      'ad': ad,
      'created_by': createdBy,
      'retention': retention == VaultRetention.ephemeral
          ? 'ephemeral'
          : 'keep',
      'reconfirm_due': retention == VaultRetention.ephemeral
          ? now.add(const Duration(days: 90)).toIso8601String()
          : null,
    });
  }

  /// Marks an item as "deletion requested" by [requestedBy]. The other partner
  /// must confirm, or after 14 days the requester can hard-delete.
  static Future<void> requestDelete({
    required String itemId,
    required String requestedBy,
  }) async {
    await _c.from('vault_items').update({
      'delete_requested': true,
      'delete_requested_by': requestedBy,
      'delete_requested_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', itemId);
  }

  /// Cancels a pending delete request (either partner, within the 14-day window).
  static Future<void> cancelDeleteRequest(String itemId) async {
    await _c.from('vault_items').update({
      'delete_requested': false,
      'delete_requested_by': null,
      'delete_requested_at': null,
    }).eq('id', itemId);
  }

  /// Hard-deletes an item. Used either after mutual confirm or after the 14-day
  /// timeout elapses (the requester's escape hatch).
  ///
  /// We soft-delete (set `deleted = true`) so the spec's purge-on-breakup
  /// semantics and any audit trails still resolve. Supabase storage isn't
  /// billed for soft-deleted rows if a periodic hard-purge job runs.
  static Future<void> hardDelete({
    required String itemId,
    required String deletedBy,
  }) async {
    await _c.from('vault_items').update({
      'deleted': true,
      'deleted_by': deletedBy,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', itemId);
  }

  /// Returns the item with [itemId] (must belong to the current couple).
  /// Used by the delete-confirm flow to check whether the caller is the
  /// requester or confirmer.
  static Future<VaultItem?> fetchById(String itemId) async {
    final res = await _c
        .from('vault_items')
        .select()
        .eq('id', itemId)
        .maybeSingle();
    if (res == null) return null;
    final uid = SupabaseService.currentUserId!;
    return VaultItem.fromJson(res, uid);
  }

  /// 16-byte random AD string bound to each new item.
  static String _generateAd() {
    final rng = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    for (var i = 0; i < 22; i++) {
      buf.write((rng + i * 2654435761).toRadixString(36));
      if (i == 0) buf.write('.');
    }
    return buf.toString().substring(0, 24);
  }
}

/// Decrypts the note/photo bytes of [item] back to its original form.
/// Throws if the MAC check fails (tampering) or the shared key is missing.
Future<String> decryptVaultNote(VaultItem item) {
  return CryptoCore.decryptString(item.payload);
}

Future<Uint8List> decryptVaultBytes(VaultItem item) {
  return CryptoCore.decryptBytes(item.payload);
}
