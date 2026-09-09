import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/media/plain_media_cache.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/vault/vault_repository.dart';

/// Copies received/sent chat + touch media into the Private Vault — and ONLY
/// the vault. The bytes are downloaded once and re-uploaded, in the clear,
/// under the owner's own folder of the personal_vault bucket (owner-only RLS,
/// behind the vault PIN and FLAG_SECURE — THREAT-MODEL §1). Zero bytes touch
/// device storage: no gallery entry, no Downloads file, no temp file.
class SaveMediaService {
  SaveMediaService._();

  /// couple_media (public) photo — e.g. a chat image. URL never expires.
  static Future<bool> savePhotoToVault({
    required String url,
    required String senderName,
    String? cacheBucket,
    String? cachePath,
  }) =>
      _save(
        type: 'saved_photo',
        noun: 'Photo',
        senderName: senderName,
        publicUrl: url,
        cacheBucket: cacheBucket,
        cachePath: cachePath,
      );

  /// couple_media (public) voice note.
  static Future<bool> saveVoiceToVault({
    required String url,
    required String senderName,
  }) =>
      _save(type: 'saved_voice', noun: 'Voice note', senderName: senderName, publicUrl: url);

  /// couple_intimate (private) video — store the path, re-sign on open.
  static Future<bool> saveVideoToVault({
    required String path,
    required String senderName,
    String? thumbPath,
  }) =>
      _save(
        type: 'saved_video',
        noun: 'Video',
        senderName: senderName,
        storagePath: path,
        // A video streams from its signed URL and never enters the image
        // store, so the disk-cache read misses. It does not matter any more:
        // the copy path below never reads the bytes at all.
        cacheBucket: privateBucket,
        cachePath: MediaUrls.toPath(privateBucket, path),
        // The poster the gallery already holds. Copied beside the video, and
        // it is the whole of why a saved video finally has a preview.
        sourceThumbPath: thumbPath,
      );

  /// couple_intimate (private) photo — e.g. a Touch body photo. Path stored.
  static Future<bool> saveIntimatePhotoToVault({
    required String path,
    required String senderName,
    String? thumbPath,
  }) =>
      _save(
        type: 'saved_photo',
        noun: 'Photo',
        senderName: senderName,
        storagePath: path,
        // The gallery grid and its pager both file this object under exactly
        // this key — PlainMediaCache.keyFor(privateBucket, storagePath) — so
        // saving a picture the user is looking at reads it off the disk the
        // viewer just wrote it to.
        cacheBucket: privateBucket,
        cachePath: MediaUrls.toPath(privateBucket, path),
        sourceThumbPath: thumbPath,
      );

  static Future<bool> _save({
    required String type,
    required String noun,
    required String senderName,
    String? publicUrl,
    String? storagePath,
    String? cacheBucket,
    String? cachePath,
    String? sourceThumbPath,
  }) async {
    final label = '$noun from $senderName · ${_formatDate(DateTime.now())}';
    try {
      // SERVER-SIDE COPY FIRST, and this is the one that makes a save feel
      // instant. Reading the bytes off the disk cache (below) removed the
      // download and left the UPLOAD, which for a video is tens of megabytes
      // over a phone uplink — the whole of what "saving takes a long time"
      // was. Storage duplicates the object itself; nothing crosses the wire
      // but two small POSTs and a row insert.
      //
      // It also carries the poster across, which is what gives a saved video
      // a preview in the vault grid for the first time.
      if (cacheBucket != null && cachePath != null && cachePath.isNotEmpty) {
        try {
          final item = await VaultRepository.saveMediaByCopy(
            sourceBucket: cacheBucket,
            sourcePath: cachePath,
            sourceThumbPath: sourceThumbPath,
            mimeType: _mimeForPath(cachePath) ?? _mimeForType(type),
            label: label,
            type: type,
          );
          if (item != null) return true;
        } on VaultCopyUnavailable {
          // Expected on any server that will not copy across buckets. The
          // byte path below is what every build before this did, so a save
          // still succeeds — it is only slow again.
        }
      }

      // The disk FIRST. This is the whole of "why does saving a picture I am
      // already looking at take so long": the object was downloaded to paint
      // the page, and the save then downloaded it again from Supabase over the
      // phone's uplink before uploading it back. The viewer and this method
      // agree on the key by construction — PlainMediaCache.keyFor is what the
      // pager passes as its cacheKey — so a hit is the same bytes, not a
      // guess. A miss is ordinary and silent; the network path below is still
      // the answer for anything never opened.
      final local = await _cachedBytes(cacheBucket, cachePath);
      if (local != null) {
        await VaultRepository.saveMedia(
          bytes: local.bytes,
          mimeType: local.mimeType ?? _mimeForType(type),
          label: label,
          type: type,
        );
        return true;
      }

      // Fetch the bytes and give the vault its OWN copy, in the owner's folder
      // of the personal bucket rather than the couple's shared one.
      //
      // Storing a pointer was the whole defect: a publicUrl is a signed link
      // that expires within a day, and a storagePath lives in the couple's
      // shared bucket where the partner can read it and delete it. Neither is
      // a private vault. Saving is worth one download.
      final url = publicUrl ??
          (storagePath == null
              ? null
              : await ChatRepository.signedVideoUrl(storagePath));
      if (url != null) {
        final res = await http.get(Uri.parse(url));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          await VaultRepository.saveMedia(
            bytes: res.bodyBytes,
            mimeType: res.headers['content-type']?.split(';').first ??
                _mimeForType(type),
            label: label,
            type: type,
          );
          return true;
        }
      }

      // The source is already gone. Recording a bookmark to it would create
      // exactly the dead row this change exists to stop making.
      ErrorReporter.report(
        StateError('vault save: source unreachable ($type)'),
        StackTrace.current,
        kind: 'vault',
      );
      return false;
    } catch (e, st) {
      ErrorReporter.report(e, st, kind: 'vault');
      return false;
    }
  }

  /// The object's bytes from the plaintext disk store, or null.
  ///
  /// Never throws and never reports: a miss is the normal case for anything
  /// the user has not opened, and turning it into an error would put a failure
  /// in front of a save that is about to succeed over the network.
  static Future<_LocalBytes?> _cachedBytes(String? bucket, String? path) async {
    if (bucket == null || path == null || path.isEmpty) return null;
    try {
      final hit = await PlainMediaCache.manager
          .getFileFromCache(PlainMediaCache.keyFor(bucket, path));
      if (hit == null) return null;
      final bytes = await hit.file.readAsBytes();
      if (bytes.isEmpty) return null;
      // The store names the file with the extension derived from the
      // content-type the server sent, so this is the real type rather than a
      // guess from the row's `type` column — which would file a PNG as JPEG.
      return _LocalBytes(bytes, _mimeForPath(hit.file.path));
    } catch (e) {
      debugPrint('[vault] disk copy unreadable: ${e.runtimeType}');
      return null;
    }
  }

  static String? _mimeForPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return null;
    return switch (path.substring(dot + 1).toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp4' => 'video/mp4',
      'm4a' || 'aac' => 'audio/mp4',
      _ => null,
    };
  }

  static String _mimeForType(String type) => switch (type) {
        'saved_video' => 'video/mp4',
        'saved_voice' => 'audio/mp4',
        _ => 'image/jpeg',
      };

  static String _formatDate(DateTime dt) =>
      '${dt.day} ${_month(dt.month)} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';

  static String _month(int m) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ][m - 1];
}

/// Bytes lifted from the disk cache, plus the type the store recorded for them.
class _LocalBytes {
  const _LocalBytes(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String? mimeType;
}
