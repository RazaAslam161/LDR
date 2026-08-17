import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/server_clock.dart';

/// Presence could only ever DECAY, never switch.
///
/// The foreground heartbeat re-stamps `app_last_active_at` every 30s and
/// [Presence.isTrulyOnline] called it fresh for 45s. So at the moment a phone
/// was put down the stamp was already 0-30s old and kept testing fresh for
/// another 15-45s: the partner's avatar held "Online" for 45-75 seconds after
/// they had gone, then jumped straight to "1 minute ago". main.dart had always
/// written `is_online:false` on the way out and no reader had ever looked at it.
///
/// It is read now, one way only: a false flag may push the partner offline, a
/// true one may never pull them online — because a force-kill leaves the flag
/// true on the row forever and the 45s window is the only thing that catches
/// that. These prove both directions, and the ordering guard that keeps a
/// goodbye from outliving the activity that followed it.
void main() {
  setUp(ServerClock.reset);
  tearDown(ServerClock.reset);

  DateTime ago(int seconds) =>
      DateTime.now().toUtc().subtract(Duration(seconds: seconds));

  /// Built through fromJson, not the constructor: the parse is part of what is
  /// under test (updated_at is parsed local, app_last_active_at UTC, and the
  /// comparison between them has to survive that).
  Presence row({
    required bool isOnline,
    required DateTime updatedAt,
    DateTime? appActiveAt,
  }) =>
      Presence.fromJson({
        'user_id': 'partner-1',
        'is_online': isOnline,
        'updated_at': updatedAt.toIso8601String(),
        'app_last_active_at': appActiveAt?.toIso8601String(),
      });

  group('an explicit goodbye switches the avatar off', () {
    test('backgrounding reads offline at once, not 45-75s later', () {
      // The heartbeat fired 5s before the user left, so the freshness window
      // alone still says "online" — that is exactly the reported bug.
      final beat = ago(5);
      final p = row(isOnline: false, updatedAt: ago(1), appActiveAt: beat);

      expect(p.saidGoodbye, isTrue);
      expect(p.isTrulyOnline, isFalse,
          reason: 'the app said it was leaving one second ago',);
      expect(ServerClock.now().difference(beat).inSeconds, lessThan(45),
          reason: 'proves freshness alone would still have said online',);
    });

    test('the last-seen line is honest rather than a claim of being online',
        () {
      final p = row(isOnline: false, updatedAt: ago(1), appActiveAt: ago(5));
      expect(p.lastSeenText, 'Just now');
    });

    test('being in the chat cannot outlive the app', () {
      final p = Presence.fromJson({
        'user_id': 'partner-1',
        'is_online': false,
        'typing_in_chat': true,
        'updated_at': ago(1).toIso8601String(),
        'app_last_active_at': ago(5).toIso8601String(),
      });
      expect(p.isActivelyInChat, isFalse);
    });
  });

  group('freshness stays the backstop for an exit with no goodbye', () {
    test('a force-kill leaves the flag true and the window catches it', () {
      // Nothing wrote false — the process died. Only the stale stamp knows.
      final p = row(isOnline: true, updatedAt: ago(60), appActiveAt: ago(60));
      expect(p.saidGoodbye, isFalse);
      expect(p.isTrulyOnline, isFalse);
    });

    test('a true flag can never pull a stale row back online', () {
      final p = row(isOnline: true, updatedAt: ago(200), appActiveAt: ago(200));
      expect(p.isTrulyOnline, isFalse,
          reason: 'is_online:true is never evidence of anything',);
    });

    test('an ordinary foreground heartbeat still reads online', () {
      final beat = ago(10);
      final p = row(isOnline: true, updatedAt: beat, appActiveAt: beat);
      expect(p.saidGoodbye, isFalse);
      expect(p.isTrulyOnline, isTrue);
    });

    test('the 45s window is unchanged either side of the edge', () {
      expect(row(isOnline: true, updatedAt: ago(44), appActiveAt: ago(44))
          .isTrulyOnline, isTrue,);
      expect(row(isOnline: true, updatedAt: ago(46), appActiveAt: ago(46))
          .isTrulyOnline, isFalse,);
    });
  });

  group('a goodbye never outlives the activity that followed it', () {
    test('activity newer than the goodbye wins', () {
      // Real sequence: the user backgrounds (is_online:false at T1), comes
      // back, and the setOnline(true) write is the one that fails — but
      // setTypingInChat / setMood / setScreen all stamp app_last_active_at
      // WITHOUT touching is_online. Without this guard the flag would strand a
      // partner offline while they sat in the chat typing.
      final p = row(isOnline: false, updatedAt: ago(30), appActiveAt: ago(2));
      expect(p.saidGoodbye, isFalse,
          reason: 'they did something after saying goodbye',);
      expect(p.isTrulyOnline, isTrue);
    });

    test('a GPS ping after the goodbye does not resurrect them', () {
      // Location upserts bump updated_at and deliberately never stamp
      // app_last_active_at, so the goodbye stays the newest app fact.
      final p = row(isOnline: false, updatedAt: ago(1), appActiveAt: ago(20));
      expect(p.saidGoodbye, isTrue);
      expect(p.isTrulyOnline, isFalse,
          reason: 'a phone reporting its position is not a person using the app',
      );
    });

    test('a goodbye stamped at the same instant as the activity counts', () {
      // The pause write can share a millisecond with the beat that preceded it.
      final t = ago(3);
      final p = row(isOnline: false, updatedAt: t, appActiveAt: t);
      expect(p.saidGoodbye, isTrue);
    });
  });

  group('a row with nothing to go on stays offline', () {
    test('no activity stamp at all', () {
      final p = row(isOnline: false, updatedAt: ago(1));
      expect(p.isTrulyOnline, isFalse);
      expect(p.saidGoodbye, isFalse,
          reason: 'there is no activity to compare the goodbye against',);
    });

    test('a flag with no timestamps decides nothing on its own', () {
      final p = Presence.fromJson({'user_id': 'partner-1', 'is_online': false});
      expect(p.saidGoodbye, isFalse);
      expect(p.isTrulyOnline, isFalse);
    });
  });
}
