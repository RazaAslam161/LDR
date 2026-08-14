import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/media/thumbnails.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One photograph inside a memory: three encrypted objects and a row.
class MemoryPhoto {
  const MemoryPhoto({
    required this.id,
    required this.memoryId,
    required this.position,
    required this.coverPath,
    required this.tilePath,
    required this.fullPath,
    required this.mimeType,
    this.addedBy,
    this.createdAt,
  });

  final String id;
  final String memoryId;
  final int position;
  final String coverPath;
  final String tilePath;
  final String fullPath;
  final String mimeType;
  final String? addedBy;
  final DateTime? createdAt;

  /// Associated data, FROZEN from the first write.
  ///
  /// These bind CONTAINMENT, not just identity, and that decision was now-or-
  /// never. `crypto_core.dart` derives ONE key for all of Closer, so the AD
  /// string is the only thing separating one feature's ciphertext from
  /// another's — and `memory_id`, `cover_photo_id` and `position` are all
  /// plaintext columns. With a per-photo AD, anyone with database write access
  /// could re-parent a photograph into a different memory and every device
  /// would accept it, because the Poly1305 tag still verifies.
  ///
  /// `position` is deliberately NOT in the AD: it changes on reorder, and
  /// folding it in would make every drag a re-encrypt and re-upload of three
  /// objects. The residual — an adversary with write access can reorder a
  /// gallery — is accepted explicitly.
  String get coverAd => '${memoryId}_${id}_cover';
  String get tileAd => '${memoryId}_${id}_tile';
  String get fullAd => '${memoryId}_${id}_full';

  static MemoryPhoto fromJson(Map<String, dynamic> json) => MemoryPhoto(
        id: JsonUtils.parseString(json['id']),
        memoryId: JsonUtils.parseString(json['memory_id']),
        position: (json['position'] as num?)?.toInt() ?? 0,
        coverPath: JsonUtils.parseString(json['cover_path']),
        tilePath: JsonUtils.parseString(json['tile_path']),
        fullPath: JsonUtils.parseString(json['full_path']),
        mimeType: JsonUtils.parseStringOrNull(json['mime_type']) ?? 'image/jpeg',
        addedBy: JsonUtils.parseStringOrNull(json['added_by']),
        createdAt: JsonUtils.parseDateOrNull(json['created_at'])?.toUtc(),
      );
}

/// The photographs inside a memory.
///
/// The couple id must be the FIRST path segment — every storage policy on this
/// bucket tests `(storage.foldername(name))[1] = current_user_couple_id()`.
class MemoryPhotoRepository {
  MemoryPhotoRepository._();

  static const _bucket = intimateBucket;

  /// 40 MB. The bucket's own limit is 104857600, verified; this leaves room for
  /// the nonce, the MAC and a base64-free margin rather than discovering the
  /// ceiling during an upload.
  static const int maxOriginalBytes = 40 * 1024 * 1024;

  /// The one place that knows the associated-data format, so the timeline —
  /// which has a `cover_path` and a `cover_photo_id` but no photo row — builds
  /// the same string the upload sealed with.
  static String coverAdFor(String memoryId, String photoId) =>
      '${memoryId}_${photoId}_cover';
  static String tileAdFor(String memoryId, String photoId) =>
      '${memoryId}_${photoId}_tile';
  static String fullAdFor(String memoryId, String photoId) =>
      '${memoryId}_${photoId}_full';

  static String coverPathFor(String coupleId, String photoId) =>
      '$coupleId/memory/$photoId/c.enc';
  static String tilePathFor(String coupleId, String photoId) =>
      '$coupleId/memory/$photoId/t.enc';
  static String fullPathFor(String coupleId, String photoId) =>
      '$coupleId/memory/$photoId/f.enc';

  static Future<List<MemoryPhoto>> listFor(String memoryId) async {
    final rows = await SupabaseService.client
        .from('memory_photos')
        .select('id,memory_id,position,cover_path,tile_path,full_path,'
            'mime_type,added_by,created_at')
        .eq('memory_id', memoryId)
        .order('position');
    return [
      for (final r in rows as List) MemoryPhoto.fromJson(JsonUtils.asMap(r)),
    ];
  }

  /// Derives, encrypts and uploads one photograph, then claims it with a row.
  ///
  /// Order is strictly **cover → tile → full → row**, so a `memory_photos` row
  /// is never visible without the media behind it. The reverse ordering is what
  /// makes a grid of permanently black tiles with no way back.
  ///
  /// Atomicity honestly degrades from one operation to four: a crash between
  /// them leaves orphaned objects that the reap table never learns about,
  /// because there is no row to trigger on. The vault already lives with
  /// exactly this shape, and the compensating delete below covers the common
  /// case (the insert being rejected) rather than pretending to cover all of it.
  static Future<MemoryPhoto> upload({
    required String coupleId,
    required String memoryId,
    required String addedBy,
    required int position,
    required Uint8List original,
    String mimeType = 'image/jpeg',
  }) async {
    if (original.lengthInBytes > maxOriginalBytes) {
      throw const PhotoTooBig();
    }

    // Refuse before doing any work. `encryptBytes` with no key and an agreed
    // plaintext partner emits 24 zero bytes, 16 zero bytes and the raw JPEG —
    // and packFull would then hand that to storage, so the object behind a
    // shareable signed URL would be the photograph itself. Today's blast radius
    // for that bug is one bytea column; letting it reach the bucket widens it
    // to a CDN.
    final key = await CryptoCore.exportSharedKeyBytes();
    if (key == null) {
      throw StateError('no couple key — refusing to upload');
    }

    final photoId = _uuid();
    final derived = await deriveImage(original);
    if (derived == null) throw const PhotoUndecodable();

    final coverPath = coverPathFor(coupleId, photoId);
    final tilePath = tilePathFor(coupleId, photoId);
    final fullPath = fullPathFor(coupleId, photoId);

    final packedCover = packFull(await CryptoCore.encryptBytesOffThread(
        derived.cover, associatedData: '${memoryId}_${photoId}_cover',),);
    final packedTile = packFull(await CryptoCore.encryptBytesOffThread(
        derived.tile, associatedData: '${memoryId}_${photoId}_tile',),);
    final packedFull = packFull(await CryptoCore.encryptBytesOffThread(
        original, associatedData: '${memoryId}_${photoId}_full',),);

    refuseCleartext(packedCover);
    refuseCleartext(packedTile);
    refuseCleartext(packedFull);

    await _put(coverPath, packedCover);
    await _put(tilePath, packedTile);
    await _put(fullPath, packedFull);

    try {
      // couple_id is omitted on purpose — a trigger derives it from the parent.
      // Nothing in the INSERT policy could constrain a supplied one against the
      // memory, and a mismatched pair produces objects under a prefix the
      // couple cannot read: an invisible, unrecoverable orphan.
      final row = await SupabaseService.client
          .from('memory_photos')
          .insert({
            'id': photoId,
            'memory_id': memoryId,
            'added_by': addedBy,
            'position': position,
            'cover_path': coverPath,
            'tile_path': tilePath,
            'full_path': fullPath,
            'mime_type': mimeType,
          })
          .select('id,memory_id,position,cover_path,tile_path,full_path,'
              'mime_type,added_by,created_at')
          .single();

      // The bytes were just in memory; without this, looking at the photo you
      // have this second uploaded downloads it back.
      await EncryptedMediaCache.seed(
          bucket: _bucket, path: coverPath, packed: packedCover,);
      await EncryptedMediaCache.seed(
          bucket: _bucket, path: tilePath, packed: packedTile,);

      return MemoryPhoto.fromJson(row);
    } catch (_) {
      await _remove([coverPath, tilePath, fullPath]);
      rethrow;
    }
  }

  /// Removes a photograph you added. The objects go through the Storage API on
  /// this path; the reap table is the backstop for crashes and cascades.
  static Future<void> remove(MemoryPhoto photo) async {
    await SupabaseService.client
        .from('memory_photos')
        .delete()
        .eq('id', photo.id);
    await _remove([photo.coverPath, photo.tilePath, photo.fullPath]);
  }

  /// Choose which photograph the timeline shows. A trigger re-denormalises
  /// `cover_path` onto the parent.
  static Future<void> setCover({
    required String memoryId,
    required String photoId,
  }) async {
    await SupabaseService.client
        .from('memory_threads')
        .update({'cover_photo_id': photoId}).eq('id', memoryId);
  }

  /// `upsert` is NEVER true.
  ///
  /// Verified against the live project: `couple_intimate` has
  /// intimate_select / intimate_insert / intimate_delete and **no UPDATE
  /// policy**, so an upsert over an existing path is a 403 rather than an
  /// overwrite. A retry removes first.
  static Future<void> _put(String path, Uint8List packed) async {
    try {
      await SupabaseService.client.storage.from(_bucket).uploadBinary(
            path,
            packed,
            // octet-stream is in this bucket's whitelist, verified. A JPEG mime
            // type here would also be a small lie about what the object is.
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              cacheControl: '31536000',
            ),
          );
    } catch (_) {
      await _remove([path]);
      await SupabaseService.client.storage.from(_bucket).uploadBinary(
            path,
            packed,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              cacheControl: '31536000',
            ),
          );
    }
  }

  static Future<void> _remove(List<String> paths) async {
    try {
      await SupabaseService.client.storage.from(_bucket).remove(paths);
    } catch (e) {
      debugPrint('[memory-photo] cleanup failed: ${e.runtimeType}');
    }
  }

  /// Belt and braces after packing: a blob whose first 40 bytes are all zero is
  /// a 24-zero nonce and a 16-zero MAC — the legacy signature — which means the
  /// remainder is the photograph in the clear.
  @visibleForTesting
  static void refuseCleartext(Uint8List packed) {
    if (packed.length >= 40 && packed.take(40).every((b) => b == 0)) {
      throw StateError('refusing to upload cleartext');
    }
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class PhotoTooBig implements Exception {
  const PhotoTooBig();
  @override
  String toString() => 'PhotoTooBig';
}

class PhotoUndecodable implements Exception {
  const PhotoUndecodable();
  @override
  String toString() => 'PhotoUndecodable';
}
