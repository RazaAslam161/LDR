# Disguises — what the app looks like, and how to get back in

The app ships nine launcher identities. One is active at a time; the launcher
shows that identity's name and icon, and tapping it opens that identity's cover
screen. The real app is behind a hidden gesture on the cover, then the app lock.

**If you remember nothing else: the way in is in the table below, and the picker
inside the app (Settings › How this app looks) prints it under every option.**

## The threat model these are built against

Someone who should not see this app picks up an unlocked phone. They are not
forensic. They will tap the icon, look for about two seconds, maybe scroll once,
and move on — *if nothing is odd*.

A disguise fails on: an icon that looks hand-drawn, an app that does nothing
when tapped, a screen that never changes, a name no real app has, and an entry
gesture a curious person would hit by accident. Every decision below is one of
those five.

## The table

| Disguise | Icon | Cover | The way in |
| --- | --- | --- | --- |
| **News** *(default)* | Crimson tile, article card | A real RSS headlines reader | Five quick taps on the masthead mark, top left |
| **Calculator** | Charcoal tile, four operators | A working calculator | Hold `=` while the display reads 0 and nothing is pending |
| **Notes** | Orange tile, folded page | A notepad that really keeps notes | Hold the empty-state artwork, which only shows with no notes |
| **Weather** | Blue tile, sun and cloud | A day-stable local forecast | Hold today's big temperature reading |
| **Convert** | Teal tile, arrow cycle | Unit and currency converter | Hold the swap arrows with both sides on the same unit and the amount empty |
| **Recorder** | Near-black tile, outlined mic | A voice recorder that records | Hold the 00:00 readout before recording anything |
| **Timer** | Green circle, stopwatch | Stopwatch + countdown with a real alarm | Hold **Reset** on the Stopwatch tab while it reads 00:00.00 |
| **Level** | Sand tile, spirit level | Live bubble level + compass | Hold the angle readout with the phone lying flat |
| **Device Info** | Indigo tile, bar chart | Live device and storage statistics | Hold the battery ring |

The News cover keeps one spare door from the original design: a 2.5-second
press on the **Local** item in the bottom bar. A tap there navigates, as it
looks like it will; only a deliberate hold does anything else.

Two other News doors were removed for failing the rule below. Submitting `home`
in the search box opened the gate — but searching a news reader for "home" is
something a person does on purpose. A plain long-press on the **Local** section
tab opened it too, and long-pressing a tab to check for a menu is a reflex.
Both put a biometric prompt in front of whoever was holding the phone.

## The visible ring

Every cover also draws one small ring near the top right (`CoverExitButton`).
It is the same door: tapping it runs the entry flow, app lock included. The
gestures above exist for the moment someone else is holding the phone; the
ring exists for the owner, whose memory of one confirmation dialog used to be
the only way back — a forgotten gesture was a lockout with no recovery short
of a reinstall. It is quiet and unlabeled, and what a curious tap gets is the
nameless system unlock prompt — which is only true because App Lock is a
PRECONDITION of wearing a cover: the picker refuses to apply one without it,
and the shell keeps asking any install whose cover predates that rule. A ring
with no lock behind it would open the app for whoever is holding the phone.
It is also Play's requirement: the shipping contract in `build.gradle.kts`
demands a visible way out on every cover.

## Why every gesture has the same shape

**Hold an inert control while the app is in its resting state.**

A tap on that control is either the app's normal action or nothing at all. The
hold only means something in a state a real user has no reason to be in —
swapping metres for metres, resetting a stopwatch that already reads zero,
holding a number on a phone lying flat on a table. Three of those are two
coincidences stacked, and none of them is a state the app disables or marks in
any way, so there is nothing on screen to notice.

One pattern, not nine, because a fifth distinct mechanism is a fifth thing to
get wrong — and because the user has to remember these.

Failure is silent everywhere: a hold that misses the state does nothing. No
toast, no ripple, no shake. Someone who half-tripped a door learns nothing.

What is deliberately **not** used:

- **Tapping the build number seven times** in Device Info. It is a famous
  Android easter egg; a curious person is measurably likely to actually try it.
- **A gesture on a primary control.** Every door is on something inert — a
  passive readout, a chart, a disabled-in-practice button.

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
- **The biometric prompt.** Tripping a door shows the system unlock prompt. It
  is nameless, but it is visible — that is the accepted cost of having a door at
  all.
- **Notification channels.** Listed under whatever the launcher calls this app,
  so every channel name is deliberately generic ("Alerts", "Voice", "Timers").
  Guarded by `test/unit/disguise/disguise_notification_test.dart`.
- **Launcher shortcuts.** There are none, on purpose — a long-press popup
  offering "New note" would name a feature the cover cannot explain. Guarded by
  a test.

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
   `disguise_profile.dart` (including its `entry` line, written against what
   the trigger code actually checks — down to the label on the control), a
   cover screen using the `CoverGate` mixin and carrying a `CoverExitButton`
   wired to `runEntryGate`, a branch in `disguise_cover_host.dart`, a style in
   `disguise_notification.dart`, and a row in the table above.
