import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/closer_load_result.dart';

/// What kind of thing a vault row holds. Maps to the `kind` text column.
enum VaultKind { note, photo, video, voice, trace }

VaultKind _parseKind(String s) {
  switch (s) {
    case 'photo':
      return VaultKind.photo;
    case 'video':
      return VaultKind.video;
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
    case VaultKind.video:
      return 'video';
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
    required this.coupleId,
    required this.kind,
    required this.ad,
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
    this.storagePath,
    this.mediaMimeType,
  });

  final String id;
  final String coupleId;
  final VaultKind kind;

  /// The per-item associated-data bound at encrypt time — required to decrypt.
  final String ad;

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
  final String? storagePath;
  final String? mediaMimeType;

  bool get hasOriginalMedia =>
      kind == VaultKind.photo ||
      kind == VaultKind.video ||
      kind == VaultKind.voice;

  String get resolvedStoragePath => storagePath ?? '$coupleId/vault/$ad.enc';

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
      deleteState == VaultDeleteState.expired && deleteRequestedBy != null;

  static VaultItem fromJson(Map<String, dynamic> json) {
    final blob = byteaToBytes(json['ciphertext']);
    if (blob.length < 16) {
      throw const FormatException('Vault ciphertext is missing its MAC.');
    }
    final nonce = byteaToBytes(json['nonce']);
    final macBytes = blob.sublist(0, 16);
    final cipherBytes = blob.sublist(16);

    final requested = (json['delete_requested'] as bool?) ?? false;
    final requestedAt =
        JsonUtils.parseDateOrNull(json['delete_requested_at'])?.toUtc();
    var deleteState = VaultDeleteState.none;
    if (requested && requestedAt != null) {
      final age = DateTime.now().toUtc().difference(requestedAt);
      deleteState = age.inDays >= 14
          ? VaultDeleteState.expired
          : VaultDeleteState.requested;
    }

    return VaultItem(
      id: JsonUtils.parseString(json['id']),
      coupleId: JsonUtils.parseString(json['couple_id']),
      kind: _parseKind(JsonUtils.parseString(json['kind'])),
      ad: JsonUtils.parseString(json['ad']),
      ciphertext: cipherBytes,
      nonce: nonce,
      mac: macBytes,
      createdBy: JsonUtils.parseString(json['created_by']),
      createdAt: JsonUtils.parseDate(json['created_at']).toUtc(),
      retention: (json['retention'] as String?) == 'ephemeral'
          ? VaultRetention.ephemeral
          : VaultRetention.keep,
      reconfirmDue: JsonUtils.parseDateOrNull(json['reconfirm_due'])?.toUtc(),
      deleteState: deleteState,
      deleteRequestedBy:
          JsonUtils.parseStringOrNull(json['delete_requested_by']),
      deleteRequestedAt: requestedAt,
      storagePath: JsonUtils.parseStringOrNull(json['storage_path']),
      mediaMimeType: JsonUtils.parseStringOrNull(json['media_mime_type']),
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

  /// Streams all non-deleted vault items for the current couple, newest first,
  /// syncing in real-time.
  static Stream<CloserLoadResult<VaultItem>> streamItems(String coupleId) {
    return _c
        .from('vault_items')
        .stream(primaryKey: ['id'])
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false)
        .map((rows) {
          final items = <VaultItem>[];
          var unreadable = 0;
          for (final row in rows) {
            if (row['deleted'] == true) continue;
            try {
              items.add(VaultItem.fromJson(row));
            } catch (e) {
              unreadable++;
              debugPrint('vault: unreadable row: $e');
            }
          }
          return CloserLoadResult(
            List<VaultItem>.unmodifiable(items),
            unreadable: unreadable,
          );
        });
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
    String? mediaMimeType,
  }) async {
    final ad = _generateAd();
    final EncryptedPayload payload;
    String? storagePath;
    if (kind == VaultKind.note || kind == VaultKind.trace) {
      final plain = String.fromCharCodes(plaintextBytes);
      payload = await CryptoCore.encryptString(plain, associatedData: ad);
    } else {
      if (plaintextBytes.length > _maxOriginalMediaBytes) {
        throw ArgumentError.value(
          plaintextBytes.length,
          'plaintextBytes',
          'Media is larger than the 100 MB encrypted-vault limit.',
        );
      }
      final isVideo = kind == VaultKind.video;
      final isVoice = kind == VaultKind.voice;

      // A compact preview makes the grid fast; the original is encrypted and
      // uploaded without recompression so opening it never loses quality.
      Uint8List thumbBytes;
      if (isVideo || isVoice) {
        thumbBytes = Uint8List(0);
      } else {
        thumbBytes = await FlutterImageCompress.compressWithList(
          plaintextBytes,
          minWidth: 300,
          minHeight: 300,
          quality: 50,
        );
      }

      // The preview is tens of kilobytes and stays inline. The ORIGINAL is up
      // to 100MB, and encrypting it on the main isolate is why the upload
      // spinner did not merely take a long time — it stopped animating, because
      // the thread that animates it was doing AES over 100MB and then a base64
      // encode of the result. Off-thread now, mirroring the decrypt isolate the
      // vault cache already uses.
      payload = await CryptoCore.encryptBytes(thumbBytes, associatedData: ad);
      final fullPayload = await CryptoCore.encryptBytesOffThread(
        plaintextBytes,
        associatedData: ad,
      );
      final storageBlob = packFull(fullPayload);
      storagePath = '$coupleId/vault/$ad.enc';
      await _c.storage
          .from('couple_intimate')
          .uploadBinary(
            storagePath,
            storageBlob,
            fileOptions: const supabase.FileOptions(
              contentType: 'application/octet-stream',
              cacheControl: '31536000',
            ),
            retryAttempts: 2,
          )
          .timeout(const Duration(minutes: 2));
    }

    final cipherBlob = packMacAndCiphertext(payload);
    final nonceBytes = Uint8List.fromList(base64Decode(payload.nonceB64));

    final now = DateTime.now().toUtc();
    try {
      await _c.from('vault_items').insert({
        'couple_id': coupleId,
        'kind': _stringifyKind(kind),
        'ciphertext': bytesToBytea(cipherBlob),
        'nonce': bytesToBytea(nonceBytes),
        'ad': ad,
        'created_by': createdBy,
        'retention':
            retention == VaultRetention.ephemeral ? 'ephemeral' : 'keep',
        'reconfirm_due': retention == VaultRetention.ephemeral
            ? now.add(const Duration(days: 90)).toIso8601String()
            : null,
        if (storagePath != null) 'storage_path': storagePath,
        if (mediaMimeType != null) 'media_mime_type': mediaMimeType,
      });
    } catch (_) {
      if (storagePath != null) {
        try {
          await _c.storage.from('couple_intimate').remove([storagePath]);
        } catch (_) {
          // A retention job can remove an orphaned encrypted object later.
        }
      }
      rethrow;
    }
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
    final item = await fetchById(itemId);
    if (item == null) return;

    await _c.from('vault_items').update({
      'deleted': true,
      'deleted_by': deletedBy,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', itemId);

    if (item.hasOriginalMedia) {
      try {
        await _c.storage
            .from('couple_intimate')
            .remove([item.resolvedStoragePath]);
      } catch (_) {
        // The row is already hidden. A later retention cleanup can remove an
        // orphaned encrypted object without making deletion feel broken.
      }
    }
  }

  /// Returns the item with [itemId] (must belong to the current couple).
  /// Used by the delete-confirm flow to check whether the caller is the
  /// requester or confirmer.
  static Future<VaultItem?> fetchById(String itemId) async {
    final res =
        await _c.from('vault_items').select().eq('id', itemId).maybeSingle();
    if (res == null) return null;
    return VaultItem.fromJson(res);
  }

  static const _maxOriginalMediaBytes = 100 * 1024 * 1024 - 40;

  /// A random, non-guessable associated-data value bound to each new item.
  static String _generateAd() {
    final bytes = Uint8List(24);
    final random = Random.secure();
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = random.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

/// Decrypts the note/photo bytes of [item] back to its original form.
/// Throws if the MAC check fails (tampering) or the shared key is missing.
Future<String> decryptVaultNote(VaultItem item) {
  return CryptoCore.decryptString(item.payload, associatedData: item.ad);
}
