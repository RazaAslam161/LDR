import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/watch/watch_protocol.dart';

void main() {
  group('leader election', () {
    test('whoever acted most recently drives', () {
      expect(leaderBetween(a: 'aaa', aSeq: 5, b: 'zzz', bSeq: 9), 'zzz');
      expect(leaderBetween(a: 'aaa', aSeq: 12, b: 'zzz', bSeq: 9), 'aaa');
    });

    test('a tie is broken the same way on both devices', () {
      // The property that matters: run it from either side and get one answer.
      final fromA = leaderBetween(a: 'aaa', aSeq: 7, b: 'zzz', bSeq: 7);
      final fromZ = leaderBetween(a: 'zzz', aSeq: 7, b: 'aaa', bSeq: 7);
      expect(fromA, fromZ);
    });

    test('the lower uid does not simply always win', () {
      // If it did, one person's play button would never do anything.
      expect(leaderBetween(a: 'aaa', aSeq: 1, b: 'zzz', bSeq: 2), 'zzz');
    });
  });

  group('correction', () {
    test('a small gap is left alone', () {
      expect(correctionFor(0), WatchCorrection.none);
      expect(correctionFor(kNudgeMs - 1), WatchCorrection.none);
      expect(correctionFor(-(kNudgeMs - 1)), WatchCorrection.none);
    });

    test('a middling gap is absorbed, not jumped', () {
      expect(correctionFor(kNudgeMs), WatchCorrection.hold);
      expect(correctionFor(kSeekMs - 1), WatchCorrection.hold);
    });

    test('a gap the viewer can already see is seeked', () {
      expect(correctionFor(kSeekMs), WatchCorrection.seek);
      expect(correctionFor(9000), WatchCorrection.seek);
    });

    test('the threshold is well below the beat interval', () {
      // The old build corrected at 2500ms and beat every 2500ms, so a 2.4s gap
      // was re-confirmed forever and never once corrected.
      expect(kSeekMs, lessThan(kBeatInterval.inMilliseconds * 2));
      expect(kNudgeMs, lessThan(kBeatInterval.inMilliseconds));
    });
  });

  group('projection', () {
    test('a paused position does not move', () {
      const m = WatchMessage(
        intent: WatchIntent.pause,
        from: 'a',
        seq: 1,
        atMs: 0,
        posMs: 42000,
      );
      expect(m.projectedPosMs(), 42000);
    });

    test('a playing position advances with the shared clock', () {
      final m = WatchMessage(
        intent: WatchIntent.play,
        from: 'a',
        seq: 1,
        atMs: DateTime.now().millisecondsSinceEpoch - 1000,
        posMs: 42000,
        playing: true,
      );
      // ~1s later, so it should be ahead of where it was stamped. This is the
      // whole reason a late message is harmless.
      expect(m.projectedPosMs(), greaterThan(42000));
    });

    test('a sender whose clock runs ahead cannot drag us backwards', () {
      final m = WatchMessage(
        intent: WatchIntent.play,
        from: 'a',
        seq: 1,
        // Stamped in the future.
        atMs: DateTime.now().millisecondsSinceEpoch + 60000,
        posMs: 42000,
        playing: true,
      );
      expect(m.projectedPosMs(), 42000);
    });
  });

  group('wire format', () {
    test('a message survives a round trip', () {
      const m = WatchMessage(
        intent: WatchIntent.seek,
        from: 'me',
        seq: 3,
        atMs: 1234,
        videoId: 'abc',
        posMs: 5000,
        playing: true,
        leader: 'me',
      );
      final back = WatchMessage.fromJson(m.toJson());
      expect(back.intent, WatchIntent.seek);
      expect(back.from, 'me');
      expect(back.seq, 3);
      expect(back.atMs, 1234);
      expect(back.videoId, 'abc');
      expect(back.posMs, 5000);
      expect(back.playing, isTrue);
      expect(back.leader, 'me');
    });

    test('an unknown intent from a newer build degrades to a beat', () {
      // A beat is inert — it never commands anything — so an intent this build
      // does not understand cannot make it do something arbitrary.
      final back = WatchMessage.fromJson({
        'intent': 'something_new',
        'from': 'them',
        'seq': 1,
        'at': 0,
      });
      expect(back.intent, WatchIntent.beat);
    });

    test('hello carries no position', () {
      // The old build announced pos: 0 on arrival, which dragged the other
      // person back to the start of the film.
      const m = WatchMessage(
        intent: WatchIntent.hello,
        from: 'me',
        seq: 1,
        atMs: 0,
      );
      expect(m.posMs, 0);
      expect(m.playing, isFalse);
      expect(m.intent, WatchIntent.hello);
    });
  });
}
