# Screen share, done the way the leaders do it — and then past them

Written 2026-08-28, on the owner's brief: *"top class master plan … most
powerful and most advanced, silky smooth … without dropping any single quality
anywhere."* Research: Zoom / Google Meet architecture notes, the W3C
content-hint spec, Multi.app's legibility engineering (the deepest public
writeup), Android 14 app-sharing docs, and the flutter_webrtc 1.6.0 source.

## The governing law (the owner's constraint, made precise)

**Legibility is never traded away.** Screen content is text, UI, photos being
looked at together — its worth is sharpness. When the network narrows, the
share loses MOTION (fps) first, then latency headroom, and only in true
collapse resolution — and every loss recovers automatically. This is the exact
inverse of the camera's policy (faces keep moving, sharpness bends), and it is
how every leader ships:

- Meet/Zoom encode screen content around **1080p at 5–15fps**, not 720p at 30.
- The W3C hint for it is `contentHint: 'detail'/'text'` +
  `degradationPreference: maintain-resolution`.
- Multi's single biggest legibility win was **clamping the encoder's max QP**
  (52 → 36): the encoder is forbidden to mush text no matter the bitrate math.
- Zoom turns AV1 on only when the CPU can afford it, dynamically — quality
  features arrive guarded, never as a gamble.

## Where Miles is today (post build 57)

One WebRTC peer connection; share rides a dedicated second video m-line.
Capture is whole-display at native resolution/30fps (the plugin discards
constraints). Encoder ladder: 5 rungs that today drop fps AND resolution,
`BALANCED` preference, normalised to a 1280 long edge, 2.5 Mbps cap, stats now
pinned to the screen sender, CallPip excluded from capture. Known ceilings
from the code audit: no `contentHint` in the plugin, `MediaProjection`'s
`onStop`/`onCapturedContentResize` unplumbed, DRM/FLAG_SECURE arrives black,
no internal audio.

**The discovery this research adds: Miles OPTS OUT of Android 14's single-app
sharing.** `Helper.requestCapturePermission(fullScreenOnly: true)`
(call_controller.dart:1119) forces the whole-display config. Since Android 14
QPR2 the DEFAULT system picker lets the user choose **"One app"** — which
excludes the status bar, notifications, the launcher, other apps, and Miles's
own PiP window from the captured frames. The echo the owner photographed and
the privacy hazards (notifications, the disguise cover in-frame) are largely
a one-argument decision we are making against ourselves on modern phones.

---

## The plan — three phases, each shippable alone

### Phase 1 — Dart-only. No fork, no schema. The 80%.

1. **Single-app share on Android 14+.** Drop `fullScreenOnly: true`; let the
   system picker offer One app / Entire screen. Consequences, all free:
   status bar, notifications, launcher, cover and CallPip can no longer leak
   into the frame when the user picks an app; "entire screen" remains one tap
   away for the tour-of-the-phone use case. Older Android keeps today's
   whole-display behaviour untouched. UI copy on the share button explains the
   choice once. (`docs`: Android 14 app-screen-sharing page.)
2. **The screencast encoder profile.** On the screen sender only:
   `degradationPreference: MAINTAIN_RESOLUTION` (today `BALANCED`), fps ladder
   `15 → 10 → 5` with **scale locked at 1.0** for every rung above collapse;
   one emergency rung (scale 1.5, fps 5) exists but requires two consecutive
   `bandwidth` samples to enter and leaves at the first clean one. Text never
   softens because a bar filled.
3. **Native-quality capture bound raised.** `_screenTargetLongEdge` 1280 →
   **1920**: a 1080p-class panel shares at full logical sharpness. Bitrate cap
   2.5 → **4 Mbps** and a **250 kbps floor** (`minBitrate`) so VP9's
   undershoot cannot starve a static page into mush. All on the dedicated
   screen sender — the camera's line is never touched (a set parameter cannot
   be unset; already-learned law).
4. **VP9 for the screen m-line.** flutter_webrtc 1.6.0 exposes
   `setCodecPreferences` + sender/receiver capabilities: put VP9 first on the
   SCREEN transceiver only (H.264 stays available for negotiation fallback;
   camera line untouched). VP9 beats H.264 on text at equal bitrate in every
   public comparison; this is Meet's own split (camera one codec, share
   another).
5. **The sharer sees what they share.** With single-app capture there is no
   mirror recursion unless Miles itself is shared — so when the capture is
   app-scoped, replace the static `_SharingCard` with a genuine live
   mini-preview of the outgoing track; keep the card (and its honest line)
   only for whole-screen shares.
6. **Verification HUD.** The existing stats line gains
   `share 1920×864 @12fps · VP9` when a share is live — the on-device proof
   that every setting above actually took, which is exactly what §78 could
   never check.

### Phase 2 — A maintained flutter_webrtc fork (one patchset, upstreamable)

7. **`contentHint` plumb-through** (`'detail'` on the screen track): flips
   libwebrtc's internal screencast handling on both ends. Small patch; the
   interface exists in `webrtc_interface` already.
8. **QP clamp — Multi's biggest win.** Max QP 36 for the screen encoder via
   libwebrtc field trials at factory init. Legibility becomes enforced, not
   hoped for.
9. **Playout-delay minimisation** on the receive side for the share track
   (Multi measured ~90 ms saved) — silky is mostly latency variance, and this
   is where it lives.
10. **Plumb `MediaProjection.Callback.onStop` and `onCapturedContentResize`.**
    Kills the stall-watchdog workaround (the system "Stop sharing"
    notification finally reports), and single-app shares resize cleanly when
    the shared app rotates or splits.
11. **Internal audio (API 29+ `AudioPlaybackCapture`).** Share a video WITH
    its sound — the Watch-Together companion feature. Its absence is a plugin
    limitation, not an Android one.

### Phase 3 — The frontier, guarded like Zoom guards it

12. **AV1 with Screen Content Coding** where the device proves it can:
    AV1's IntraBC + palette modes are BUILT for UI/text (30–50% under VP9 at
    equal quality; ~100 kbps for calm 1080p screen content). Enable
    dynamically — hardware AV1 or a strong CPU, never in power-saving,
    fall back mid-call on CPU pressure. Both this couple's flagships qualify;
    the vivo never will, and never has to.
13. **Perceptual ladder tuning from the field**: use the receiver's
    `freezeCount`/jitter series (already collected) to bias the fps ladder per
    link, so "silky" is measured on the receiving eye, not assumed.

## What this plan deliberately does NOT chase

- **DRM black frames** — platform law, every leader shows the same black.
- **Whole-screen echo on Android <14** — physics of whole-display capture;
  mitigations (PiP hidden, honest copy) already shipped in 57.
- **Simulcast/SVC** — two people, one link; layering buys nothing here
  (Multi dropped it too, for quality reasons).

## Verification protocol (per phase, two phones)

- The **legibility test**: share a fixed page of small text; photograph the
  receiving phone; the text is readable at every ladder rung or the rung is
  wrong. (The pass Multi optimised for.)
- The **silk test**: scroll the shared app for 30 s; receiver
  `freezeCount` delta and jitter from the stats line; HUD confirms fps rides
  the ladder and resolution NEVER moves.
- The **stop test**: system notification "Stop sharing" ends the share within
  2 s (Phase 2's onStop).
- The **privacy test** (Android 14, single-app): drop a notification during a
  share — it must not appear in the received frames.

## Order of work when un-held

Phase 1 is one sitting (items 1–6 are Dart edits to two files plus copy),
gates + build; hardware matrix next session. Phase 2 is its own repo decision
(fork + pin) — proposed only after Phase 1's HUD numbers are in hand from a
real call. Phase 3 waits for both.
