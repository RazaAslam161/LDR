import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:miles/core/data/media_urls.dart';

/// Voice notes, kept on disk after the first listen.
///
/// This is not a nicety, it is what makes the waveform a control rather than a
/// picture. Seeking a streamed m4a costs a range request per drag, so
/// "drag anywhere to hear that part again" stutters on mobile data and lands
/// somewhere other than where the finger let go. Downloaded once, every later
/// seek is instant and every re-listen is offline.
class VoiceNoteCache {
  VoiceNoteCache._();

  /// Its OWN store, never `DefaultCacheManager`. That singleton holds 200
  /// objects shared with every CachedNetworkImage in the app, so ten minutes of
  /// scrolling photos would evict the conversation's voice notes completely —
  /// the same reasoning already written over EncryptedMediaCache's L1.
  static final CacheManager _store = CacheManager(
    Config(
      'milesVoiceNotes',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 300,
    ),
  );

  /// The object name to file this note under.
  ///
  /// The storage PATH, never the signed URL. The URL carries a token that
  /// rotates daily, so keying on it would re-download the whole conversation
  /// every morning — the bug already documented on Message.tileCacheKey.
  static String keyFor(String url) => MediaUrls.toPath(chatBucket, url);

  /// A local file for [url], or null if it could not be fetched.
  ///
  /// Null is an ordinary answer, not a failure to report: the caller falls back
  /// to streaming from the URL, which is what every build before this one did.
  /// Refusing to play a note because a cache write failed would be a worse
  /// outcome than the one this is trying to improve on.
  static Future<String?> fileFor(String url) async {
    try {
      final file = await _store.getSingleFile(url, key: keyFor(url));
      return await file.exists() ? file.path : null;
    } on Exception {
      return null;
    }
  }

  /// Wiped on sign-out, beside the other two caches.
  ///
  /// The next account on this handset has no business inheriting the previous
  /// couple's voice notes, and unlike chat photos these are audio of the two of
  /// them talking. session_provider empties EncryptedMediaCache and the default
  /// image store for exactly this reason; a third store that skipped it would
  /// be the one that leaked.
  static Future<void> clearAll() => _store.emptyCache();
}
