import 'package:flutter/foundation.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The Doorstep's brain, kept pure so every beat is provable without a widget.
///
/// Two layers, because one cannot work. A pure function of `(row, role, now)`
/// can say WHICH world to show — settled street, last call, how far dawn has
/// crept — but it cannot sequence one-shots: slam→settle→bird is an order,
/// not a state, and "the letter arrived" is an edge, not a level. So:
///
///  * [SceneModel.of] — the steady truth. Deterministic, comparable,
///    recomputable at any time on either phone with the same answer.
///  * [BeatSequencer] — diffs consecutive models and queues the one-shots.
///    Beats dedupe by identity, drain one at a time, and a steady-state flip
///    flushes the queue and cuts to the new world (the `off()` philosophy:
///    cut to finished, never fast-forward through a story nobody is in
///    anymore).
///
/// The scene never invents state. It performs what the server row already
/// says — which is the entire reason two phones agree on the story.

/// Which world the stage shows. Steady states only — one-shots are [SceneBeat]s.
enum SceneAct {
  /// The street at rest: character on the doorstep, lamp warm, bird about.
  settled,

  /// Both of them chose it. Bolt shut, five minutes on the clock.
  lastCall,
}

/// Who this phone is in the story. The outside view belongs to the person who
/// closed the door; the inside view to the person still in the house. Each
/// phone casts its OWN user as its character.
enum SceneRole { outside, inside }

/// The character variants. Neutral is not a fallback error state: `gender` is
/// nullable in practice (role-setup has a sign-out escape hatch), and the app
/// already ships a gender-neutral figure on the touch map.
enum PuppetVariant { male, female, neutral }

PuppetVariant puppetVariantOf(String? gender) => switch (gender) {
      'male' => PuppetVariant.male,
      'female' => PuppetVariant.female,
      _ => PuppetVariant.neutral,
    };

/// One-shot performances, in the order the sequencer may play them.
enum SceneBeat {
  /// The door shuts hard: exit walk, swing, impact shake, lamp flicker.
  slam,

  /// The character finds the words: the thought cloud opens and the quote is
  /// SAID, word by word.
  speak,

  /// A letter passes under the door. On the outside view it slips out and
  /// drifts to the doorstep; on the inside view the character slides it under.
  letter,

  /// The bolt slides shut — the mutual decision, made visible.
  bolt,
}

/// A beat plus the identity that makes it play exactly once.
///
/// The letter's identity is its `note_updated_at`: a refetch and a broadcast
/// of the same write collapse to ONE animation, and a REPLACED letter is a
/// new beat. Beats without natural identity use their name.
@immutable
class SceneBeatEvent {
  const SceneBeatEvent(this.beat, this.key);

  final SceneBeat beat;
  final String key;

  @override
  bool operator ==(Object other) =>
      other is SceneBeatEvent && other.beat == beat && other.key == key;

  @override
  int get hashCode => Object.hash(beat, key);

  @override
  String toString() => '$beat($key)';
}

/// The steady truth of the scene at one instant, derived and nothing else.
@immutable
class SceneModel {
  const SceneModel({
    required this.act,
    required this.role,
    required this.slamFresh,
    required this.handleGlow,
    required this.gateOpen,
    required this.dawn,
    required this.letterAt,
  });

  /// Derives the model from the row. [slamPlayed] is the local latch — a cold
  /// start six hours in opens on the settled street, not a replay of the
  /// worst moment of somebody's day.
  factory SceneModel.of(
    UnlinkRow row, {
    required SceneRole role,
    required bool slamPlayed,
    DateTime? now,
  }) {
    final t = now ?? ServerClock.now();
    final total = row.coolingEndsAt.difference(row.startedAt);
    final gone = t.difference(row.startedAt);
    final dawn = total.inSeconds <= 0
        ? 0.0
        : (gone.inSeconds / total.inSeconds).clamp(0.0, 1.0);
    return SceneModel(
      act: row.lastCall ? SceneAct.lastCall : SceneAct.settled,
      role: role,
      // Fresh only within the ceremony's opening moments AND unplayed: the
      // slam belongs to the tap, not to every process that ever mounts this.
      slamFresh: !slamPlayed && gone < const Duration(seconds: 45),
      // Gates computed against THIS mapper's clock, never through the row's
      // own getters — those read ServerClock internally, which would make
      // the one pure function in the scene secretly depend on the wall
      // clock. Same instant, same answer, on any machine, in any test.
      handleGlow:
          role == SceneRole.outside && !row.relinkOpensAt.isAfter(t),
      gateOpen:
          role == SceneRole.inside && !row.partnerGateOpensAt.isAfter(t),
      dawn: dawn,
      letterAt: row.hasNote ? row.noteUpdatedAt : null,
    );
  }

  final SceneAct act;
  final SceneRole role;

  /// The slam has not played yet and the ceremony just began.
  final bool slamFresh;

  /// The door handle catches the light — the way back, visible (outside only).
  final bool handleGlow;

  /// The inside person's own decision is now open to them.
  final bool gateOpen;

  /// 0 at the start, 1 at the deadline: the sky's slow walk toward pre-dawn.
  final double dawn;

  /// When the current letter was written, or null when there is none. The
  /// value is the letter's IDENTITY, which is what makes replacement a new
  /// beat and a duplicate refetch no beat at all.
  final DateTime? letterAt;

  @override
  bool operator ==(Object other) =>
      other is SceneModel &&
      other.act == act &&
      other.role == role &&
      other.slamFresh == slamFresh &&
      other.handleGlow == handleGlow &&
      other.gateOpen == gateOpen &&
      // dawn is continuous; two models are "the same scene" if everything
      // discrete matches. The painter reads dawn directly every frame.
      other.letterAt == letterAt;

  @override
  int get hashCode =>
      Object.hash(act, role, slamFresh, handleGlow, gateOpen, letterAt);
}

/// Orders the one-shots, plays them one at a time, and never plays one twice.
///
/// Not a widget and not a ticker: the stage asks [take] for the next beat
/// whenever it finishes one and falls idle. Everything else — dedupe,
/// ordering, the flush-and-cut on a world change — lives here, where a unit
/// test can replay a whole ceremony against it.
class BeatSequencer {
  BeatSequencer();

  final List<SceneBeatEvent> _queue = [];
  final Set<SceneBeatEvent> _played = {};
  SceneModel? _last;

  @visibleForTesting
  List<SceneBeatEvent> get queue => List.unmodifiable(_queue);

  /// Feed the next model; returns true when anything changed (queued a beat
  /// or cut the world), so the stage knows to wake.
  bool push(SceneModel next) {
    final prev = _last;
    _last = next;
    var changed = false;

    // A world change flushes the story: beats queued for a street that no
    // longer exists would play over the wrong scene. The transition itself
    // (bolt) is queued fresh below, from the same diff.
    if (prev != null && next.act != prev.act) {
      if (_queue.isNotEmpty) {
        _queue.clear();
        changed = true;
      }
    }

    void offer(SceneBeat beat, String key) {
      final e = SceneBeatEvent(beat, key);
      if (_played.contains(e) || _queue.contains(e)) return;
      _queue.add(e);
      changed = true;
    }

    if (prev == null) {
      // First model of this mount. The slam only if the ceremony is fresh
      // and unplayed; the quote is spoken after whatever comes before it,
      // every mount — it is the scene's welcome, not a ceremony event.
      if (next.slamFresh) offer(SceneBeat.slam, 'slam');
      offer(SceneBeat.speak, 'speak');
    }

    // An EDGE needs two samples: with no prev there is no arrival, only a
    // letter that was already resting when the scene opened — a cold start
    // must not replay its delivery.
    if (prev != null &&
        next.letterAt != null &&
        next.letterAt != prev.letterAt) {
      offer(SceneBeat.letter, next.letterAt!.toIso8601String());
    }

    if (prev != null &&
        next.act == SceneAct.lastCall &&
        prev.act != SceneAct.lastCall) {
      offer(SceneBeat.bolt, 'bolt');
    }

    return changed;
  }

  /// The next beat to perform, or null when the stage should just be the
  /// steady world. Taking a beat marks it played — a beat interrupted by a
  /// world flush stays played; the story moved on.
  SceneBeatEvent? take() {
    if (_queue.isEmpty) return null;
    final e = _queue.removeAt(0);
    _played.add(e);
    return e;
  }

  /// The current steady world, as last pushed.
  SceneModel? get model => _last;
}
