/// The wire protocol for watching together, kept away from the widget so the
/// parts that decide anything can be tested without a player or a socket.
///
/// The old version had no protocol at all: both phones broadcast their own
/// position every 2.5s and both corrected toward whatever they last heard.
/// Two devices each chasing the other is not synchronisation, it is a feedback
/// loop that happens to look stable while the network is quiet.
library;

import 'package:miles/core/services/server_clock.dart';

/// What one side is telling the other.
///
/// Intents are FACTS ABOUT A MOMENT, not state to be mirrored. `play at 42.0s
/// as of T` survives being delivered late — the receiver works out where that
/// puts it now. `playing: true, pos: 42.0` does not: acted on two seconds
/// later it is two seconds wrong, forever, which is the drift the old
/// heartbeat kept re-introducing every time it fired.
enum WatchIntent {
  /// A video was chosen. Carries the id.
  load,

  /// Resume from [WatchMessage.posMs] as of [WatchMessage.atMs].
  play,

  /// Hold at [WatchMessage.posMs].
  pause,

  /// Jump to [WatchMessage.posMs].
  seek,

  /// The leader's periodic "here is where I am". Never a command.
  beat,

  /// A newcomer asking for the current state. Carries no position — the old
  /// build broadcast pos: 0 on arrival and dragged the other person back to
  /// the start of the film.
  hello,

  /// The follower cannot keep up and everyone should wait.
  stall,

  /// The follower is ready again.
  ready,
}

/// One message on the wire.
class WatchMessage {
  const WatchMessage({
    required this.intent,
    required this.from,
    required this.seq,
    required this.atMs,
    this.videoId,
    this.posMs = 0,
    this.playing = false,
    this.leader,
  });

  factory WatchMessage.fromJson(Map<String, dynamic> j) => WatchMessage(
        intent: WatchIntent.values.firstWhere(
          (e) => e.name == j['intent'],
          orElse: () => WatchIntent.beat,
        ),
        from: j['from']?.toString() ?? '',
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        atMs: (j['at'] as num?)?.toInt() ?? 0,
        videoId: j['videoId']?.toString(),
        posMs: (j['pos'] as num?)?.toInt() ?? 0,
        playing: j['playing'] == true,
        leader: j['leader']?.toString(),
      );

  final WatchIntent intent;
  final String from;

  /// Per-sender monotonic counter.
  ///
  /// Identity, not a wall clock. The old build guarded against echo with a
  /// 600ms `_applyingRemote` flag, which both swallowed real intents inside
  /// the window and let stale ones through outside it.
  final int seq;

  /// When the sender believed this was true, on the SHARED clock.
  ///
  /// The whole reason a position can be acted on late. Two handsets in this
  /// repo have been measured seconds apart, so this is ServerClock, never
  /// DateTime.now().
  final int atMs;

  final String? videoId;
  final int posMs;
  final bool playing;

  /// Who the sender believes is driving.
  final String? leader;

  Map<String, dynamic> toJson() => {
        'intent': intent.name,
        'from': from,
        'seq': seq,
        'at': atMs,
        if (videoId != null) 'videoId': videoId,
        'pos': posMs,
        'playing': playing,
        if (leader != null) 'leader': leader,
      };

  /// Where the sender would be NOW if it kept playing since [atMs].
  ///
  /// This is what makes a late message harmless. Only meaningful while
  /// playing — a paused position does not move.
  int projectedPosMs() {
    if (!playing) return posMs;
    final elapsed = ServerClock.now().millisecondsSinceEpoch - atMs;
    // A negative elapsed means the sender's clock is ahead of ours by more
    // than transit. Clamping rather than trusting it stops a skewed handset
    // from dragging the other one backwards on every beat.
    return posMs + (elapsed < 0 ? 0 : elapsed);
  }
}

/// How far apart the two sides may drift before anything is done about it.
///
/// The old build used 2500ms and beat every 2500ms, so a 2.4s gap was
/// re-confirmed forever and never corrected. Below [kNudgeMs] nothing is worth
/// doing; between the two, the follower sheds the difference by holding still
/// for exactly that long; past [kSeekMs] it is a hard seek, which is visible
/// and so is reserved for a gap that is already visible.
const int kNudgeMs = 350;
const int kSeekMs = 1500;

/// The follower's periodic check. Frequent enough that a correction is a
/// micro-pause rather than a jump.
const Duration kBeatInterval = Duration(milliseconds: 1200);

/// No sample for this long while playing means the other side has stalled.
const Duration kStallAfter = Duration(seconds: 3);

/// What a follower should do about [driftMs], where positive means the
/// follower is AHEAD of the leader.
enum WatchCorrection { none, hold, seek }

/// Correction is one-sided on purpose.
///
/// If both devices correct toward each other they oscillate: each sees the
/// other's stale position, moves toward it, and reports a new position that
/// makes the other move back. Only the follower ever acts.
WatchCorrection correctionFor(int driftMs) {
  final d = driftMs.abs();
  if (d < kNudgeMs) return WatchCorrection.none;
  if (d < kSeekMs) return WatchCorrection.hold;
  return WatchCorrection.seek;
}

/// Who drives, when both sides have an opinion.
///
/// Whoever acted most recently leads; a tie falls to the lower uid so the two
/// devices always agree. Deliberately not "whoever has the lower uid" alone —
/// that would mean the same person always drives and the other's play button
/// does nothing.
String leaderBetween({
  required String a,
  required int aSeq,
  required String b,
  required int bSeq,
}) {
  if (aSeq != bSeq) return aSeq > bSeq ? a : b;
  return a.compareTo(b) <= 0 ? a : b;
}
