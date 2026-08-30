import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The Doorstep's brain, proven without a stage.
///
/// Every rule here is a way the scene could lie: replay the slam on a cold
/// start, play one letter twice, keep performing a story the server already
/// ended. The mapper and the sequencer are pure so a test can walk a whole
/// ceremony through them and check what would have played.
void main() {
  const initiator = 'aaaaaaaa-0000-0000-0000-000000000001';

  UnlinkRow row({
    DateTime? started,
    String state = 'cooling',
    DateTime? lastLook,
    String? noteCipher,
    DateTime? noteUpdated,
  }) {
    final s = started ?? DateTime.utc(2026, 8, 30, 12);
    return UnlinkRow(
      coupleId: 'c1',
      initiatedBy: initiator,
      state: state,
      startedAt: s,
      coolingEndsAt: s.add(const Duration(hours: 24)),
      lastLookEndsAt: lastLook,
      acceptedAt: null,
      relinkOpensAt: s.add(const Duration(minutes: 15)),
      partnerGateOpensAt: s.add(const Duration(minutes: 15)),
      noteCipherBytea: noteCipher,
      noteNonceBytea: noteCipher == null ? null : r'\x01',
      noteAuthor: null,
      noteUpdatedAt: noteUpdated,
    );
  }

  group('the mapper', () {
    test('a fresh tap slams; a cold start hours later never does', () {
      final started = DateTime.utc(2026, 8, 30, 12);
      final fresh = SceneModel.of(
        row(started: started),
        role: SceneRole.outside,
        slamPlayed: false,
        now: started.add(const Duration(seconds: 5)),
      );
      expect(fresh.slamFresh, isTrue);

      final coldStart = SceneModel.of(
        row(started: started),
        role: SceneRole.outside,
        slamPlayed: false,
        now: started.add(const Duration(hours: 6)),
      );
      expect(coldStart.slamFresh, isFalse,
          reason: 'six hours in, the street opens settled — nobody replays '
              'the worst moment of the day',);

      final latched = SceneModel.of(
        row(started: started),
        role: SceneRole.outside,
        slamPlayed: true,
        now: started.add(const Duration(seconds: 5)),
      );
      expect(latched.slamFresh, isFalse,
          reason: 'the latch outranks freshness — once per ceremony, ever',);
    });

    test('dawn walks from 0 to 1 across the window and clamps past it', () {
      final started = DateTime.utc(2026, 8, 30, 12);
      double dawnAt(Duration after) => SceneModel.of(
            row(started: started),
            role: SceneRole.outside,
            slamPlayed: true,
            now: started.add(after),
          ).dawn;
      expect(dawnAt(Duration.zero), 0);
      expect(dawnAt(const Duration(hours: 12)), closeTo(0.5, 0.01));
      expect(dawnAt(const Duration(hours: 30)), 1,
          reason: 'past the deadline the sky holds at pre-dawn, it does not '
              'wrap or overshoot',);
    });

    test("the handle glow is the outside view's alone", () {
      final started = DateTime.utc(2026, 8, 30, 12);
      final at20 = started.add(const Duration(minutes: 20));
      final outside = SceneModel.of(
        row(started: started),
        role: SceneRole.outside,
        slamPlayed: true,
        now: at20,
      );
      final inside = SceneModel.of(
        row(started: started),
        role: SceneRole.inside,
        slamPlayed: true,
        now: at20,
      );
      expect(outside.handleGlow, isTrue);
      expect(inside.handleGlow, isFalse);
      expect(inside.gateOpen, isTrue);
      expect(outside.gateOpen, isFalse);
    });
  });

  group('the sequencer', () {
    SceneModel model(
      UnlinkRow r, {
      SceneRole role = SceneRole.outside,
      bool slamPlayed = true,
      DateTime? now,
    }) =>
        SceneModel.of(r, role: role, slamPlayed: slamPlayed, now: now);

    test('first push of a fresh ceremony queues slam then speak, in order', () {
      final seq = BeatSequencer();
      final started = DateTime.utc(2026, 8, 30, 12);
      seq.push(model(
        row(started: started),
        slamPlayed: false,
        now: started.add(const Duration(seconds: 3)),
      ),);
      expect(seq.take()!.beat, SceneBeat.slam);
      expect(seq.take()!.beat, SceneBeat.speak);
      expect(seq.take(), isNull);
    });

    test('a cold start seeds settled: the quote speaks, no slam', () {
      final seq = BeatSequencer()..push(model(row()));
      expect(seq.take()!.beat, SceneBeat.speak);
      expect(seq.take(), isNull);
    });

    test('one letter plays once, however many rails deliver it', () {
      final at = DateTime.utc(2026, 8, 30, 13);
      final letter = model(row(noteCipher: r'\xdead', noteUpdated: at));
      final seq = BeatSequencer()
        ..push(model(row()))
        ..take() // speak
        // The write lands; then the same row arrives again via the 15s poll,
        // then again via realtime. One beat.
        ..push(letter)
        ..push(letter)
        ..push(letter);
      expect(seq.take()!.beat, SceneBeat.letter);
      expect(seq.take(), isNull,
          reason: 'a refetch and a broadcast of the same write collapse to '
              'ONE animation',);
    });

    test('a letter already resting on a cold start never replays its '
        'arrival', () {
      // An edge needs two samples. The first model of a mount that already
      // has a note is a letter RESTING on the doorstep, not one arriving —
      // reopening the app must not re-deliver an hour-old farewell.
      final seq = BeatSequencer()
        ..push(model(row(
          noteCipher: r'\xdead',
          noteUpdated: DateTime.utc(2026, 8, 30, 13),
        ),),);
      expect(seq.take()!.beat, SceneBeat.speak);
      expect(seq.take(), isNull,
          reason: 'the quote still speaks; the letter stays where it lay',);
    });

    test('a REPLACED letter is a new beat', () {
      final seq = BeatSequencer()
        ..push(model(row()))
        ..take() // speak
        ..push(model(row(
          noteCipher: r'\xdead',
          noteUpdated: DateTime.utc(2026, 8, 30, 13),
        ),),);
      expect(seq.take()!.beat, SceneBeat.letter);
      seq.push(model(row(
        noteCipher: r'\xbeef',
        noteUpdated: DateTime.utc(2026, 8, 30, 14),
      ),),);
      expect(seq.take()!.beat, SceneBeat.letter,
          reason: 'new note_updated_at, new identity, new performance',);
    });

    test('accepting queues the bolt exactly once', () {
      final started = DateTime.utc(2026, 8, 30, 12);
      final lastLook = row(
        started: started,
        state: 'last_look',
        lastLook: started.add(const Duration(minutes: 25)),
      );
      final seq = BeatSequencer()
        ..push(model(row(started: started)))
        ..take() // speak
        ..push(model(lastLook))
        ..push(model(lastLook)); // the poll re-delivers; no double bolt
      expect(seq.take()!.beat, SceneBeat.bolt);
      expect(seq.take(), isNull);
    });

    test('a world flip flushes beats queued for the street that is gone', () {
      final started = DateTime.utc(2026, 8, 30, 12);
      final seq = BeatSequencer()
        ..push(model(row(started: started)))
        ..take() // speak plays
        // A letter lands but has NOT been taken yet when the accept arrives —
        // the poll gap collapsed two events into one refetch cycle.
        ..push(model(row(
          started: started,
          noteCipher: r'\xdead',
          noteUpdated: DateTime.utc(2026, 8, 30, 13),
        ),),)
        ..push(model(row(
          started: started,
          state: 'last_look',
          lastLook: started.add(const Duration(minutes: 25)),
        ),),);
      // The flush dropped the letter; the bolt — the transition itself — is
      // queued fresh from the same diff.
      expect(seq.take()!.beat, SceneBeat.bolt);
      expect(seq.take(), isNull,
          reason: 'beats for a world that no longer exists never play over '
              'the new one',);
    });
  });

  group('the variant table', () {
    test('gender maps, and null casts the neutral figure', () {
      expect(puppetVariantOf('male'), PuppetVariant.male);
      expect(puppetVariantOf('female'), PuppetVariant.female);
      expect(puppetVariantOf(null), PuppetVariant.neutral,
          reason: 'gender is nullable in practice — role-setup has a '
              'sign-out escape — and the scene must cast somebody',);
      expect(puppetVariantOf('other'), PuppetVariant.neutral);
    });
  });
}
