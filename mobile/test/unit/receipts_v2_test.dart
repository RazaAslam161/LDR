import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Receipts were wrong for two months because they compared two clocks:
/// `chat_last_read` stamped by the READER'S PHONE against `created_at` stamped
/// by POSTGRES, with one second of slop. Two NTP-synced dev phones agree to the
/// millisecond, so it looked perfect and was broken for everyone else.
///
/// These pin the properties that make the replacement correct by construction,
/// not by luck.
/// Resolves a migration by name, so renumbering or reordering migrations/
/// cannot break this test the way a hardcoded path does.
String _migration(String name) {
  final dir = Directory('../supabase/migrations');
  final f = dir.listSync().whereType<File>().firstWhere(
      (f) => f.path.endsWith('_$name.sql'),
      orElse: () => throw StateError('no migration named $name'));
  return f.readAsStringSync();
}

void main() {
  String read(String p) => File(p).readAsStringSync();
  String codeOnly(String s) => s
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('--'))
      .join('\n');

  final sql = _migration('receipts_v2');
  final chat = read('lib/features/chat/chat_screen.dart');
  final repo = read('lib/features/chat/chat_repository.dart');
  final push = _migration('message_push');

  group('order comes from the server, never a device', () {
    test('messages carry a server-assigned monotonic seq', () {
      expect(codeOnly(sql), contains('add column if not exists seq bigint'));
      expect(codeOnly(sql), contains('nextval'));
      expect(repo, contains("seq: JsonUtils.parseInt(j['seq'])"));
    });

    test('existing history is backfilled, not orphaned', () {
      // A NOT NULL seq with no backfill would reject every historical row and
      // blank the conversation.
      expect(codeOnly(sql), contains('row_number() over (order by created_at'));
      expect(codeOnly(sql), contains('setval'));
    });
  });

  group('a receipt can never move backwards', () {
    test('advancement is greatest(), server-side', () {
      final body = codeOnly(sql);
      expect(body, contains('greatest(public.chat_receipts.read_seq'));
      expect(body, contains('greatest(public.chat_receipts.delivered_seq'));
    });

    test('clients cannot write the row directly', () {
      // Only a SELECT policy exists; advancement goes through the RPCs, so a
      // PATCH cannot bypass the monotonicity guarantee.
      final body = codeOnly(sql);
      expect(body, contains('chat_receipts_select_member'));
      expect(body.contains('for update using'), isFalse,
          reason: 'no direct client UPDATE path may exist on chat_receipts');
      expect(body, contains('grant  execute on function public.ack_read'));
    });

    test('reading implies delivery', () {
      // You cannot read what you never received; ack_read must advance both or
      // a message could show seen-but-not-delivered.
      final i = sql.indexOf('function public.ack_read');
      expect(i, greaterThan(-1));
      expect(sql.substring(i, i + 900), contains('delivered_seq'));
    });
  });

  test('the status tick reads integers, not clocks', () {
    final i = chat.indexOf('_MsgStatus _statusFor');
    final body = codeOnly(chat.substring(i, chat.indexOf('\n  }', i)));
    expect(body, contains('readSeq'));
    expect(body, contains('deliveredSeq'));
    for (final banned in ['chatLastRead', 'createdAt', 'DateTime']) {
      expect(body.contains(banned), isFalse,
          reason: '$banned reintroduces a clock into receipt logic');
    }
  });

  group('nothing is lost while the socket is down', () {
    test('there is a catch-up fetch keyed on seq', () {
      // postgres_changes is live-only: its cursor is "the moment I joined".
      // Rejoining a channel does not replay the gap, so it has to be read.
      expect(repo, contains('fetchSince'));
      final i = repo.indexOf('static Future<List<Message>> fetchSince');
      final body = codeOnly(repo.substring(i, repo.indexOf('\n  }', i)));
      expect(body, contains("gt('seq'"));
      expect(body, contains("order('seq', ascending: true)"));
    });

    test('catch-up runs on reconnect AND on resume', () {
      // Android freezes the process on background, so the socket was dead the
      // whole time it was away.
      expect(chat, contains('_catchUp()'));
      final i = chat.indexOf('didChangeAppLifecycleState');
      expect(codeOnly(chat.substring(i, i + 900)), contains('_catchUp'));
    });
  });

  test('a backgrounded partner is actually woken', () {
    // The only transport used to be the live websocket, so a frozen process
    // received nothing and the row sat unread in Postgres.
    final body = codeOnly(push);
    expect(body, contains('after insert on public.messages'));
    expect(body, contains("'kind', 'message'"),
        reason: 'a bare row is treated as a reach and rejected for no from_user');
  });
}
