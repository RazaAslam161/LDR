import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ceremony row's client-side reading, without a database.
void main() {
  const a = 'aaaaaaaa-0000-0000-0000-000000000001';
  const b = 'bbbbbbbb-0000-0000-0000-000000000002';

  Map<String, dynamic> row({
    String state = 'cooling',
    String cooling = '2026-09-05T00:00:00Z',
    String? lastLook,
    String? noteCipher,
    String? noteNonce,
  }) =>
      {
        'couple_id': 'cccccccc-0000-0000-0000-000000000003',
        'initiated_by': a,
        'state': state,
        'started_at': '2026-08-29T00:00:00Z',
        'cooling_ends_at': cooling,
        'last_look_ends_at': lastLook,
        'accepted_at': null,
        'note_cipher': noteCipher,
        'note_nonce': noteNonce,
        'note_author': noteCipher == null ? null : b,
        'note_updated_at': null,
      };

  tearDown(UnlinkState.reset);

  test('a cooling row parses, with the cooling deadline as the deadline', () {
    UnlinkState.applyRow(row());
    final r = UnlinkState.current.value!;
    expect(r.state, 'cooling');
    expect(r.accepted, isFalse);
    expect(r.endsAt, DateTime.utc(2026, 9, 5));
    expect(r.iAmInitiator(a), isTrue);
    expect(r.iAmInitiator(b), isFalse);
    expect(r.hasNote, isFalse);
  });

  test('accepting swaps the deadline to the clamped last look', () {
    UnlinkState.applyRow(
        row(state: 'last_look', lastLook: '2026-08-30T00:00:00Z'),);
    final r = UnlinkState.current.value!;
    expect(r.accepted, isTrue);
    expect(r.endsAt, DateTime.utc(2026, 8, 30),
        reason: 'the effective deadline is always '
            'coalesce(last_look, cooling)',);
  });

  test('the note halves ride together', () {
    UnlinkState.applyRow(row(noteCipher: r'\xdeadbeef', noteNonce: r'\x01'));
    expect(UnlinkState.current.value!.hasNote, isTrue);
  });

  test('a malformed row shows NOTHING rather than a broken ceremony', () {
    UnlinkState.applyRow({'couple_id': 42});
    expect(UnlinkState.current.value, isNull);
  });

  test('reset clears — sign-out must not describe the last account', () {
    UnlinkState.applyRow(row());
    UnlinkState.reset();
    expect(UnlinkState.current.value, isNull);
  });

  group('due is read off the server clock, never this handset', () {
    // The deadline was computed by Postgres, so the comparison has to be too.
    // Deadlines here are relative to now, not the fixture's fixed date: a
    // fixed one makes both of these invert the day it passes.
    tearDown(ServerClock.reset);

    test('a deadline the server has not reached yet is not due', () {
      // A handset running an hour fast. Its own clock is already past the
      // deadline, and executing on that reading ends the couple an hour
      // early — the whole reason the offset exists.
      ServerClock.setOffsetForTest(const Duration(hours: -1));
      UnlinkState.applyRow(
        row(
          cooling: DateTime.now()
              .toUtc()
              .subtract(const Duration(minutes: 30))
              .toIso8601String(),
        ),
      );
      expect(UnlinkState.current.value!.due, isFalse);
    });

    test('a deadline the server has passed is due', () {
      // The mirror: a handset running an hour slow must not hold the ceremony
      // open past the moment the server would accept execute().
      ServerClock.setOffsetForTest(const Duration(hours: 1));
      UnlinkState.applyRow(
        row(
          cooling: DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 30))
              .toIso8601String(),
        ),
      );
      expect(UnlinkState.current.value!.due, isTrue);
    });

    test('the accepted deadline is the one measured', () {
      ServerClock.setOffsetForTest(const Duration(hours: 1));
      UnlinkState.applyRow(
        row(
          state: 'last_look',
          cooling: DateTime.now()
              .toUtc()
              .add(const Duration(days: 2))
              .toIso8601String(),
          lastLook: DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 30))
              .toIso8601String(),
        ),
      );
      expect(UnlinkState.current.value!.due, isTrue,
          reason: 'coalesce(last_look, cooling) is the effective deadline on '
              'this side too',);
    });
  });
}
