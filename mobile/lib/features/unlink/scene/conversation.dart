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

/// How long a spoken line stays on the stage before the quiet takes it back.
/// Longer than a lull inside a cluster, shorter than the gaps between them,
/// so an exchange is readable while it is happening and gone once it isn't.
const spokenLinger = Duration(seconds: 40);

/// The window of exchanges that have "happened" by [elapsed], newest last.
///
/// [tail] bounds how much history stands on screen — the last few lines in a
/// faded stack, the way the plan describes, not a transcript.
List<Exchange> visibleExchanges(
  List<Exchange> script, {
  required Duration elapsed,
  required Duration window,
  int tail = 3,
  Duration? within,
}) {
  if (window.inSeconds <= 0) return const [];
  final t = elapsed.inMilliseconds / window.inMilliseconds;
  // A said thing does not stay said forever. Without this the last line of a
  // cluster hung on the stage through the whole lull after it, so two stale
  // sentences sat there like labels and the scene stopped looking like a
  // conversation between anybody.
  final floor = within == null
      ? null
      : (elapsed.inMilliseconds - within.inMilliseconds) /
          window.inMilliseconds;
  final said = [
    for (final e in script)
      if (e.at <= t && (floor == null || e.at >= floor)) e,
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
  Duration lead = const Duration(milliseconds: 2500),
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
/// SEVENTY-THREE LINES, roughly one every twelve seconds.
///
/// The first version had twenty-one across the same fifteen minutes and read,
/// on a handset, as "too slow — it doesn't even look like a conversation is
/// going on between them". It wasn't one. Two people talking exchange a line
/// every few seconds and fall quiet in stretches; they do not deliver a
/// sentence every forty-five seconds like a station announcement. So the
/// script is now dense where people talk and genuinely silent where they
/// don't: five clusters of eleven to fifteen exchanges, seven to thirteen
/// seconds apart, separated by real lulls of thirty-five to sixty seconds
/// where the stage breathes and nothing is said.
///
/// A line also LEAVES now. `visibleExchanges` drops anything older than its
/// `within`, so the stage clears between clusters instead of holding two
/// stale sentences up forever — which is what made it read as two labels
/// rather than a dialogue.
const birdScript = <Exchange>[
  Exchange(0.0167, Speaker.companion, "Oh. Someone's on my step."),
  Exchange(0.0244, Speaker.character, '…'),
  Exchange(0.0322, Speaker.companion, 'It’s my step. I was here first.'),
  Exchange(0.04, Speaker.character, 'Sorry.'),
  Exchange(0.0489, Speaker.companion, 'He speaks.'),
  Exchange(0.0578, Speaker.character, "I'm not in the mood."),
  Exchange(0.0667, Speaker.companion, 'Nobody sits out here in the mood.'),
  Exchange(0.0767, Speaker.character, 'Then why are you here?'),
  Exchange(0.0856, Speaker.companion, "Lamp's warm. And you're new."),
  Exchange(0.0956, Speaker.character, "I'm not new. I live here."),
  Exchange(0.1056, Speaker.companion, 'Lived. Present tense is a choice.'),
  Exchange(0.1444, Speaker.character, 'It was a stupid fight.'),
  Exchange(0.1544, Speaker.companion, 'They usually are.'),
  Exchange(0.1633, Speaker.character, "It wasn't about the thing we were saying."),
  Exchange(0.1733, Speaker.companion, "They usually aren't."),
  Exchange(0.1833, Speaker.character, 'Do you have an opinion, or just echoes?'),
  Exchange(0.1933, Speaker.companion, 'Mostly pigeons. But go on.'),
  Exchange(0.2044, Speaker.character, "I said something I can't take back."),
  Exchange(0.2144, Speaker.companion, 'Out loud, or with the door?'),
  Exchange(0.2244, Speaker.character, '…the door.'),
  Exchange(0.2344, Speaker.companion, 'That one carries.'),
  Exchange(0.2456, Speaker.character, 'The whole street heard it.'),
  Exchange(0.2556, Speaker.companion, "The whole street's asleep. One person heard it."),
  Exchange(0.3167, Speaker.character, 'They stopped hearing me a long time ago.'),
  Exchange(0.3267, Speaker.companion, 'That’s a big sentence for one evening.'),
  Exchange(0.3367, Speaker.character, "It's been building."),
  Exchange(0.3467, Speaker.companion, 'Building where? In you, or between you?'),
  Exchange(0.3578, Speaker.character, 'Does it matter?'),
  Exchange(0.3678, Speaker.companion, 'One of those you can fix from a step.'),
  Exchange(0.3789, Speaker.character, "I don't know how to start."),
  Exchange(0.3889, Speaker.companion, 'You started. Loudly.'),
  Exchange(0.3989, Speaker.character, "That's not starting. That's leaving."),
  Exchange(0.41, Speaker.companion, "You're eleven feet from your own door."),
  Exchange(0.42, Speaker.character, '…'),
  Exchange(0.43, Speaker.companion, "That's not leaving. That's pacing."),
  Exchange(0.4411, Speaker.character, "You're annoying."),
  Exchange(0.4511, Speaker.companion, "I'm accurate. It's similar."),
  Exchange(0.5167, Speaker.companion, 'I flew off once.'),
  Exchange(0.5267, Speaker.character, 'From what?'),
  Exchange(0.5367, Speaker.companion, 'Nest. Argument. Feathers everywhere.'),
  Exchange(0.5467, Speaker.character, 'Birds argue?'),
  Exchange(0.5567, Speaker.companion, 'Constantly. Terrible communicators.'),
  Exchange(0.5678, Speaker.companion, 'I sat on a wire for two days.'),
  Exchange(0.5778, Speaker.character, 'And then?'),
  Exchange(0.5878, Speaker.companion, 'And then it was three days. Then a week.'),
  Exchange(0.5989, Speaker.character, 'Did you go back?'),
  Exchange(0.6089, Speaker.companion, 'I went back.'),
  Exchange(0.6189, Speaker.character, 'Was it the same?'),
  Exchange(0.6289, Speaker.companion, 'No. It was better, and it took a while.'),
  Exchange(0.64, Speaker.character, 'How long is a while?'),
  Exchange(0.65, Speaker.companion, 'Longer than a step. Shorter than a life.'),
  Exchange(0.7111, Speaker.character, "They're probably not even upset."),
  Exchange(0.7211, Speaker.companion, "You don't believe that."),
  Exchange(0.7311, Speaker.character, 'No.'),
  Exchange(0.7411, Speaker.companion, 'Sitting in there thinking the same thing, likely.'),
  Exchange(0.7522, Speaker.character, 'About me?'),
  Exchange(0.7622, Speaker.companion, "About the quiet. It's the same thought."),
  Exchange(0.7733, Speaker.character, 'What do I even say?'),
  Exchange(0.7833, Speaker.companion, "Fewer words than you're planning."),
  Exchange(0.7933, Speaker.character, 'Like what?'),
  Exchange(0.8044, Speaker.companion, '“I’m still here.” That’s two more than nothing.'),
  Exchange(0.8144, Speaker.character, "And if it's not enough?"),
  Exchange(0.8256, Speaker.companion, "Then you'll be inside, saying the next thing."),
  Exchange(0.8356, Speaker.character, 'You make it sound easy.'),
  Exchange(0.8467, Speaker.companion, 'I make it sound possible. Different word.'),
  Exchange(0.9, Speaker.character, "I don't want to be the one who ended it."),
  Exchange(0.9111, Speaker.companion, "Then don't be."),
  Exchange(0.9222, Speaker.character, "It's not only up to me."),
  Exchange(0.9333, Speaker.companion, 'No. Your half is, though.'),
  Exchange(0.9456, Speaker.character, 'My half.'),
  Exchange(0.9578, Speaker.companion, 'Your half is a door handle.'),
  Exchange(0.9711, Speaker.character, 'So what do I do?'),
  Exchange(1, Speaker.companion, "Now it's yours to choose. I'll stay either way."),
];

/// The room. The partner sits on the sofa; the cat arrives without asking.
/// Same density and the same discipline as [birdScript]. The cat is drier and
/// interrupts less, but it is never more than about fifteen seconds from
/// saying something while a cluster is running.
const catScript = <Exchange>[
  Exchange(0.0222, Speaker.companion, '…'),
  Exchange(0.0311, Speaker.character, 'Not now.'),
  Exchange(0.04, Speaker.companion, "I wasn't going anywhere."),
  Exchange(0.05, Speaker.character, 'Did you hear that?'),
  Exchange(0.06, Speaker.companion, 'The whole house heard that.'),
  Exchange(0.07, Speaker.character, "It's fine. It's fine."),
  Exchange(0.08, Speaker.companion, "You've said it twice."),
  Exchange(0.09, Speaker.character, "It's fine."),
  Exchange(0.1, Speaker.companion, 'Three.'),
  Exchange(0.11, Speaker.character, 'Go away.'),
  Exchange(0.12, Speaker.companion, 'No.'),
  Exchange(0.1611, Speaker.character, "I don't even know what I did."),
  Exchange(0.1711, Speaker.companion, 'Maybe nothing.'),
  Exchange(0.1811, Speaker.character, "People don't slam doors over nothing."),
  Exchange(0.1911, Speaker.companion, "They slam them over everything. It's cheaper than saying it."),
  Exchange(0.2022, Speaker.character, "That's not comforting."),
  Exchange(0.2122, Speaker.companion, "I'm a cat. I'm warm, not comforting."),
  Exchange(0.2233, Speaker.character, 'They just left.'),
  Exchange(0.2333, Speaker.companion, 'They went eleven feet.'),
  Exchange(0.2444, Speaker.character, 'How do you know?'),
  Exchange(0.2544, Speaker.companion, 'The window. I keep an eye on things.'),
  Exchange(0.2656, Speaker.character, 'Are they still there?'),
  Exchange(0.2756, Speaker.companion, 'Still there.'),
  Exchange(0.3333, Speaker.character, "Then why don't they come in?"),
  Exchange(0.3433, Speaker.companion, "Why don't you open it?"),
  Exchange(0.3533, Speaker.character, 'Because they left.'),
  Exchange(0.3644, Speaker.companion, "Because they're on a step. Those are different."),
  Exchange(0.3744, Speaker.character, 'It feels the same from here.'),
  Exchange(0.3856, Speaker.companion, 'Most things do, from in here.'),
  Exchange(0.3956, Speaker.character, "I'm not going to beg."),
  Exchange(0.4056, Speaker.companion, 'Nobody said beg.'),
  Exchange(0.4167, Speaker.character, 'Then what?'),
  Exchange(0.4267, Speaker.companion, "A door opening isn't a speech."),
  Exchange(0.4378, Speaker.character, "And if they don't want it open?"),
  Exchange(0.4478, Speaker.companion, "Then you'll know, and knowing is lighter than this."),
  Exchange(0.4589, Speaker.character, "You've clearly never waited for anyone."),
  Exchange(0.47, Speaker.companion, 'I wait by a door for a living.'),
  Exchange(0.5333, Speaker.companion, 'Can I tell you what I see from the sill?'),
  Exchange(0.5433, Speaker.character, "You're going to anyway."),
  Exchange(0.5544, Speaker.companion, 'Two people sitting still, one wall apart.'),
  Exchange(0.5644, Speaker.character, "That's not profound."),
  Exchange(0.5756, Speaker.companion, "It's not meant to be. It's just true."),
  Exchange(0.5856, Speaker.character, "I hate that it's true."),
  Exchange(0.5967, Speaker.companion, 'Both of you waiting for the other to move first.'),
  Exchange(0.6067, Speaker.character, 'Someone has to.'),
  Exchange(0.6178, Speaker.companion, "Yes. That's the whole thing, really."),
  Exchange(0.6278, Speaker.character, 'Why me?'),
  Exchange(0.6389, Speaker.companion, 'Why not you?'),
  Exchange(0.6489, Speaker.character, "Because I'm the one who got left."),
  Exchange(0.66, Speaker.companion, "You're the one with the warm room and the handle."),
  Exchange(0.6711, Speaker.character, "That's not fair."),
  Exchange(0.6811, Speaker.companion, "No. It's just where everyone's standing."),
  Exchange(0.7333, Speaker.character, "I'm scared it's already over."),
  Exchange(0.7444, Speaker.companion, 'Is that what the step looks like to you?'),
  Exchange(0.7544, Speaker.character, 'It looks like someone deciding.'),
  Exchange(0.7656, Speaker.companion, 'It looks like someone not leaving.'),
  Exchange(0.7756, Speaker.character, '…'),
  Exchange(0.7867, Speaker.companion, 'Fifteen minutes on a cold step is a lot of not leaving.'),
  Exchange(0.7978, Speaker.character, 'What if I open it and they walk off?'),
  Exchange(0.8078, Speaker.companion, 'Then they walk off having been asked.'),
  Exchange(0.8189, Speaker.character, "That's worse."),
  Exchange(0.8289, Speaker.companion, "That's clearer. Worse and clearer aren't the same."),
  Exchange(0.84, Speaker.character, "You're very sure of yourself."),
  Exchange(0.8511, Speaker.companion, "I'm very sure of you. Different thing."),
  Exchange(0.8622, Speaker.character, '…thanks.'),
  Exchange(0.8733, Speaker.companion, 'Move over.'),
  Exchange(0.9222, Speaker.character, 'If I do nothing?'),
  Exchange(0.9356, Speaker.companion, 'Then nothing is what you chose. It still counts.'),
  Exchange(0.95, Speaker.character, "That's harsh."),
  Exchange(0.9644, Speaker.companion, "That's arithmetic."),
  Exchange(0.9778, Speaker.character, 'What would you do?'),
  Exchange(1, Speaker.companion, "I'd stay close, and let you choose. So: choose."),
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
