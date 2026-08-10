import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/media_urls.dart';

/// couple_media held 255 of a couple's photos in a public bucket. The bucket
/// was not listable, so the exposure was never enumeration — it was that a
/// `/object/public/...` URL needs no authentication at all, forever, with no
/// way to revoke it. These pin the two things that have to be right for the
/// bucket to close without breaking what is already stored.
void main() {
  setUp(MediaUrls.clearForTest);

  group('toPath', () {
    test('leaves a plain storage path alone', () {
      const path = 'fc1c8a3a-baae-4e02-aecb-b3fc670b18c4/img_178638.jpg';
      expect(MediaUrls.toPath('couple_media', path), path);
    });

    test('recovers the path from a legacy public URL', () {
      // Rows written while the bucket was public hold the whole URL. They stop
      // resolving the instant it closes unless every read goes through here.
      const url = 'https://abc.supabase.co/storage/v1/object/public/'
          'couple_media/fc1c8a3a/img_178638.jpg';
      expect(MediaUrls.toPath('couple_media', url), 'fc1c8a3a/img_178638.jpg');
    });

    test('decodes an escaped path', () {
      const url = 'https://abc.supabase.co/storage/v1/object/public/'
          'couple_media/fc1c8a3a/my%20snap.jpg';
      expect(MediaUrls.toPath('couple_media', url), 'fc1c8a3a/my snap.jpg');
    });

    test('does not confuse one bucket for another', () {
      // A chat-bg URL passed with the couple_media bucket must not be sliced at
      // the wrong marker and turned into a path that resolves to nothing.
      const url = 'https://abc.supabase.co/storage/v1/object/public/'
          'chat-bg/uid/bg_1.jpg';
      expect(MediaUrls.toPath('couple_media', url), url);
      expect(MediaUrls.toPath('chat-bg', url), 'uid/bg_1.jpg');
    });
  });

  group('cache', () {
    test('a miss is null rather than a blocking call', () {
      // The getters run inside build(). Returning null lets the bubble paint
      // its existing "unavailable" placeholder for one frame; anything else
      // would put a network round trip on the raster path.
      expect(MediaUrls.cached('couple_media', 'a/b.jpg'), isNull);
    });

    test('a hit is returned synchronously', () {
      MediaUrls.seedForTest('couple_media', 'a/b.jpg', 'https://signed/x');
      expect(MediaUrls.cached('couple_media', 'a/b.jpg'), 'https://signed/x');
    });

    test('buckets do not share a namespace', () {
      MediaUrls.seedForTest('couple_media', 'a/b.jpg', 'https://one');
      expect(MediaUrls.cached('chat-bg', 'a/b.jpg'), isNull);
    });
  });
}
