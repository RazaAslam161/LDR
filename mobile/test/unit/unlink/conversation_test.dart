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
      // 0.02 of 15min = 18s. At 10s: nothing. At 20s: the bird has spoken.
      expect(
        visibleExchanges(birdScript,
            elapsed: const Duration(seconds: 10), window: window,),
        isEmpty,
      );
      final at20 = visibleExchanges(birdScript,
          elapsed: const Duration(seconds: 20), window: window,);
      expect(at20, hasLength(1));
      expect(at20.single.line, 'Hi.');
      expect(at20.single.speaker, Speaker.companion);
    });

    test('resume mid-window shows exactly where the talk truly is', () {
      // Minute 12 of 15 = t=0.80, which lands in the quiet after beat five.
      // The newest thing said is that beat's closer — NOT whatever a
      // metronome would have reached, because the script is no longer one.
      final lines = visibleExchanges(birdScript,
          elapsed: const Duration(minutes: 12), window: window,);
      expect(lines, hasLength(3));
      expect(lines.last.at, 0.713);
      expect(lines.last.line, "That's not nothing. Leaving looks different.");
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

  group('pacing', () {
    // THE LAW THE FIRST BUILD BROKE. Twenty-one lines spread evenly over
    // fifteen minutes put forty-five seconds of nothing between every pair,
    // and forty-five seconds of nothing between "I'm fine" and "Didn't ask"
    // does not read as two people talking — it reads as a frozen screen,
    // which is exactly how it was reported off the handset. Every gap must
    // be either conversational (people answering each other) or a real
    // silence (people sitting with it). The dead middle is banned.
    for (final (name, script) in [
      ('bird', birdScript),
      ('cat', catScript),
    ]) {
      test('$name talks in beats, never on a metronome', () {
        const window = Duration(minutes: 15);
        var quick = 0;
        for (var i = 1; i < script.length; i++) {
          final gap =
              (script[i].at - script[i - 1].at) * window.inSeconds;
          expect(gap > 0, isTrue,
              reason: '$name line $i runs backwards in time',);
          expect(gap <= 15 || gap >= 45, isTrue,
              reason: '$name gap $i is ${gap.toStringAsFixed(1)}s — too slow '
                  'to be an answer, too quick to be a silence',);
          if (gap <= 15) quick++;
        }
        expect(quick / (script.length - 1), greaterThan(0.6),
            reason: '$name is mostly silence; a companion who speaks six '
                'times in fifteen minutes is scenery, not company',);
      });
    }
  });

  group('pendingSpeaker', () {
    const window = Duration(minutes: 15);

    test('leans forward just before a line, and not otherwise', () {
      // 0.022 * 900s = 19.8s. Four seconds ahead of it, the bird is coming.
      expect(
        pendingSpeaker(birdScript,
            elapsed: const Duration(seconds: 17), window: window,),
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
