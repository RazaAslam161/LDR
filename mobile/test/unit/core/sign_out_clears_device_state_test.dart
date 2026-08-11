import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/features/chat/chat_send_queue.dart';

/// What one account leaves on the handset for the next one.
///
/// The FCM token was this exact shape: device-scoped state that outlived the
/// session, so the account signed in afterwards received the previous couple's
/// Reaches. Two more pieces of state have the same lifetime — a map of live
/// 24-hour signed URLs to a couple's storage objects, and a queue of uploads
/// accepted for them — and both are process singletons that no sign-out
/// touched.
void main() {
  test('signing out forgets every signed URL', () {
    MediaUrls.seedForTest('couple_media', 'couple-a/img_1.jpg', 'https://one');
    expect(MediaUrls.cached('couple_media', 'couple-a/img_1.jpg'), 'https://one');

    MediaUrls.clear();

    expect(MediaUrls.cached('couple_media', 'couple-a/img_1.jpg'), isNull);
  });

  test('signing out drops uploads accepted for the couple being left', () {
    final tmp = Directory.systemTemp.createTempSync('signout');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final q = ChatSendQueue.instance;
    // A hung uploader, so the send is still pending when the session ends.
    final held = Completer<void>();
    q.uploader = (_) => held.future;
    addTearDown(() {
      held.complete();
      q.uploader = null;
    });

    q.enqueueFiles('couple-a', [
      (file: File('${tmp.path}/a.pdf')..writeAsBytesSync([1]), name: 'a.pdf'),
    ]);
    expect(q.pending, isNotEmpty);

    q.clear();

    expect(q.pending, isEmpty);
  });

  test('sign-out is where both are called, not the buttons', () {
    // Two of the four sign-out buttons never unbound the device, which is how
    // the token leak shipped. Anything that has to happen on sign-out belongs
    // in signOut(), where a caller cannot forget it.
    final src =
        File('lib/core/app/session_provider.dart').readAsStringSync();
    final signOut = src.substring(src.indexOf('Future<void> signOut()'));
    expect(signOut, contains('MediaUrls.clear();'));
    expect(signOut, contains('ChatSendQueue.instance.clear();'));
  });
}
