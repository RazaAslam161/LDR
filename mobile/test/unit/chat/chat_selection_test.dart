import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_selection.dart';

/// Behaviour, not source text.
///
/// The first version of these tests read chat_screen.dart as a string and
/// asserted on substrings. It passed against a build where bulk delete deleted
/// nothing at all, because the substrings were still present. Anything that
/// matters here runs the code.
void main() {
  const me = 'me-uid';
  const them = 'them-uid';

  Message msg(
    String id, {
    String sender = me,
    SendStatus status = SendStatus.sent,
    bool tombstone = false,
    String kind = 'text',
  }) =>
      Message(
        id: id,
        senderId: sender,
        createdAt: DateTime(2026),
        kind: kind,
        sendStatus: status,
        deletedForEveryone: tombstone,
      );

  group('what can be picked', () {
    test('a landed message can', () {
      final s = ChatSelection()..toggle(msg('a'));
      expect(s.contains('a'), isTrue);
      expect(s.isActive, isTrue);
    });

    test('a second toggle unpicks it, and the selection closes', () {
      final m = msg('a');
      final s = ChatSelection()..toggle(m);
      s.toggle(m);
      expect(s.isActive, isFalse, reason: 'an empty set is not a selection');
    });

    test('a still-uploading message cannot', () {
      // Its id exists only on this device until the upload finishes, so the
      // delete hits no row and the upload lands it anyway — the message
      // reappears seconds after the user deleted it.
      final s = ChatSelection()..toggle(msg('a', status: SendStatus.sending));
      expect(s.isActive, isFalse);
    });

    test('a send the queue gave up on CAN', () {
      // This used to be bundled with the line above, on the same reasoning.
      // That reasoning expired when the queue grew a backoff ladder: anything
      // recoverable now stays `sending` and keeps trying, so `failed` no
      // longer means "not yet" — it means nothing is ever coming. A message
      // that can neither be sent nor removed is one the user is stuck looking
      // at. The chat drains these through ChatSendQueue.discard, never the
      // server, which has no row for them (chat_send_durability_test).
      final s = ChatSelection()..toggle(msg('b', status: SendStatus.failed));
      expect(s.isActive, isTrue);
    });

    test('a tombstone cannot', () {
      // delete_message_for_everyone updates no rows and raises nothing, so the
      // delete would silently do nothing and say it worked.
      final s = ChatSelection()..toggle(msg('a', tombstone: true));
      expect(s.isActive, isFalse);
    });
  });

  group('delete for everyone is offered only when it can succeed', () {
    test('all mine', () {
      final all = [msg('a'), msg('b')];
      final s = ChatSelection()
        ..toggle(all[0])
        ..toggle(all[1]);
      expect(s.allMine(all, me), isTrue);
    });

    test('one of theirs is enough to withdraw it', () {
      final all = [msg('a'), msg('b', sender: them)];
      final s = ChatSelection()
        ..toggle(all[0])
        ..toggle(all[1]);
      expect(s.allMine(all, me), isFalse);
    });

    test('a selection whose messages are gone is not "all mine"', () {
      // every() over an empty list is true. Without the guard, a partner
      // deleting the picked messages turns the safe option destructive.
      final s = ChatSelection()..toggle(msg('a'));
      expect(s.allMine(const [], me), isFalse);
    });
  });

  test('a selection cannot outlive the messages in it', () {
    final s = ChatSelection()
      ..toggle(msg('a'))
      ..toggle(msg('b'));
    s.prune(['a']);
    expect(s.length, 1, reason: 'the count has to stay truthful');
    expect(s.contains('b'), isFalse);
  });

  group('deleting the batch', () {
    test('every picked message is deleted, once', () async {
      final calls = <String>[];
      final s = ChatSelection()
        ..toggle(msg('a'))
        ..toggle(msg('b'))
        ..toggle(msg('c'));

      final failed = await s.deleteAll((id) async => calls.add(id));

      expect(calls..sort(), ['a', 'b', 'c']);
      expect(failed, isEmpty);
      expect(s.isActive, isFalse, reason: 'a clean batch closes the selection');
    });

    test('one failure does not abandon the rest', () async {
      final calls = <String>[];
      final s = ChatSelection()
        ..toggle(msg('a'))
        ..toggle(msg('b'))
        ..toggle(msg('c'));

      final failed = await s.deleteAll((id) async {
        calls.add(id);
        if (id == 'a') throw Exception('offline');
      });

      expect(calls.length, 3, reason: 'b and c must still be attempted');
      expect(failed, ['a']);
    });

    test('what failed stays selected, so it can be retried', () async {
      // Clearing up front made a dropped connection cost the user the whole
      // selection — re-picking twenty photos is the work this feature removes.
      final s = ChatSelection()
        ..toggle(msg('a'))
        ..toggle(msg('b'));

      await s.deleteAll((id) async {
        if (id == 'a') throw Exception('offline');
      });

      expect(s.contains('a'), isTrue);
      expect(s.contains('b'), isFalse, reason: 'b really was deleted');
      expect(s.length, 1);
    });

    test('a retry of the failures deletes exactly those', () async {
      final s = ChatSelection()
        ..toggle(msg('a'))
        ..toggle(msg('b'));
      var online = false;
      await s.deleteAll((id) async {
        if (!online) throw Exception('offline');
      });
      expect(s.length, 2);

      online = true;
      final calls = <String>[];
      final failed = await s.deleteAll((id) async => calls.add(id));

      expect(calls..sort(), ['a', 'b']);
      expect(failed, isEmpty);
      expect(s.isActive, isFalse);
    });

    test('a second tap mid-batch does not run every delete again', () async {
      final calls = <String>[];
      final s = ChatSelection()..toggle(msg('a'));

      final failed = await s.deleteAll((id) async {
        calls.add(id);
        // Re-entering while the first batch is still awaiting is exactly what
        // an impatient second tap on the delete button does.
        await s.deleteAll((inner) async => calls.add(inner));
      });

      expect(calls, ['a'], reason: 'the re-entrant call must be refused');
      expect(failed, isEmpty);
    });

    test('busy flips before the first await, so the UI can gate on it',
        () async {
      // The screen starts the batch and then rebuilds. If busy were set after
      // the first await, that rebuild would read false and the delete button
      // would stay live for the whole batch.
      final s = ChatSelection()..toggle(msg('a'));
      final pending = s.deleteAll((_) async {});
      expect(s.busy, isTrue, reason: 'set synchronously on entry');
      await pending;
      expect(s.busy, isFalse);
    });

    test('deleting nothing is not an error', () async {
      final s = ChatSelection();
      expect(await s.deleteAll((_) async => fail('must not be called')),
          isEmpty,);
    });
  });
}
