import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reported defect: a message sat on ONE grey tick until the recipient
/// opened the conversation, and opening it then acked delivered and read in the
/// same breath — so one grey jumped straight to two green and two grey never
/// existed. `ackDelivered` had exactly one call site, the chat screen's
/// catch-up, and nothing else in the app could say "this handset has it".
///
/// These pin the two halves of the replacement: delivery can now be acked with
/// nothing on screen, and none of the paths that do it may ever ack READ.
String _read(String p) => File(p).readAsStringSync();

String _codeOnly(String s) => s
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const couple = 'aaaaaaaa-0000-0000-0000-000000000001';
  const other = 'bbbbbbbb-0000-0000-0000-000000000002';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('acking the same seq twice is free', () {
    test('the watermark only moves forward', () async {
      await DeliveredMark.recordAcked(couple, 42);
      await DeliveredMark.recordAcked(couple, 7);
      expect(await DeliveredMark.acked(couple), 42,
          reason: 'a late, out-of-order ack must not un-deliver anything',);
    });

    test('a confirmed ack settles everything owed below it', () async {
      await DeliveredMark.recordOwed(couple, 30);
      await DeliveredMark.recordAcked(couple, 31);
      expect(await DeliveredMark.owed(couple), 0);
    });

    test('an ack that failed stays owed until one lands', () async {
      await DeliveredMark.recordOwed(couple, 30);
      await DeliveredMark.recordAcked(couple, 29);
      expect(await DeliveredMark.owed(couple), 30,
          reason: 'a push-driven ack has no next one; a lost seq must be kept',);
    });
  });

  test('the watermark belongs to a couple, not to a handset', () async {
    // The device keeps its SharedPreferences across a sign-out. Without the
    // stamp, the previous account's watermark would suppress the new account's
    // acks and leave their partner on one grey tick forever.
    await DeliveredMark.recordAcked(couple, 900);
    expect(await DeliveredMark.acked(other), 0);
    expect(await DeliveredMark.acked(null), 0);
  });

  test('the background isolate can find the running app', () {
    // How the FCM isolate decides whether to hand the ack to a live UI isolate
    // or do it itself. Registering twice must not throw or lose the mapping —
    // FcmService.init() runs again on every hot restart.
    DeliveryAckPort.listen();
    DeliveryAckPort.listen();
    expect(DeliveryAckPort.liveApp, isNotNull);
  });

  group('delivered is not read', () {
    test('read is acked from visibility, not from mount', () {
      // The lock screen and the stealth scrim are Stack siblings over a
      // still-mounted chat, and a full-screen page pushed over it leaves it
      // mounted too. `mounted` was the only guard, so a message arriving
      // while the phone lay locked turned the sender's tick green.
      final chat = _read('lib/features/chat/chat_screen.dart');
      final at = chat.indexOf('void _ackRead(');
      expect(at, greaterThan(-1));
      final body = chat.substring(at, chat.indexOf('\n  }', at));
      expect(body.trimLeft(),
          startsWith('void _ackRead(String trigger, {bool flush = false}) {'),);
      expect(body.indexOf('if (!_chatVisible)'), lessThan(body.indexOf('_maxSeq')),
          reason: 'visibility is checked before anything advances',);
      final gate = chat.indexOf('bool get _chatVisible');
      expect(gate, greaterThan(-1));
      final predicate = chat.substring(gate, gate + 300);
      expect(predicate, contains('humanPresent'));
      expect(predicate, contains('isCurrent'));
      expect(predicate, contains('ChatScreen.visible'));
      final deps = chat.indexOf('void didChangeDependencies()');
      expect(deps, greaterThan(-1));
      expect(chat.substring(deps, deps + 400), contains('_settleOwedAck()'));
      expect(chat, contains('PresenceService.present.addListener(_settleOwedAck)'));
    });

    final receipts = _read('lib/features/chat/chat_receipts.dart');
    final fcm = _read('lib/core/services/fcm_service.dart');
    final resume = _read('lib/core/realtime/realtime_resume.dart');
    final background = _read('lib/core/services/reach_notifications.dart');

    test('no path that fires without the chat may ack read', () {
      // The whole defect. Opening the conversation is the only thing allowed to
      // say a human saw a message; a push, a socket reconnect and an app resume
      // say only that the bytes are here.
      for (final entry in {
        'fcm_service.dart': fcm,
        'realtime_resume.dart': resume,
        'reach_notifications.dart': background,
      }.entries) {
        expect(_codeOnly(entry.value).contains('ackRead'), isFalse,
            reason: '${entry.key} acks delivery without anyone looking; '
                'acking read there is what turned one grey into two green',);
      }
    });

    test('the background isolate never acks read either', () {
      final i = receipts.indexOf('class BackgroundReceiptAck');
      expect(i, greaterThan(-1));
      final body = _codeOnly(receipts.substring(i));
      expect(body.contains('ack_read'), isFalse);
      expect(body, contains('ack_delivered'));
    });
  });

  group('delivery is acked without the conversation being open', () {
    final receipts = _read('lib/features/chat/chat_receipts.dart');
    final fcm = _read('lib/core/services/fcm_service.dart');
    final resume = _read('lib/core/realtime/realtime_resume.dart');
    final background = _read('lib/core/services/reach_notifications.dart');

    test('a push in the foreground acks it', () {
      // `msg_sync` is the type the TRIGGER sends (notify_message, migration
      // 20260817110000). This pinned `'message'` — the older name — and passed
      // while the foreground handler was deaf to every push the server actually
      // sent. Two halves each green, one string apart, and the tick never moved.
      final i = fcm.indexOf("type == 'msg_sync'");
      expect(i, greaterThan(-1),
          reason: 'the foreground handler must recognise the type the trigger '
              'sends; see notify_message in 20260817110000',);
      expect(_codeOnly(fcm.substring(i, i + 1400)), contains('_ackDelivery'));
    });

    test('the background handler lets the wake through its allow-list', () {
      // The gate that made this concrete: reach_notifications returns early for
      // any type not named here, so a wake the list does not know is dropped
      // before it can ack. Silent, and indistinguishable from no push at all.
      expect(_codeOnly(background), contains("type != 'msg_sync'"));
    });

    test('the delivery wake acks BEFORE it draws anything', () {
      // This used to assert the wake drew nothing at all. That was the right
      // rule while the app had no message notifications; it now has them, and
      // the rule that replaces it is about ORDER.
      //
      // The receipt is the part that has been working for weeks. It is started
      // first and awaited last, so a notification that throws — a bad icon, a
      // channel that does not exist, a plugin failure in the background isolate
      // — cannot cost the sender their second grey tick. A new feature must not
      // be able to break an old one.
      final i = background.indexOf("type == 'msg_sync'");
      expect(i, greaterThan(-1));
      final branch = _codeOnly(background.substring(i, i + 1600));
      final ack = branch.indexOf('BackgroundReceiptAck.onMessagePush');
      final show = branch.indexOf('showMessageNotification');
      expect(ack, greaterThan(-1));
      expect(show, greaterThan(-1),
          reason: 'the wake now also draws the coalesced unread alert',);
      expect(ack, lessThan(show),
          reason: 'the receipt must be in flight before anything is drawn',);
    });

    test('the unread alert is one per conversation, not one per message', () {
      // The defect this exists to prevent, in the owner's words: a weather app
      // that notifies on every message is not a weather app anyone believes.
      // The id keys on the couple and updates in place; onlyAlertOnce means
      // only the first of a burst makes a sound.
      final rn = _read('lib/core/services/reach_notifications.dart');
      final i = rn.indexOf('Future<void> showMessageNotification');
      expect(i, greaterThan(-1));
      // Wide enough to reach past the comment explaining WHY covers are
      // silent — _codeOnly strips comments, but only after this slice is taken.
      final fn = _codeOnly(rn.substring(i, i + 4200));
      expect(fn, contains('coupleId.hashCode'),
          reason: 'one notification per conversation, not per message',);
      expect(fn, isNot(contains('messageId.hashCode')));
      expect(fn, contains('onlyAlertOnce'));
      expect(fn, contains('profile.cover != DisguiseCover.none'),
          reason: 'a cover must post NOTHING: Android stamps the app label '
              '("Miles") on every notification regardless of the body text, so '
              'a disguised build cannot post one that does not name the app',);
    });

    test('a push with the app closed acks it', () {
      expect(_codeOnly(background),
          contains('BackgroundReceiptAck.onMessagePush'),);
    });

    test('the socket coming back acks it', () {
      expect(_codeOnly(resume), contains('ackHighestDelivered'));
    });

    test('resuming the app acks it', () {
      final i = fcm.indexOf('static Future<void> registerToken');
      expect(i, greaterThan(-1));
      expect(_codeOnly(fcm.substring(i, i + 700)),
          contains('ackHighestDelivered'),);
    });

    test('a failed ack is written down rather than dropped', () {
      // The old comment called it best-effort because the chat screen re-acked
      // on every catch-up. A push-driven ack has no such second chance.
      final i = receipts.indexOf('static Future<void> ackDelivered');
      final body = receipts.substring(i, receipts.indexOf('\n  }', i));
      expect(body, contains('recordOwed'));
    });
  });
}
