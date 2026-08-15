import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/features/safety/contact_pause.dart';

/// A timed pause is a comparison between an expiry the SERVER computed and
/// "now". Taking "now" from the handset is the bug ServerClock was written for:
/// a phone whose clock runs an hour fast lifts an eight-hour pause after seven,
/// and the person who asked for quiet gets rung anyway.
///
/// So every case here moves the clock rather than waiting.
void main() {
  String isoIn(Duration d) =>
      ServerClock.now().add(d).toIso8601String();

  setUp(() {
    ServerClock.reset();
    ContactPause.reset();
  });

  tearDown(ServerClock.reset);

  test('no row means no pause', () {
    ContactPause.applyRow(null);
    expect(ContactPause.isActive, isFalse);
    expect(ContactPause.active.value, isFalse);
  });

  test('a row with no expiry is a pause until it is lifted', () {
    ContactPause.applyRow({'expires_at': null});
    expect(ContactPause.isActive, isTrue);
    expect(ContactPause.expiresAt, isNull);

    // And it does not decay: a week of clock drift changes nothing.
    ServerClock.setOffsetForTest(const Duration(days: 7));
    expect(ContactPause.isActive, isTrue);
  });

  test('a timed pause is active before its expiry', () {
    ContactPause.applyRow({'expires_at': isoIn(const Duration(hours: 1))});
    expect(ContactPause.isActive, isTrue);
  });

  test('a timed pause has lapsed once the SERVER clock passes it', () {
    ContactPause.applyRow({'expires_at': isoIn(const Duration(hours: 1))});
    expect(ContactPause.isActive, isTrue);

    // Not a sleep and not DateTime.now(): the server is now two hours ahead of
    // where it was when the row was written.
    ServerClock.setOffsetForTest(const Duration(hours: 2));
    expect(ContactPause.isActive, isFalse);
  });

  test('a handset clock running fast does not lift the pause early', () {
    // The row says one hour. This device thinks it is 90 minutes later than
    // the server does — but the offset corrects for exactly that, so the pause
    // is still on until the SERVER passes the hour.
    final expires = ServerClock.now().add(const Duration(hours: 1));
    ServerClock.setOffsetForTest(const Duration(minutes: -90));
    ContactPause.applyRow({'expires_at': expires.toIso8601String()});

    expect(ContactPause.isActive, isTrue,
        reason: 'the pause lapsed on device time rather than server time',);
  });

  test('an expiry written in a non-UTC offset is read as the same instant', () {
    // Postgres hands PostgREST a timestamptz, and what lands in the JSON is
    // not guaranteed to be Z-suffixed. Parsed without normalising, a +05:00
    // expiry reads five hours late and the pause outlives its own duration.
    ContactPause.applyRow({'expires_at': '2026-08-16T10:00:00+05:00'});
    expect(ContactPause.expiresAt,
        DateTime.utc(2026, 8, 16, 5),);
  });

  test('reset clears the pause, so it cannot outlive a sign-out', () {
    ContactPause.applyRow({'expires_at': null});
    expect(ContactPause.isActive, isTrue);

    ContactPause.reset();

    expect(ContactPause.isActive, isFalse);
    expect(ContactPause.active.value, isFalse);
  });

  test('the umbrella kind is what the server reads', () {
    // push_muted matches `kind in (p_kind, 'contact')`. A different string
    // here writes a row nothing ever consults.
    expect(ContactPause.kind, 'contact');
  });
}
