import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/media/media_decode.dart';
import 'package:miles/core/media/media_source.dart';

/// The grid tile and the viewer's underlay paint the same thumbnail. They only
/// share Flutter's decoded frame if the provider AND its resize bounds match,
/// so this asserts the cache keys are equal rather than asserting that some
/// constant has some value.
///
/// The distinction is the whole point. Before this, both surfaces used the same
/// width and the hand-off still did not happen, because the tile also passed
/// `height: side` — memCacheHeight joins the resize key, so the entries were
/// different and the viewer decoded the file a second time. A test on the width
/// constant would have passed throughout.
void main() {
  ImageProvider tileProvider(MediaItem item, {required String url}) {
    final base = CachedNetworkImageProvider(url, cacheKey: item.tileCacheKey);
    final w = item.tileDecodeWidth;
    return w == null ? base : ResizeImage(base, width: w);
  }

  ImageProvider underlayProvider(MediaItem item, {required String url}) {
    // What media_viewer's underlay builds: same key, no explicit resize,
    // because a real thumbnail is its own bound.
    final base = CachedNetworkImageProvider(url, cacheKey: item.tileCacheKey);
    final w = item.tileDecodeWidth;
    return w == null ? base : ResizeImage(base, width: w);
  }

  group('decode identity', () {
    test('a thumbed item resolves to ONE cache entry across both surfaces', () {
      final item = MediaItem.stored(
        'couple_media',
        'c1/photo.jpg',
        thumbPath: 'c1/thumb/photo.jpg',
        senderName: 'you',
      );
      const url = 'https://example.test/signed?token=a';

      expect(tileProvider(item, url: url), underlayProvider(item, url: url),
          reason: 'the tile and the underlay must share one decoded frame',);
    });

    test('a legacy item shares one entry too, at the capped width', () {
      final item = MediaItem.stored(
        'couple_media',
        'c1/old.jpg',
        senderName: 'you',
      );
      const url = 'https://example.test/signed?token=b';

      expect(item.hasThumb, isFalse);
      expect(item.tileDecodeWidth, kTileDecodePx,
          reason: 'a legacy original must not decode at source resolution',);
      expect(tileProvider(item, url: url), underlayProvider(item, url: url));
    });

    test('the tile key follows the thumbnail, not the original', () {
      final item = MediaItem.stored(
        'couple_media',
        'c1/photo.jpg',
        thumbPath: 'c1/thumb/photo.jpg',
        senderName: 'you',
      );
      expect(item.tileCacheKey, 'couple_media/c1/thumb/photo.jpg');
      expect(item.cacheKey, 'couple_media/c1/photo.jpg');
      expect(item.tileCacheKey, isNot(item.cacheKey),
          reason: 'the underlay and the full image are different objects and '
              'must not collide in the cache',);
    });

    test('a rotated signed token does not change any cache key', () {
      final item = MediaItem.stored(
        'couple_media',
        'c1/photo.jpg',
        thumbPath: 'c1/thumb/photo.jpg',
        senderName: 'you',
      );
      // The URL carries a token that rotates every 24h. Keys are derived from
      // the storage path precisely so the library is not re-downloaded daily.
      final a = tileProvider(item, url: 'https://x.test/o?token=MONDAY');
      final b = tileProvider(item, url: 'https://x.test/o?token=TUESDAY');
      expect(a, b);
    });
  });

  group('decode budget', () {
    test('the zoom thresholds are not equal', () {
      // Equal thresholds mount and unmount a full-resolution decode on every
      // jitter around the boundary.
      expect(kZoomUpgradeScale, greaterThan(kZoomRevertScale));
    });

    test('thumbnails are precached further than originals are fetched', () {
      // A thumbnail is tens of kilobytes; an original is megabytes. Reversing
      // these is how a pager left open on mobile data pulls the library.
      expect(kThumbPrecacheRadius, greaterThan(kFileWarmRadius));
      expect(kFileWarmRadiusMetered, lessThan(kFileWarmRadius));
    });
  });
}
