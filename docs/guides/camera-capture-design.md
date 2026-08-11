# Camera capture — the Snapchat-style gesture

Tap = photo. Press-and-hold = video. Slide the **holding** finger up/down to zoom.
No second finger, no quality loss.

Status: `ZoomController` built and tested (`lib/features/chat/camera/zoom_controller.dart`).
Gesture wiring and tap-to-preview delivery not yet done.

Full research output, including citations, is in the workflow result for run
`wf_876b7439-70d`. What follows is only the load-bearing parts.

---

## 1. `GestureDetector` cannot express this gesture

It hard-codes `LongPressGestureRecognizer` and passes only `debugOwner` and
`supportedDevices` — no `duration`, no `preAcceptSlopTolerance`, no
`postAcceptSlopTolerance` (`gesture_detector.dart:1122-1125`). Those are exactly
the knobs this interaction turns.

**`RawGestureDetector` is mandatory, not a preference.**

## 2. The defect that would have sunk it silently

`LongPressGestureRecognizer` does not override `preAcceptSlopTolerance`, so it
falls back to `gestureSettings?.touchSlop ?? kTouchSlop` — on Android, the
platform's scaled slop, around **8 logical pixels**, not Flutter's 18
(`recognizer.dart:634-651`, `constants.dart:65`).

Move further than that *before* the hold deadline and the recogniser calls
`resolve(GestureDisposition.rejected)` (`recognizer.dart:707-719`). The press is
dead. No video — and no photo either, because `TapGestureRecognizer` rejects on
the same slop.

The whole point of this gesture is that **the finger is already travelling while
the hold matures.** About 8px of upward drift kills it, and the failure is
invisible: the shutter simply does nothing.

This is the most likely reason a naive port feels broken on a OnePlus 7 or Vivo
1908 and fine on a desk emulator. **Set `preAcceptSlopTolerance` generously
(≈40px) explicitly.**

## 3. Slide-off-and-keep-recording is free

`postAcceptSlopTolerance` is `null` on this recogniser (`long_press.dart:283`),
so once accepted the finger may travel without limit and keeps emitting
`onLongPressMoveUpdate`. Pointer routing is bound to the **pointer id** at down,
not to the widget under the finger — `PointerRouter` never re-runs hit testing
mid-sequence. Sliding off the button does not stop the recording.

## 4. Use `offsetFromOrigin.dy`, not `localOffsetFromOrigin.dy`

Both are `current − down` against a transform frozen at pointer-down, so they are
identical under pure translation and diverge under scale or rotation.

The shutter is an `AnimatedContainer` that grows 72→84 when recording starts, and
a press-scale animation is the obvious next addition. Either puts a `Transform`
in the chain, and then N pixels of real travel become N/scale in local space —
**zoom sensitivity would become a function of the button's own animation.**
`offsetFromOrigin` is screen-space finger travel, which is the physical quantity
the distance→zoom curve is calibrated against.

## 5. There is no arena conflict today, and there will be after the redesign

Today the preview's scale detector is Stack child 0 and the bottom panel is
`HitTestBehavior.opaque`. `defaultHitTestChildren` walks last→first and returns
on the first hit, so a pointer landing on the shutter is never offered to the
preview. Its `ScaleGestureRecognizer` is not in that pointer's arena.

**That protection disappears the moment the shutter floats over the viewfinder**
— the natural Snapchat layout. `ScaleGestureRecognizer` accepts on a *single*
pointer once the focal point moves `kPanSlop` = 36px, **with no deadline to wait
for** (`scale.dart:743-750`). A deliberate zoom drag passes 36px in well under
100ms, before any 200ms long-press deadline. Scale wins, long press gets
`rejectGesture`, recording never starts.

A `GestureArenaTeam` does **not** fix this — a team only substitutes the captain
as winner, it cannot stop a member from claiming one (`team.dart:78-86`). Keep
the shutter subtree hit-opaque so the Stack stops there.

## 6. Tap latency is not a cost here

The usual "tap waits for the competitor" delay comes from a recogniser that stays
in the arena. Long press self-rejects synchronously on a `PointerUpEvent` before
its deadline, so when the arena sweeps on that same event, tap is the only member
left and fires immediately.

---

## Zoom controller — already built

`lib/features/chat/camera/zoom_controller.dart`, six tests.

- Gesture and zoom on **separate clocks**: the finger writes a target (one clamp,
  one field write); a ticker interpolates toward it once per frame.
- **One platform call in flight.** `setZoomLevel` is a round trip; calling it
  again before the last returns queues, and a queue is what turns a smooth drag
  into late jumps.
- **Geometric curve**, `zoom = min * (max/min)^t` — zoom is a ratio, not a
  distance, so equal travel must mean equal ratio or the finger races through
  1×–2× and crawls through 5×–6×.
- **0.35/frame smoothing** — ~90% of the gap in five frames (80ms): instant to
  the eye, still eats the jitter of a finger that is also holding the shutter.
- **Capped at 6×.** Phones report digital maxima they cannot resolve.
- `value` is a `ValueListenable`, so only the indicator repaints — never the
  1518-line camera tree, which is what `setState` on every pointer move was doing.

## Remaining work

1. Wire `ZoomController` behind `RawGestureDetector` with an explicit
   `LongPressGestureRecognizer` (duration ≈200ms, `preAcceptSlopTolerance` ≈40),
   and delete the `onScaleUpdate → setState` path.
2. Tap-to-preview delivery into chat: model flag, migration, placeholder bubble,
   reuse `media_viewer` + `SaveMediaService` for the explicit save.

**Assumption, stated:** tap-to-preview **persists**. This is not Snapchat's
auto-delete — the bubble hides the media behind a tap, opening shows it, saving
is a separate action, and the message stays in the conversation.
