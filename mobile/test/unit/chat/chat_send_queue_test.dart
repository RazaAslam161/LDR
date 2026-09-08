import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The queue is what stands between "the user tapped send" and the photo
/// actually existing somewhere. It runs with no chat screen mounted and it is
/// the only thing holding the file, so the property that matters is that it
/// never quietly loses one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late File photo;

  setUp(() {
    // The queue persists every media send; without a mocked store that is a
    // "Binding has not yet been initialized" line per enqueue.
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('sendq');
    photo = File('${tmp.path}/snap.jpg')..writeAsBytesSync([1, 2, 3]);
    // Each test starts from an empty queue — it is a singleton by design.
    // clear(), not a discard loop: discard only removes a send the queue has
    // GIVEN UP on, and the ladder means a send can now be parked on a backoff
    // rung instead, with a timer that would fire inside the next test.
    ChatSendQueue.instance.clear();
    // The upload fails by NAME. Without this seam the failure was a
    // LateInitializationError from a Supabase client that does not exist in
    // a unit test, which reads like a bug in the bench rather than the path
    // being pinned.
    //
    // A PERMANENT refusal, and that is a change to this bench. It used to
    // throw a StateError, which the queue now reads as transient and RETRIES
    // — correctly: a dead second of network is not a reason to stop. Every
    // test below is about what happens once the queue has given up, so the
    // bench has to produce a failure it actually gives up on. 42501 is RLS.
    // The transient half of the ladder is pinned in
    // chat_send_durability_test.dart.
    ChatSendQueue.instance.uploader = (_) async =>
        throw const PostgrestException(message: 'denied', code: '42501');
  });
  tearDown(() {
    ChatSendQueue.instance.uploader = null;
    tmp.deleteSync(recursive: true);
  });

  /// The upload always throws (see setUp) — which is exactly the path worth
  /// pinning. Let it settle.
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

  test('a send the server refuses outright is KEPT, not dropped', () async {
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

  // The ceiling is the free plan's global storage limit, which takes
  // precedence over couple_intimate's own 100 MiB and is the reason build 80
  // logged `video n=1 gave-up storage.413`. A 413 is permanent, so a file past
  // it becomes a bubble that can never be retried into working — it has to be
  // refused before it is a bubble.
  group('the upload ceiling', () {
    test('a file under it is sendable', () {
      expect(ChatSendQueue.tooBig(photo), isFalse);
    });

    test('a file over it is not', () {
      final big = File('${tmp.path}/big.mp4')
        ..writeAsBytesSync(
            Uint8List(ChatSendQueue.maxUploadBytes + 1),);
      expect(ChatSendQueue.tooBig(big), isTrue);
    });

    test('a file exactly at it is still sendable — the bound is inclusive', () {
      final edge = File('${tmp.path}/edge.mp4')
        ..writeAsBytesSync(Uint8List(ChatSendQueue.maxUploadBytes));
      expect(ChatSendQueue.tooBig(edge), isFalse);
    });

    // The upload is the authority on what Storage accepts. Refusing on a
    // failed stat would drop sends this ceiling was never about.
    test('a file that cannot be measured is allowed through', () {
      expect(ChatSendQueue.tooBig(File('${tmp.path}/not-there.mp4')), isFalse);
    });

    // The in-app camera and the system camera are both capped by DURATION,
    // and this is the size they are capped against: 1080p at the AOSP
    // QUALITY_1080P profile is ~17 Mbps, so 20 seconds is ~42 MB. If either
    // cap is raised without raising this, a recording made inside the app
    // becomes unsendable again — which is the bug this pair exists to close.
    test('20s of 1080p at 17 Mbps fits under the ceiling', () {
      const bytesPerSecond = 17000000 ~/ 8;
      expect(20 * bytesPerSecond, lessThan(ChatSendQueue.maxUploadBytes));
      expect(60 * bytesPerSecond, greaterThan(ChatSendQueue.maxUploadBytes));
    });
  });
}
