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

    test('a text send whose insert throws is KEPT, and still trying',
        () async {
      final id = ChatSendQueue.instance.enqueueText('couple-1', 'hello');
      await settle();
      final s =
          ChatSendQueue.instance.pendingText.where((t) => t.id == id).single;
      // This pinned `failed`. Being signed out is the most recoverable
      // failure there is — the session comes back, on a token refresh or the
      // next sign-in — so parking the message and waiting for a human to press
      // retry was the wrong shape. What the law protects is unchanged and now
      // stronger: the body is the only copy left anywhere, so it is KEPT.
      expect(s.status, SendStatus.sending,
          reason: 'the body is the only copy of the message left anywhere',);
      expect(s.attempts, greaterThan(0));
      expect(s.nextAttempt, isNotNull, reason: 'and it is booked in to go');
    });

    test('a resume tries it again rather than waiting out the rung', () async {
      // retryText is the wrong verb for this now: it only wakes a send the
      // queue GAVE UP on, and being signed out is recoverable, so this one is
      // merely parked. What actually recovers it is the kick a resume or a
      // socket reconnect fires — which is also when the session is most likely
      // to have come back.
      ChatSendQueue.instance.enqueueText('couple-1', 'hello');
      await settle();
      final before = ChatSendQueue.instance.pendingText.single.attempts;
      expect(before, greaterThan(0));

      ChatSendQueue.instance.kick();
      await settle();
      expect(ChatSendQueue.instance.pendingText.single.attempts,
          greaterThan(before),);
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
