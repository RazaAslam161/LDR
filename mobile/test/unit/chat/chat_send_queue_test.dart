import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_send_queue.dart';

/// The queue is what stands between "the user tapped send" and the photo
/// actually existing somewhere. It runs with no chat screen mounted and it is
/// the only thing holding the file, so the property that matters is that it
/// never quietly loses one.
void main() {
  late Directory tmp;
  late File photo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sendq');
    photo = File('${tmp.path}/snap.jpg')..writeAsBytesSync([1, 2, 3]);
    // Each test starts from an empty queue — it is a singleton by design.
    for (final s in ChatSendQueue.instance.pending.toList()) {
      ChatSendQueue.instance.discard(s.id);
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Supabase is not initialised in a unit test, so the upload always throws —
  /// which is exactly the path worth pinning. Let it settle.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('a send appears immediately, before anything is uploaded', () {
    final id = ChatSendQueue.instance.enqueueImage('couple-1', photo);
    // Synchronous on purpose: the camera pops on the next line, and the bubble
    // has to exist by then.
    final pending = ChatSendQueue.instance.pending;
    expect(pending, hasLength(1));
    expect(pending.single.id, id);
    expect(pending.single.status, SendStatus.sending);
    expect(pending.single.file.path, photo.path);
  });

  test('listeners are told the moment a send is accepted', () {
    var notified = 0;
    void listener() => notified++;
    ChatSendQueue.instance.addListener(listener);
    addTearDown(() => ChatSendQueue.instance.removeListener(listener));

    ChatSendQueue.instance.enqueueImage('couple-1', photo);
    expect(notified, greaterThan(0));
  });

  test('a failed send is KEPT, not dropped', () async {
    // The old behaviour: the photo vanished with no way to try again.
    final id = ChatSendQueue.instance.enqueueImage('couple-1', photo);
    await settle();

    final s = ChatSendQueue.instance.pending.where((p) => p.id == id).single;
    expect(s.status, SendStatus.failed);
    expect(s.file.existsSync(), isTrue, reason: 'the photo must survive too');
  });

  test('retry puts a failed send back in flight', () async {
    final id = ChatSendQueue.instance.enqueueImage('couple-1', photo);
    await settle();
    expect(ChatSendQueue.instance.pending.single.status, SendStatus.failed);

    ChatSendQueue.instance.retry(id);
    expect(ChatSendQueue.instance.pending.single.status, SendStatus.sending);
  });

  test('retry does nothing to a send that is still going', () {
    final id = ChatSendQueue.instance.enqueueImage('couple-1', photo);
    ChatSendQueue.instance.retry(id); // still sending
    expect(ChatSendQueue.instance.pending, hasLength(1));
    expect(ChatSendQueue.instance.pending.single.status, SendStatus.sending);
  });

  test('discard only removes a send the user has given up on', () async {
    final id = ChatSendQueue.instance.enqueueImage('couple-1', photo);
    ChatSendQueue.instance.discard(id); // in flight — must not vanish
    expect(ChatSendQueue.instance.pending, hasLength(1));

    await settle();
    ChatSendQueue.instance.discard(id); // now failed
    expect(ChatSendQueue.instance.pending, isEmpty);
  });

  test('sends keep their own identity and couple', () async {
    final other = File('${tmp.path}/other.jpg')..writeAsBytesSync([9]);
    final a = ChatSendQueue.instance.enqueueImage('couple-1', photo);
    final b = ChatSendQueue.instance.enqueueImage('couple-2', other);
    expect(a, isNot(b));

    await settle();
    final byId = {for (final s in ChatSendQueue.instance.pending) s.id: s};
    expect(byId[a]!.coupleId, 'couple-1');
    expect(byId[b]!.coupleId, 'couple-2');
    expect(byId[b]!.file.path, other.path);
  });

  test('an explicit id is honoured, so the DB echo can dedupe the bubble',
      () {
    final id = ChatSendQueue.instance
        .enqueueImage('couple-1', photo, id: 'fixed-id');
    expect(id, 'fixed-id');
    expect(ChatSendQueue.instance.pending.single.id, 'fixed-id');
  });

  test('a video is queued as a video', () {
    ChatSendQueue.instance.enqueueVideo('couple-1', photo);
    expect(ChatSendQueue.instance.pending.single.kind, 'video');
  });
}
