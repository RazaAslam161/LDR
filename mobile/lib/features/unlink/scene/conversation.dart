/// The doorstep conversations — the bird outside, the cat inside — and the
/// engine that paces them.
///
/// THE ONE RULE: the line on screen is a PURE FUNCTION of the row's own
/// timestamps and the server-anchored clock. No state, no timers that own
/// truth, no taps that advance anything. Close the app at minute 3, reopen at
/// minute 12, and the conversation is exactly where it truly is — because
/// "where it is" is arithmetic, not memory. This is the same discipline
/// `SceneModel.of` uses, applied to words.
///
/// Timing is expressed as FRACTIONS of the gate window (started_at →
/// relink_opens_at / partner_gate_opens_at), not absolute seconds, so the
/// script cannot drift from the button: the companion's final line lands AT
/// the gate because both read the same timestamp. A test row with a shorter
/// window compresses the whole conversation with it.
library;

import 'package:flutter/foundation.dart';

/// Who is talking. The character's own lines render differently — the user is
/// reading their character's side of a dialogue, not being addressed.
enum Speaker { companion, character }

@immutable
class Exchange {
  const Exchange(this.at, this.speaker, this.line);

  /// 0..1 across the gate window. 1.0 is reserved for the handover line.
  final double at;
  final Speaker speaker;
  final String line;
}

/// The window of exchanges that have "happened" by [elapsed], newest last.
///
/// [tail] bounds how much history stands on screen — the last few lines in a
/// faded stack, the way the plan describes, not a transcript.
List<Exchange> visibleExchanges(
  List<Exchange> script, {
  required Duration elapsed,
  required Duration window,
  int tail = 3,
}) {
  if (window.inSeconds <= 0) return const [];
  final t = elapsed.inMilliseconds / window.inMilliseconds;
  final said = [
    for (final e in script)
      if (e.at <= t) e,
  ];
  return said.length <= tail ? said : said.sublist(said.length - tail);
}

/// Who is about to speak, within [lead] of their line landing — or null.
///
/// The difference between a paused screen and an inhabited one. In the long
/// silences between beats nothing moves and nothing is said, and the scene
/// reads as frozen; three dots at the speaker's own head a few seconds ahead
/// say "wait, they are getting to it". Pure arithmetic like everything else
/// here, so both phones lean forward on the same second.
Speaker? pendingSpeaker(
  List<Exchange> script, {
  required Duration elapsed,
  required Duration window,
  Duration lead = const Duration(seconds: 4),
}) {
  if (window.inSeconds <= 0) return null;
  final t = elapsed.inMilliseconds / window.inMilliseconds;
  final leadT = lead.inMilliseconds / window.inMilliseconds;
  for (final e in script) {
    if (e.at > t && e.at - t <= leadT) return e.speaker;
  }
  return null;
}

/// One line from the companionship pool, or null in the quiet stretches.
///
/// After the gate the companion stays but mostly keeps company in silence:
/// each [interval] slot picks its line deterministically — the same slot on
/// both phones and after any restart — and the line is "spoken" only for
/// [hold] at the top of the slot, then fades. `%` wraps the pool for the
/// long night; within one sitting nothing repeats until the pool is spent.
String? companionshipLine(
  List<String> pool, {
  required Duration sinceGate,
  Duration interval = const Duration(minutes: 25),
  Duration hold = const Duration(seconds: 40),
}) {
  if (pool.isEmpty || sinceGate.isNegative) return null;
  final slot = sinceGate.inSeconds ~/ interval.inSeconds;
  final into = sinceGate.inSeconds - slot * interval.inSeconds;
  if (into > hold.inSeconds) return null;
  return pool[slot % pool.length];
}

// ───────────────────────────────────────────────────────────────────────────
// The scripts. House law binds them: the app authors no blame — nothing here
// decides who was wrong — and no line names the UI (no "button", no "unlink",
// no "app"). The bird is lively and a little cheeky; the cat is quiet and
// dry. Both end the same way: the choice is handed back, at the gate,
// because that is the moment the choice actually exists.
// ───────────────────────────────────────────────────────────────────────────

/// The street. The initiator sits on the porch steps; the bird takes the lamp.
///
/// TIMED IN BEATS, NOT ON A METRONOME. Spread evenly across the window these
/// lines stood 45 seconds apart, and 45 seconds of stillness between "I'm
/// fine" and "Didn't ask" is not a conversation, it is buffering — which is
/// exactly how it read on a handset. Real talk clusters: four or five
/// exchanges seven to eleven seconds apart, then a long silence while both of
/// them sit with it, then another cluster. The silences are the scene doing
/// the talking; `pendingSpeaker` leans the next beat forward so the quiet
/// still feels inhabited.
const birdScript = <Exchange>[
  // Beat 1 — the bird lands. ~0:20
  Exchange(0.022, Speaker.companion, 'Hi.'),
  Exchange(0.030, Speaker.character, '…hi.'),
  Exchange(0.042, Speaker.companion, "Cold step. I've sat on warmer wires."),
  Exchange(0.052, Speaker.character, "I'm fine."),
  Exchange(0.060, Speaker.companion, "Didn't ask. But okay."),
  // Beat 2 — what happened. ~2:05
  Exchange(0.140, Speaker.character, 'I just needed air.'),
  Exchange(0.150, Speaker.companion,
      'Loud air, from out here. The door heard it too.'),
  Exchange(0.161, Speaker.character, 'You saw that.'),
  Exchange(0.172, Speaker.companion,
      'I see everything on this street. Mostly pigeons.'),
  // Beat 3 — the real thing. ~4:15
  Exchange(0.285, Speaker.character, "It wasn't about tonight. It's everything."),
  Exchange(0.297, Speaker.companion,
      'Mm. Everything is a lot to carry down three steps.'),
  Exchange(0.310, Speaker.character, 'They stopped hearing me.'),
  Exchange(0.322, Speaker.companion, 'And out here — who hears you out here?'),
  Exchange(0.335, Speaker.character, '…'),
  // Beat 4 — the bird's own confession. ~7:20
  Exchange(0.490, Speaker.companion, 'I fly off in a huff most days. Worms, mostly.'),
  Exchange(0.502, Speaker.companion,
      'I always land somewhere I can still see the nest.'),
  Exchange(0.515, Speaker.character, 'You think I should go back in.'),
  // Beat 5 — the turn. ~10:30
  Exchange(0.700, Speaker.companion, "I think you're still on the step."),
  Exchange(0.713, Speaker.companion,
      "That's not nothing. Leaving looks different."),
  // Beat 6 — the handover, pinned to the gate.
  Exchange(0.910, Speaker.character, 'So what do I do?'),
  Exchange(1.0, Speaker.companion,
      "Now it's yours to choose. I'll stay either way."),
];

/// The room. The partner sits on the sofa; the cat arrives without asking.
/// Same beat discipline as [birdScript], one beat behind it: inside, the
/// silences are longer, because nothing has happened to them yet.
const catScript = <Exchange>[
  // Beat 1 — the cat arrives. ~0:25
  Exchange(0.028, Speaker.companion, '…'),
  Exchange(0.038, Speaker.character, 'Not now.'),
  Exchange(0.048, Speaker.companion, "I wasn't going anywhere."),
  Exchange(0.060, Speaker.character, 'Did you hear the door?'),
  Exchange(0.070, Speaker.companion, 'The whole street heard the door.'),
  // Beat 2 — the blame loop. ~2:15
  Exchange(0.150, Speaker.character, "I don't even know what I did."),
  Exchange(0.162, Speaker.companion,
      'Maybe nothing. Doors slam on nothing sometimes.'),
  Exchange(0.174, Speaker.character, 'They just left.'),
  // Beat 3 — the window. ~4:20
  Exchange(0.290, Speaker.companion,
      'They went as far as the step. I checked the window.'),
  Exchange(0.302, Speaker.character, 'The step?'),
  Exchange(0.313, Speaker.companion,
      'The step. Sitting. Like you. Two rooms, one wall.'),
  // Beat 4 — both sides of a door. ~7:00
  Exchange(0.467, Speaker.character, 'They could come back in.'),
  Exchange(0.480, Speaker.companion,
      'You could open it. Doors work from both sides.'),
  Exchange(0.493, Speaker.character, "And if they don't want me to?"),
  Exchange(0.506, Speaker.companion,
      "Then you'll know. Knowing is better than this."),
  // Beat 5 — the fear said out loud. ~10:20
  Exchange(0.688, Speaker.character, "I'm scared of knowing."),
  Exchange(0.700, Speaker.companion,
      'I know. Move over. My spot is by your side.'),
  // Beat 6 — the handover, pinned to the gate.
  Exchange(0.915, Speaker.character, 'What would you do?'),
  Exchange(1.0, Speaker.companion,
      "I'd stay close, and let you choose. So: choose."),
];

/// After the gate: the bird keeps loose company on the lamp.
const birdCompanionship = <String>[
  'Still here. The lamp and I are old friends.',
  'The light inside is still on. Just saying.',
  'No hurry. Streets are patient.',
  'You breathe better than an hour ago.',
  'A step is a place to sit, not a place to live.',
];

/// After the gate: the cat holds the sofa.
const catCompanionship = <String>[
  '…still here.',
  'The kettle would help. It usually helps.',
  "The step light is on. They haven't gone.",
  'You can lean. That is what I am for.',
  'Quiet is not the same as over.',
];
