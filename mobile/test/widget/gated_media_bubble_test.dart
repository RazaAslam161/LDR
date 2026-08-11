import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/widgets/gated_media_bubble.dart';

/// The one property of this bubble that review cannot check by reading it:
/// that nothing of the media reaches the screen. The widget is handed the whole
/// message, path and all, so "it can't leak because it doesn't have it" is not
/// true here — a thumbnail is one Image.network away, and adding one would look
/// like an improvement.
///
/// These pump the real widget and search the rendered tree for the path.
void main() {
  const secret = 'couple-1/img_2026_bedroom.jpg';

  Message snap({
    String kind = 'image',
    SendStatus status = SendStatus.sent,
  }) =>
      Message(
        id: 'm1',
        senderId: 'me',
        createdAt: DateTime(2026),
        kind: kind,
        imagePath: kind == 'image' ? secret : null,
        videoPath: kind == 'video' ? secret : null,
        previewGated: true,
        localPath: '/data/user/0/cache/snap_local.jpg',
        sendStatus: status,
      );

  Future<void> pump(WidgetTester t, Message m, {VoidCallback? onTap}) =>
      t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: GatedMediaBubble(message: m, onTap: onTap)),
        ),
      ),);

  testWidgets('nothing of the media is painted', (t) async {
    await pump(t, snap());

    expect(find.byType(Image), findsNothing,
        reason: 'a thumbnail, however small, defeats the whole gate',);
    for (final w in t.allWidgets) {
      if (w is DecoratedBox) {
        final d = w.decoration;
        expect(d is BoxDecoration ? d.image : null, isNull,
            reason: 'a DecorationImage is a thumbnail by another name',);
      }
    }
  });

  testWidgets('no storage path or local file appears anywhere in the subtree',
      (t) async {
    await pump(t, snap());

    // Proves the scan can see rendered content at all: a search that matches
    // nothing would pass this test on a bubble made entirely of thumbnails.
    expect(t.allWidgets.any((w) => w.toString().contains('Photo')), isTrue,
        reason: 'the tree search reads nothing — this check is blind',);

    // The bubble itself legitimately holds the message; everything it builds
    // must be free of it.
    final leaks = t.allWidgets
        .where((w) => w is! GatedMediaBubble)
        .where((w) =>
            w.toString().contains(secret) ||
            w.toString().contains('snap_local.jpg'),)
        .map((w) => w.runtimeType.toString())
        .toList();
    expect(leaks, isEmpty, reason: 'the path reached the tree: $leaks');
  });

  testWidgets('it says what it is, and nothing more', (t) async {
    await pump(t, snap());

    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>()
        .toList();
    expect(texts, ['Photo', 'Tap to view']);
  });

  testWidgets('a gated video says video', (t) async {
    await pump(t, snap(kind: 'video'));

    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Photo'), findsNothing);
  });

  testWidgets('tapping it is what opens the media', (t) async {
    var opened = 0;
    await pump(t, snap(), onTap: () => opened++);

    await t.tap(find.byType(GatedMediaBubble));
    await t.pump();

    expect(opened, 1);
  });

  testWidgets('a send still in flight is not openable', (t) async {
    // There is no signed URL yet, so a tap would open an empty viewer.
    var opened = 0;
    await pump(t, snap(status: SendStatus.sending), onTap: () => opened++);

    await t.tap(find.byType(GatedMediaBubble));
    await t.pump();

    expect(opened, 0);
    expect(find.text('Tap to view'), findsNothing);
  });
}
