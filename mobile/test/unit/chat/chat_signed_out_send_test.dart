import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_send_queue.dart';

/// A send that races an auth loss must FAIL, never complete.
///
/// Every send in ChatRepository used to open with `if (uid == null) return`,
/// and a normal completion is ChatSendQueue's signal that the send LANDED: it
/// deletes the pending item and its persisted copy. A send racing a sign-out
/// was therefore recorded as delivered while the message existed nowhere at
/// all — permanent loss, drawn as a grey tick.
///
/// The null-uid branch itself cannot be reached from here: SupabaseService
/// holds a bare `static late final SupabaseClient` with no injection seam, so
/// `currentUserId` throws LateInitializationError in a test instead of
/// answering null. So the guard is pinned as shape — the same idiom as
/// chat_send_path_test.dart — and the half that CAN run does: the queue
/// keeping a send whose repository call threw.
void main() {
  final repo =
      File('lib/features/chat/chat_repository.dart').readAsStringSync();
  final core =
      File('lib/core/data/supabase_repository.dart').readAsStringSync();

  group('a repository throw keeps the send, a return would delete it', () {
    setUp(() {
      ChatSendQueue.instance.clear();
      // The insert fails by NAME — the signed-out refusal this file is about —
      // rather than with the LateInitializationError of a client that does
      // not exist in a unit test.
      ChatSendQueue.instance.textSender =
          (_) async => throw StateError('not signed in');
    });
    tearDown(() => ChatSendQueue.instance.textSender = null);

    /// The insert always throws (see setUp). Let it settle.
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('a text send whose insert throws is kept as failed', () async {
      final id = ChatSendQueue.instance.enqueueText('couple-1', 'hello');
      await settle();
      final s =
          ChatSendQueue.instance.pendingText.where((t) => t.id == id).single;
      expect(s.status, SendStatus.failed,
          reason: 'the body is the only copy of the message left anywhere',);
    });

    test('retryText puts the failed text back in flight', () async {
      final id = ChatSendQueue.instance.enqueueText('couple-1', 'hello');
      await settle();
      ChatSendQueue.instance.retryText(id);
      expect(ChatSendQueue.instance.pendingText.single.status,
          SendStatus.sending,);
    });
  });

  group('no send path can report success for a signed-out user', () {
    test('every ChatRepository send throws on a null uid', () {
      expect(repo.contains('if (uid == null) return'), isFalse,
          reason: 'a bare return reads as success to the queue, which then '
              'deletes the pending item and its persisted copy',);
      expect(
          RegExp(r"throw StateError\('not signed in'\)")
              .allMatches(repo)
              .length,
          5,
          reason: 'text, image, video, file and voice each carry the guard',);
    });

    test('the profile setters Settings toasts over throw too', () {
      for (final method in [
        'static Future<void> updateMyProfile',
        'static Future<void> setAvatarUrl',
        'static Future<void> setGender',
      ]) {
        final at = core.indexOf(method);
        expect(at, greaterThan(-1), reason: '$method should exist');
        final end = at + 700 < core.length ? at + 700 : core.length;
        final body = core.substring(at, end);
        expect(body, contains("throw StateError('Not signed in')"),
            reason: '$method returned silently while Settings toasted '
                "'Updated'",);
        expect(body.contains('if (uid == null) return'), isFalse,
            reason: '$method must not read as success when signed out',);
      }
    });
  });
}
