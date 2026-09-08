import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:miles/core/data/media_urls.dart';

/// Plaintext media on disk — chat photos, gallery pictures, vault objects.
///
/// **Its OWN store, never `DefaultCacheManager`.** That singleton is
/// `Config('libCachedImageData')`, whose defaults are 200 objects and 30 days,
/// and until this existed every photograph in the app shared those 200 slots
/// with the avatars, the cover art and the thumbnail backfill. A couple with
/// two hundred pictures evicted their own gallery by scrolling it, so going
/// back in re-downloaded what the phone had held minutes earlier — which is
/// the loading wheel on media that has already been seen. The same reasoning
/// is already written over `EncryptedMediaCache`'s L1 and `VoiceNoteCache`;
/// this is the layer both of those documents and neither of them covered.
///
/// 1500 objects at 90 days, matching L1: a couple's whole gallery, their chat
/// photographs and their vault, which is the point — this is what makes the
/// second look instant.
class PlainMediaCache {
  PlainMediaCache._();

  /// Typed as the interface every consumer takes — `CachedNetworkImage`,
  /// `CachedNetworkImageProvider` and the thumbnail backfill all want a
  /// `BaseCacheManager`, and naming the private class here would be a private
  /// type in a public API.
  static final BaseCacheManager manager = _PlainStore();

  /// What the disk cache files an object under.
  ///
  /// The storage PATH, never the signed URL. Every one of these buckets is
  /// private and its token rotates within the day, so a URL key re-downloads
  /// the whole library every morning into a cache already holding it.
  static String keyFor(String bucket, String path) => '$bucket/$path';

  /// A provider over an object whose signed URL is already in hand.
  static ImageProvider provider(String bucket, String path, String url) =>
      CachedNetworkImageProvider(
        url,
        cacheKey: keyFor(bucket, path),
        cacheManager: manager,
      );

  /// The provider for an object already signed, or null — SYNCHRONOUSLY.
  ///
  /// The point is the absence of an await. Resolving a URL and building a
  /// provider are a map lookup and a constructor, but reaching them through a
  /// `Future` costs a frame with nothing painted, and that frame is the
  /// placeholder that flashes over a picture the phone is already holding.
  /// `CachedNetworkImageProvider` equality is `cacheKey ?? url`, so the
  /// provider this returns is the same ImageCache entry a re-signed URL would
  /// build — the re-sign costs nothing and the decode is not repeated.
  static ImageProvider? warm(String bucket, String path) {
    final url = MediaUrls.cached(bucket, path);
    return url == null ? null : provider(bucket, path, url);
  }

  /// Sign-out and unpair. These are a couple's photographs, decrypted, under
  /// stable keys — readable at the filesystem level long after they are gone.
  static Future<void> clearAll() async {
    try {
      await manager.emptyCache();
    } catch (e) {
      debugPrint('[media] plain empty failed: ${e.runtimeType}');
    }
  }
}

/// `ImageCacheManager` for the same reason `DefaultCacheManager` mixes it in:
/// `cached_network_image` THROWS rather than degrades if a caller ever passes
/// maxWidthDiskCache to a manager without it.
class _PlainStore extends CacheManager with ImageCacheManager {
  _PlainStore()
      : super(
          Config(
            'milesPlainMedia',
            stalePeriod: const Duration(days: 90),
            maxNrOfCacheObjects: 1500,
          ),
        );
}
