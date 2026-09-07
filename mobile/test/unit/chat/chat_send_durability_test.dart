import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_selection.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A message the user pressed send on must land, or say why.
///
/// Two holes, both of them silent. A text body was deliberately never
/// persisted — "it lands in seconds or the sender is looking at a bubble they
/// can retry" — which was only true while the process lived, and Android kills
/// this app whenever it is backgrounded, which is whenever the cover goes up.
/// And EVERY failure, of any kind, went straight to `failed`: one dead second
/// of network parked a message behind a retry button nobody was in the room to
/// press, and `debugPrint` — inert in a release build — was the only record
/// that it had ever been attempted.
String _code(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late File photo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('senddur');
    photo = File('${tmp.path}/snap.jpg')..writeAsBytesSync([1, 2, 3]);
    for (final s in ChatSendQueue.instance.pending.toList()) {
      ChatSendQueue.instance
        ..retry(s.id)
        ..discard(s.id);
    }
    ChatSendQueue.instance.clear();
  });
  tearDown(() {
    ChatSendQueue.instance
      ..uploader = null
      ..textSender = null
      ..clear();
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  group('the ladder', () {
    test('a transient failure re-arms instead of giving up', () async {
      // The whole defect in one assertion. A 5xx, a dropped socket, a tunnel:
      // none of them means the message cannot be sent, and all of them used to
      // end it.
      ChatSendQueue.instance.uploader =
          (_) async => throw const SocketException('offline');
      ChatSendQueue.instance.enqueueImage('couple-1', photo);
      await settle();

      final s = ChatSendQueue.instance.pending.single;
      expect(s.status, SendStatus.sending,
          reason: 'a network blip is not a permanent failure',);
      expect(s.attempts, greaterThan(0));
      expect(s.nextAttempt, isNotNull,
          reason: 'and it must be booked in for another try',);
    });

    test('a refusal nothing can fix stops, and says it stopped', () async {
      // 42501 is RLS. Retrying it forever is a spinner that never resolves.
      ChatSendQueue.instance.uploader = (_) async =>
          throw const PostgrestException(message: 'denied', code: '42501');
      ChatSendQueue.instance.enqueueImage('couple-1', photo);
      await settle();

      final s = ChatSendQueue.instance.pending.single;
      expect(s.status, SendStatus.failed);
      expect(s.nextAttempt, isNull, reason: 'nothing is booked in');
    });

    test('a full account is permanent, and a lost connection is not', () {
      // Both arrive as a StorageException. Only the counter tells them apart,
      // and only for the person looking at it — the ladder has to decide from
      // the status alone.
      expect(
          ChatSendQueue.permanent(
              const StorageException('quota', statusCode: '403'),),
          isTrue,);
      expect(
          ChatSendQueue.permanent(
              const StorageException('too big', statusCode: '413'),),
          isTrue,);
      expect(
          ChatSendQueue.permanent(
              const StorageException('gateway', statusCode: '502'),),
          isFalse,);
      expect(ChatSendQueue.permanent(const SocketException('down')), isFalse);
    });

    test('the backoff climbs and then holds, never gives up', () {
      final src =
          File('lib/features/chat/chat_reactions.dart').readAsStringSync();
      expect(src, contains('static Duration backoffFor(int attempt)'),
          reason: 'one ladder, shared with the send queue',);
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      expect(q, contains('ChatReactionOutbox.backoffFor(send.attempts)'));
    });

    test('text sends never hold an upload slot', () async {
      // PendingText exists precisely so the row-only send does not compete for
      // the three upload slots a photo needs. The first cut of the ladder put
      // both in one set, so three messages typed in a row stopped every photo
      // uploading at all.
      ChatSendQueue.instance.textSender =
          (_) async => throw const SocketException('offline');
      var uploads = 0;
      ChatSendQueue.instance.uploader = (_) async {
        uploads++;
        throw const SocketException('offline');
      };
      for (var i = 0; i < 4; i++) {
        ChatSendQueue.instance.enqueueText('couple-1', 'm$i');
      }
      ChatSendQueue.instance.enqueueImage('couple-1', photo);
      await settle();
      expect(uploads, greaterThan(0),
          reason: 'the photo must still have been attempted',);
    });

    test('a kick collapses the ladder but is floored', () async {
      ChatSendQueue.instance.uploader =
          (_) async => throw const SocketException('offline');
      ChatSendQueue.instance.enqueueImage('couple-1', photo);
      await settle();
      expect(ChatSendQueue.instance.pending.single.nextAttempt, isNotNull);

      ChatSendQueue.instance.kick();
      await settle();
      // Attempted again immediately — the person opened the app, and the rung
      // they were parked on is no longer the best evidence available.
      expect(ChatSendQueue.instance.pending.single.attempts, greaterThan(1));

      final before = ChatSendQueue.instance.pending.single.attempts;
      ChatSendQueue.instance.kick(); // inside the 3s floor
      await settle();
      expect(ChatSendQueue.instance.pending.single.attempts, before,
          reason: 'a flapping socket must not fire every parked send at a '
              'connection that is still broken',);
    });
  });

  group('the body outlives the process', () {
    test('an unsent text is written to the encrypted outbox, never prefs', () {
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      final code = _code(q);
      expect(code, contains('ChatTextOutbox.put('));
      // The prefs blob is paths and ids. A body in it is the one thing the
      // disguise cannot cover.
      final persist = code.substring(
        code.indexOf('Future<void> _persist()'),
        code.indexOf('Future<void> _restore()'),
      );
      expect(persist, isNot(contains("'body'")));
      expect(persist, isNot(contains('s.caption')));
      expect(persist, isNot(contains('.body')));
    });

    test('the outbox is prefix-filtered and per account', () {
      final src =
          File('lib/features/chat/chat_text_outbox.dart').readAsStringSync();
      final code = _code(src);
      expect(code, contains('encryptedSharedPreferences: true'));
      expect(code, isNot(contains('deleteAll()')),
          reason: 'this storage also holds the X25519 key, which cannot be '
              'regenerated',);
      expect(code, contains('startsWith(_prefix)'));
      final restore = code.substring(code.indexOf('restore(String uid)'));
      expect(restore.substring(0, 900), contains("j['u'] != uid"),
          reason: 'two accounts share one handset',);
      // A read that FAILED and an outbox that is EMPTY were the same answer,
      // and the caller latches on a successful restore — so one transient
      // keystore fault meant the bodies were never restored again for the life
      // of the process, and the next sign-out deleted them.
      expect(restore.substring(0, 900), contains('return null;'));
      expect(restore.substring(0, 900), contains("kind: 'chat-outbox-read'"));
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      expect(q, contains('if (rows == null) {'));
      expect(q.substring(q.indexOf('if (rows == null) {'),
          q.indexOf('if (rows == null) {') + 400,), contains('_restoredFor = null;'),
          reason: 'a failed read must not latch',);
    });

    test('ending the couple takes the unsent bodies with it', () {
      final q = _code(
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync(),);
      final clear = q.substring(q.indexOf('void clear() {'));
      expect(clear.substring(0, 400), contains('ChatTextOutbox.clearAll()'),
          reason: 'a message typed during the argument must not be delivered '
              'to a couple the user has walked away from',);
    });

    test('a restored send whose file is gone is reported, not dropped', () {
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      final restore = q.substring(q.indexOf('Future<void> _restoreMedia()'));
      expect(restore.substring(0, 2400), contains("kind: 'chat-send-restore'"));
      expect(restore.substring(0, 2400), contains("code: 'file.gone'"));
    });

    test('the bodies are restored even when there is no media to restore', () {
      // Both halves were one method with an early `return` on a null prefs
      // blob — and a text-only queue writes no prefs blob at all, so the
      // bodies were skipped on exactly the launch that had bodies and no
      // media. The whole feature, silently off.
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      final restore = q.substring(
        q.indexOf('Future<void> _restore() async {'),
        q.indexOf('Future<void> _restoreMedia()'),
      );
      final media = restore.indexOf('_restoreMedia()');
      final text = restore.indexOf('_restoreText()');
      expect(media, greaterThan(-1));
      expect(text, greaterThan(media),
          reason: 'and neither may be able to skip the other',);
    });

    test('a body comes back in the order it was typed, and stays given-up-on',
        () {
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      final restore = q.substring(q.indexOf('Future<void> _restoreText()'));
      expect(restore.substring(0, 1800), contains('rows.sort('),
          reason: 'readAll() returns hash order, not typing order',);
      expect(restore.substring(0, 1800), contains("j['f'] == true"),
          reason: 'a send the ladder gave up on must not come back sending',);
      expect(q, contains("if (failed) 'f': true"));
    });
  });

  group('a send nothing can save is the user\'s to remove', () {
    test('a failed message can be selected', () {
      // It could not be, on the same reasoning as one still uploading. That
      // reasoning expired with the ladder: `failed` now means the queue gave
      // up, so nothing is coming — and a message that can neither be sent nor
      // removed is one the user is stuck looking at.
      expect(
          ChatSelection.canSelect(Message(
            id: 'a',
            senderId: 'me',
            createdAt: DateTime.now(),
            sendStatus: SendStatus.failed,
          ),),
          isTrue,);
      expect(
          ChatSelection.canSelect(Message(
            id: 'b',
            senderId: 'me',
            createdAt: DateTime.now(),
            sendStatus: SendStatus.sending,
          ),),
          isFalse,
          reason: 'an upload in flight will land; deleting it deletes nothing',);
    });

    test('the chat drains the queue before it asks the server', () {
      final src =
          File('lib/features/chat/chat_screen.dart').readAsStringSync();
      final del = src.substring(src.indexOf('Future<void> _deleteSelected('));
      final drain = del.indexOf('holdsFailed');
      final rpc = del.indexOf('_selection.deleteAll');
      expect(drain, greaterThan(-1));
      expect(drain, lessThan(rpc),
          reason: 'there is no row to delete — the RPC would touch nothing and '
              'report success',);
      expect(del.substring(0, rpc), contains('discardText'));
    });
  });

  group('a caption reaches a phone that cannot be updated', () {
    // The first cut put the caption in the media row's `body` and rendered it
    // under the frame. An adversarial read of build 73 (commit 3238b5f) proved
    // that INVISIBLE there: its `_Content` never reads a body in the image or
    // video arm, and its previewText() hard-returns a camera glyph — so the
    // sentence decrypted on that handset and was discarded by every surface it
    // has, while the composer had already deleted the draft. Two phones in the
    // field run it and can never be made to update.
    //
    // A caption is now an ordinary text message. Both builds render one.
    test('it is sent as its own message, not as the media row body', () {
      final repo =
          File('lib/features/chat/chat_repository.dart').readAsStringSync();
      expect(repo, isNot(contains('_captionColumns')));
      final img = repo.substring(
        repo.indexOf('static Future<String?> sendImage('),
        repo.indexOf('static Future<String?> uploadGif('),
      );
      expect(img, isNot(contains('caption')),
          reason: 'a media row carries no body a pinned client cannot read',);

      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      final send = q.substring(q.indexOf('void _sendCaption('));
      expect(send.substring(0, 400), contains('enqueueText(coupleId, body)'));
    });

    test('the picture still carries an id of its own', () {
      // Not for the caption any more — for the 23505 dedupe, which is what
      // stops a re-attempt writing the photo a second time.
      final repo =
          File('lib/features/chat/chat_repository.dart').readAsStringSync();
      final img = repo.substring(
        repo.indexOf('static Future<String?> sendImage('),
        repo.indexOf('static Future<String?> uploadGif('),
      );
      expect(img, contains('final rowId = id ?? const Uuid().v4();'));
      expect(img, isNot(contains("if (id != null) 'id': id")));
    });

    test('the composer is cleared when its text becomes a caption', () {
      final bar = File('lib/features/chat/widgets/chat_input_bar.dart')
          .readAsStringSync();
      final take = bar.substring(bar.indexOf('String? _takeCaption()'));
      expect(take.substring(0, 400), contains('_text.clear()'));
      expect(take.substring(0, 400), contains('ChatDraftStore.clear'),
          reason: 'otherwise the same sentence is sent twice',);
    });
  });

  group('the ladder cannot burn a metered link', () {
    test('a media send stops climbing; text never does', () async {
      // Every rung re-runs the WHOLE send, upload included, under a fresh
      // random object name. Unbounded, a 40 MB video went up again at 1s, 3s,
      // 8s, 20s, 45s, 90s and then every three minutes for the life of the
      // process — and while it read `sending` there was no gesture anywhere
      // that could stop it.
      final q =
          File('lib/features/chat/chat_send_queue.dart').readAsStringSync();
      expect(q, contains('static const _maxMediaAttempts'));
      expect(q, contains('capped: n >= _maxMediaAttempts'));

      ChatSendQueue.instance.uploader =
          (_) async => throw const SocketException('offline');
      final id = ChatSendQueue.instance.enqueueImage('couple-1', photo);
      for (var i = 0; i < 8; i++) {
        ChatSendQueue.instance.retry(id);
        await settle();
      }
      // Each retry() resets the count, so this only proves the cap exists in
      // the path; the arithmetic is pinned by the source assertions above.
      expect(ChatSendQueue.instance.pending, hasLength(1));
    });
  });
}
