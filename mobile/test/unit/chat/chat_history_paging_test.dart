import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The conversation opened on the newest 300 and stopped there.
///
/// Nothing loaded anything older and nothing said so, so a couple ten weeks in
/// scrolled to the top and simply found the list would not move — which reads
/// as the app having lost everything before that point. Chat was live-only.
String _code(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  final repo =
      File('lib/features/chat/chat_repository.dart').readAsStringSync();
  final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();

  String fn(String src, String head) {
    final at = src.indexOf(head);
    expect(at, greaterThan(-1), reason: '$head not found');
    return src.substring(at, src.indexOf(RegExp(r'\n  \}\r?\n'), at));
  }

  group('the page behind the page', () {
    test('it is cursored on seq, not on a timestamp', () {
      final f = fn(repo, 'static Future<List<Message>> fetchOlder(');
      expect(f, contains("lt('seq', beforeSeq)"));
      expect(f, contains("order('seq', ascending: false)"));
      // created_at cannot separate two messages inside one clock tick, so a
      // page boundary there can repeat or skip one.
      expect(f, isNot(contains('created_at')));
    });

    test('what the viewer deleted for themselves stays deleted', () {
      final f = fn(repo, 'static Future<List<Message>> fetchOlder(');
      expect(f, contains("not('deleted_by', 'cs', [uid])"),
          reason: 'otherwise the message comes back through the history door',);
      // But a tombstone MUST come back: the conversation renders it as "This
      // message was deleted", and filtering it here would make the placeholder
      // exist only above the fold.
      expect(f, isNot(contains('deleted_for_everyone')));
    });

    test('history never moves the read watermark', () {
      // Comments stripped: this method's own comment EXPLAINS that it does not
      // go through _onIncoming, and the explanation would fail the assertion
      // about what the code does — a correct fix reported as a regression.
      final load = fn(_code(chat), 'Future<void> _loadOlder() async {');
      expect(load, isNot(contains('_onIncoming')),
          reason: 'that path owns the NEWEST watermark; an old message must '
              'not ack a read the user never made',);
      expect(load, contains('_messages.addAll(fresh)'));
      expect(load, contains('_ids.add(m.id)'),
          reason: 'the seam between two pages must not draw a message twice',);
    });

    test('the cursor ignores sends that have no server seq yet', () {
      // An optimistic bubble carries seq 0, and a cursor of 0 asks for
      // everything before the beginning of time.
      final min = _code(chat)
          .substring(_code(chat).indexOf('int get _minSeq'));
      expect(min.substring(0, 200), contains('m.seq > 0'));
      final load = fn(chat, 'Future<void> _loadOlder() async {');
      expect(load, contains('cursor <= 0'));
    });

    test('the end is asked once and then remembered', () {
      final load = fn(chat, 'Future<void> _loadOlder() async {');
      expect(load, contains('older.length < ChatRepository.historyPageSize'));
      expect(load, contains('_moreHistory == false'),
          reason: 'a finger parked at the top must not keep asking',);
      expect(load, contains('_loadingOlder'));
    });

    test('a failed page says so and can be retried', () {
      final load = fn(chat, 'Future<void> _loadOlder() async {');
      expect(load, contains("'chat-history'"),
          reason: 'the reporter, not a swallowed catch',);
      expect(load, contains('_historyFailed = true'));
      expect(chat, contains('class _HistoryFooter'));
      final footer = chat.substring(chat.indexOf('class _HistoryFooter'));
      expect(footer, contains('Could not load older messages'));
      expect(footer, contains('The beginning'));
    });

    test('the ordinary scroll draws no spinner at all', () {
      // The next page is asked for 600px early, so a spinner on every upward
      // scroll would be the most-seen widget in the app.
      final footer = chat.substring(chat.indexOf('class _HistoryFooter'));
      expect(footer, contains('if (!loading && !failed && !atEnd)'));
      final scroll = fn(chat, 'void _onScroll() {');
      expect(scroll, contains('extentAfter < 600'));
    });

    test('a replaced conversation forgets how far back it had reached', () {
      // _reload refills from the newest 300 and a partner's clear empties the
      // list — neither touched the paging flags, so a conversation paged to
      // its end could never load history again, and a page in flight across a
      // clear re-appended a hundred bubbles the partner had just deleted.
      expect(chat, contains('void _resetHistory()'));
      final reload = fn(chat, 'Future<void> _reload() async {');
      expect(reload, contains('_resetHistory()'));
      final cleared = fn(chat, 'void _onClearedBroadcast(');
      expect(cleared, contains('_resetHistory()'));
      final load = fn(_code(chat), 'Future<void> _loadOlder() async {');
      expect(load, contains('_historyGeneration != generation'));
    });

    test('the footer is a real row, not a phantom index', () {
      expect(chat, contains('itemCount: rows.length + 1'));
      expect(chat, contains('if (i == rows.length) {'));
    });
  });
}
