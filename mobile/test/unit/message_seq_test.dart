import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// Behaviour, executed. The nine tests in receipts_v2_test.dart all passed
/// against a build where reconcileWith silently dropped the server seq,
/// because every one of them greps source text instead of constructing a
/// Message. seq is the entire basis of read receipts, so losing it means one
/// grey tick forever — and it is invisible to any account with chat history,
/// whose mount-time fetch seeds a non-zero _maxSeq.
void main() {
  Message local(String id) => Message(
        id: id,
        senderId: 'me',
        createdAt: DateTime(2026, 1, 1),
        body: 'hello',
        localPath: '/tmp/photo.jpg',
        sendStatus: SendStatus.sending,
      );

  Message server(String id, int seq) => Message(
        id: id,
        senderId: 'me',
        createdAt: DateTime(2026, 1, 2),
        body: 'hello',
        seq: seq,
      );

  test('an optimistic message adopts the server seq when it lands', () {
    final reconciled = local('a').reconcileWith(server('a', 41));
    expect(reconciled.seq, 41,
        reason: 'without this the tick can never leave "sent"');
  });

  test('reconciling keeps the local file so the image does not re-download', () {
    final reconciled = local('a').reconcileWith(server('a', 7));
    expect(reconciled.localPath, '/tmp/photo.jpg');
    expect(reconciled.sendStatus, SendStatus.sent);
  });

  test('a message with no seq yet reads as un-sent, not as seq 0 delivered',
      () {
    // 0 is the "not on the server" sentinel; it must never be mistaken for a
    // real position, or a partner's receipt of 0 would mark it seen.
    expect(local('a').seq, 0);
  });

  test('seq survives copyWith', () {
    // copyWith is used for send-status transitions; dropping seq there would
    // reintroduce the same bug by a different route.
    final m = server('a', 99).copyWith(sendStatus: SendStatus.sent);
    expect(m.seq, 99);
  });

  test('fromJson reads the server seq', () {
    final m = Message.fromJson({
      'id': 'a',
      'sender_id': 'me',
      'created_at': DateTime(2026, 1, 1).toIso8601String(),
      'kind': 'text',
      'seq': 1234,
    });
    expect(m.seq, 1234);
  });

  test('a row with no seq column degrades to 0 rather than throwing', () {
    // A client talking to a database where receipts_v2.sql has not been run.
    final m = Message.fromJson({
      'id': 'a',
      'sender_id': 'me',
      'created_at': DateTime(2026, 1, 1).toIso8601String(),
      'kind': 'text',
    });
    expect(m.seq, 0);
  });

  test('the max seq of a conversation advances as messages reconcile', () {
    // This is what _maxSeq does, and what gates _ackRead. With the bug every
    // element stayed 0, so a brand-new couple never acked anything at all.
    final msgs = [local('a'), local('b'), local('c')];
    expect(msgs.fold<int>(0, (a, m) => m.seq > a ? m.seq : a), 0);

    final landed = [
      msgs[0].reconcileWith(server('a', 10)),
      msgs[1].reconcileWith(server('b', 11)),
      msgs[2].reconcileWith(server('c', 12)),
    ];
    expect(landed.fold<int>(0, (a, m) => m.seq > a ? m.seq : a), 12);
  });
}
