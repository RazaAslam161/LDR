import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';

/// Chat photos, voice notes, GIFs, avatars and check-in snaps. Private
/// since the audit found 255 of them served without authentication.
const chatBucket = 'couple_media';

/// Signed URLs for private storage, cached so rendering stays synchronous.
///
/// `couple_media` held 255 of a couple's photos in a PUBLIC bucket. Its RLS was
/// correct and the bucket was not listable, but `public: true` means the
/// `/object/public/...` endpoint bypasses RLS entirely: any URL that ever
/// escaped — a forwarded link, a screenshot, a proxy log, browser history — was
/// unauthenticated, permanent and unrevocable. For an app whose whole premise
/// is privacy, and which already signed `couple_intimate` correctly, that was
/// the wrong half of the codebase to copy from.
///
/// Signing is asynchronous and rendering is not, so the URL is resolved BEFORE
/// the widget needs it: the repository warms a whole page of messages in one
/// round trip via createSignedUrls, and the Message getters then read the cache
/// synchronously. A miss renders the existing "unavailable" placeholder rather
/// than blocking a frame.
class MediaUrls {
  MediaUrls._();

  /// 24h. Long enough that a conversation scrolled all day never re-signs,
  /// short enough that a leaked URL stops working within a day rather than
  /// never.
  static const _ttl = Duration(hours: 24);

  /// Re-sign once inside this window rather than handing out a URL that expires
  /// while the image is still on screen.
  static const _renewWithin = Duration(hours: 1);

  static final Map<String, _Signed> _cache = {};

  static String _key(String bucket, String path) => '$bucket/$path';

  /// The signed URL if one is cached and still good, else null.
  ///
  /// Synchronous on purpose — this is called from build().
  static String? cached(String bucket, String path) {
    final hit = _cache[_key(bucket, path)];
    if (hit == null) return null;
    if (hit.expires.difference(DateTime.now()) < _renewWithin) return null;
    return hit.url;
  }

  /// Sign a page of objects in ONE request.
  ///
  /// Called by the repository as messages load, so the cache is warm before the
  /// list paints. Signing per bubble instead would put a network round trip
  /// behind every image in the conversation.
  static Future<void> warm(String bucket, Iterable<String> paths) async {
    final need = paths.toSet().where((p) => cached(bucket, p) == null).toList();
    if (need.isEmpty) return;
    try {
      final signed = await SupabaseService.client.storage
          .from(bucket)
          .createSignedUrls(need, _ttl.inSeconds);
      final expires = DateTime.now().add(_ttl);
      for (final s in signed) {
        _cache[_key(bucket, s.path)] = _Signed(s.signedUrl, expires);
      }
    } catch (e) {
      // Best-effort. A failure here costs a placeholder, never a frame and
      // never a send.
      debugPrint('[media] warm failed for $bucket: ${e.runtimeType}');
    }
  }

  /// Sign one object, for the paths that arrive outside a page load.
  static Future<String?> sign(String bucket, String path) async {
    final hit = cached(bucket, path);
    if (hit != null) return hit;
    try {
      final url = await SupabaseService.client.storage
          .from(bucket)
          .createSignedUrl(path, _ttl.inSeconds);
      _cache[_key(bucket, path)] = _Signed(url, DateTime.now().add(_ttl));
      return url;
    } catch (e) {
      debugPrint('[media] sign failed for $bucket/$path: ${e.runtimeType}');
      return null;
    }
  }

  /// The storage path inside [bucket] for a value that may be either a path or
  /// a legacy public URL.
  ///
  /// Rows written before the bucket was closed hold a full
  /// `.../object/public/<bucket>/<path>` URL. Those stop resolving the moment
  /// the bucket goes private, so every read goes through here.
  static String toPath(String bucket, String value) {
    final marker = '/object/public/$bucket/';
    final i = value.indexOf(marker);
    if (i < 0) return value;
    return Uri.decodeComponent(value.substring(i + marker.length));
  }

  @visibleForTesting
  static void clearForTest() => _cache.clear();

  @visibleForTesting
  static void seedForTest(String bucket, String path, String url) =>
      _cache[_key(bucket, path)] = _Signed(url, DateTime.now().add(_ttl));
}

@immutable
class _Signed {
  const _Signed(this.url, this.expires);
  final String url;
  final DateTime expires;
}
