import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/thumbnails.dart';
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
    // Thrown, not returned: a bare return completes normally, and the screen
    // reads a normal completion as "saved" — the note then simply never
    // appears, with nothing said. Same law as every ChatRepository send.
    if (uid == null) throw StateError('not signed in');
    await _c.from('personal_vault_items').insert({
      'owner_id': uid,
      'type': 'note',
      'content': content,
    });
  }

  // ─── Media the vault actually owns ───────────────────────────────────────

  static const bucket = 'personal_vault';

  /// Bound to the row, so a blob cannot be replayed into a different item.
  static String fullAdFor(String itemId) => '${itemId}_vault_full';
  static String thumbAdFor(String itemId) => '${itemId}_vault_thumb';


  /// Copies [bytes] INTO the vault, under the owner's own folder, with a
  /// thumbnail so a grid never decodes an original.
  ///
  /// The bytes are stored PLAINTEXT in a private bucket — see the decision
  /// recorded at the upload below. This doc said "encrypted" for two builds
  /// after that stopped being true, directly above the line that writes it in
  /// the clear.
  ///
  /// The previous design stored a string — a public URL, or
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
    // Thrown for the same reason as addNote: null reads as success upstream.
    if (uid == null) throw StateError('not signed in');

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

    // Derived once for the whole save. This is the fix: the vault used to
    // encrypt with the COUPLE key, which nothing on this path ever derived, so
    // every save after a cold start threw 'no shared key' before reaching the
    // first upload. See CryptoCore._vaultKey.
    // PLAINTEXT in the PRIVATE bucket, read back by signed URL — the exact
    // mechanism the gallery proved on this fleet all day. Owner's decision
    // (2026-08-28): the E2EE tile pipeline produced three builds of black
    // tiles; what the vault keeps is what actually guards it — the PIN gate,
    // FLAG_SECURE, and owner-only RLS — the same protection level every
    // couple_intimate photo already lives at. Legacy `.enc` objects keep
    // their decrypt read-path; nothing old breaks harder.
    final ext = _plainExt(mimeType);
    final fullPath = '$uid/vault/$id$ext';
    final thumbPath = tile == null ? null : '$uid/vault/thumb/$id.jpg';
    await Future.wait([
      _uploadPlain(fullPath, bytes, mimeType),
      if (tile != null && thumbPath != null)
        _uploadPlain(thumbPath, tile, 'image/jpeg'),
    ]);

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

  /// The bucket's allow-list already carries these (verified live:
  /// image/jpeg|png|webp, video/mp4|quicktime, audio/mp4|aac|mpeg).
  static String _plainExt(String mime) => switch (mime) {
        'image/jpeg' => '.jpg',
        'image/png' => '.png',
        'image/webp' => '.webp',
        'video/mp4' => '.mp4',
        'video/quicktime' => '.mov',
        'audio/mp4' || 'audio/aac' => '.m4a',
        'audio/mpeg' => '.mp3',
        _ => '.bin',
      };

  static Future<void> _uploadPlain(
      String path, Uint8List bytes, String mime,) async {
    await _c.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
  }

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
