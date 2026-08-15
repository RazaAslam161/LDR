# Product brief — what to build next

Generated 2026-08-15 by a 10-agent tournament: six independent idea lenses, three
judges scoring retention / feasibility / coercion-risk separately, then synthesis.
25 ideas generated, 2 gated as unsafe.

> **CORRECTION to section 1(a) below:** the brief claims E2EE is off and RLS is the
> sole privacy boundary. That is WRONG. It came from docs/REFERENCE.md:164, which is
> stale — it describes the 2026-06-25 state and points at lib/core/crypto_core.dart,
> a path that no longer exists. The real file is lib/core/data/crypto_core.dart and it
> performs XChaCha20-Poly1305 AEAD (see _aead.encrypt at :314, _aead.decrypt at :380).
> Encryption is ON. REFERENCE.md needs fixing before it misleads anyone else.

# MILES — WHAT TO BUILD NEXT

## 1. THE STRATEGIC ANSWER

The hard truth first: **you cannot port Snapchat's engine, and the part of it that does port is the part you are ethically forbidden from using.** Snapchat's pull is audience — variable reward from an unpredictable crowd. At N=2 that machinery is simply absent, and no amount of design recovers it. The one Snapchat mechanic that *is* dyadic is reciprocal obligation ("you owe me a snap today"), and between romantic partners that is a coercion instrument, not a feature. So the honest retention theory for Miles rests on three things a crowd app cannot do and WhatsApp structurally refuses to do. First, **the archive compounds**: Miles is the only place that holds this couple's history, and an artifact that gets denser every year is switching cost you cannot buy elsewhere — but today Miles has roughly thirty write surfaces and exactly one read surface (`timeline_screen.dart`, which renders hand-typed `visits` and nothing else), so nothing that was written is ever encountered again. Second, **simultaneity is genuinely scarce across timezones and genuinely unpredictable** — that is a real variable-interval schedule with no crowd required, and `presence` currently spends it on a green dot. Third, **withholding**: Miles can hold something back — until they wake, until you both put something in, until you are in the same room — and a general-purpose messenger never will, because delivery is its whole product. The binding constraint on all three is one rule: *the loop must never make absence legible.* Every mechanic that produces a number, a receipt, a streak, or a timestamp hands one partner evidence to use against the other, and in this app that is the failure mode that matters more than churn.

**Two facts to hold while reading the rest.** (a) E2EE is currently *off* — `lib/core/crypto_core.dart`'s encrypt/decrypt are identity base64 pass-throughs as of 2026-06-25 and **RLS is the sole privacy boundary** (`docs/REFERENCE.md:164`). Every design below is built so it holds identically whether or not you restore real crypto — but do not describe the app as encrypted to its users today. (b) No update channel means **no tunable parameters**: every constant below is baked client-side or into a migration, and nothing needs retuning after release.

---

## RULE ZERO — ship this invariant before any feature (from "Nothing to Show")

Not a feature; a checklist you apply to every screen you touch from now on. **No surface in the app may reveal that a privacy option was exercised.** No "sharing paused", no "message deleted", no "1 hidden", no locked placeholders, no gaps in counts, no per-partner sharing summaries. Every off state renders identically to *nothing here*. Server-side it is subtractive: `presence.location_sharing_mode` is readable by the partner today (`presence_service.dart:57`, consumed in `home_screen.dart`), which makes "you set it to off" arguable — drop it from the row. Same for `chat_last_read` used as a receipt.

**Cut the decoy-PIN half of that idea.** A second PIN that opens a plausible, populated fake module is a whole parallel dataset that has to stay convincing for years; it is a feature masquerading as an invariant. Ship the invariant, skip the decoy.

The general law it establishes, which decides several calls below: **a privacy control whose exercise is visible is worse than no control**, because switching it on becomes the demand.

---

## 2. THE SLATE

### 1. Rerun (+ Again as its second verb) — the cheapest thing here and the highest-value

Treat **Rerun and Again as one feature**, not two. They occupy the same slot on Home and share one selection engine.

**Concretely.** Both phones independently pick the *same* single artifact from the couple's own history each day and render it as one card — one item, no next, no feed. Candidates come from plaintext metadata columns that already exist: `gallery_items.created_at`, `messages`, `love_reasons.created_at`, `capsule_items`, `memory_threads.happened_on`, and paired `prompt_responses`. Selection is `index = hash(coupleId + dayNumber) % count` — deterministic, on-device, no server decides anything. This is the identical trick `promptForDay(date)` already uses (`daily_prompt_repository.dart:33-35`). The card has two verbs: **Keep** (a mark — a line, a voice snip — pinned permanently back onto the original artifact, so next year's Rerun of a Year-1 photo shows the Year-2 mark underneath and you add a Year-3 one) and **Again** (re-ask an old `prompt_response` today; the new answer sits beside the old one).

**Combines:** `gallery`, `chat`, `timeline`, `capsule`, `reasons`, `daily_prompt`, and `closer/memory_threads` — into one surface instead of a tenth silo. It also fills **`memory_revisits`**, a table that exists in the schema (`REFERENCE.md:267`, PK `memory_id → memory_threads`) with **zero code references anywhere in `lib/`** — the intent was designed and never built.

**Loop.** Reminiscence bump + endowment effect. Facebook's On This Day beat new content on daily opens precisely because resurfacing costs the user nothing to produce. Facebook's version misfires constantly because it resurfaces exes and funerals from a graph of 800 people it does not understand; at N=2 the archive is one relationship where both parties consented to every item. Being tiny makes this mechanic *better*, which is true of nothing else on the list.

**Why not WhatsApp.** WhatsApp has the messages and will never show them to you again. Scrollback is not a read path — nobody scrolls to March. And the marks make the object appreciate: the artifact is worth more each year, and it only exists here.

**Also fixes a live defect.** `promptPool` is 20 hard-coded strings selected `dayOfYear % 20` — it repeats every 20 days forever, and with no update channel you can never extend it. That is actively churn-inducing. Rerun replaces the pool with an unbounded one the couple writes themselves.

**Cost.** The cheapest tier on this list. One `marks` table (couple_id, target_kind, target_id, ciphertext, created_at), one selection function, one Home card. No push, no native code, no server work, no new dependency, no migration beyond the one table.

**Before you start:** count the rows. If `gallery_items` + `prompt_responses` + `love_reasons` is under a couple of hundred, the first month is thin — seed the candidate pool from chat photos, which is the one table that definitely has volume.

**Coercion.** Lowest of anything active. Demands nothing of the partner; absence is unobservable by construction. Long-press → *not this one* removes an artifact from the pool permanently and **silently** — the other partner is never told an item was retired, because a visible veto is itself an argument. Never show "partner viewed this" and never show a mark count.

---

### 2. The Handoff — the highest retention that survives the ethics filter

Build the **on-device (ldr-pain) variant**, not the cron variant. It is materially cheaper and needs no dormant column collected.

**Concretely.** `partner_sentence.dart` already infers "she is probably asleep" from `profiles.timezone` + `TzHelper` + `ServerClock` and renders it as a label. Promote it from a label to a *state*. When your partner crosses into their night, Home's Reach button becomes Night Watch. Anything you send during their night — chat message, photo, voice note, Reach — delivers normally but is also tagged into an open handoff row for that night; no new capture UI, it piggybacks on writes those features already make. Before you sleep you may seal one thing: 15s of voice, a photo, or a line. On their first app open after their local sunrise, they get **The Night**: your sealed thing plays first, then everything you left while they were dark, in order, each stamped with what time it was on *your* clock. Sealing nothing does not stop you receiving.

**Combines:** `home/partner_sentence`, `chat`, `photo`, `reach`, `closer/closer_crypto` (for sealing), and `core/services/server_clock`. It also finally gives a purpose to `rituals.deliver_at` / `rituals.delivered` — columns that exist and whose scheduled delivery `ritual_repository.dart` documents in-code as **not implemented** (confirmed: the deployed edge functions are `care-notify`, `map-token`, `reach-notify`, `reap-storage`, `turn-credentials` — there is no delivery worker).

**Loop.** Snapchat's reciprocal daily exchange with the counter amputated and the simultaneity requirement removed — which is the specific thing that makes Snapchat's version untranslatable to LDR. Plus a Zeigarnik open loop: you fall asleep knowing something of yours will be opened in a few hours. It claims the first waking minute of the day, the highest-intent moment in an LDR day, currently owned by nothing in the app. The trigger is sleep — an unmissable biological event — not an arbitrary streak.

**Why not WhatsApp.** WhatsApp delivers instantly, which is exactly wrong: your 2am message lands in a pile they scroll past at 8am. WhatsApp cannot *hold* something until their sunrise, cannot seal it so you can't preview it either, and cannot stamp the arrivals to your clock so the night reads as a night.

**Cost.** One `handoffs` table (couple_id, sleeper_id, window_start, window_end, opened_at) plus a nullable `handoff_id` on rows chat/photo/reach already insert. The night window computes **on-device** from `profiles.timezone` + `ServerClock` — the same two inputs `partnerSentence` already uses — so no pg_cron worker, no edge function, no dependence on `profiles.wake_time`/`sleep_time`, which I verified are read (`partner_sentence.dart:90`) and **written by nothing**. Push is at most a silent data message; the payload lands in-app on open, so the disguise is untouched. Medium build: a few days, and most of it is the morning screen.

**Hard dependency:** the receiving screen must **never render an empty state** — when nothing was left, it shows a Rerun. That single detail is what stops the feature dying in a quiet week and what makes absence unrenderable. Do not ship Handoff before Rerun exists.

**Coercion.** This is streak-shaped, so three rules are load-bearing: (a) **no counter, ever** — no "12 nights in a row", because the number is what gets quoted at someone; (b) absence is invisible — no read receipt, no delivered tick, no per-night history, and the sender genuinely cannot tell from the app whether anything was opened; (c) The Night reports only what *they* sent, never what *you* did — no open time, no "seen at 3am". Note the residual honestly: The Night compiles the partner's dark hours into a timestamped digest, which is marginal over chat timestamps but foregrounds them by design. If you want to reduce that, stamp arrivals to the hour, not the minute.

---

### 3. Sealed — reciprocity driven by self-interest instead of guilt

**Concretely.** A send mode, not a screen. Any photo, voice note, or line can be sent **Sealed**. On their phone it appears as a weight — a shape with a shimmer, no preview, no sender-chosen teaser. The only affordance is *put something in*. They record or write something **without knowing what is inside**; the instant their half lands, both halves unlock simultaneously on both phones and it becomes an ordinary pair of messages. One live outbound seal per person, so envelopes cannot stack into a pile of debts.

**Combines:** generalises the mutual-reveal `daily_prompt_repository.dart` already ships (both must answer before either sees) from one screen into a mode across `chat`, `photo`, and voice.

**Loop.** The Hooked investment phase moved *before* the reward — a blind bid. You cannot predict what they sealed, and you find out only after your own cost is sunk. The deep move: it inverts reciprocal obligation. Instead of "you owe me a reply", the pressure lands on the person who *wants to open*. Nobody has to be made to feel bad for the loop to close.

**Why not WhatsApp.** WhatsApp cannot make a message unreadable-until-you-reciprocate. The gate must be enforced server-side or it is theatre — and that means a database that will refuse, which is not something a general messenger will ever build.

**Cost.** One table plus one RLS policy: each half's payload row is SELECT-able only via `exists (select 1 from sealed_halves h where h.envelope_id = ... and h.from_user = auth.uid())`. Postgres refuses the row, so a patched client cannot peek — this holds under RLS-only *and* under restored E2EE, because the server arbitrates by row existence and never reads content. The real work is not the gate; it is wiring a Sealed mode into three separate send paths, each with its own composer. Budget for that.

**Coercion.** Sender-blind by construction: the sender learns exactly one thing, the reveal, at the moment it happens. No age, no unopened badge, no "seen", no chase push, and **no distinction between "not yet" and "declined"** — the receiver can dissolve a seal and the sender simply never hears about that one.

**One restriction the judge is right about and I am making mandatory: Sealed must be unavailable inside the Closer modules.** The gate is "produce something before you may receive", and pointed at `desire`, `fantasy_jar`, `private_vault` or `touch_trace` it becomes a lever to extract intimate content blind — you cannot see what you are trading for, and you cannot refuse once committed. Whitelist Sealed to `chat`, `photo`, and voice notes only.

---

### 4. The Box — the highest payoff-to-new-code ratio in the repo

**Concretely.** The moment a `visits` row is added with a future `start_date`, Home surfaces *the box for March 14*. Either partner drops notes, photos or voice clips in; neither can read the other's deposits, because `capsule_items_select_unlocked` already refuses to SELECT items until the parent capsule's `unlocked_at` is set (verified, `REFERENCE.md:271`). Nobody has to remember the feature exists or hand-pick `unlock_mode: proximity` — the visit creates the capsule. At the reunion `ProximityService` sees both phones within 100m and fires `unlock_capsule`. On open, the contents seed a `memory_thread` with `visit_id` set, and photos land in `visit_memories`.

**Combines:** `capsule` (`proximity_service.dart` — ephemeral `capsule_proximity:<coupleId>` broadcast, Haversine computed on-device, coordinates never persisted), `timeline`/`visits`, and `closer/memory_threads`. It activates two dormant things I verified: `MemoryThreadRepository.propose(visitId:)` accepts a `visitId` that its only caller never passes, and **`visit_memories`** (`REFERENCE.md:231`) has zero code references in `lib/`.

**Loop.** Zeigarnik tension plus delayed gratification, gated on a real-world event neither partner can trigger alone. This is the exact inversion of the streak pathology: Snapchat rewards opening the app daily, so the reward is farmable and the anxiety manufactured. A box that only opens when you are physically together cannot be farmed, and the anticipation it builds is anticipation of the thing the couple actually wants. It closes the app's only complete narrative arc — anticipate, reunite, keep — using three features that currently do not know each other exists.

**Why not WhatsApp.** WhatsApp has no concept of a future date that changes what you can read.

**Cost.** Mostly wiring. Every leg is in the repo already. The honest constraint: both apps must be foregrounded at the reunion for the broadcast to meet, so surface a quiet in-app prompt when the visit date arrives rather than pretending a background service will catch it.

**Coercion.** Keep the existing property that coordinates are never persisted or sent, and additionally **never display distance-to-partner** — only the boolean the service already computes on-device. **The load-bearing defuse is a unilateral date fallback: the box also opens at visit end + 1 day, by either partner alone.** Without it, a partner who cannot or will not travel is holding the other's letters hostage, and someone could be pressured into a trip to retrieve their own words. Deposits stay withdrawable until first unlock, so nothing written in a good week is trapped in a bad one.

**Retention caveat, stated plainly:** this is bursty. It has real pull while a visit is on the calendar and none the rest of the year. Build it because it makes the app feel finished and it costs almost nothing, not because it produces Tuesday opens.

---

### 5. Overlap — but in-app only, with the push deleted

**Concretely.** When both `presence` rows have been online for ≥60s and neither is in a call, a **Window** opens on both phones at the same instant: one card, live 3 minutes, identical on both screens, drawn from a shared no-repeat bag seeded on `hash(couple_id + shared date)` so both phones draw the same item with no server round-trip. Items are only possible when both are present — point your camera at whatever is in front of you for 3 seconds, never saved; press play on the same track together; one line that deletes itself when the Window shuts. Either person closes it; it closes itself when either goes offline. Underneath sits **one** number: minutes overlapped this week, joint, never split by person, decaying slightly on a quiet day and never resetting to zero.

**Combines:** `core/services/presence_service.dart` (`is_online`, `current_screen`, channel `presence:<coupleId>`), `RealtimeService.broadcast`, `NoRepeatBag` (`lib/features/games/no_repeat_bag.dart`), and the deterministic-shared-seed idiom from `promptForDay`. `breath` and `heartbeat` are the obvious second-wave Window contents.

**Loop.** Variable-*interval* reinforcement with a human clock instead of an algorithmic one. The payoff exists only live and cannot be caught up on later — that is the one genuinely anti-decay property in the whole set, and it is what streaks fake with a counter.

**Why not WhatsApp.** WhatsApp shows a green dot and does precisely nothing with it. Overlap spends the couple's scarcest resource instead of displaying it.

**Two required changes to the idea as written.** (1) **Delete the FCM push.** An edge function firing on `presence` UPDATE is an *awake-detector*: "the app pinged me at 2am, so you were up" is evidence a controlling partner can quote, and no amount of dull copy fixes that. Fire the Window client-side off the realtime subscription both phones already hold — a Window is only meaningful if you are both already looking, so a push is not merely risky, it is pointless. This also removes the debounce problem entirely (presence writes every 30s per user; a webhook on that is a bad idea regardless). (2) Be honest that the item pool is thin. Three item types become a known ritual within a few weeks; either invest in the pool or accept Overlap as a garnish rather than a pillar.

**Cost.** Medium — a new Window UI is the bulk of it. No server work at all once the push is dropped.

**Coercion.** Never render anything of the form "they were online 4 hours and you did not overlap" — no absence metrics, ever. Keep the minute count joint. A private *not tonight* suppresses Windows for the rest of the day and is invisible to the partner, so a declined Window and a missed Window are indistinguishable from the other side. Decay-instead-of-reset removes the cliff: nothing can be "broken", so nobody can be blamed for breaking it. Note the residual the design does not fully solve: at N=2 a joint number is per-person by subtraction — I know my own contribution, so the shortfall is you. Keep the number small, unlabelled and slow-moving, or leave it out.

---

### 6. Tucked — the honest way to manufacture variance at N=2

**Concretely.** Long-press almost any surface — the 6am line on the routines chart, the third card in the reasons jar, the mood lamp, next month on the cycle calendar, a photo in the gallery — and tuck a voice note, photo or line behind it. She is told nothing: no push, no badge, no "you have 1". Days later she opens routines to tick Fajr and the surface comes apart in her hands. Max three live per person; the finder can dissolve one without the sender learning which.

**Combines:** `routines`, `reasons`, `cycle`, `gallery`, and closer's `mood_lamp` — it makes ten dormant modules worth visiting, which is the cheapest way to make features you already built pay rent.

**Loop.** You cannot manufacture volume at N=2, but you can manufacture **search space**. Every screen carries a small non-zero probability of containing something — variable-ratio reinforcement where the variance is spatial rather than social, so it needs no crowd.

**Why not WhatsApp.** WhatsApp has one surface. Tucked only works in an app with forty rooms, which is the one asset Miles's sprawl actually gives you.

**Cost.** One table (`couple_id, from_user, anchor_key, payload, found_at`) where `anchor_key` is a stable string naming a surface (`routines:fajr`, `reasons:3`, `mood_lamp`, `cycle:2026-09`), plus one wrapper widget. The cost is breadth, not depth: mechanical integration across five or six screens.

**Two required changes.** (1) **The find notification is a monitoring primitive** as specified — tuck one behind the cycle calendar and you learn exactly when she opened the cycle calendar, three renewable tripwires at a time. Fix it by **decoupling the signal from the event**: the sender is told *that* something was found, batched and delayed to the next day boundary, never *which* and never *when*. (2) Nothing may be tucked into a Closer module unless the recipient has opted that surface in — a surprise behind a PIN-and-biometric gate is an ambush inside the one place designed to require deliberate consent.

**Coercion.** The sender never sees an unfound count, an age, or a location list. They get the find or they get nothing. Unfound tucks are silently reclaimable by the sender with no trace either way. The three-item cap stops the app becoming a minefield you are obliged to sweep.

---

### 7. Ember — nearly free, and the correct replacement for a streak

**Concretely.** One small warm object on Home. No number, no day count, no "best ever". Any act of tending warms it — sending anything, ticking a routine, answering the daily prompt, adding a reason. Warmth is a decay curve with a ~5-7 day half-life, so one quiet day is imperceptible and a quiet fortnight is a soft visible cooling. There is no zero and no broken state; the floor is a dim ember that relights fully on the first touch. Solo acts count exactly as much as reciprocal ones. It never pushes.

**Cost.** The least code of anything here. One table `hearth_events(couple_id, local_day)`, insert-if-absent, **no user_id and no content** — the server sees a couple id and a date. Local date computed device-side, the pattern `RoutineRepository.today()` already uses and documents (two timezones make a server-side midnight for neither). Decay constant is a client-side constant, so nothing to tune.

**Be clear-eyed about what it is.** Every property that made streaks retentive has been removed, correctly, and what remains is ambient decoration nobody opens the app to check. It is worth building only as a *replacement* — it occupies the slot a streak would otherwise take, and its presence is the argument against ever adding one. Do not expect opens from it.

**Coercion.** Dropping `user_id` is the clever part: "I do all the work" has no data to appeal to, so the scorekeeping argument cannot be settled and is therefore not worth starting. Residual, stated honestly: it is still a visibly cooling object between two people, and cooling is attributable by subtraction — which is why the cooling must stay slow, unquantified, and fully reversible with one act.

---

### 8. The genuine bet: Drift

**Concretely.** A *for whenever* pile. Drop in a line, a photo, a voice note, with no recipient action expected. The sender attaches a condition rather than a time — "when she's up before me", or nothing at all. The receiving device holds the pile and releases at most one or two a day at moments neither party can predict. The sender is never told when it landed or whether it was opened. The item has **no reply affordance**. Undelivered items expire silently rather than accumulating a badge. The receiver sets a per-day cap, including zero, and the sender is never told.

**Loop.** This is the actual variable-ratio schedule rebuilt at N=2: Snapchat's unpredictability comes from an unpredictable crowd, here it comes from unpredictable *timing* over a stockpile the partner already made. The asymmetry is the point — the sender does the work in advance, so the receiver gets pure intermittent reward carrying zero debt. "You didn't respond" cannot form as a grievance because nothing was asked.

**Why it is a bet.** The refill loop has no reward attached. The sender is told nothing about landings or opens — correct for safety, but it means the only thing motivating a restock is faith, and **an empty pile is a dead feature**. You will not know if this works until it has run for a month. Ship it small and be willing to delete it.

**Cost.** The pile, an opaque `not_before`, and client-side release are straightforward. **Ship conditions v1 as "no condition" plus "local time of day" only.** "When it's raining there" needs a weather API; "three days without a call" needs a local event log that does not exist (`call_invites` records an offer with no end time). And drop that second one permanently regardless — see section 3.

The disguise helps rather than hurts here: a generic "News · 1 update" cannot spoil a surprise.

---

## 3. WHAT NOT TO BUILD

### Developing — REFUSED

*The idea:* a gift arriving at 16 pixels that sharpens as a joint progress counter climbs on things the couple already does — Overlap windows, daily prompts, routine ticks, breath sessions — with RLS releasing resolution layer N only when progress ≥ N.

**Abuse scenario.** A visible bar unlocking a withheld gift is obligation by construction: *"we're at 80%, just do the prompt tonight."* "No per-person split" is not a defusal at N=2 — I know exactly what I contributed, so the remainder is provably you. And the escape hatch makes it worse rather than better: once the sender *can* release it with one tap and doesn't, withholding stops being a mechanic and becomes a deliberate, pointed-at choice. It turns every existing feature — routines, rituals, breath, daily prompt — into a chore with a hostage attached, which is the precise opposite of what you want those features to feel like. Two engineering problems confirm it is not worth fighting for: 8× storage per item, and a voice note has no meaningful progressive-resolution ladder at all, so half the stated payloads don't work.

**Safe alternative:** **Sealed**. Same withheld-object pull, but the cost is paid once by the person who wants to open, not extracted over days from the person who doesn't.

### Room Tone — REFUSED

*The idea:* mutual, timer-limited ambient mic loudness — RMS quantised to four levels at 0.5 Hz, no audio ever leaving the device — rendered as a glow and a haptic floor.

**Abuse scenario.** An ambient mic channel between partners is a checking instrument no matter how coarse the quantisation. Four levels at 0.5 Hz still tells you the room went quiet, got busy, or is a bar — *"it was loud at 11, where were you."* The hard session timer forecloses "always on" only until it is restarted, and the mutual-accept invite is the trap: once it exists, declining it *means something*, so the invite itself becomes the demand. That is exactly the shape Rule Zero forbids. The cheapness of the build (no new dependency — `record`'s `onAmplitudeChanged` is already in use in `disguise/covers/recorder_cover.dart`, and `flutter_foreground_task` is already wired to the disguise notification) makes it tempting, which is why it needs an explicit refusal rather than a backlog entry.

**Safe alternative:** none that keeps the mic. If you want ambient co-presence, use **Overlap** — presence without a sensor channel.

### Front Page / Their Sky (home-screen widgets) — REFUSED for now, and Front Page is the painful one

*The idea:* their latest photo living inside a genuine-looking news or weather widget on your home screen.

**Abuse scenario.** Two vectors, and the second is disqualifying. First, the sender pushes uncontrolled imagery onto the receiver's home screen, in public, with cover mode as the only after-the-fact recourse — that is a harassment surface as much as an affection one. Second and fatal: **compliance is verifiable from outside the app.** *"Show me your home screen."* Every in-app silence guarantee you build — no delivery receipt, no view count, no "partner covered it" state — is defeated by one sentence in a phone call. Rule Zero says an off state must be undetectable; a widget's off state is detectable by looking at the phone. There is also a real disguise regression: `FLAG_SECURE` does not extend to widgets.

This is the painful refusal, because Locket is the only couples product that empirically retained anyone, and it did so precisely because the reward needs no session. Note the honest engineering cost too: the only Kotlin in the repo is `MainActivity.kt`, `home_widget` is not a dependency, and Their Sky additionally specifies a triple-tap-with-timed-revert that RemoteViews cannot do — home-screen widgets support click handlers only, so the actual hook is the part that doesn't build.

**Safe alternative:** none that is a home-screen surface. If you ever revisit it, the only defensible version is receiver-controlled: the *receiver* chooses which photo is shown and when it changes, which kills the sender hook that made it worth building.

### The Ping (BeReal at N=2) — REFUSED

*The idea:* a server picks one random minute in the couple's shared awake window and both phones fire; you cannot see theirs until you send yours.

**Abuse scenario.** A daily front-camera capture of wherever you are, gated on sending yours, is a whereabouts-and-companion prover with an app-legitimated demand attached. *"It's not me asking, the app asked"* is the best line an abuser could be handed. Removing the counter and the history is ethically right but doesn't touch it — the leverage is in the capture itself, not the record of it. Also note the premise is unbuilt: `profiles.wake_time`/`sleep_time` are read in `partner_sentence.dart` and written by nothing, so there is no shared window to schedule against.

**Safe alternative:** **Overlap**. Same "both of you, right now" payoff, but the app never demands a capture and never asks for your face or your surroundings.

### Hours (cumulative time-together counter) — REFUSED as a visible number

*The idea:* have `watch_sessions`, calls, and `breath_events` each leave one row on end, producing a lifetime "412 hours in the same room" figure to replace the Timeline's `daysApartSinceLastVisit`.

**Abuse scenario.** Monotonic-only does not stop a human from differencing. Read the number weekly and you have a rate — which is exactly the *"you're giving me less than you used to"* instrument the monotonic rule was invented to prevent. Any visible cumulative figure is a trend line to a determined observer.

**Safe alternative, and do build this half:** the *emission* is fine and worth doing — one small row on session end (kind, start, end) so the archive stops discarding hours the couple actually spent. Feed those rows into **Rerun** as candidate artifacts ("you were on a call for 2h14m on this night last year"), which is a memory, not a metric. But **do not render a running total anywhere.** And while you are in there: `_Stats.compute` in `timeline_screen.dart` currently makes `daysApartSinceLastVisit` its most prominent figure — a number that grows when things are bad. Delete it regardless of what else you build.

### Rooms, Nightside, Open Line — not now

**Rooms** (self-declared place with a photo): manual status is the most reliably abandoned pattern in consumer software (Foursquare check-ins, Slack statuses), eight rooms are exhausted in a fortnight, and worse, self-declared place turns location into a *falsifiable claim you can be caught on*, with an opt-in geofence a controlling partner can demand per-room. **Nightside** (sleep light + morning haptic): the payload is sleep and wake time, the most weaponised signal class there is, the 20-minute jitter narrows rather than removes the wake proof, and per-night arming is itself a nightly compliance check — plus the core payoff is a data-only FCM delivered to a killed app on a Vivo and a OnePlus, the least reliable path on Android. **Open Line** (always-open silent call): the line's open/closed state is live and visible by design, so *"keep it open"* is an easy demand with continuous, effortless verification; the promised battery win also evaporates, since per-press WebRTC setup costs seconds of ICE so in practice you hold the connection and toggle the track.

### One condition to never implement, in any feature

Drift's proposed trigger **"next time we go three days without a call"** is automated punishment-for-absence with a message attached. It is the single most coercive line in the whole idea set. Do not ship it, and treat any future condition of the form *"if they haven't X"* as forbidden by the same rule.

---

## 4. THE ONE THING

**Build Rerun.**

The diagnosis behind that choice: **Miles is all write path and no read path.** Thirty modules create artifacts, and exactly one screen shows any of them back — `timeline_screen.dart`, which renders hand-typed `visits` and nothing else. `prompt_responses` accumulate and are never read after the day they are written. `memory_revisits` exists in the schema with zero code references. `visit_memories` exists with zero code references. Every couples app that died — Between, Couple, LoveByte — died the same way: they shipped a shared album and never shipped a reason to open it. Miles has already built the album ten times over. Nothing compounds until something reads it back.

The tactical case is just as strong. It is the **cheapest** item on the slate — one table, one deterministic selection function copying `promptForDay`, one Home card, no server work, no native code, no push, no new dependency. It has the **lowest coercion risk** of anything active, because it demands nothing of the partner and absence is unobservable by construction. It **fixes a live defect** — a 20-string prompt pool cycling every 20 days forever with no update channel to extend it. It **retrofits value onto ten modules you already shipped** without adding an eleventh silo. And it is a **hard prerequisite for The Handoff**, which is the highest-retention idea that survives the ethics filter: the thing that stops Handoff from becoming a guilt machine is that the morning screen never renders an empty state, and the never-empty state *is* a Rerun. Build the read path first and the best feature on the list becomes a small delta on top of it. Build Handoff first and you will either ship an empty-state that says "nothing today" — the exact sentence this entire brief exists to prevent — or you will build Rerun anyway, in a hurry, badly.

One week. Then measure the only thing worth measuring: whether either of them opens the app on a day when neither has anything to say.