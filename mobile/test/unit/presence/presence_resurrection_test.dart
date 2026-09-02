import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/server_clock.dart';

/// A partner who was force-killed came BACK.
///
/// The socket's leave hint switched the avatar off at ~2s — and the next row
/// the database handed the notifier switched it on again: the dead partner's
/// own row, `is_online:true` with a stamp seconds old, refetched every time
/// any event touched the couple's presence channel (the reader's own 30s
/// heartbeat is enough). Measured on the OnePlus 8, BRAIN §250: offline at
/// +4s, online at +22s and +38s, gone for good only at the 45s decay.
///
/// [PresenceService.reconcile] is the one rule that stops it: a row may only
/// win against a hint by carrying activity NEWER than the hint.
void main() {
  setUp(ServerClock.reset);
  tearDown(ServerClock.reset);

  DateTime ago(int seconds) =>
      DateTime.now().toUtc().subtract(Duration(seconds: seconds));

  Presence row({required bool isOnline, required DateTime activeAt}) =>
      Presence.fromJson({
        'user_id': 'partner-1',
        'is_online': isOnline,
        'updated_at': activeAt.toIso8601String(),
        'app_last_active_at': activeAt.toIso8601String(),
        'current_screen': 'Chat',
      });

  group('a leave hint outlives the rows written before it', () {
    test("the killed partner's own fresh row cannot resurrect them", () {
      // Their last heartbeat landed 20s ago; the socket saw them die 18s ago.
      final beat = ago(20);
      final left = (online: false, at: ago(18));
      final p = PresenceService.reconcile(
        row(isOnline: true, activeAt: beat),
        left,
      )!;
      expect(p.isTrulyOnline, isFalse,
          reason: 'the row is older than the leave — nothing new happened',);
      expect(p.currentScreen, 'Chat',
          reason: 'only liveness moves; the rest of the row is kept',);
    });

    test('activity newer than the leave means they came back', () {
      final left = (online: false, at: ago(18));
      final p = PresenceService.reconcile(
        row(isOnline: true, activeAt: ago(3)),
        left,
      )!;
      expect(p.isTrulyOnline, isTrue,
          reason: 'they wrote something 15s after the socket said goodbye',);
    });
  });

  group('an arrival hint outlives the stale rows around it', () {
    test('a row from before the arrival still reads online', () {
      // The DB still says "last active 2 minutes ago" — the join landed first.
      final joined = (online: true, at: ago(1));
      final p = PresenceService.reconcile(
        row(isOnline: true, activeAt: ago(120)),
        joined,
      )!;
      expect(p.isTrulyOnline, isTrue);
      expect(p.appLastActiveAt, joined.at,
          reason: 'the hint moved the clock the 45s window reads',);
    });
  });

  test('no hint, no change', () {
    final r = row(isOnline: true, activeAt: ago(5));
    expect(identical(PresenceService.reconcile(r, null), r), isTrue);
    expect(PresenceService.reconcile(null, (online: false, at: ago(1))),
        isNull,);
  });
}
