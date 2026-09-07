import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The report's worst chat moment: on the train with no signal the whole
/// conversation was gone — 'Say something sweet', like day one. Nothing was
/// deleted: one bare `catch (_)` treated every failure of the history read as
/// the first-run case. And worse than the empty screen, `_catchUp` then ran
/// `fetchSince(0)` on a zero watermark it had not earned and painted the
/// OLDEST 500 messages of the relationship as the conversation.
String _fn(String src, String head) {
  final at = src.indexOf(head);
  expect(at, greaterThan(-1), reason: '$head not found');
  return src.substring(at, src.indexOf('\n  }', at));
}

void main() {
  final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();
  final repo = File('lib/features/chat/chat_repository.dart').readAsStringSync();

  test('the first read has a failure state and no bare catch', () {
    final init = _fn(chat, 'Future<void> _init() async {');
    expect(init, isNot(contains('catch (_)')));
    expect(init, contains('_loadNewest()'));
    final load = _fn(chat, 'Future<void> _loadNewest() async {');
    expect(load, contains('_loadFailed = true'));
    expect(load, contains("reportIfNotMerelyOffline(e, st, 'chat-fetch')"));
    expect(chat, contains('_LoadFailed(onRetry: _retryLoad)'));
    // Rendered BEFORE the first-run screen, so an empty list that came from a
    // failed read is never mistaken for a conversation nobody has started.
    expect(chat.indexOf('_LoadFailed(onRetry'), lessThan(chat.indexOf('? const _EmptyChat()')));
  });

  test('a catch-up never runs from a watermark it did not earn', () {
    final catchUp = _fn(chat, 'Future<void> _catchUp({required String trigger}) async {');
    expect(catchUp, contains('if (_maxSeq == 0)'));
    expect(catchUp, contains('_loadNewest()'));
    expect(catchUp, isNot(contains('fetchSince(couple, 0)')));
    // ...and walks the gap in pages instead of stopping at the first 500.
    expect(catchUp, contains('ChatRepository.catchUpPageSize'));
    expect(catchUp, contains('page.last.seq'));
    expect(catchUp, contains("reportIfNotMerelyOffline(e, st, 'chat-catchup')"));
    final since = _fn(repo, 'static Future<List<Message>> fetchSince(');
    expect(since, contains('.limit(catchUpPageSize)'));
  });

  test('a failed reload keeps the rows and says so', () {
    final reload = _fn(chat, 'Future<void> _reload() async {');
    expect(reload, isNot(contains('catch (_)')));
    expect(reload, contains("reportIfNotMerelyOffline(e, st, 'chat-reload')"));
    expect(reload, contains('SnackBarAction'));
  });

  test('a refused messages join leaves the handset', () {
    final sub = repo.substring(repo.indexOf('static RealtimeChannel subscribe('));
    final status = sub.substring(sub.indexOf('.subscribe((status, [error])'));
    expect(status.substring(0, 900), contains("kind: 'realtime-subscribe'"));
  });
}
