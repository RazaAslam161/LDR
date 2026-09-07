import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/realtime/realtime_service.dart';

/// A subscription that ran out of join attempts stopped for good.
///
/// `_verifyJoin` gave up after five refused joins and simply returned, so the
/// channel stayed silent until the socket happened to cycle — which on a phone
/// left alone can be hours. Nothing anywhere read that state either, so the
/// whole failure reached the user as a partner who never wrote back.
void main() {
  final rt =
      File('lib/core/realtime/realtime_service.dart').readAsStringSync();

  setUp(RealtimeStatus.reset);
  tearDown(RealtimeStatus.reset);

  group('the app has one answer to "are live updates working"', () {
    test('nothing subscribed is not the same as something broken', () {
      expect(RealtimeStatus.worst.value, RealtimeHealth.joined);
      expect(RealtimeStatus.deadCount, 0);
    });

    test('a dead key stays dead until a join actually lands', () {
      // The parked retry publishes `joining` the moment it fires, so a channel
      // refused for an hour hid the warning for twelve seconds out of every
      // seventy-five — and that gap is when a person looks up.
      RealtimeStatus.publish('k', RealtimeHealth.dead);
      RealtimeStatus.publish('k', RealtimeHealth.joining);
      expect(RealtimeStatus.worst.value, RealtimeHealth.dead);
      RealtimeStatus.publish('k', RealtimeHealth.retrying);
      expect(RealtimeStatus.worst.value, RealtimeHealth.dead);
      RealtimeStatus.publish('k', RealtimeHealth.joined);
      expect(RealtimeStatus.worst.value, RealtimeHealth.joined);
    });

    test('one key can be asked about on its own', () {
      // The chat's strip speaks for the chat. Reading the app-wide worst made
      // it announce a refused channel on a screen the user is not even on.
      final chat = RealtimeStatus.of('chat:c1');
      RealtimeStatus.publish('rewrap:c1', RealtimeHealth.dead);
      expect(RealtimeStatus.worst.value, RealtimeHealth.dead);
      expect(chat.value, RealtimeHealth.joined);
      RealtimeStatus.publish('chat:c1', RealtimeHealth.dead);
      expect(chat.value, RealtimeHealth.dead);
    });

    test('the registry carries the WORST, not the last', () {
      RealtimeStatus.publish('messages', RealtimeHealth.joined);
      RealtimeStatus.publish('receipts', RealtimeHealth.dead);
      RealtimeStatus.publish('reactions', RealtimeHealth.joined);
      // A receipt channel that is dead while the message channel is fine is
      // still a broken chat.
      expect(RealtimeStatus.worst.value, RealtimeHealth.dead);
      expect(RealtimeStatus.deadCount, 1);
    });

    test('a recovery is reflected, and so is a disposal', () {
      RealtimeStatus.publish('a', RealtimeHealth.dead);
      RealtimeStatus.publish('b', RealtimeHealth.retrying);
      expect(RealtimeStatus.worst.value, RealtimeHealth.dead);
      RealtimeStatus.publish('a', RealtimeHealth.joined);
      expect(RealtimeStatus.worst.value, RealtimeHealth.retrying);
      RealtimeStatus.forget('b');
      expect(RealtimeStatus.worst.value, RealtimeHealth.joined);
    });

    test('a couple ending takes its topics with it', () {
      // The keys are couple-scoped. A `dead` left behind would show the next
      // account a permanent warning about a channel that no longer exists.
      RealtimeStatus.publish('chat:old-couple', RealtimeHealth.dead);
      RealtimeStatus.reset();
      expect(RealtimeStatus.worst.value, RealtimeHealth.joined);
      final session = File('lib/core/app/session_provider.dart')
          .readAsStringSync();
      expect(session, contains('RealtimeStatus.reset()'));
    });

    test('the worst order is joining < joined < retrying < dead', () {
      // The enum's ORDER is the comparison. Reordering it silently changes
      // which state wins.
      expect(RealtimeHealth.values.map((e) => e.name).toList(),
          ['joining', 'joined', 'retrying', 'dead'],);
    });
  });

  group('a subscription out of attempts is parked, not abandoned', () {
    test('ManagedSubscription retries after a minute instead of returning', () {
      final verify = rt.substring(rt.indexOf('void _verifyJoin() {'));
      final dead = verify.indexOf("_publish(RealtimeHealth.dead)");
      expect(dead, greaterThan(-1));
      final park = verify.indexOf('_parked');
      expect(park, greaterThan(dead),
          reason: 'the give-up used to be the end of it',);
      expect(rt, contains('static const _parked = Duration(seconds: 60);'));
      expect(verify.substring(park, park + 200), contains('_rand.nextInt'),
          reason: 'a rate limiter that refused the whole fleet at once must '
              'not be met by the whole fleet again on one schedule',);
    });

    test('every rung of the ladder is published', () {
      expect(rt, contains('_publish(RealtimeHealth.joining)'));
      expect(rt, contains('_publish(RealtimeHealth.joined)'));
      expect(rt, contains('_publish(RealtimeHealth.retrying)'));
      final dispose = rt.substring(rt.indexOf('void dispose() {'));
      expect(dispose, contains('RealtimeStatus.forget'),
          reason: 'a disposed screen must not leave a permanent warning',);
    });
  });

  group('the chat verifies its own joins', () {
    // Its four channels are hand-rolled and do not go through
    // ManagedSubscription, so nothing ever checked whether they LANDED — and a
    // refused join is not retried by the client library at all.
    final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();

    test('the receipt channel counts, because the tick has no other path', () {
      // _expectedTopics was a const 2 covering messages and the broadcast, and
      // its comment claimed receipts were counted. Nothing counted them — so
      // the one channel this file calls "the only live path by which the
      // sender's tick ever advances" could be refused with the chat reporting
      // itself perfectly healthy.
      expect(chat, contains('_requiredTopics = partnerId != null ? 3 : 2;'));
      expect(chat, contains("_joinedTopics.add('receipts')"));
      expect(chat, contains('_joinedTopics.length >= _requiredTopics'));
    });

    test('a join that did not land is retried, then parked', () {
      expect(chat, contains('void _armJoinCheck()'));
      final check = chat.substring(chat.indexOf('void _armJoinCheck()'));
      expect(check.substring(0, 2500), contains('Duration(seconds: 12)'),
          reason: 'longer than the client\'s own 10s join timeout',);
      expect(check.substring(0, 2500), contains('Duration(seconds: 60)'));
      expect(check.substring(0, 2500), contains('RealtimeHealth.dead'));
      expect(chat, contains('_armJoinCheck();'),
          reason: 'and it has to actually be armed after subscribing',);
    });

    test('the screen says so, and only when it has really stopped', () {
      expect(chat, contains('_LiveUpdatesStrip'));
      final strip = chat.substring(chat.indexOf('class _LiveUpdatesStrip'));
      expect(strip, contains('health != RealtimeHealth.dead'),
          reason: 'retrying is what a tunnel produces several times a day; a '
              'banner for it is noise',);
      expect(strip, contains('Live updates paused'));
      expect(strip, contains('RealtimeStatus.of(healthKey)'),
          reason: 'this strip speaks for THIS chat, not for every channel in '
              'the app',);
    });

    test('Settings answers the same question when the chat is closed', () {
      final settings = File('lib/features/settings/settings_screen.dart')
          .readAsStringSync();
      expect(settings, contains('RealtimeStatus.worst'));
      expect(settings, contains("title: 'Live updates paused'"));
    });
  });
}
