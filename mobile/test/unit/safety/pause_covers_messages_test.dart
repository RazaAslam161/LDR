import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The contact pause silenced Reaches, nudges and calls and left messages
/// alone — not because msg_sync draws nothing (it has drawn the coalesced
/// unread alert since build 44) but because notify_message was never gated.
/// 20260906140400 adds the flag; the receiving handset decides.
String _code(String s) => s
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final background =
      File('lib/core/services/reach_notifications.dart').readAsStringSync();
  final fn = File('../supabase/functions/reach-notify/index.ts').readAsStringSync();
  final sql = File(
    '../supabase/migrations/'
    '20260906140400_the_pause_reaches_messages_without_touching_the_ticks.sql',
  ).readAsStringSync();
  final sheet = File('lib/features/safety/safety_sheets.dart').readAsStringSync();
  final faq = File('lib/features/legal/faq_text.dart').readAsStringSync();

  test('the muted wake still acks, and draws nothing at all', () {
    final branch = _code(
      background.substring(background.indexOf("type == 'msg_sync'")),
    ).substring(0, 1600);
    final ack = branch.indexOf('BackgroundReceiptAck.onMessagePush');
    final muted = branch.indexOf("message.data['muted'] as String?");
    final tally = branch.indexOf('UnreadTally.increment');
    final show = branch.indexOf('showMessageNotification');
    final preview = branch.indexOf('MessagePreviewPort.liveApp');
    expect(ack, greaterThan(-1));
    expect(muted, greaterThan(ack),
        reason: 'the receipt is in flight before the pause is consulted',);
    // The count is kept, the drawing is not. Under a cover the tally IS the
    // unread signal — no notification is ever posted there — so skipping it
    // while paused erased the whole window with nothing to restore it.
    expect(tally, lessThan(muted),
        reason: 'a paused message is still counted; only the drawing stops',);
    expect(muted, lessThan(show));
    expect(muted, lessThan(preview),
        reason: 'the live isolate would otherwise re-post it with the text',);
  });

  test('the flag is computed by the trigger and forwarded as a string', () {
    expect(sql, contains(
      "'muted', public.push_muted(new.couple_id, new.sender_id, 'message')",
    ),);
    // The wake itself is never suppressed: that would freeze the sender's
    // second tick and leak the pause.
    expect(sql, isNot(contains('if public.push_muted')));
    expect(sql, contains("'kind', 'msg_sync'"));
    expect(sql, contains('ROLLBACK'));
    expect(fn, contains('muted: String(row?.muted === true)'));
  });

  test('the copy no longer says messages are unaffected', () {
    for (final src in [sheet, faq]) {
      expect(src, isNot(contains('messages are not affected')));
      expect(src, isNot(contains('Messages are not affected')));
      expect(src, isNot(contains('Chat messages are not affected')));
    }
    // And it no longer promises a call notification the server already stops.
    expect(sheet, isNot(contains('its notification can still appear')));
    expect(faq, isNot(contains('notification itself can still appear')));
    expect(faq, contains('Settings → Notifications'),
        reason: 'the row is not under Partner',);
  });
}
