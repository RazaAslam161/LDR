import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Chat photos, voice notes, GIFs, avatars and check-in snaps. Private
/// since the audit found 255 of them served without authentication.
const chatBucket = 'couple_media';

/// The per-user custom chat background. Private for the same reason.
const chatBgBucket = 'chat-bg';

/// Chat video and Touch body photos. Private since it was written.
const privateBucket = 'couple_intimate';

/// Documents sent in chat. Separate from [chatBucket] because that bucket's
/// allowed_mime_types is a whitelist of images and audio, and a PDF has no
/// business forcing it open for the photographs.
const filesBucket = 'couple_files';

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
          .createSignedUrlsResult(need, _ttl.inSeconds);
      final expires = DateTime.now().add(_ttl);
      for (final s in signed.whereType<SignedUrlSuccess>()) {
        _cache[_key(bucket, s.path)] = _Signed(s.signedUrl, expires);
      }
    } catch (e) {
      // Best-effort. A failure here costs a placeholder, never a frame and
      // never a send.
      debugPrint('[media] warm failed for $bucket: ${e.runtimeType}');
    }
  }

  /// Stands in for the signing call under test. A widget test has no
  /// Supabase behind it, and without this every page a pager warms threw a
  /// LateInitializationError into ErrorReporter — 153 lines per run, none of
  /// them about the pager. Returning null here is the exact failed state
  /// those tests are built on.
  @visibleForTesting
  static Future<String?> Function(String bucket, String path)? signForTest;

  /// Sign one object, for the paths that arrive outside a page load.
  static Future<String?> sign(String bucket, String path) async {
    final hit = cached(bucket, path);
    if (hit != null) return hit;
    final seam = signForTest;
    if (seam != null) return seam(bucket, path);
    try {
      final url = await SupabaseService.client.storage
          .from(bucket)
          .createSignedUrl(path, _ttl.inSeconds);
      _cache[_key(bucket, path)] = _Signed(url, DateTime.now().add(_ttl));
      return url;
    } catch (e, st) {
      // Null stays the contract (callers render an absence), but the failure
      // now reaches client_errors instead of one handset's logcat: a signing
      // outage used to look like users spontaneously sending less media.
      // ErrorReporter dedups and never records the path.
      ErrorReporter.report(e, st, kind: 'media-sign');
      return null;
    }
  }

  /// Sign again from scratch, discarding whatever is cached.
  ///
  /// [cached] only declines a URL it can see is nearly expired. A token can
  /// stop working before that: the object was re-uploaded, the project's JWT
  /// secret was rotated, or this handset's clock is simply wrong, and a phone
  /// that is an hour fast hands out URLs it believes are fresh and the server
  /// believes are dead. That is a 403 the viewer has to be able to recover
  /// from, and it cannot while the dead URL stays in the map.
  static Future<String?> refresh(String bucket, String path) {
    _cache.remove(_key(bucket, path));
    return sign(bucket, path);
  }

  /// The storage path inside [bucket] for a value that may be a path or a
  /// legacy URL of either shape.
  ///
  /// Rows written before the bucket was closed hold a full
  /// `.../object/public/<bucket>/<path>` URL. Those stop resolving the moment
  /// the bucket goes private, so every read goes through here.
  ///
  /// `/object/sign/` is the other half of that, and it is not hypothetical:
  /// the custom chat background persisted the SIGNED url, so every couple who
  /// ever picked one has a token in their profile row rather than a path. The
  /// token has long since expired, and there is no update channel to migrate
  /// them off it — miss this shape and the only way back to a background is to
  /// pick it again. The query string carries that dead token, so it is dropped
  /// rather than pasted onto the object name.
  static String toPath(String bucket, String value) {
    for (final kind in const ['public', 'sign']) {
      final marker = '/object/$kind/$bucket/';
      final i = value.indexOf(marker);
      if (i < 0) continue;
      final rest = value.substring(i + marker.length);
      final q = rest.indexOf('?');
      return Uri.decodeComponent(q < 0 ? rest : rest.substring(0, q));
    }
    return value;
  }

  /// Forget every signed URL. Called on sign-out.
  ///
  /// This cache is device-scoped and lives as long as the process, so without
  /// this the next account on the handset inherits a map of live 24-hour URLs
  /// to the previous couple's objects. Nothing in the app looks a path up
  /// without a row that names it, so it is not reachable today — but "not
  /// reachable today" is what the FCM token was, and the account after it got
  /// that couple's Reaches.
  static void clear() => _cache.clear();

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
