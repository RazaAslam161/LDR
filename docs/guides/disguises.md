# Disguises — what the app looks like, and how to get back in

The app ships nine launcher identities. One is active at a time; the launcher
shows that identity's name and icon, and tapping it opens that identity's cover
screen. Behind every cover is the real app — and **the app ships no way through
a cover of its own**. The way in is a move the owner records on that cover, and
the one thing the app defines is the backup way in, which lands on the PIN.

**Maintainers only, and deliberately not printed anywhere a user can read it:
hold two fingers still in the middle of the cover's opening screen for ten
seconds, then unlock with your fingerprint or app PIN.** That is the backup way
in, it works on every cover, and it is the only way in the app itself knows.
Since 2026-09-03 (owner's ruling) the app, the in-app FAQ and the public web FAQ
teach it nowhere; `disguise_test.dart` fails if any of them starts to. Not at the edges: a finger that lands in the
24 dp edge band is not counted, and the other one alone is not the hold.

## The threat model these are built against

Someone who should not see this app picks up an unlocked phone. They are not
forensic. They will tap the icon, look for about two seconds, maybe scroll once,
and move on — *if nothing is odd*.

A disguise fails on: an icon that looks hand-drawn, an app that does nothing
when tapped, a screen that never changes, a name no real app has, and an entry
gesture a curious person would hit by accident. Every decision below is one of
those five.

There is a sixth failure the earlier design had and this one does not: **a door
everyone can read.** The old covers each carried a fixed gesture written into
the app — five taps on the News mark, a hold on the Calculator's `=`, a hold on
the Weather temperature, and so on — printed in the picker, printed in an About
sheet on every cover, printed in this file, and compiled into an APK anyone can
unpack. A door in the listing is not a door. All of them are gone.

## Your own way in

| Cover | What it is | Where the owner records their way in |
| --- | --- | --- |
| **News** *(default)* | A real RSS headlines reader | On the cover's opening screen |
| **Calculator** | A working calculator | On the cover, or a secret number typed and committed with `=` |
| **Notes** | A notepad that really keeps notes | On the cover, or a secret word as a new note's title, committed with Save |
| **Weather** | A day-stable local forecast | On the cover's opening screen |
| **Convert** | Unit and currency converter | On the cover, or a secret number typed as the amount, committed with the swap arrows |
| **Recorder** | A voice recorder that records | On the cover's opening screen |
| **Timer** | Stopwatch + countdown with a real alarm | On the cover's opening screen |
| **Level** | Live bubble level + compass | On the cover's opening screen |
| **Device Info** | Live device and storage statistics | On the cover's opening screen |

### The kinds of move

- **Taps and holds.** A sequence of taps and holds at spots the owner chooses,
  in order. Positions are remembered in short-side units of the safe area, with
  a tolerance the recorder derives from the owner's own two attempts (floored at
  8% and capped at 18% of the short side); hold lengths are remembered as the
  shorter of the two attempts and matched at 60% of that; the whole move must
  fit its recorded window and its gaps.
- **A secret number or word.** Only on the three covers that have a control
  which commits typed text without the keyboard: the Calculator's `=`, the
  Converter's swap button, a new note's Save. Nothing a user merely types is
  ever looked at; only the committed string is compared, against a salted
  SHA-256 in the keystore, in the same format as the app-lock PIN. A note whose
  title was the secret is not saved.

### The accident law, enforced at record time

The recorder refuses, out loud, anything a curious person performs by ordinary
use of a cover (`cover_entry_trigger.dart`, pinned by
`cover_entry_trigger_test.dart`):

- a lone tap;
- a lone hold under three seconds (a reflex press for a menu is shorter);
- a sequence with no hold of at least two seconds, unless it is five or more
  quick taps within three seconds on at least two different spots (the shape
  typing a number never produces — the same spot five times is refused as
  "just typing");
- a hold between 400 ms and 700 ms (too easy to fail on either side);
- for numbers: a straight run, one digit repeated, a round number ending in 000;
- anything shorter than six characters.

Touches that start inside the edge band (24 dp, or the system gesture insets if
larger) are never counted, recording or matching: thumbs rest there, and
Android's own edge gestures cancel there.

### Recording it

Settings › How this app looks › pick a cover, or Settings › Your way in for the
cover already worn. The recorder draws the **real cover** under the same theme
and in the same box the host draws it (`buildCoverWidget`, `coverHostTheme`),
with the same pointer layer over it in record mode, so what is recorded is
exactly what is later matched. Two steps, and only two: do the move, then do
it again. The second is not ceremony — it is where the tolerances come from,
derived from the owner's own variance between the two, and a move they cannot
repeat is refused there rather than stored. Asking a third time was tested on
a handset and cut: it taught nothing the second attempt had not already
proved. Nothing is stored until the caller saves the result, and applying a
cover saves it BEFORE the launcher switch — the switch is where Android may
force-stop the process.

While the move is being set, each tap and hold is **drawn on the screen** as a
numbered mark — a filled dot for a tap, a ring for a hold — so the owner can
see the move they are making instead of guessing. On the second attempt the
first move's marks sit underneath as a faint guide. This is the recorder only:
on the cover itself the layer paints nothing, ever, and that is what keeps a
miss silent.

The instruction card sits at the top and **Hide this** collapses it to one
line, because the top of the screen is somewhere a move may legitimately go
and a card covering it would put that out of reach. **Back** returns to the
choice of kind; on the second attempt **Start over** returns to the first,
because a move the owner cannot reproduce has to be abandonable without
losing the whole flow.

A PIN must exist before a move can be recorded (the picker and the Settings row
both set one up first). App Lock's own on/off switch stays the owner's choice:
with it off, the owner's move opens Miles directly; with it on, the move lands
on the lock. The backup hold lands on the PIN either way.

A move is recorded on the cover's **opening screen** only. Screens a cover
pushes — the note editor, an article — sit above the layer, and back returns to
the opening screen.

### The backup way in

Two still fingers in the middle of the cover's opening screen for ten seconds
(`kCoverRecoveryHoldSeconds` in `cover_gate.dart`; `kBackupSlop` is derived from
it, because a resting finger drifts further the longer it rests and a tolerance
tuned for five seconds makes a ten-second hold impossible). It is **not**
disclosed to users any more — only Play Console's App access notes carry it —
so with a move recorded it may never open the app
on its own: it lands on a **nameless** lock screen (a lock icon, "Locked", and
the biometric prompt first where one is enrolled, the PIN pad otherwise or on
cancel), and back returns to the cover silently.

With nothing recorded — a cover worn before this build, on its first launch —
the hold runs the ordinary lock, which off means straight to the reveal. That
state is not allowed to stand: the shell asks, on every mount and without a
dismiss, to record a move or take the cover off.

Under a screen reader raw touches never reach the pointer layer, so neither
the move nor the hold can fire. While TalkBack is driving, the host draws one
unlabelled-to-sight semantic node, "Unlock", over the cover's title area; it
lands where the hold lands, on the PIN. A stranger who enables TalkBack with
the volume-key shortcut reaches the PIN pad and nothing more — except on a
cover worn with nothing recorded and App Lock off, where it opens like the hold
does, until the shell's setup prompt is answered.

### Failure is silent

Everywhere on the cover: no toast, no ripple, no haptic, no counter, no log. A
miss is a miss and the buffer forgets it. Only the recorder, inside the
authenticated app, ever says anything.

### Where the move lives

One record per cover in the platform keystore
(`miles_cover_entry_<cover>_v1`, `cover_entry_store.dart`), the same store as
the app-lock PIN hash, and beside it one plain-prefs mirror
(`cover_entry_present_<cover>`) that only says a record exists. The mirror is
what the host reads on the first frame; the payload follows. Three modes:

- **none** — nothing recorded; only the backup hold, running the ordinary lock;
- **custom** — the move is loaded and matched;
- **customUnknown** — the mirror says a move exists but the payload could not
  be read (keystore pending or broken): the move is dead, the backup hold still
  lands on the PIN, and the shell reports it once and offers a re-record.

Positions cannot be hashed (matching is tolerant), so a touch move is stored in
the clear inside the keystore-encrypted store; a text move is only a salted
hash. `allowBackup` is off, so a backup holds nothing. A phone with a live
keystore and root can read the template — the same exposure as the PIN hash in
the same store. The PIN lives in that same store, so a keystore wiped clean
takes both: the mirror then says `customUnknown`, and on a phone with no
biometric the backup opens through the no-key floor — the never-lockout rule
winning, as it must. The move is a property of the phone, like the alias and the
lock: it survives sign-out, and a second account on the same handset changes it
from Settings.

### What a stranger learns

Nothing from the APK: no cover file names a door, and `disguise_test.dart` pins
that (no cover reaches the gate, the lock or the store; no cover wires a
long-press handler). Nothing from the cover: no About sheet, no printed gesture,
no reaction to a miss. Nothing from the listing or the FAQ either, since
2026-09-03 — the hold is told only to Play Console.
From watching the owner: the move — a watched unlock still leaks it, as it always
did the fixed one.

## Icons

All nine are drawn programmatically by `mobile/tool/generate_icon.dart` and
written at every mipmap density:

```
cd mobile && dart run tool/generate_icon.dart
```

It writes four bitmaps per icon — the legacy tile, the adaptive background, the
adaptive foreground and the monochrome layer — 180 files. Edit the spec in that
file, never the PNGs.

Rules the generator enforces or encodes:

- **Nothing imitates a real brand.** The previous News icon was a copy of a
  well-known company's letterform in that company's exact brand hexes, in the
  launcher icon *and* in the cover's masthead. Both are gone. A counterfeit of a
  mark people know by heart is a worse disguise than an unremarkable one, quite
  apart from being someone else's trademark.
- **Contrast is checked, not asserted.** `_assertContrast` fails the build if
  any mark falls below 3.0:1 against its own background — the level's ochre vial
  on sand was 1.9:1 before it was darkened.
- **The set does not look like one designer.** Nine matching tiles on one home
  screen is itself the anomaly, so the backgrounds use four different light
  models (linear gradient, radial highlight, flat, and one circular tile).
- **Monochrome layers are authored.** Android tints them by alpha, so a solid
  silhouette turns the mic into a lozenge and the notepad into a slab. The
  `cut` flag punches the real holes.

## The surfaces that are NOT disguised

Worth knowing before trusting this too far.

- **Settings › Apps still says "News".** That name comes from
  `<application android:label>`, which is fixed when the app is installed;
  no app can change it at runtime. The launcher name and icon change; the
  system app list does not. The picker says so on screen.
- **The lock screen.** The backup hold shows a nameless lock; the owner's own
  move, with App Lock on, shows the app's own lock. Both are visible — that is
  the accepted cost of having a way in at all.
- **Notification channels.** Listed under whatever the launcher calls this app,
  so every channel name is deliberately generic ("Alerts", "Voice", "Timers").
  Guarded by `test/unit/disguise/disguise_notification_test.dart`.
- **Launcher shortcuts.** There are none, on purpose — a long-press popup
  offering "New note" would name a feature the cover cannot explain. Guarded by
  a test.
- **A watched unlock.** Whoever watches the owner do their move has it.

## Adding a disguise

Five places, all checked by tests:

1. `mobile/tool/generate_icon.dart` — add an `_IconSpec`, re-run it.
2. `mobile/android/app/src/main/res/mipmap-anydpi-v26/` — the adaptive-icon XML.
3. `mobile/android/app/src/main/res/drawable/ic_notif_<name>.xml` — the
   notification silhouette.
4. `AndroidManifest.xml` — one `<activity-alias>`, `android:enabled="false"`.
   Exactly one alias in the file may ship enabled, and it must be the catalog
   default.
5. Dart — a `DisguiseCover` value, a `DisguiseProfile` in
   `disguise_profile.dart`, a cover screen that is a plain fake app (no
   callback, no gate, no long-press handler — `disguise_test.dart` refuses
   any of them), a branch in `buildCoverWidget` in `disguise_cover_host.dart`,
   a style in `disguise_notification.dart`, and a row in the table above. If
   the cover has a control that commits typed text without the keyboard, it
   may hand the committed string to `CoverEntryScope.maybeOf(context)
   ?.feedText(text, commit: true)` and add a `TextSlot` — never from a
   keyboard `onSubmitted`.
