import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/plain_media_cache.dart';
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

  /// Re-derives a thumbnail that already exists but was made too small.
  ///
  /// [Thumbnails.maxEdge] was 400 for the life of the pipeline, chosen for a
  /// 150dp album tile; the 220dp chat bubble it missed is ~605px, so every
  /// thumbnail written before the raise is UPSCALED in the surface a couple
  /// looks at most. Raising the constant only helps pictures sent after it,
  /// and nothing else re-derives: [heal] fires on rows with no thumbnail at
  /// all and would skip these forever.
  ///
  /// Recognised without a schema column: the object is on disk, and its header
  /// says how big it is. Free in the same sense the rest of this class is —
  /// both the thumbnail and the original are already local, or it declines.
  static Future<bool> resize({
    required String messageId,
    required String bucket,
    required String path,
    required String thumbPath,
  }) async {
    final mark = '$messageId:resize';
    if (_busy || _seen.contains(mark)) return false;
    _busy = true;
    _seen.add(mark);
    try {
      final small = await PlainMediaCache.manager
          .getFileFromCache(PlainMediaCache.keyFor(bucket, thumbPath));
      // Not downloaded means this surface has not painted it, so there is
      // nothing to be too small on screen yet.
      if (small == null) return false;
      final edge = Thumbnails.longestEdge(await small.file.readAsBytes());
      // Null is "not a picture I can read the header of" — never a reason to
      // re-derive, which would upload over a perfectly good object.
      if (edge == null || edge >= Thumbnails.maxEdge) return false;

      final original = await PlainMediaCache.manager
          .getFileFromCache(PlainMediaCache.keyFor(bucket, path));
      // The original is what a re-derive needs and fetching one would turn a
      // read-time optimisation into a download, which is the rule this whole
      // class is built on.
      if (original == null) return false;

      final bytes = await Thumbnails.forImage(original.file);
      if (bytes == null) return false;

      await SupabaseService.client.storage.from(bucket).uploadBinary(
            thumbPath,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );

      // The row already claims a thumbnail and the path has not changed, so
      // there is nothing to claim — but the DEVICE still holds the old small
      // object under a key that never expires from its own point of view.
      // Without this the app keeps painting the 400px copy it just replaced.
      await PlainMediaCache.manager
          .removeFile(PlainMediaCache.keyFor(bucket, thumbPath));
      final url = MediaUrls.cached(bucket, thumbPath);
      if (url != null) {
        await PlainMediaCache.provider(bucket, thumbPath, url).evict();
      }
      return true;
    } catch (e) {
      debugPrint('[thumb-resize] ${e.runtimeType}');
      return false;
    } finally {
      _busy = false;
    }
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
      final cached = await PlainMediaCache.manager
          .getFileFromCache(PlainMediaCache.keyFor(bucket, path));
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
