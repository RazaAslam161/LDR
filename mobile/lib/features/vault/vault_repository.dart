import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/media/thumbnails.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VaultItem {
  VaultItem({
    required this.id,
    required this.type,
    required this.createdAt,
    this.content,
    this.mediaUrl,
    this.storagePath,
    this.thumbPath,
    this.mimeType,
  });

  factory VaultItem.fromJson(Map<String, dynamic> j) => VaultItem(
        id: JsonUtils.parseString(j['id']),
        type: JsonUtils.parseString(j['type'], fallback: 'note'),
        content: JsonUtils.parseStringOrNull(j['content']),
        mediaUrl: JsonUtils.parseStringOrNull(j['media_url']),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
        storagePath: JsonUtils.parseStringOrNull(j['storage_path']),
        thumbPath: JsonUtils.parseStringOrNull(j['thumb_path']),
        mimeType: JsonUtils.parseStringOrNull(j['mime_type']),
      );

  final String id;
  final String type;
  final String? content;

  /// The display label. Deliberately not a URL despite the column name — the
  /// old shape repurposed it, and shipped clients still write it that way.
  final String? mediaUrl;
  final DateTime createdAt;

  /// Set only on rows written by a build that owns its bytes. Null means this
  /// is a legacy bookmark row: a bare URL, or `intimate:<path>` pointing into
  /// the couple's shared bucket.
  final String? storagePath;

  final String? thumbPath;
  final String? mimeType;

/// The shared-bucket path a legacy row points at, if it points at one.
  ///
  /// These are still readable — the bytes are in couple_intimate and can be
  /// re-signed on demand. Only the rows holding a bare signed URL are dead,
  /// because that signature expired within a day of being saved.
  String? get legacyIntimatePath {
    final c = content;
    if (c == null || !c.startsWith('intimate:')) return null;
    return c.substring(9);
  }

  /// True when there is genuinely nothing left to show.
  bool get isDeadBookmark => !isOwned && legacyIntimatePath == null;

  bool get isNote => type == 'note';

  /// True once the vault holds the bytes itself rather than a pointer.
  bool get isOwned => storagePath != null;

  bool get isVideo => (mimeType ?? '').startsWith('video/');
  bool get isAudio => (mimeType ?? '').startsWith('audio/');

  /// What a grid tile paints. Thumbnail first, so a cell never decodes a
  /// full-size original, and never a video path — there is no image in an mp4.
  String? get gridPath => thumbPath ?? (isVideo || isAudio ? null : storagePath);
}

/// Personal (owner-only) vault + 4-digit PIN. PIN hashing/verification + lockout
/// run server-side (bcrypt via pgcrypto) so the PIN is never compared on-device.
class VaultRepository {
  VaultRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static Future<bool> hasPin() async {
    final res = await _c.rpc<dynamic>('has_vault_pin');
    return res == true;
  }

  static Future<void> setPin(String pin) =>
      _c.rpc<dynamic>('set_vault_pin', params: {'p_pin': pin});

  /// Returns 'ok' | 'wrong' | 'locked' | 'no_pin'.
  static Future<String> verifyPin(String pin) async {
    final res = await _c.rpc<dynamic>('verify_vault_pin', params: {'p_pin': pin});
    return res?.toString() ?? 'wrong';
  }

  static const _pageSize = 200;

  /// Everything in the personal vault, newest first, read a page at a time.
  ///
  /// The cursor is `created_at` rather than an offset: OFFSET makes the server
  /// walk rows it then discards, and it shifts under anything saved while the
  /// list is open.
  static Future<List<VaultItem>> items() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return [];
    final out = <VaultItem>[];
    DateTime? cursor;
    while (true) {
      var q = _c.from('personal_vault_items').select().eq('owner_id', uid);
      if (cursor != null) {
        q = q.lt('created_at', cursor.toUtc().toIso8601String());
      }
      final res =
          await q.order('created_at', ascending: false).limit(_pageSize);
      out.addAll(res.map(VaultItem.fromJson));
      if (res.length < _pageSize) return out;
      cursor = out.last.createdAt;
    }
  }

  static Future<void> addNote(String content) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('personal_vault_items').insert({
      'owner_id': uid,
      'type': 'note',
      'content': content,
    });
  }

  /// Saves a reference to chat/touch media into the personal vault — ZERO bytes
  /// written to the device. The file stays in Supabase storage.
  ///
  /// [publicUrl] (couple_media, never expires) is stored as-is in `content`.
  /// [storagePath] (couple_intimate, private) is stored as `intimate:<path>`,
  /// and a fresh signed URL is generated on open. [label] is shown in the vault.
  static Future<void> saveMediaToVault({
    required String type, // 'saved_photo' | 'saved_video' | 'saved_voice'
    required String label,
    String? publicUrl,
    String? storagePath,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final content = storagePath != null ? 'intimate:$storagePath' : publicUrl;
    if (content == null) return;
    await _c.from('personal_vault_items').insert({
      'owner_id': uid,
      'type': type,
      'content': content,
      'media_url': label, // repurposed as the display label
    });
  }

  // ─── Media the vault actually owns ───────────────────────────────────────

  static const bucket = 'personal_vault';

  /// Bound to the row, so a blob cannot be replayed into a different item.
  static String fullAdFor(String itemId) => '${itemId}_vault_full';
  static String thumbAdFor(String itemId) => '${itemId}_vault_thumb';

  static String _fullPath(String ownerId, String id) =>
      '$ownerId/vault/$id.enc';
  static String _thumbPath(String ownerId, String id) =>
      '$ownerId/vault/thumb/$id.enc';

  /// Copies [bytes] INTO the vault: encrypted, under the owner's own folder,
  /// with a thumbnail so a grid never decodes an original.
  ///
  /// The old `saveMediaToVault` stored a string — a public URL, or
  /// `intimate:<path>` pointing at the couple's shared bucket. That gave the
  /// vault no privacy (the partner's SELECT policy matches the same couple
  /// folder), no durability (so does their DELETE), and no permanence (photos
  /// and voice notes were saved as an already-expiring 24h signed URL, which is
  /// what the "Link expired" toast was). A private vault has to hold its own
  /// bytes.
  ///
  /// Upload order is thumbnail, then original, then row — the same order the
  /// gallery uses, and for the same reason: a row visible before its objects is
  /// a tile that can never paint, because nothing re-derives it.
  static Future<VaultItem?> saveMedia({
    required Uint8List bytes,
    required String mimeType,
    required String label,
    String type = 'saved_photo',
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;

    final id = _uuid();
    final isVideo = mimeType.startsWith('video/');
    final isAudio = mimeType.startsWith('audio/');

    Uint8List? tile;
    int? width;
    int? height;
    if (!isVideo && !isAudio) {
      final derived = await deriveImage(bytes);
      if (derived == null) throw const VaultUndecodable();
      tile = derived.tile;
      width = derived.width;
      height = derived.height;
    }

    final fullPath = _fullPath(uid, id);
    final packedFull = packFull(
      await CryptoCore.encryptBytesOffThread(bytes,
          associatedData: fullAdFor(id),),
    );
    _refuseCleartext(packedFull);

    String? thumbPath;
    if (tile != null) {
      thumbPath = _thumbPath(uid, id);
      final packedTile = packFull(
        await CryptoCore.encryptBytesOffThread(tile,
            associatedData: thumbAdFor(id),),
      );
      _refuseCleartext(packedTile);
      await _upload(thumbPath, packedTile);
      await EncryptedMediaCache.seed(
        bucket: bucket, path: thumbPath, packed: packedTile,);
    }

    await _upload(fullPath, packedFull);

    try {
      final row = await _c
          .from('personal_vault_items')
          .insert({
            'id': id,
            'owner_id': uid,
            'type': type,
            'media_url': label,
            'storage_path': fullPath,
            'thumb_path': thumbPath,
            'mime_type': mimeType,
            'width': width,
            'height': height,
            'byte_size': bytes.length,
          })
          .select()
          .single();
      return VaultItem.fromJson(row);
    } catch (e) {
      // The row is what makes the objects reachable. Without it they are an
      // orphan nobody can see, list, or delete.
      await _removeObjects([fullPath, if (thumbPath != null) thumbPath]);
      rethrow;
    }
  }

  /// A packed blob whose first 40 bytes are all zero is the legacy plaintext
  /// shape — nonce and MAC both empty. Uploading one would put the vault's
  /// contents in storage in the clear.
  ///
  /// Deliberately local rather than reaching for the memory-threads copy, which
  /// is @visibleForTesting: the vault should not depend on another feature's
  /// internals to know it is encrypted.
  static void _refuseCleartext(Uint8List packed) {
    if (packed.length >= 40 && packed.take(40).every((b) => b == 0)) {
      throw StateError('refusing to upload vault media as cleartext');
    }
  }

  static Future<void> _upload(String path, Uint8List packed) =>
      _c.storage.from(bucket).uploadBinary(
            path,
            packed,
            // Ciphertext is opaque. Uploading it under the original mime is
            // rejected with 415 invalid_mime_type — the same omission that
            // broke the intimate bucket once already.
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: true,
            ),
          );

  static Future<void> _removeObjects(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await _c.storage.from(bucket).remove(paths);
    } catch (e) {
      debugPrint('[vault] orphan cleanup failed: ${e.runtimeType}');
    }
  }

  /// Deletes the row AND the bytes.
  ///
  /// Row-only was correct while the vault merely pointed at the couple's chat
  /// objects. Now that it owns them, dropping the row alone would bill for
  /// storage nobody can ever reach again.
  static Future<void> deleteItem(String id) async {
    final row = await _c
        .from('personal_vault_items')
        .select('storage_path, thumb_path')
        .eq('id', id)
        .maybeSingle();
    await _c.from('personal_vault_items').delete().eq('id', id);
    if (row == null) return;
    await _removeObjects([
      if (row['storage_path'] != null) row['storage_path'] as String,
      if (row['thumb_path'] != null) row['thumb_path'] as String,
    ]);
  }

  static String _uuid() {
    final r = Random.secure();
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = r.nextInt(256);
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// The picked file could not be decoded into a thumbnail.
class VaultUndecodable implements Exception {
  const VaultUndecodable();
  @override
  String toString() => 'That file could not be opened as an image.';
}
