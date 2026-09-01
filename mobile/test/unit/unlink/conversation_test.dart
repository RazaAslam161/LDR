import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/unlink/scene/conversation.dart';

/// The conversation is arithmetic, and arithmetic is testable: the line on
/// screen at any moment is a pure function of elapsed time against the gate
/// window. These pin the properties the design leans on — resume, pacing,
/// gate alignment, determinism — without a widget in sight.
void main() {
  const window = Duration(minutes: 15);

  group('visibleExchanges', () {
    test('opens in silence — nothing has been said at t=0', () {
      expect(
        visibleExchanges(birdScript, elapsed: Duration.zero, window: window),
        isEmpty,
      );
    });

    test('the first hello lands early, not at once', () {
      // The bird lands at 15s. At 10s the step is still quiet.
      expect(
        visibleExchanges(birdScript,
            elapsed: const Duration(seconds: 10), window: window,),
        isEmpty,
      );
      final at20 = visibleExchanges(birdScript,
          elapsed: const Duration(seconds: 20), window: window,);
      expect(at20, hasLength(1));
      expect(at20.single.line, "Oh. Someone's on my step.");
      expect(at20.single.speaker, Speaker.companion);
    });

    test('resume mid-window shows exactly where the talk truly is', () {
      // Minute 12 of 15 = t=0.80, which lands in the quiet after beat five.
      // The newest thing said is that beat's closer — NOT whatever a
      // metronome would have reached, because the script is no longer one.
      final lines = visibleExchanges(birdScript,
          elapsed: const Duration(minutes: 12), window: window,);
      expect(lines, hasLength(3));
      // 0.80 * 900s = 720s, inside the cluster that runs 640-762s: the
      // newest thing said is the character's, at 714s.
      expect(lines.last.at, 0.7933);
      expect(lines.last.line, 'Like what?');
      expect(lines.last.speaker, Speaker.character);
      // And the identical call returns the identical answer — resume IS
      // recompute.
      expect(
        visibleExchanges(birdScript,
            elapsed: const Duration(minutes: 12), window: window,),
        lines,
      );
    });

    test('the handover line lands exactly at the gate, in every window', () {
      for (final w in [window, const Duration(minutes: 5), const Duration(minutes: 24)]) {
        final justBefore = visibleExchanges(birdScript,
            elapsed: w - const Duration(seconds: 1), window: w,);
        expect(justBefore.last.at, lessThan(1.0),
            reason: 'the choice must not be handed over before it exists',);
        final atGate = visibleExchanges(birdScript, elapsed: w, window: w);
        expect(atGate.last.at, 1.0);
        expect(atGate.last.line, contains('choose'));
      }
    });

    test('a zero window says nothing rather than everything', () {
      expect(
        visibleExchanges(birdScript,
            elapsed: const Duration(minutes: 1), window: Duration.zero,),
        isEmpty,
      );
    });

    test('both scripts end on a companion handover and blame nobody', () {
      for (final script in [birdScript, catScript]) {
        expect(script.last.at, 1.0);
        expect(script.last.speaker, Speaker.companion);
        for (final e in script) {
          // The app authors no verdicts and never names its own chrome.
          for (final banned in ['fault', 'blame', 'button', 'unlink', 'app']) {
            expect(e.line.toLowerCase(), isNot(contains(banned)),
                reason: '"${e.line}" says "$banned"',);
          }
        }
      }
    });

    test('fractions are ordered — a script cannot speak out of turn', () {
      for (final script in [birdScript, catScript]) {
        for (var i = 1; i < script.length; i++) {
          expect(script[i].at, greaterThan(script[i - 1].at));
        }
      }
    });
  });

  group('companionshipLine', () {
    test('speaks at the top of each slot, then keeps quiet company', () {
      expect(
        companionshipLine(birdCompanionship,
            sinceGate: const Duration(seconds: 10),),
        birdCompanionship.first,
      );
      expect(
        companionshipLine(birdCompanionship,
            sinceGate: const Duration(minutes: 10),),
        isNull,
      );
      expect(
        companionshipLine(birdCompanionship,
            sinceGate: const Duration(minutes: 25, seconds: 5),),
        birdCompanionship[1],
      );
    });

    test('deterministic: both phones, any restart, same slot, same line', () {
      const t = Duration(minutes: 50, seconds: 12);
      expect(
        companionshipLine(catCompanionship, sinceGate: t),
        companionshipLine(catCompanionship, sinceGate: t),
      );
    });

    test('wraps the pool for the long night, never runs dry', () {
      final line = companionshipLine(
        catCompanionship,
        sinceGate: Duration(minutes: 25 * (catCompanionship.length + 2)) +
            const Duration(seconds: 5),
      );
      expect(line, catCompanionship[2 % catCompanionship.length]);
    });

    test('before the gate there is no companionship mode at all', () {
      expect(
        companionshipLine(birdCompanionship,
            sinceGate: const Duration(seconds: -30),),
        isNull,
      );
    });
  });

  group('liveness', () {
    // THE COMPLAINT THIS FILE EXISTS FOR: "conversation is too slow, it
    // doesn't even look like that conversation is going on between them."
    // It was true. Twenty-one lines across fifteen minutes is one utterance
    // every forty-five seconds, which is not a conversation at any speed.
    //
    // So this walks the ENTIRE window a second at a time and asks the only
    // question that matters: how often does what is on the stage change, and
    // what is the longest anyone stares at something that does not?
    const window = Duration(minutes: 15);

    for (final (name, script) in [
      ('bird', birdScript),
      ('cat', catScript),
    ]) {
      test('$name keeps the stage moving for the whole fifteen minutes', () {
        expect(script.length, greaterThanOrEqualTo(60),
            reason: '$name has ${script.length} lines; a fifteen-minute '
                'conversation cannot be carried by fewer',);

        String? shown;
        var changes = 0;
        var still = 0;
        var worstStill = 0;
        for (var sec = 0; sec <= 900; sec++) {
          final now = visibleExchanges(
            script,
            elapsed: Duration(seconds: sec),
            window: window,
            within: spokenLinger,
          );
          final newest = now.isEmpty ? null : now.last.line;
          if (newest != shown) {
            shown = newest;
            changes++;
            still = 0;
          } else {
            still++;
            if (still > worstStill) worstStill = still;
          }
        }

        expect(changes, greaterThanOrEqualTo(65),
            reason: '$name changed the stage only $changes times in fifteen '
                'minutes',);
        expect(worstStill, lessThanOrEqualTo(90),
            reason: '$name leaves the same thing on screen for $worstStill '
                'seconds — that stretch is what reads as a frozen app',);
      });

      test('$name never leaves a stale line standing', () {
        // A line used to hang on the stage through the whole lull after it,
        // so two sentences from different minutes sat there like labels. A
        // said thing is visible for `spokenLinger` and then the quiet has it.
        for (var sec = 0; sec <= 900; sec += 5) {
          final now = visibleExchanges(
            script,
            elapsed: Duration(seconds: sec),
            window: window,
            within: spokenLinger,
          );
          for (final e in now) {
            final saidAt = e.at * 900;
            expect(sec - saidAt, lessThanOrEqualTo(spokenLinger.inSeconds),
                reason: '$name still showing "${e.line}" at ${sec}s, said at '
                    '${saidAt.round()}s',);
          }
        }
      });

      test('$name talks in clusters, not on a metronome', () {
        var quick = 0;
        for (var i = 1; i < script.length; i++) {
          final gap = (script[i].at - script[i - 1].at) * 900;
          expect(gap, greaterThan(0),
              reason: '$name line $i runs backwards in time',);
          if (gap <= 15) quick++;
        }
        expect(quick / (script.length - 1), greaterThan(0.75),
            reason: '$name is mostly waiting; people answer each other',);
        expect(script.last.at, 1.0,
            reason: 'the handover must land ON the gate',);
      });
    }
  });

  group('pendingSpeaker', () {
    const window = Duration(minutes: 15);

    test('leans forward just before a line, and not otherwise', () {
      // The bird's first line lands at 15s; two seconds out, it is coming.
      expect(
        pendingSpeaker(birdScript,
            elapsed: const Duration(seconds: 13), window: window,),
        Speaker.companion,
      );
      // Deep in a silence, nobody is about to say anything — the stillness
      // is the scene, not a stall.
      expect(
        pendingSpeaker(birdScript,
            elapsed: const Duration(minutes: 4), window: window,),
        isNull,
      );
    });

    test('a zero window leans nowhere', () {
      expect(
        pendingSpeaker(birdScript,
            elapsed: const Duration(minutes: 1), window: Duration.zero,),
        isNull,
      );
    });
  });
}
