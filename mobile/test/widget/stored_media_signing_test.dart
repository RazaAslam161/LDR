import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/features/chat/widgets/media_viewer.dart';

/// The bucket going private only breaks the reads that forgot to sign, and the
/// ones that forgot are invisible in review: the stored value is a String and
/// so is a URL, so `Image.network(row.column)` compiles and looks right.
///
/// It shipped that way on the home check-in snap — the card signed, the tap
/// handler passed the raw path to the viewer, and the result was a black screen
/// with a broken-image icon. These pump both readers with a seeded cache, so no
/// Supabase client is involved and the only thing under test is whether the
/// stored value reaches the network as-is.
void main() {
  const path = 'fc1c8a3a/checkins/0227786b_1786412731691.jpg';
  const signed = 'https://abc.supabase.co/storage/v1/object/sign/'
      'couple_media/$path?token=xyz';

  setUp(MediaUrls.clear);

  /// A tap target that actually paints. A bare SizedBox has nothing to hit-test
  /// against, so the tap lands on nothing and the assertions pass vacuously.
  Widget tapper(void Function(BuildContext) onTap) => MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () => onTap(context),
              child: Container(
                key: const Key('tap'),
                width: 80,
                height: 80,
                color: const Color(0xFF333333),
              ),
            ),
          ),
        ),
      );

  testWidgets('the tile renders the signed URL, not the stored path',
      (tester) async {
    MediaUrls.seedForTest(chatBucket, path, signed);
    await tester.pumpWidget(const MaterialApp(
      home: SignedImage(bucket: chatBucket, value: path),
    ),);
    await tester.pump();

    expect(tester.widget<NetImage>(find.byType(NetImage)).url, signed);
  });

  testWidgets('tapping through to the viewer carries the stored path',
      (tester) async {
    // The bug exactly: the viewer was handed 'fc1c8a3a/checkins/…jpg' as if it
    // were a URL. Image.network on that resolves to nothing and paints the
    // broken-image icon on the viewer's black backdrop.
    //
    // The viewer takes the PATH now and signs for itself, which is also what
    // lets it sign AGAIN when a 24-hour token dies while it is open.
    MediaUrls.seedForTest(chatBucket, path, signed);
    await tester.pumpWidget(
        tapper((c) => MediaViewer.openStored(c, chatBucket, path)),);

    await tester.tap(find.byKey(const Key('tap')));
    // Not pumpAndSettle: the page's placeholder is a CircularProgressIndicator
    // and there is no cache manager under a widget test to ever resolve it, so
    // settling here waits for a frame that never stops being scheduled.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final item =
        tester.widget<MediaViewer>(find.byType(MediaViewer)).source.itemAt(0);
    expect(item.bucket, chatBucket);
    expect(item.path, path);
    expect(item.cacheKey, '$chatBucket/$path');
  });

  testWidgets('the page renders the signed URL, keyed by the path',
      (tester) async {
    MediaUrls.seedForTest(chatBucket, path, signed);
    await tester.pumpWidget(
        tapper((c) => MediaViewer.openStored(c, chatBucket, path)),);

    await tester.tap(find.byKey(const Key('tap')));
    // Not pumpAndSettle: the page's placeholder is a CircularProgressIndicator
    // and there is no cache manager under a widget test to ever resolve it, so
    // settling here waits for a frame that never stops being scheduled.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final image =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(image.imageUrl, signed);
    // Not the URL: the token in it rotates every 24h, so a URL-keyed cache
    // re-downloads the whole library the next day and fills the disk with
    // duplicates of bytes it already had.
    expect(image.cacheKey, '$chatBucket/$path');
  });

  testWidgets('a legacy public URL is signed rather than fetched',
      (tester) async {
    // Rows written while couple_media was public hold the whole URL. It still
    // looks like a URL, so nothing fails loudly — it just 404s.
    const legacy = 'https://abc.supabase.co/storage/v1/object/public/'
        'couple_media/$path';
    MediaUrls.seedForTest(chatBucket, path, signed);
    await tester.pumpWidget(
        tapper((c) => MediaViewer.openStored(c, chatBucket, legacy)),);

    await tester.tap(find.byKey(const Key('tap')));
    // Not pumpAndSettle: the page's placeholder is a CircularProgressIndicator
    // and there is no cache manager under a widget test to ever resolve it, so
    // settling here waits for a frame that never stops being scheduled.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
        tester.widget<MediaViewer>(find.byType(MediaViewer)).source.itemAt(0).path,
        path,);
  });
}
