import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/profile/shared_media_window.dart';

/// The window both the grid and the pager read.
///
/// Worth testing on its own because the bug it exists to prevent is invisible
/// on a couple with fifty photos and certain on a couple with five thousand:
/// the pager can only swipe as far as the window has loaded, so "does it
/// extend, in the right order, from the right cursor" is the whole feature.
void main() {
  Message photo(int seq) => Message(
        id: 'm$seq',
        senderId: 'them',
        createdAt: DateTime(2026, 1, seq.clamp(1, 28)),
        kind: 'image',
        imagePath: 'couple/img_$seq.jpg',
        seq: seq,
      );

  Message video(int seq) => Message(
        id: 'v$seq',
        senderId: 'me',
        createdAt: DateTime(2026, 2, seq.clamp(1, 28)),
        kind: 'video',
        videoPath: 'couple/vid_$seq.mp4',
        seq: seq,
      );

  SharedMediaWindow windowOver(
    SharedMediaFetch fetch, {
    int pageSize = 3,
    String? myUid = 'me',
  }) =>
      SharedMediaWindow(
        fetch: fetch,
        pageSize: pageSize,
        partnerName: 'Ana',
        myUid: myUid,
      );

  test('a page keeps the order the server sent it in', () async {
    final window = windowOver((_) async => [photo(9), photo(8), photo(7)]);
    await window.more();

    expect(window.length, 3);
    expect([for (var i = 0; i < 3; i++) window.itemAt(i).path],
        ['couple/img_9.jpg', 'couple/img_8.jpg', 'couple/img_7.jpg'],);
  });

  test('the cursor is the last row it holds, never an offset', () async {
    final asked = <int?>[];
    final window = windowOver((beforeSeq) async {
      asked.add(beforeSeq);
      final from = beforeSeq ?? 100;
      return [photo(from - 1), photo(from - 2), photo(from - 3)];
    });

    await window.more();
    await window.more();
    await window.more();

    // Null for the newest page, then the seq of the last row of the page
    // before. An OFFSET would be 0/3/6 and would shift under any message sent
    // while the grid is open.
    expect(asked, [null, 97, 94]);
    expect(window.length, 9);
  });

  test('a short page is the end of the shelf, and nothing asks again',
      () async {
    var calls = 0;
    final window = windowOver((_) async {
      calls++;
      return [photo(3), photo(2)];
    });

    await window.more();
    expect(window.hasMore, isFalse);

    await window.more();
    await window.more();
    expect(calls, 1);
  });

  test('a second request while one is in flight is dropped, not queued',
      () async {
    // The grid's scroll listener and the pager's look-ahead both call extend,
    // and they are usually looking at the same gap. Queued, that gap is
    // fetched twice and every row in it appears twice in the pager.
    final gate = Completer<List<Message>>();
    var calls = 0;
    final window = windowOver((_) {
      calls++;
      return gate.future;
    });

    final first = window.more();
    final second = window.more();
    gate.complete([photo(3), photo(2), photo(1)]);
    await Future.wait([first, second]);

    expect(calls, 1);
    expect(window.length, 3);
  });

  test('a row with no path is dropped without shifting the index', () async {
    // Otherwise the tile the grid drew at index 4 opens the pager on item 5,
    // which is the class of bug nobody reports and everybody notices.
    final window = windowOver((_) async => [
          photo(9),
          Message(
              id: 'broken',
              senderId: 'them',
              createdAt: DateTime(2026, 3),
              kind: 'image',
              seq: 8,),
          photo(7),
        ],);
    await window.more();

    expect(window.messages.length, 3);
    expect(window.length, 2);
    expect(window.itemAt(1).path, 'couple/img_7.jpg');
  });

  test('photos and videos carry the bucket they actually live in', () async {
    final window = windowOver((_) async => [photo(9), video(8)]);
    await window.more();

    expect(window.itemAt(0).bucket, chatBucket);
    expect(window.itemAt(0).isVideo, isFalse);
    expect(window.itemAt(1).bucket, privateBucket);
    expect(window.itemAt(1).isVideo, isTrue);
    // What the disk files the bytes under. Keyed by the signed URL instead,
    // the whole library re-downloads once the token rotates.
    expect(window.itemAt(1).cacheKey, '$privateBucket/couple/vid_8.mp4');
  });

  test('a save is labelled with whoever actually sent it', () async {
    // Half of any shelf is the user's own sends, and "Photo from Ana" on a
    // photo you took yourself is the chat's own bug moved to a new screen.
    final window = windowOver((_) async => [photo(9), video(8)]);
    await window.more();

    expect(window.itemAt(0).senderName, 'Ana');
    expect(window.itemAt(1).senderName, 'you');
  });

  test('a failed page is a failure, not an empty shelf', () async {
    var fail = true;
    final window = windowOver((_) async {
      if (fail) throw StateError('offline');
      return [photo(3), photo(2)];
    });

    await window.more();
    expect(window.failed, isTrue);
    expect(window.loadedOnce, isTrue);
    // Telling a couple with four hundred photos that they have none is the app
    // lying about their history because a request timed out.
    expect(window.hasMore, isTrue);

    fail = false;
    await window.retry();
    expect(window.failed, isFalse);
    expect(window.length, 2);
  });

  test('a page landing after the screen is gone is not a crash', () async {
    // Backing out of the profile while a page is in flight. Notifying a
    // disposed ChangeNotifier is an assertion failure in debug, so this is a
    // crash for the offence of closing a screen half a second too early.
    final gate = Completer<List<Message>>();
    final window = windowOver((_) => gate.future);
    final pending = window.more();

    window.dispose();
    gate.complete([photo(3)]);

    await expectLater(pending, completes);
  });

  test('every page appended tells the views to redraw', () async {
    var notified = 0;
    final window = windowOver((_) async => [photo(3), photo(2), photo(1)])
      ..addListener(() => notified++);

    await window.more();
    await window.more();

    // Without this the pager holds an itemCount that stopped growing and the
    // swipe past the loaded window does nothing at all.
    expect(notified, 2);
  });
}
