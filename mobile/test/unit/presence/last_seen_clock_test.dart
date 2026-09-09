import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/services/presence_service.dart';

/// Home shows the HOUR the partner was last here; chat's AppBar shows the age.
/// Both read app_last_active_at, and this file exists because Home did not.
///
/// It printed `last_seen`, a column that moves only on a real online CLAIM, so
/// on any day the app was left open the clock time was the moment she first
/// came online rather than the moment she was last there — and it carried no
/// day, so a stamp from last week read as this morning.
void main() {
  /// Local DateTimes on purpose: `.toLocal()` is then a no-op and the expected
  /// strings are identical on any machine, so the day rules are what is under
  /// test rather than this laptop's zone.
  ///
  /// Pinned to a WEDNESDAY IN THE PAST, and that is load-bearing. `now` is
  /// injectable but [Presence.isTrulyOnline] is not — it reads ServerClock —
  /// so a fixture stamped later today would test as live and return null. It
  /// stays in the past for good, because real time only moves away from it.
  Presence at(DateTime active, {DateTime? lastSeen}) => Presence(
        userId: 'her',
        appLastActiveAt: active,
        lastSeen: lastSeen,
      );

  final now = DateTime(2026, 9, 2, 14, 30);

  test('today is the bare hour, which is the shape Home asked for', () {
    expect(at(DateTime(2026, 9, 2, 10, 12)).lastSeenClock(now: now),
        'Last seen 10:12 AM',);
  });

  test('yesterday says so, rather than passing for this morning', () {
    expect(at(DateTime(2026, 9, 1, 10, 12)).lastSeenClock(now: now),
        'Last seen yesterday 10:12 AM',);
  });

  test('inside the week names the day', () {
    // 2026-08-30 is a Sunday, three days before the Wednesday above.
    expect(at(DateTime(2026, 8, 30, 22, 5)).lastSeenClock(now: now),
        'Last seen Sun 10:05 PM',);
  });

  test('older than a week carries the date', () {
    expect(at(DateTime(2026, 8, 23, 7, 41)).lastSeenClock(now: now),
        'Last seen 23 Aug 7:41 AM',);
  });

  test('the boundary is the CALENDAR day, not elapsed hours', () {
    // Twenty minutes earlier, and still yesterday. Counting hours would call
    // this "today" and put last night's activity on this morning's card.
    expect(
        at(DateTime(2026, 9, 1, 23, 50))
            .lastSeenClock(now: DateTime(2026, 9, 2, 0, 10)),
        'Last seen yesterday 11:50 PM',);
  });

  test('a stamp ahead of this clock is skew, not the future', () {
    expect(
        at(DateTime(2026, 9, 2, 14, 35))
            .lastSeenClock(now: DateTime(2026, 9, 2, 14, 30)),
        'Last seen 2:35 PM',);
  });

  test('nothing to show says Offline, never a made-up hour', () {
    expect(Presence(userId: 'her').lastSeenClock(now: now), 'Offline');
  });

  test('online returns null so the caller can say Online', () {
    final live = Presence(
      userId: 'her',
      isOnline: true,
      appLastActiveAt: DateTime.now().toUtc(),
    );
    expect(live.isTrulyOnline, isTrue, reason: 'the fixture must be live');
    expect(live.lastSeenClock(), isNull);
  });

  test('a UTC stamp is rendered in the reader local time', () {
    // Production parses app_last_active_at as UTC. Dropping the .toLocal()
    // would print the UTC hour, which is five hours out where this is used.
    final utc = DateTime.utc(2026, 9, 2, 5, 12);
    expect(at(utc).lastSeenClock(now: now),
        contains(DateFormat('h:mm a').format(utc.toLocal())),);
  });

  test('THE DEFECT: the hour follows app_last_active_at, not last_seen', () {
    // She came online at 09:00 and was still there at 13:45. `last_seen` holds
    // the claim; app_last_active_at holds the truth. Home used to print
    // 9:00 AM and call it her last seen.
    final p = at(DateTime(2026, 9, 2, 13, 45),
        lastSeen: DateTime(2026, 9, 2, 9),);
    expect(p.lastSeenClock(now: now), 'Last seen 1:45 PM');
    expect(p.lastSeenClock(now: now), isNot(contains('9:00')));
  });
}
