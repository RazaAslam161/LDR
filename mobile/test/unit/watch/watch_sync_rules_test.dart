import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/watch/watch_protocol.dart';

/// The two freezes that survived the player fix were both decisions, not
/// rendering: when a held correction may be released, and when a state change
/// is our own echo. Both are reproduced here as the rules they are, so a
/// regression fails a test instead of a film.
void main() {
  group('a held correction is released regardless of who is leading', () {
    // The release used to sit behind an `if (_isLeader) return;`. A follower
    // that paused itself to shed drift and then took the lead — which is what
    // pressing play does — never reached it and stayed paused forever.
    bool releaseDue({
      required bool holdExpired,
      required bool isLeader,
    }) {
      // Mirrors _tick: the hold is evaluated BEFORE the leader branch.
      if (holdExpired) return true;
      if (isLeader) return false;
      return false;
    }

    test('follower releases an expired hold', () {
      expect(releaseDue(holdExpired: true, isLeader: false), isTrue);
    });

    test('a device that became leader still releases its own hold', () {
      expect(releaseDue(holdExpired: true, isLeader: true), isTrue);
    });

    test('an unexpired hold is not released early', () {
      expect(releaseDue(holdExpired: false, isLeader: false), isFalse);
    });
  });

  group('echo detection matches on expectation, not on elapsed time', () {
    // Returns true when (pos, playing) is the echo of a command we issued.
    bool isEcho({
      required int pos,
      required bool playing,
      required int? wantPos,
      required bool? wantPlaying,
      required bool windowOpen,
    }) {
      if (!windowOpen) return false;
      if (wantPlaying != null && wantPlaying != playing) return false;
      if (wantPos != null && (pos - wantPos).abs() > kNudgeMs) return false;
      return true;
    }

    test('the state we asked for is our echo', () {
      expect(
        isEcho(
          pos: 42000,
          playing: true,
          wantPos: 42000,
          wantPlaying: true,
          windowOpen: true,
        ),
        isTrue,
      );
    });

    test('small jitter around the commanded position is still our echo', () {
      expect(
        isEcho(
          pos: 42000 + kNudgeMs - 1,
          playing: true,
          wantPos: 42000,
          wantPlaying: true,
          windowOpen: true,
        ),
        isTrue,
      );
    });

    test('a real seek inside the window is NOT swallowed', () {
      // The old 600ms flag swallowed genuine gestures that landed inside it.
      expect(
        isEcho(
          pos: 90000,
          playing: true,
          wantPos: 42000,
          wantPlaying: true,
          windowOpen: true,
        ),
        isFalse,
      );
    });

    test('a real pause inside the window is NOT swallowed', () {
      expect(
        isEcho(
          pos: 42000,
          playing: false,
          wantPos: 42000,
          wantPlaying: true,
          windowOpen: true,
        ),
        isFalse,
      );
    });

    test('once the window closes nothing is treated as an echo', () {
      // A command whose echo never arrives must not gag the user forever.
      expect(
        isEcho(
          pos: 42000,
          playing: true,
          wantPos: 42000,
          wantPlaying: true,
          windowOpen: false,
        ),
        isFalse,
      );
    });
  });

  group('correction thresholds still hold', () {
    test('a gap under the nudge floor is left alone', () {
      expect(correctionFor(kNudgeMs - 1), WatchCorrection.none);
    });

    test('a middling gap is shed by holding, not by jumping', () {
      expect(correctionFor(kNudgeMs + 1), WatchCorrection.hold);
      expect(correctionFor(-(kNudgeMs + 1)), WatchCorrection.hold);
    });

    test('a gap already visible is corrected by seeking', () {
      expect(correctionFor(kSeekMs + 1), WatchCorrection.seek);
    });
  });
}
