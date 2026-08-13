import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/thumbnails.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Gives a thumbnail to media that was sent before there was a thumbnail
/// pipeline, using the copy the viewer has already downloaded.
///
/// Every row written before build 9 has `has_thumb = false`, so the grid tile,
/// the chat bubble and the viewer's underlay all fall back to the original —
/// which is the difference between a tile that paints instantly and one that
/// pulls several megabytes first. Production is only 8% legacy today, but the
/// population GROWS: this fleet is sideloaded with no update channel, so every
/// handset still on an older build keeps writing rows with no thumbnail.
///
/// A server-side job would be the obvious answer and is the wrong one here —
/// it needs a worker that can read a private bucket, decode arbitrary images
/// and write back, for a few dozen rows. This costs nothing instead: the
/// original is already on this device, already decoded, sitting on screen.
///
/// Ordering is UPLOAD, THEN CLAIM, and never the reverse. `has_thumb = true`
/// with no object behind it makes `imageThumbPath` non-null everywhere at once,
/// so the grid, the bubble, the album tile and the filmstrip all switch to a
/// path that 404s — black tiles for that message, permanently, with no way back
/// because the legacy branch is never entered again.
class ThumbBackfill {
  ThumbBackfill._();

  /// One at a time, whatever the user is doing.
  ///
  /// The work is a full-size decode plus a resize plus an upload. Firing one
  /// per page of a fast swipe would put four of those on the same phone that is
  /// trying to animate the swipe.
  static bool _busy = false;

  /// Ids already attempted this run, successfully or not.
  ///
  /// A failure is not retried in the same session on purpose: the two ways this
  /// fails are a decode the platform cannot do and an upload the network will
  /// not take, and neither improves by being attempted again forty milliseconds
  /// later on every swipe past the same photo.
  static final Set<String> _seen = <String>{};

  @visibleForTesting
  static void resetForTest() {
    _busy = false;
    _seen.clear();
  }

  /// Heal one message, if it needs it and the bytes are already local.
  ///
  /// [messageId] is the row to claim; [bucket]/[path] locate the original.
  /// Returns true only when a thumbnail was uploaded AND claimed.
  static Future<bool> heal({
    required String messageId,
    required String bucket,
    required String path,
  }) async {
    if (_busy || _seen.contains(messageId)) return false;
    _busy = true;
    _seen.add(messageId);
    try {
      final url = MediaUrls.cached(bucket, path);
      // Not signed yet means this page has not even loaded its original, so
      // there is nothing local to work from and fetching one would turn a
      // read-time optimisation into a download.
      if (url == null) return false;

      // getFileFromCache, never getSingleFile: this must use bytes that are
      // already here. The whole justification is that healing is free.
      final cached = await DefaultCacheManager()
          .getFileFromCache('$bucket/$path');
      if (cached == null) return false;

      final bytes = await Thumbnails.forImage(cached.file);
      if (bytes == null) return false;

      await SupabaseService.client.storage.from(bucket).uploadBinary(
            Thumbnails.pathFor(path),
            bytes,
            // upsert, so a heal that uploaded and then failed to claim — lost
            // network, app backgrounded — is not wedged on a 409 forever.
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );

      await SupabaseService.client
          .rpc<void>('claim_thumb', params: {'p_message_id': messageId});
      return true;
    } catch (e) {
      debugPrint('[thumb-backfill] ${e.runtimeType}');
      return false;
    } finally {
      _busy = false;
    }
  }
}
