import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_send_queue.dart';

/// A gallery pick of fifty is where this queue either works or loses someone's
/// photos. The three properties worth pinning are the ones a person would only
/// discover the hard way: everything is accepted before anything is uploaded,
/// the uploads are bounded rather than fifty-at-once or one-at-a-time, and a
/// single item failing is one item failing.
void main() {
  final q = ChatSendQueue.instance;
  late Directory tmp;
  late File photo;
  late File clip;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('batch');
    photo = File('${tmp.path}/a.jpg')..writeAsBytesSync([1]);
    clip = File('${tmp.path}/b.mp4')..writeAsBytesSync([2]);
    // clear(), not a discard loop: discard only removes a send the queue has
    // GIVEN UP on, and a send parked on a backoff rung is not one of those —
    // it would survive into the next test carrying a live timer.
    q.clear();
  });

  tearDown(() {
    q.uploader = null;
    tmp.deleteSync(recursive: true);
  });

  /// Long enough for a completed upload to run its listeners and free its slot.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  List<({File file, bool isVideo})> pick(int n) => [
        for (var i = 0; i < n; i++)
          (file: i.isEven ? photo : clip, isVideo: i.isOdd),
      ];

  /// An upload that hangs, released once the test is over so the singleton is
  /// handed to the next test empty.
  void hangingUploader() {
    final held = Completer<void>();
    addTearDown(() async {
      held.complete();
      await settle();
    });
    q.uploader = (_) => held.future;
  }

  test('every picked item is a bubble before a single byte moves', () {
    hangingUploader();
    final ids = q.enqueueAll('couple-1', pick(12));

    // Synchronous on purpose: the picker sheet has already closed and the
    // conversation is what the user is looking at.
    expect(ids, hasLength(12));
    expect(q.pending, hasLength(12));
    expect(q.pending.every((s) => s.status == SendStatus.sending), isTrue);
    expect(q.pending.map((s) => s.id), ids, reason: 'pick order is kept');
  });

  test('photos and videos are told apart, interleaved as picked', () {
    hangingUploader();
    q.enqueueAll('couple-1', pick(4));
    expect(q.pending.map((s) => s.kind), ['image', 'video', 'image', 'video']);
    expect(q.pending.first.file.path, photo.path);
  });

  test('only the first item answers the reply', () {
    // Twelve photos each quoting the same message is twelve copies of it
    // running down the conversation.
    hangingUploader();
    q.enqueueAll('couple-1', pick(3), replyToId: 'msg-1');
    expect(q.pending.map((s) => s.replyToId), ['msg-1', null, null]);
  });

  test('a batch uploads a few at a time — not all of them, and not one', () async {
    var live = 0;
    var peak = 0;
    final gates = <Completer<void>>[];
    q.uploader = (_) async {
      live++;
      if (live > peak) peak = live;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      live--;
    };

    q.enqueueAll('couple-1', pick(10));
    await settle();
    expect(gates, hasLength(3),
        reason: 'ten queued, three moving: fifty parallel uploads on one phone '
            'uplink makes the first photo land as late as the last',);

    for (var i = 0; i < 10; i++) {
      gates[i].complete();
      await settle();
    }
    expect(peak, 3, reason: 'a freed slot has to be taken, or this is serial');
    expect(q.pending, isEmpty);
  });

  test('one item failing does not take the rest of the batch with it', () async {
    // The whole point of a queue rather than a loop: the user picked ten
    // photos, one of them hit a dead connection, and the other nine are fine.
    final bad = File('${tmp.path}/bad.jpg')..writeAsBytesSync([3]);
    q.uploader = (s) async {
      if (s.file.path == bad.path) throw const SocketException('no route');
    };

    final items = pick(9)..insert(1, (file: bad, isVideo: false));
    final ids = q.enqueueAll('couple-1', items);
    await settle();

    expect(q.pending.map((s) => s.id), [ids[1]],
        reason: 'the nine that worked are gone; the one that failed is kept',);
    // Kept, and BOOKED IN. It used to be pinned as `failed`, which was the
    // whole defect: a dead route is not a reason to stop, and the bubble sat
    // behind a retry button nobody was in the room to press.
    expect(q.pending.single.status, SendStatus.sending);
    expect(q.pending.single.nextAttempt, isNotNull);
    expect(q.pending.single.file.existsSync(), isTrue,
        reason: 'the file has to survive, or there is nothing to retry',);
  });

  test('the item that failed can be sent on its own afterwards', () async {
    final bad = File('${tmp.path}/bad.jpg')..writeAsBytesSync([3]);
    q.uploader = (s) async {
      if (s.file.path == bad.path) throw const SocketException('no route');
    };
    final ids = q.enqueueAll('couple-1', [
      (file: photo, isVideo: false),
      (file: bad, isVideo: false),
    ]);
    await settle();
    expect(q.pending.single.id, ids[1]);

    q.uploader = (_) async {};
    // retry() only wakes a send the queue GAVE UP on. This one is merely
    // parked, so the kick — what a resume or a reconnect does — is the verb
    // that applies to it.
    q.kick();
    await settle();
    expect(q.pending, isEmpty);
  });

  test('a batch of fifty is accepted whole', () async {
    // The cap the picker is asked for. Anything that silently dropped the tail
    // would look identical to the user changing their mind.
    hangingUploader();
    expect(q.enqueueAll('couple-1', pick(50)), hasLength(50));
    expect(q.pending, hasLength(50));
  });
}
