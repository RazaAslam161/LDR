import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/thumbnails.dart';
import 'package:miles/features/vault/vault_repository.dart';

/// Gives a saved VIDEO the poster it was never given.
///
/// `VaultRepository.saveMedia` derives a tile only for images — there is no
/// image inside an mp4 to decode — so every video ever saved to this vault has
/// `thumb_path` null, `VaultItem.gridPath` therefore null, and the grid paints
/// a play glyph where a poster belongs. Production says this is not an edge
/// case: **8 of 8** vault videos carry no thumbnail, against 32 of 32 photos
/// that do.
///
/// The save path now COPIES the source's existing poster across, which fixes
/// every future save at zero cost. It cannot fix a row that already exists —
/// the vault row does not record where its bytes came from — so those are
/// healed here, from the video the vault already owns.
///
/// Deliberately modelled on `ThumbBackfill` rather than invented beside it, and
/// the two rules that matter are its rules:
///
///   * ONE at a time, whatever the grid is doing. A vault of forty videos
///     scrolled quickly would otherwise start forty frame extractions on a
///     phone that is trying to animate the scroll.
///   * UPLOAD, then CLAIM, never the reverse. A `thumb_path` with no object
///     behind it makes `gridPath` non-null and the tile 404s permanently, with
///     no way back — the null branch that would have healed it is never
///     entered again.
class VaultThumbBackfill {
  VaultThumbBackfill._();

  static bool _busy = false;

  /// Item ids already attempted this run, successfully or not.
  ///
  /// A failure is not retried in the same session: the ways this fails are a
  /// codec that cannot open the file and a network that will not take the
  /// upload, and neither improves by being tried again on the next scroll past
  /// the same tile.
  static final Set<String> _seen = <String>{};

  @visibleForTesting
  static void resetForTest() {
    _busy = false;
    _seen.clear();
  }

  /// Whether [item] is a row this can do anything about.
  ///
  /// Public because the tile asks before it schedules, and a predicate that
  /// lives in two places drifts.
  static bool wants(VaultItem item) =>
      item.isVideo && item.thumbPath == null && item.storagePath != null;

  /// Extracts a first frame for [item], stores it, and points the row at it.
  ///
  /// Returns the new thumb path on success so the caller can repaint without
  /// re-reading the row, or null when nothing was done.
  static Future<String?> heal(VaultItem item) async {
    if (_busy || !wants(item) || _seen.contains(item.id)) return null;
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    _busy = true;
    _seen.add(item.id);
    try {
      final path = item.storagePath!;
      final url = MediaUrls.cached(VaultRepository.bucket, path) ??
          await MediaUrls.sign(VaultRepository.bucket, path);
      if (url == null) return null;

      // From the URL, not from a downloaded file. The platform extractor
      // range-reads the header and the first frame rather than pulling the
      // whole video, which is the difference between a poster and a 30MB
      // download for a tile.
      final bytes = await Thumbnails.forVideoUrl(url);
      if (bytes == null || bytes.isEmpty) return null;

      final thumbPath = '$uid/vault/thumb/${item.id}.jpg';
      await VaultRepository.uploadThumb(thumbPath, bytes);
      await VaultRepository.attachThumb(item.id, thumbPath);
      return thumbPath;
    } catch (e) {
      debugPrint('[vault-thumb] ${e.runtimeType}');
      return null;
    } finally {
      _busy = false;
    }
  }
}
