# Device checklist — the Sensory Overhaul

Everything in this file is a thing **a host test cannot decide**: it needs a
handset, a speaker, an accelerometer or a second phone. What follows is the
shortest path from "built" to "trusted". Two of the checks are scripted
(run from `mobile/` with a phone on the cable):

- `python tool/perf_budget.py --serial <serial>` — cold start (median of
  three `am start -W`) and resident memory against the rating's budgets;
  fails today by design (BRAIN §258 records the first numbers).
- `MILES_SUPABASE_SERVICE_KEY=... python tool/two_phone_chat_check.py --a
  <serial> --b <serial>` — one message each way, then the database as the
  oracle: cipher-only rows, no `chat-decrypt` error, both read watermarks
  moved. The §254 run, repeatable.

Order matters: §1 can invalidate work, §2–4 are feel, §5 is the go/no-go
that unlocks a future performance win.

---

## 1. The two defects that already existed (verify the fixes on real hardware)

**1.1 App lock no longer greys the app out.** `LockScreen` returns a
`Positioned.fill` and was mounted under a `RepaintBoundary`, which threw
"Incorrect use of ParentDataWidget" — the error that takes the whole overlay
layer down and swallows every touch. Turn on Settings → Security → Biometric
app lock, background the app, return.
- PASS: the lock appears, the fingerprint prompt works, the app is fully
  interactive afterwards.
- FAIL: grey screen or dead touches → stop and report; the fix is in
  `main.dart`'s root Stack.

**1.2 Modest-mode no longer teleports anyone into Touch.** With modest mode
ON, stand on the Closer tab. On the partner's phone, turn modest mode OFF.
Wait for (or force) a resume on the first phone.
- PASS: you are still in Closer (or on Home), never on the body-photo Touch
  screen.
- Repeat the reverse (modest ON while standing in Touch) → you land Home.

## 2. Sound — the one thing with no host proxy

Settings → Sounds is ON by default. Then:

- **2.1 Latency.** Send a message, press a capsule seal, tap a primary
  button. Does the sound feel attached to the finger, or late? On the
  slowest handset you have, if a cue trails visibly, say so — `tap.ogg` is
  the first candidate to drop to silence.
- **2.2 Your music survives.** Start Spotify/YouTube Music. Return to Miles
  and fire several cues. PASS: your music keeps playing (it may duck
  briefly). FAIL: it pauses and stays paused → the audio-session policy
  needs another pass. *(This was a real bug found in review: every cue used
  to seize permanent audio focus.)*
- **2.3 The bed loops seamlessly.** Breath Sync, let it run two full minutes.
  Any audible click or gap at the loop point? (`bed_air.ogg` is 28s with a
  2s crossfade.)
- **2.4 Discretion.** Mid-capsule-ceremony (the long cue), raise the stealth
  cover (long-press) and separately trigger the panic gesture. PASS: audio
  stops immediately, both times. Also: with a cover up, nothing chimes AND
  nothing buzzes.
- **2.5 Calls.** During a call, have the partner send a message. PASS: no cue
  plays into the mic path.
- **2.6 Vorbis on the oldest device.** If any cue is silent or crackles on
  the MTK-class handset, name which — the format is the suspect.

## 3. Motion — feel and frame time

- **3.1 The ember field.** It was rebuilt (cached glow texture, two
  `drawAtlas` calls, 24fps cap). Compare against your memory of the old
  look: same warmth, same drift? Any banding on the dark gradient?
- **3.2 Frame time.** `flutter run --profile`, open the performance overlay,
  sit on Home for 30s, then scroll. The field is PERF_PLAN hotspot #1 and
  this is the first real measurement it has ever had.
- **3.3 Parallax.** Home's partner card and the capsule orb lean with the
  phone. Check all three postures: held upright, lying flat on a table, and
  in landscape. PASS everywhere: at rest the card sits still (not pinned to
  one side), and tilting moves it a few pixels.
  *(In landscape the horizontal lean may answer mirrored — that is known and
  acceptable. "Stuck at the edge" is not.)*
- **3.4 Battery.** Leave Home open 20 minutes with the screen on. Compare
  battery drain to a build without the overhaul if you can. The accelerometer
  only streams while Home is visible and uncovered — verify by leaving the
  stealth cover up for 10 minutes and seeing no extra drain.
- **3.5 Haptics.** Press feels crisp, Reach's lub-dub reads as a heartbeat,
  nothing double-buzzes.

## 4. Typography and layout

- **4.1 Bundled fonts.** Fraunces and Inter now ship in the APK (no runtime
  fetch). Turn airplane mode ON and cold-start: text must render in the real
  faces immediately, with no fallback-glyph flash or reflow.
- **4.2 Transitions.** Every screen push fades and rises. With the system's
  "Remove animations" accessibility setting ON, pushes and pops must be
  INSTANT — no 300ms dead tap on back.

## 5. Impeller — the go/no-go

`AndroidManifest.xml` still forces the Skia renderer, for a segfault caused
by a `BackdropFilter` under the camera preview that **no longer exists**
anywhere in the app. Flip
`io.flutter.embedding.android.EnableImpeller` to `true` and test:
camera screen, a call with video, the ember field, Watch Together.
- PASS on all three handsets → keep it and re-measure §3.2; Impeller is a
  large win on exactly the animation work this overhaul added.
- Any crash → revert the flag, and record which device and which screen.

---

## What to report back

For each failing item: the device, the screen, and what you saw. For §2.1
and §3.3, a plain sentence about how it *felt* is enough — that judgement is
the whole reason these are yours and not mine.

Also still open, unrelated to feel:
- `ui_sound_kill` is applied to STAGING only. Apply to production after a
  build with the sound layer actually ships.
- The leaked Google Maps key `AIzaSyBa6XGz…` (git history at `5403769`, `b591d90`
  and `75a4459`) wants **deleting, not rotating** — nothing consumes a Maps key
  since Mapbox replaced Google Maps. Match the prefix first: the other `AIzaSy…`
  keys in that project are Firebase's and FCM dies without them.
  See `PLAY-RELEASE-RUNBOOK.md` §2.3.
