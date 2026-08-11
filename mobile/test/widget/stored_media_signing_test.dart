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

  testWidgets('tapping through to the viewer signs the stored path',
      (tester) async {
    // The bug exactly: the viewer was handed 'fc1c8a3a/checkins/…jpg' as if it
    // were a URL. Image.network on that resolves to nothing and paints the
    // broken-image icon on the viewer's black backdrop.
    MediaUrls.seedForTest(chatBucket, path, signed);
    await tester.pumpWidget(
        tapper((c) => MediaViewer.openStored(c, chatBucket, path)),);

    await tester.tap(find.byKey(const Key('tap')));
    await tester.pumpAndSettle();

    expect(
        tester.widget<MediaViewer>(find.byType(MediaViewer)).imageUrl, signed,);
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
    await tester.pumpAndSettle();

    expect(
        tester.widget<MediaViewer>(find.byType(MediaViewer)).imageUrl, signed,);
  });
}
