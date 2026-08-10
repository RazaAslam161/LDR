# presence (revised)

## What changed vs v1
**F1 (fatal) — "the observer's own socket is never checked; the fold renders a stale snapshot as ONLINE, and the design deletes the accidental reconnect that masks it." CLOSED, with a named residual.**
Closed by making socket freshness an *input to the render*, not an assumption, in three parts that each fail toward `unknown`:
(a) The rendered state becomes three-valued — `online | offline | unknown`. `unknown` is the default. The render is a pure function `render(snapshot, monotonic_now) -> state` where `snapshot` carries the monotonic instant of the *inbound server frame that produced it*. If `monotonic_now - snapshot.frame_instant > 2 x heartbeat interval (50 s)`, the function returns `unknown` regardless of contents. Staleness is therefore evaluated **at read time from an elapsed monotonic duration**, never maintained by a timer — so a throttled, frozen or never-fired Dart timer makes the state decay to `unknown`; it cannot make it look healthy. That is the structural inversion the old design lacked: in the old design silence meant "keep the last answer"; here silence *is* the answer.
(b) The presence snapshot is invalidated *unconditionally at `AppLifecycleState.resumed`*, before any network activity. A pre-background CRDT snapshot can never be rendered after a resume, even if it is only seconds old, because the render input is cleared, not aged. The next `presence_sync` on a live socket is the only thing that can restore `online`.
(c) A `heartbeatCallback` is registered (Supabase's own documented fix for silent socket death in backgrounded apps) that calls `connect()` on status `disconnected`/`timeout`, and on resume the client issues `presence_bootstrap()` — a plain PostgREST call needing no socket — so `unknown` renders with a real last-seen age within one HTTP round-trip rather than as a blank.
**Why it cannot regress:** the unconditional `realtime.disconnect()+connect()` at `app_shell.dart:77-78` is *not* removed until Stage D has shipped the gate and produced a field distribution of last-inbound-frame-age at resume. The replacement is conditional — reconnect iff last-inbound-frame age > 50 s or the channel is not SUBSCRIBED — so the case the current code accidentally covers (a long background) still forces a fresh socket, while the case it damages (a 3-second camera/picker return) no longer does. The regression gate is harness scenario 5(b): kill the *observer's* socket without a close frame, resume, assert the render is `unknown` and never `online`. That test did not exist before and is the single most important test in this document.
**Residual (stated, not hidden):** the gate is client-side. Its enforcement is a pure function plus a CI rule that the presence widget tree may only read state through that function. A build that bypasses the seam can still render a stale snapshot. This is a one-bad-build risk, not a one-bad-network risk, and it is the honest cost of having no server-side socket observability.

**F2 (fatal) — "`seq` is an unkeyed watermark; session_id rotates on every join, so after the first reconnect every typing event is dropped forever." CLOSED by deleting the mechanism.**
`seq` is removed from the design entirely. There is no ordinal, no watermark, and therefore nothing to key incorrectly. The typing receiver instead holds, per sender user, `(typing_bool, source_session_id, monotonic_expiry)` and obeys three rules: **accept every START unconditionally** (a START from a session never seen before supersedes whatever was there — nothing is ever dropped for being "old"); **a STOP clears typing only if its `session_id` matches the session that set it** (a stale STOP from a superseded connection cannot silence a newer START); **the 15 s monotonic expiry from local receipt is unconditional and always wins** (a sender that crashes mid-compose expires on the receiver's own clock). Room and geo use the same shape with 90 s and 15 s expiries.
**Why it cannot regress:** the failure mode required a persistent piece of receiver state that could reject future events. There is no longer any state whose value can cause an event to be rejected — the only per-session state is *which session owns the current STOP right*, and being unknown grants full acceptance rather than denial. The default is accept, not deny. Regression gate: verification test 2 generates random session rotations, duplications and reorderings and asserts (i) no event from a new session is ever dropped, (ii) a STOP from session A never clears a START from session B, (iii) typing is false within 15 s of the last START in every trace. Ordering within a session is already guaranteed by Phoenix's in-order per-topic-per-sender delivery, so the only reorder that could ever occur is cross-session, which rule (ii) covers by construction.

**F3 (fatal) — "the track() token bucket is a client convention, a rejected join-track renders a live user offline forever, and 'the cap cannot be exceeded' is asserted not measured." CLOSED by server-observed confirmation.**
The token bucket is demoted from an invariant to a rate-shaping rule and is replaced as the correctness mechanism by a **self-presence confirmation loop**. Supabase Presence delivers presence state to every subscriber on the topic *including the originator* (the same property that makes presence bill 3 messages, not 2 — see F11). The client therefore observes its **own** key in `presenceState()`. The rule is: after `track()`, if the client's own `<user_id>:<session_id>` key is absent from the presence set for more than 3 s (two `PRESENCE_BROADCAST_PERIOD_IN_MS=1500` batches), the track did not take — retry with Full Jitter, unbounded, until the key appears or the channel dies, and increment a `track_rejected` counter shipped as telemetry. Liveness of the client's own publication is now decided by *observed server state*, not by the client believing its own call succeeded.
Two supporting changes: the **join track is mandatory and bypasses all client rate shaping** — only zone updates are discretionary and their failure is harmless (the previous zone and the room broadcast both cover it); and the discretionary path is floored at one call per 15 s with trailing coalesce, so the worst case in any 30 s window is 1 join + 2 zone + 1 retry = 4 against the platform's `CLIENT_PRESENCE_MAX_CALLS=5 / CLIENT_PRESENCE_WINDOW_MS=30000`.
**Why it cannot regress:** the previous design's failure was *silence* — a rejected track produced no event, no retry and no signal. Now the absence of the client's own key is itself an observable event on the socket, and it is the trigger. Regression gate: harness scenario 5(c) deliberately drives track() past the cap and asserts recovery, and records whether the 5-call window resets on reconnect. Until that number exists the window's scope is labelled **INFERRED**, not asserted.

**Serious flaws closed:** F4 (Stage 0 renamed; a real, independently shippable Stage C now migrates the *consumers* of the leaking public topics, with a version-gated cutover); F5 (last-seen is floored by the observer's own monotonic measurement of the departure it witnessed); F6 (the durable row no longer has `state` or `ended_at`, so no lifecycle-pause HTTP write can leave a contradiction — the anchor is the only durable write and its failure is a no-op); F7 (one honest number per case: `bye`-announced clean background ~1.5–3 s, unannounced leave 12–14 s, hard kill 47–72 s); F9a (committed to gating `presence.read`/`presence.write` and accepting that the toggle also suppresses typing/room/geo, which is why ephemeral signals get their own channel separate from durable-message delivery); F9b (multi-device last-seen is now a single `greatest()`-guarded column, so it cannot be clobbered); F10 (singleflight + jittered retry + refetch on reconnect + persisted coarse cache + an explicitly defined empty state); F12 (a server-read config row ships *before* any user-visible flip, converting every client stage from "rebuild and sideload" to one UPDATE); F13a (couple_id derived server-side from `auth.uid()` and self-healing on every anchor); F13b (Stage A is now the outright deletion of `setChatLastRead`, moved to first because the field it writes has no consumer).
**Serious flaw only partially closed:** F8 — `DB_POOL_SIZE` is named, raised before the private channel ships, the policy is reduced to one indexed lookup, and verification measures join **latency and timeout rate** rather than `too_many_joins`. But Realtime's authorization pool is not ours to bound, so a correlated fleet-wide rejoin storm remains a measured risk, not an eliminated one. Stated in accepted limits.
**Minor:** F11 corrected throughout — presence bills 3 messages per event, not 2, and the "14x headroom at 100k" claim is downgraded to an explicit unknown.

## Target architecture
## PRESENCE — revised target architecture

Scope: online/offline/away, last seen, typing, "where they are in the app" (coarse zone + fine room), live coordinates, and the privacy control over all of it. This document is self-contained.

---

### 0. What is broken today, in one paragraph

Every presence fact is an upsert into one 24-column `public.presence` row that is `replica identity full` and in the `supabase_realtime` publication. A `setChatLastRead` fires every 5 s while a chat is open, `setOnline` every 30 s, `setLocation` every 15 s, plus typing on keystroke boundaries — roughly 18 writes/user/minute. Each write emits a WAL record carrying the entire old and new row, is decoded by wal2json on the project's own Postgres CPU, and drives `realtime.apply_rls`, whose subscriber loop is `array_agg(sub) ... where sub.entity = 'public.presence'::regclass` — **every presence subscriber project-wide**, because the `couple_id=eq.X` filter is evaluated *inside* the loop and does not shrink it. Supabase's published ceiling for postgres_changes with RLS is **30 changes/s at 500 clients, and 40/s even on a 16XL**; a 370x compute increase buys 1.3x. The observing client then throws the payload away and issues a fresh PostgREST SELECT after an 800 ms debounce, plus an unconditional 15 s poll. `is_online` is a lie by construction (a force-killed app never writes `false`), so the client compensates with a 45 s freshness window computed against `ServerClock.now()` — while the string next to it, `lastSeenText`, uses raw `DateTime.now().toUtc()` with no correction at all. Every one of these failure modes is invisible at N=2 on one wifi: the `apply_rls` loop has two entries, the WAL is empty, both clocks agree, both processes exit cleanly.

### 1. The one structural move, and the one the previous revision missed

**Online stops being a value anyone writes and becomes membership of a live, RLS-authorized socket.** That is correct and it is retained.

**And: online is only renderable by an observer whose own socket is demonstrably live.** This is the half that the previous revision omitted and that the attack phase correctly identified as fatal. Presence has two sides, and "every failure converges on offline" was only ever true for the *tracked* side. A CRDT snapshot held by a client whose socket died silently will faithfully render a partner as online forever — there is no leave event, so no grace timer arms, and nothing decays. The revision below makes socket freshness an explicit input to the render, so that on the observing side too, every failure converges on a state that does not claim more than it knows.

The rendered presence state is therefore **three-valued**, not two:

| State | Meaning | Rendered as |
|---|---|---|
| `online` / `away` | the observer has a live socket, has received a `presence_sync` on it, and the partner has a key in the current set | filled dot / hollow dot |
| `offline` | the observer has a live socket, has received a `presence_sync` on it, and the partner has no key | no dot + "last seen X" |
| `unknown` | the observer cannot currently vouch for its own link | no dot + "last seen X" (from the durable read), never a dot of any colour |

`unknown` is the initial state, the state after every resume until a fresh sync lands, and the terminal state of every observer-side failure. It is not an error state and it is not a spinner; to the user it looks like "last seen 4 minutes ago" with no dot, which is exactly what WhatsApp shows when it cannot say.

---

### 2. What is ephemeral, what is durable, where each lives

| Fact | Nature | Home | Never |
|---|---|---|---|
| online / away | ephemeral, derived from a socket | Supabase Realtime **Presence** (Phoenix.Tracker CRDT, in-memory, never touches Postgres) | any table |
| zone (coarse: which area of the app) | ephemeral, slow-changing | Presence payload, 15 s floor | any table |
| room (fine: "the Vault", "Truth or Dare") | ephemeral, fast-changing | **Broadcast** | any table |
| typing | ephemeral, keystroke-rate | **Broadcast** | any table, any FCM path |
| live coordinates | ephemeral, foreground + map-open only | **Broadcast** | any table |
| coarse location label (city) | durable, changes hourly at most | narrow `user_location`, **not** in the publication | `presence` |
| **last seen** | durable — the ONLY durable presence fact | narrow `presence_session`, **not** in the publication | — |
| privacy preference | durable, rarely written | `presence_prefs` | — |
| runtime config / migration lever | durable, rarely written | `app_runtime_config` | — |

**Two private channels per couple, not one, and not five.**

- **`couple:<couple_id>:live`** — presence + typing + room + geo. Everything on it is ephemeral and everything on it is governed by the single privacy predicate. This is the channel the privacy toggle switches off.
- **`couple:<couple_id>:msg`** — durable-event delivery for chat, receipts, reach, calls. Governed by couple membership only, never by the privacy toggle.

The split exists because Supabase's `realtime.messages` RLS can distinguish presence from broadcast (via the `extension` column) but **cannot distinguish one broadcast event name from another** — the event name lives in the payload, not in a column. Putting typing and chat delivery on the same channel would mean the privacy toggle either leaks typing or breaks chat. Two channels, two policies, and the cost is one extra join per device. This replaces today's `presence:<id>`, `screen_presence:<id>`, `mood_burst:<id>` presence half, `capsule_proximity:<id>` and the rest — all of which are today **public topics that anyone holding a couple UUID can join**, and that UUID is the first path segment of every never-expiring `couple_media` URL.

---

### 3. Data model

**Ephemeral — presence payload (well under the 10-key cap):**
`key = "<user_id>:<session_id>"`, `session_id` a fresh uuid v4 per channel join.
Payload: `{ u: user_id, s: session_id, st: "online"|"away", z: <zone 0..8>, b: <app build int> }`.
**No timestamps.** Nothing in this payload is compared to anything. `b` exists solely to drive the version-gated topic cutover in Stage C.

**Ephemeral — broadcast events on `:live`** (all `self: false`):
- `typing { s: session_id, t: bool }`
- `room   { s: session_id, r: string|null }`
- `geo    { s: session_id, lat, lon, acc }`
- `bye    { s: session_id }` — a grace-waiver token, see §7.

There is **no sequence number, no ordinal and no watermark** anywhere in this design. Ordering is handled by Phoenix's in-order per-topic-per-sender delivery within a session, and by session-scoped supersession across sessions (§6).

**Durable — `presence_session`** (narrow, **not** in the publication, `replica identity default`, `fillfactor 80`):

- `user_id uuid primary key references profiles(id) on delete cascade`
- `couple_id uuid null` — for defence-in-depth RLS only; self-healing (§4)
- `last_confirmed_at timestamptz not null default now()` — **the only meaningful column**

There is deliberately **no `state`, no `session_id`, no `online_since`, no `ended_at`.** Postgres holds exactly one presence fact — a watermark — and it is not capable of expressing "online". That is what makes it impossible for a stale durable row to contradict the CRDT, and it is what makes multi-device correct with no aggregation logic: a `greatest()` over one column is the right answer for "when was this human last confirmed present on any device". Because no indexed column is ever updated, every anchor is a HOT update: no index bloat, no vacuum treadmill.

**Durable — `presence_prefs`:** `user_id uuid pk`, `share_presence boolean not null default true` (reciprocal: online + last-seen + typing + room + geo), `share_zone boolean not null default false`.

**Durable — `user_location`:** `user_id pk, couple_id, label text, mode text, updated_at timestamptz`. Written on *label change*, not every 15 s. Coordinates are never persisted at all.

**Durable — `app_runtime_config`:** one row per couple. `presence_source enum('legacy','shadow','new')`, `min_client_build int`, plus room for the later stages' levers. This table is the revert mechanism for every client-side stage (§9) and the coordination point for the topic cutover. It is read over plain HTTP, so it works with a dead socket.

---

### 4. Write path — two RPCs, both `SECURITY DEFINER`, neither takes a timestamp, neither takes a couple_id

**`presence_anchor()`** — the *only* durable presence write in the system. Called on a 300 s ± 30 s jittered timer while foregrounded, and best-effort once at lifecycle pause. It is a guarded UPDATE, not an upsert, and it is idempotent:

> update `presence_session` set `last_confirmed_at` = `greatest(last_confirmed_at, now())`, `couple_id` = `coalesce(public.current_user_couple_id(), couple_id)` where `user_id = (select auth.uid())` and `last_confirmed_at < now() - interval '240 seconds'`; if no row was updated and none exists, insert one with `couple_id` resolved the same way.

Three properties, all server-enforced:
- **The client supplies no fields at all.** The signature takes zero parameters. A replayed, delayed, reordered or forged call is indistinguishable from a legitimate one and cannot do anything a legitimate one could not.
- **`greatest(existing, now())` is load-bearing specifically because Postgres `now()` is transaction-*start* time and is not monotonic across overlapping transactions.** A transaction that began earlier but commits later carries an older `now()`; without `greatest()` it would drag the watermark backwards. With it, the watermark is monotone by construction regardless of commit interleaving.
- **The cadence is enforced by the predicate.** A client calling this in a tight loop updates zero rows and emits zero WAL. Write amplification is bounded by the server, not by client good behaviour.

`couple_id` is resolved *inside* the function from `auth.uid()`, never passed in, and is re-resolved on every call — so a user whose first anchor predates pairing self-heals within one anchor interval instead of being invisible to their partner forever.

**`presence_bootstrap()`** — the single read RPC, also zero-parameter, `SECURITY DEFINER`, returning:
`{ last_seen_age_seconds int|null, partner_share_presence bool, presence_source text, min_client_build int }`

`last_seen_age_seconds = extract(epoch from now() - partner.last_confirmed_at)::int`, computed on the server, **nulled when either partner's `share_presence` is false**. The partner is resolved from `profiles` via `auth.uid()`, never from `presence_session.couple_id` — which is why a null `couple_id` on the durable row can never break the read path.

**The absolute timestamp never leaves the server.** The client renders `age + monotonic_elapsed_since_response` using a `Stopwatch`. A device six hours wrong renders byte-identical output. `ServerClock` (the ~90-line NTP-style round-trip-midpoint offset estimator in `server_clock.dart`) is deleted; there is nothing left for it to correct.

Roughly **6 anchor writes per 30-minute session, and one `presence_bootstrap()` per app start / resume / socket reconnect.** Compare ~540 writes per session today.

---

### 5. Read path — no poll, no unretried single shot

`presence_bootstrap()` is called on: app start, resume (debounced to 1 per 400 ms), and every socket (re)connect. It is **not** on a timer — the 15 s `Timer.periodic` at `presence_service.dart:436` and the 800 ms refetch debounce both die, removing 4 unconditional SELECTs/min/user.

But "not on a timer" is not the same as "fire once and hope", which is what the previous revision specified. The read path is:
- **singleflight per couple** — concurrent triggers collapse to one in-flight request;
- **Full Jitter retry** `random(0, min(10s, 250ms x 2^attempt))` on failure, up to a cap, then quiet;
- **persisted to disk** as `(age_seconds, wall_receipt_instant)` so a cold start with no network is not blank;
- **an explicitly defined empty state**: with no cached value and no network, the UI shows `unknown` with "last seen: unavailable" — never "Offline", which is a claim the client is not entitled to make.

The persisted cache is the **only** wall-clock-dependent render in the entire design, and it is deliberately coarse: on cold start the cached value renders in buckets ("over an hour ago" / "over a day ago" / "over a week ago") with an "about" qualifier, and it is replaced by the server-computed age within one round-trip. A ±6 hour device clock error can at worst move the display one bucket. This exception is named here so that the CI clock-hostility test can whitelist exactly this one call site and fail the build on any other.

---

### 6. Observer derivation — a pure, gated fold

Two pure functions, both property-tested, both with no I/O and no wall clock:

**`render(snapshot, monotonic_now) -> online | away | offline | unknown`**
where `snapshot = { keys: Set<PresenceKey>, frame_instant: MonotonicInstant, synced: bool }` and `frame_instant` is the monotonic instant of the **inbound server frame that produced this snapshot**.

- if `!snapshot.synced` → `unknown`
- if `monotonic_now - snapshot.frame_instant > 50_000 ms` (2 x the 25 s heartbeat) → `unknown`
- else if any key starts with `<partner_id>:` → that key's `st` (`online` or `away`)
- else → `offline`

**`zone(snapshot, u)`** = the payload of the most recently joined key with that prefix, and `unknown` under the same gates.

Three things make this structural rather than aspirational:
1. **Staleness is computed at read time from an elapsed monotonic duration.** It is never maintained by a timer, so a suppressed, throttled or frozen timer (MIUI freeze, Doze, App Standby) causes decay to `unknown` and can never cause an appearance of health. The failure direction is fixed by the arithmetic.
2. **The snapshot is cleared, not aged, at `AppLifecycleState.resumed`** — before any network call. A pre-background snapshot is unreachable by construction, so the "she was online and didn't reply" render cannot survive a backgrounding.
3. **The answer is recomputed in full from the current set on every sync/join/leave.** The diff is a wakeup, never the source. Supabase documents that presence sync can emit spurious join/leave; that cannot produce a wrong answer here because the answer does not depend on event history.

**Flap suppression:** when the last key for a user disappears, a 12 s monotonic grace runs before `offline` is rendered; a join within the grace cancels it with no repaint. This kills the visible flicker on wifi↔LTE handoff, JWT-refresh rejoin, and camera/picker return. The grace is **skipped** for a leave whose `session_id` was explicitly announced by a `bye` broadcast (§7).

**Socket self-healing:** a `heartbeatCallback` is registered; on status `disconnected` or `timeout` it calls `connect()`. This is Supabase's own documented remedy for the backgrounded-app case where "the WebSocket can silently drop" and "your application then stops receiving events without any explicit error message". It is the client-side half of Signal's `GET /v1/keepalive` zombie eviction; we cannot do the server-side half because we do not own the socket.

**Ephemeral receiver state — session-scoped, no watermark.** Per sender user the receiver holds `(typing, source_session_id, monotonic_expiry)` and obeys:
- **START** — accept unconditionally; record `source_session_id`; arm/re-arm the 15 s expiry. A session never seen before is accepted, not rejected. *Nothing is ever dropped for being unrecognised.*
- **STOP** — clear typing **only if** `session_id` matches `source_session_id`. A stale STOP from a superseded connection is a no-op.
- **Expiry** — unconditional, 15 s from local receipt, monotonic. It always wins.

`room` uses the same shape with a 90 s expiry, on whose expiry the UI falls back to the presence `zone` — which is *more* correct, not less, so no keepalive broadcast is needed. `geo` uses 15 s.

---

### 7. State machine

```
DISCONNECTED ──socket open + :live join authorized──▶ CONNECTING
CONNECTING   ──track() issued──▶ AWAITING_SELF
AWAITING_SELF──own key seen in presenceState()──▶ ONLINE
AWAITING_SELF──own key absent after 3 s──▶ retry track() (Full Jitter, unbounded, counter++)
ONLINE       ──10 min no user interaction──▶ AWAY
AWAY         ──any interaction──▶ ONLINE
ONLINE|AWAY  ──lifecycle paused──▶ LEAVING ──broadcast bye{s} → untrack()──▶ DISCONNECTED
ONLINE|AWAY  ──socket death / LMK / force-stop / radio loss / tenant refusal──▶ DISCONNECTED
```

`DISCONNECTED` is the default and the terminal state of every failure. `AWAITING_SELF` is the new state and it is the whole of the F3 fix: **the client does not believe it is online until the server has told it so**, by echoing its own key back in the presence set. Supabase delivers presence to every subscriber on the topic including the originator — the same property that makes presence bill 3 messages per event rather than 2 — so this confirmation costs nothing extra. `track_rejected` is shipped as field telemetry precisely because a silent failure here is the bug class that survived five previous fixes.

`AWAY` is Slack's split of *activity* from *connectivity* ("after 10 minutes with no activity, the user is automatically marked as away"). A phone on a kitchen table with the app open is not "here", and in a couples app that distinction is a direct source of "she was online and didn't reply".

**`bye` and the honest latency numbers.** Immediately before `untrack()`, the client broadcasts `bye { s: session_id }`. The observer treats `bye` as a *grace-waiver token*, not as a state change: it never renders offline on its own; it only authorises skipping the 12 s grace when the leave for that same session actually arrives. A forged or replayed `bye` can therefore only accelerate the offline transition of the session that named it — the safe direction, and something the partner could achieve anyway by closing the app. This resolves the previous revision's internal contradiction (a "≤2 s clean background" claimed alongside an unconditional 12 s grace that applies to every leave). The three numbers, honestly derived:

| Case | Latency | Where it comes from |
|---|---|---|
| Clean background (`bye` announced) | **1.5–3 s** | `PRESENCE_BROADCAST_PERIOD_IN_MS=1500` batching of the leave diff; the grace is waived |
| Unannounced leave (`bye` lost, or an early socket death) | **12–14 s** | the flap grace |
| Hard kill / LMK / force-stop / radio loss | **47–72 s** | 60 s Phoenix socket timeout (last frame 0–25 s before death) + 12 s grace |
| Observer's own socket dies silently | **`unknown` immediately on resume**, resolved within one HTTP round-trip | §6 gate (a) and (b) |

Note the first row is **1.5–3 s, not ≤2 s**: presence diffs are batched at 1500 ms and that floor is Supabase's, not ours.

---

### 8. Exact timing numbers

| Timer | Value | Justification |
|---|---|---|
| Transport heartbeat (client→server) | **25,000 ms** | `realtime_client` default. Keep. |
| Transport TTL (server closes socket) | **60,000 ms** | Phoenix default; Supabase's `endpoint.ex` sets `max_frame_size`/`active_n`/`fullsweep_after` but **no `:timeout`**. Ratio 2.4x. Not ours to tune — measured by verification 5(a) as a canary. |
| **Observer staleness threshold** | **50,000 ms** since last inbound frame | 2 x heartbeat, the same TTL≥2x-heartbeat discipline applied to the *reading* side. One dropped heartbeat must not produce `unknown`; two must. |
| Presence diff batching | **1,500 ms** | `PRESENCE_BROADCAST_PERIOD_IN_MS`, Supabase's. Sets the floor on every presence transition latency. |
| Flap grace (unannounced leave) | **12 s** monotonic | kills wifi↔LTE handoff, JWT-refresh rejoin, camera/picker return flicker |
| Self-confirmation timeout | **3 s** | two presence batch periods |
| Track retry backoff / channel rejoin | **`random(0, min(10s, 250ms x 2^attempt))`** | AWS Full Jitter. Load-bearing: Supabase enforces joins/sec as a hard quota (`too_many_joins`) and names "rapid reconnection loops" as a top cause of manual project suspension. |
| Discretionary track() floor | **1 per 15 s**, trailing coalesce | worst case 4 calls per 30 s against `CLIENT_PRESENCE_MAX_CALLS=5 / CLIENT_PRESENCE_WINDOW_MS=30000` |
| Away threshold | **10 min** no interaction, foregrounded | Slack |
| Durable anchor | **300 s ± 30 s jitter**, predicate at **240 s** | crash backstop for last-seen only. 5x the 60 s socket timeout — mirroring Signal's 11-minute TTL against a 30-second sweep. **The slow knob must never be the detector.** |
| Typing STARTED → first send | **immediate, no leading debounce** | Signal `TypingStatusSender`; latency is the point |
| Typing refresh while typing | **10,000 ms** | Signal `REFRESH_TYPING_TIMEOUT` |
| Typing pause → STOPPED | **3,000 ms** | Signal `PAUSE_TYPING_TIMEOUT`. Today's 1,500 ms flickers on anyone who pauses mid-sentence. |
| Typing receiver expiry | **15,000 ms from local receipt, monotonic** | Signal `RECIPIENT_TYPING_TIMEOUT`; 1.5x the refresh = exactly one missed refresh of tolerance. Today's 4 s expires *before* the 10 s refresh — a stuck-off indicator by construction. |
| Typing send policy | **1 attempt, 5 s lifespan, never retried, never persisted** | Signal `TypingSendJob`: `maxAttempts(1)`, `setLifespan(5s)`, `setMemoryOnly(true)`. A late typing indicator is worse than a missing one. |
| Room broadcast | on change, **min 1 s**, trailing coalesce; receiver expiry **90 s** | floor stops a nav-loop bug consuming the tenant msg/s budget; on expiry the UI falls back to zone |
| Live `geo` | **≥5 s and moved >25 m** while a map is open; **4 s hard floor** | replaces the unconditional 15 s write + SELECT + third-party geocode |
| Resume handling | **conditional**: reconnect iff last inbound frame > 50 s or channel not SUBSCRIBED; debounce lifecycle bursts to 1 per 400 ms | today AppShell (`app_shell.dart:77-78`) calls `realtime.disconnect()` + `connect()` on *every* resume including camera/picker returns. Unconditional is a visible offline flicker; unconditionally *not* reconnecting is the F1 stale-snapshot bug. Conditional on measured link age is the only version that is neither. |

---

### 9. Last-seen accuracy — floored by what the observer itself measured

Two independent sources of truth for "how long ago", combined by taking the more recent:

`displayed_age = min(server_age_from_bootstrap, monotonic_elapsed_since_locally_observed_departure)`

The second term requires no clock, no extra write and no network: the observer *saw* the partner in the presence set until the leave arrived, and it has a `Stopwatch` running from that instant. This closes the case where a hard kill made last-seen jump straight from "Online" to "about 6 minutes ago" — claiming she left before the message you just watched her read — because the anchor was up to 300 s stale at the moment of death and the CRDT held her for another 35–72 s on top.

Contract, stated so it can be argued with: **last-seen is accurate to within ~72 s when the observer was connected at the moment of departure, and to within ~5 minutes otherwise** (cold start, observer offline at the time, or a partner who never had a session on this device). Display is coarsened to **1-minute granularity** — never "last seen 12 seconds ago" — which makes both the 60 s platform socket timeout and the sub-minute part of the error invisible to users at zero engineering cost.

---

### 10. Privacy — one reciprocal boolean, evaluated inside the Realtime server

RLS on `realtime.messages` gating the private channel `couple:<id>:live`:

- **`presence.read` and `presence.write`** allowed iff the caller is a member of that couple **and `share_presence` is true for BOTH partners**.
- **`broadcast.read` and `broadcast.write`** on `:live` gated by the same predicate.
- `couple:<id>:msg` gated by couple membership **only** — chat, receipts, reach and calls are never affected by the privacy toggle.

Both directions, one predicate, one boolean. This is WhatsApp's rule — "if you don't share your last seen, you can't see other contacts' last seen either" — and it exists to remove the free-rider equilibrium where both hide and both watch. In a couples app the watcher set is one person, so that dynamic is the entire dynamic. Supabase's `presence_handler.ex` evaluates these policies **inside the Realtime server**, which makes this genuinely equivalent in strength to Discord's server-side `invisible`: the payload never reaches a client that should not have it. The durable path is gated symmetrically — `presence_bootstrap()` returns a null age when either side has opted out.

**Stated product consequence, which the previous revision omitted:** because Supabase RLS cannot see a broadcast's event name, `share_presence = false` also switches off **typing, room and live location** on `:live`, in both directions. The UI copy must say exactly that: *"Hide my activity — turns off the online dot, last seen, typing and live location, for both of you."* This is a deliberate limit, not an oversight: the alternative is a per-event-name policy that does not exist, or a third channel per couple.

`share_zone` is separate and **defaults off**. "Where they are in the app" is the creepiest signal in the system, and today it rides `screen_presence:<coupleId>` — an **unauthenticated public topic**. Anyone who guesses or obtains a couple UUID, which appears as the first path segment of every never-expiring `couple_media` URL, currently gets a live room-by-room feed of a partner moving through an intimate app. Closing that is Stage C and it is independently shippable.

**Honest caveat:** private-channel RLS is evaluated at join and cached for the connection lifetime. Toggling `share_presence` off does not take effect until a rejoin. Mitigation: the settings toggle forces a rejoin of `:live`, making it immediate in practice; the worst-case bound if that forced rejoin fails is one JWT expiry (3600 s default).

**Join cost, named:** Realtime evaluates private-channel RLS using **its own** connection pool, `DB_POOL_SIZE`, which defaults to **5** and is exposed in the dashboard as "Database connection pool size — determines the number of connections used for Realtime Authorization RLS checking". Five connections gate every private-channel join for the entire project. The app pays zero join-time RLS today (public topics + postgres_changes), so this is a brand-new serialization point. Three mitigations: raise `DB_POOL_SIZE` before Stage C ships; make the policy a single indexed PK lookup with `(select auth.uid())` wrapped once (the documented 179 ms → 9 ms pattern); and measure join *latency and timeout rate*, not `too_many_joins`, because a pool-bound join **times out rather than being refused** and `too_many_joins` is the failure you will not get.

---

### 11. Ephemeral signals never wake a device, and never break the disguise

No presence, zone, room, typing, geo or `bye` path may reach an FCM trigger. This holds structurally today — the four `net.http_post` triggers are on `reach_events`, `messages`, `care_nudges` and `call_invites` only, none on `presence` — and the rule is to keep it that way. It is Signal's `ephemeral` Envelope flag: `if (!destinationPresent && !message.getEphemeral())` gates the push, so a typing indicator is dropped rather than queued or pushed when the recipient is offline.

Related and non-negotiable: **no foreground service, no persistent notification, no `WorkManager` job to keep the socket alive while backgrounded.** Backgrounded *should* read as offline, because that is what a user means by "online"; it destroys battery; and on a deliberately disguised app (launcher activity-alias named "News", Google-style icon) a persistent notification defeats the disguise outright. Presence introduces nothing that appears in the launcher, the notification shade, or Telecom.

---

### 12. Why this mirrors the top tier, and where it deliberately differs

**Signal — online as a property of an open socket.** `RedisMessageAvailabilityManager` defines presence as "clients are considered 'present' if they have an open WebSocket connection", and its own javadoc says it "cannot guarantee at-most-one behavior" — best-effort by design. We take exactly that definition and get liveness detection free, because Supabase Presence is Phoenix.Tracker and the BEAM's process monitors do it at process granularity.

**Deliberate difference from Signal:** Signal owns its sockets, so it can run `pruneMissingPeers()` every 30 s and clear leases with the dead peer's own ID as a CAS token. We cannot observe socket lifecycle server-side at all — Deno Edge Functions are stateless and hold no websocket, and there is no Redis. So we take Supabase's 60 s socket timeout as **a contract we measure, not a knob we tune**. Signal's discipline of a slow crash-backstop TTL against a fast independent sweep becomes ours as a **300 s durable anchor (backstop) against the 60 s socket timeout (the detector)**.

**Deliberate improvement over Signal's CAS.** Signal's `renew_presence.lua` / `clear_presence.lua` guard on `GET presenceKey == presenceUuid` so a late disconnect handler cannot delete a newer connection's presence. We remove the need for CAS: keying presence on `<user_id>:<session_id>` and deriving online as a pure fold over the current set means there is **no mutable shared value to compare-and-swap**. The same idea is applied a second time in the typing receiver, where session-scoped supersession replaces the sequence-number watermark that the attack phase broke.

**Signal-Android typing, adopted essentially verbatim** — 10 s refresh / 3 s pause / 15 s receiver expiry, STARTED immediate, `maxAttempts(1)` + 5 s lifespan + memory-only. Critically, `TypingStatusRepository` **ignores the embedded sender timestamp entirely** and expires from a local timer at receipt. **Deliberate difference:** Signal serialises with a per-thread job queue (`"TYPING_" + threadId`) to stop a STOP overtaking a START. We have no local job manager. The previous revision substituted a per-session monotonic integer and that integer is exactly what broke. We substitute **nothing** — accept-all + clear-only-own-session + unconditional local expiry — because Phoenix already guarantees in-order delivery per topic per sender, and the only reordering it cannot cover is cross-session, which supersession covers by construction.

**Signal — server-authoritative time with named provenance.** `TextSecure.proto` carries `client_timestamp = 5` and `server_timestamp = 10` as distinct fields. **Deliberate improvement:** we ship no timestamp for freshness at all, only a server-computed *age*. Presence has no need to display the sender's intent, so removing the second clock removes the naming problem along with the bug.

**Slack — away is activity, not connectivity**, at 10 minutes. Adopted. Slack's other lesson — `presence_sub` has replace semantics, "all subscription requests require the entire subscription list each invocation" — is adopted in spirit: the observer's state is always the whole set, never an increment.

**Discord — jitter and the zombie connection.** The first heartbeat is jittered by `heartbeat_interval x random(0,1)` explicitly to avoid synchronized reconnect storms; a missing ACK is a "zombied" connection. **We adopt the zombie concept on the observing side, which is what the previous revision missed**: a socket that has not produced an inbound frame in 2x the heartbeat is zombied, and a zombied socket may not render `online`.

**WhatsApp — reciprocity, server-enforced.** One boolean, both directions, expressed as a single RLS predicate at the fan-out point, which is what makes it enforceable rather than advisory.

**Where we deliberately build nothing:** no Manifold, no relays, no passive sessions, no delta-instead-of-snapshot. Discord's containment stack exists because "1,000 online users = 1M notifications; 100,000 users = 10 billion". **Our watcher set is 1.** The entire body of presence-scaling literature reduces, for a couples app, to: get the timing discipline right, keep presence out of Postgres, and pay for sockets.

**And the option worth naming: Signal ships no presence at all** — no online indicator, no last-seen. That deletes this subsystem and its whole bug class. We reject it because presence is the emotional core of a long-distance-couple product, but the privacy toggle should make choosing Signal's answer for yourself trivially easy.

---

### 13. Rejected alternatives

1. **Keep the Postgres heartbeat table, slow the cadence.** Does not remove the class. `apply_rls` costs O(*all* subscribers to the table) per row change on a single-threaded poller; 30 changes/s with RLS, 40/s on a 16XL. No amount of money fixes it, and slowing the cadence directly degrades the product because offline-detection latency *is* the interval.
2. **`UNLOGGED` presence table.** Skips the WAL, therefore Realtime cannot see it, therefore you need a poll, therefore you reintroduce the 4 SELECTs/min/user. Still produces MVCC dead tuples, and is truncated on crash recovery.
3. **A `pg_cron` sweeper doing `UPDATE ... WHERE last_seen < now() - 45s`.** Needs sub-minute cadence (paid), **writes N rows per tick — more WAL than the heartbeats it polices** — and does nothing for the read path.
4. **Supabase Presence for typing.** Impossible, not merely unwise: 5 `track()` per client per 30 s on every plan including Enterprise; a 3 s pause debounce alone exceeds it. Supabase's docs say presence is for "slow-changing state" and warn that rapid `track()` "will flood the channel".
5. **An application-level heartbeat broadcast every 15–20 s to speed hard-kill detection.** Cuts the worst case from ~60 s to ~40 s at a cost of roughly 350,000 messages/user/month — ~50x the entire rest of the presence budget — to improve a number no user perceives. It also reintroduces client-timer-driven liveness, the exact mechanism being removed.
6. **A foreground service / `WorkManager` to keep the socket alive.** Rejected on product, battery and disguise grounds simultaneously (§11).
7. **Redis / Upstash for Signal-style leases.** Theoretically correct and what Signal actually built. Rejected because Supabase Realtime already *is* an ephemeral in-memory store with the same semantics; because we cannot observe socket connect/disconnect server-side, so we could not write the leases at the moments that make the pattern work; and because it adds a paid component plus an Edge Function hop with a 2 s CPU cap on the hot path. Revisit only if we self-host Realtime.
8. **Broadcast-from-database (`realtime.broadcast_changes`) for presence.** Correct for durable events and it should be adopted there. Wrong for presence: it still routes through the WAL (~10,000 msg/s vs 224,000 for client broadcast) and gives you no leave-on-socket-death.
9. **Room state via a join-time "request current state" broadcast.** Rejected: it makes reading current state depend on the other client answering — a two-clients-online dependency for a state read. Presence sync replays the zone from the CRDT for free, and the fine-grained room degrades gracefully to the zone.
10. **Keeping the `seq` ordinal and specifying its keying correctly** (`(session_id, event_type)`, unseen sessions start at -1). This is a valid repair and it was the attack phase's first suggestion. Rejected in favour of deleting `seq`, because the correct keying is a rule an implementer must not get wrong, whereas accept-all + clear-only-own-session + local expiry has no state whose value can cause an event to be rejected. One mechanism beats two.
11. **Consolidating everything onto a single `couple:<id>` channel** (the previous revision's recommendation). Rejected: `realtime.messages` RLS cannot distinguish broadcast event names, so a single channel forces the privacy toggle to either leak typing or break chat delivery. Two channels, two policies, one extra join.

## Invariants
- ONLINE IS NOT A VALUE ANY CLIENT CAN WRITE. It is set membership in an in-memory CRDT keyed to a live, RLS-authorized socket. Every tracked-side failure — Android LMK, force-stop, crash, radio loss, battery death, netsplit, tenant suspension, JWT expiry — either removes the key or refuses the join. Enforced by: the Realtime server. There is no column anywhere in the schema capable of expressing 'online', so no bug in any client can assert it.
- AN OBSERVER MAY NOT RENDER ONLINE WITHOUT A DEMONSTRABLY LIVE LINK. The render is a pure function of (snapshot, monotonic_now) where the snapshot carries the monotonic instant of the inbound server frame that produced it; if that elapsed duration exceeds 2x the 25 s heartbeat, or no presence_sync has arrived on this channel generation, the output is `unknown` and no dot is drawn. Enforced by construction: staleness is computed at read time from elapsed monotonic time, never maintained by a timer, so a throttled/frozen/never-fired timer decays the state toward `unknown` and can never make it appear healthy. The snapshot is additionally cleared — not aged — at every AppLifecycleState.resumed, before any network call, so a pre-background snapshot is unreachable. Residual: the seam is client-side; a build that bypasses it can regress. Guarded by a property test and a CI rule that presence widgets read state only through that function.
- THE DURABLE STORE CANNOT CONTRADICT THE CRDT, BECAUSE IT CANNOT EXPRESS ONLINE-NESS. `presence_session` has exactly one meaningful column, `last_confirmed_at`. There is no `state`, no `ended_at`, no `session_id`, no `online_since`. Enforced by the schema, and checked by a test asserting those columns do not exist. A failed or lost lifecycle-pause write is therefore a no-op rather than a lie, and multi-device needs no aggregation logic.
- LAST-SEEN IS MONOTONE AND SERVER-STAMPED. `last_confirmed_at := greatest(last_confirmed_at, now())` where `now()` is the SERVER'S transaction timestamp and the client supplies no timestamp field at all. Enforced by the server. `greatest()` is required specifically because Postgres `now()` is transaction-START time and is not monotonic across overlapping transactions — a transaction that began earlier but commits later carries an older `now()` and would otherwise drag the watermark backwards. A replayed, delayed, reordered or forged anchor can move the watermark neither backwards nor forwards past the server's own clock.
- DURABLE WRITE AMPLIFICATION IS BOUNDED BY THE SERVER, NOT BY CLIENT BEHAVIOUR. The anchor is a guarded UPDATE with `where last_confirmed_at < now() - interval '240 seconds'`. A client anchoring in a tight loop updates zero rows and emits zero WAL. Enforced by the predicate, provable by a SQL test that calls it 100 times and asserts exactly one row updated.
- NO CLIENT-SUPPLIED FIELD REACHES THE DURABLE STORE. Both RPCs take zero parameters; `couple_id` is resolved inside the SECURITY DEFINER function from `(select auth.uid())` and re-resolved on every anchor, so a row written before pairing self-heals within one anchor interval. Enforced by the function signatures, checked by a signature test — a stronger guarantee than code review.
- NO WALL CLOCK APPEARS ON EITHER SIDE OF ANY FRESHNESS COMPARISON. 'Online' involves no comparison at all. 'Last seen' ships as a server-computed integer age; the client adds only monotonic elapsed time since the response arrived. Enforced by construction and mechanically checkable: inject a wall clock at ±6 hours, a 6-hour mid-session jump, a timezone change and a DST boundary, and every rendered output must be byte-identical. Exactly one whitelisted exception exists — the cold-start cached last-seen, rendered in ≥1-hour buckets with an 'about' qualifier and replaced within one round-trip — and CI fails the build on `DateTime.now()` anywhere else in the presence package.
- THE OBSERVED STATE IS A PURE FUNCTION OF THE CURRENT PRESENCE SET, RECOMPUTED IN FULL ON EVERY EVENT — never a boolean mutated by a diff. Duplicated, reordered or spurious join/leave events (which Supabase documents Presence can emit on sync) cannot produce a wrong answer, because the answer does not depend on event history. Enforced by construction; property-tested over random interleavings including reordering and arbitrary duplication.
- A CLIENT DOES NOT BELIEVE IT IS PUBLISHED UNTIL THE SERVER ECHOES IT BACK. After `track()`, the client waits for its own `<user_id>:<session_id>` key to appear in `presenceState()`; absence after 3 s (two 1500 ms presence batch periods) triggers a Full-Jitter retry, unbounded, and increments a `track_rejected` counter. Enforced by observation of server state rather than by trusting the local call's return. This is what makes a rejected join-track — the platform's response to exceeding CLIENT_PRESENCE_MAX_CALLS=5 per 30 s — self-correcting instead of a silent permanent offline.
- NO EPHEMERAL RECEIVER STATE CAN REJECT A FUTURE EVENT. There is no sequence number, ordinal or watermark anywhere in the design. Typing/room/geo receivers accept every START unconditionally (an unrecognised session supersedes rather than being dropped), a STOP clears only the session that set it, and an unconditional 15 s monotonic expiry from local receipt always wins. Enforced by construction: the default is accept, not deny, so no reconnect, session rotation or reordering can produce a permanently dead indicator, and no crashed sender can produce a permanently stuck one.
- PRESENCE KEYS ARE `<user_id>:<session_id>` WITH A FRESH SESSION_ID PER CHANNEL JOIN. A late leave from a superseded connection can only remove its own key. This is the stronger form of Signal's compare-and-swap on lease ownership: instead of guarding a mutable lease, there is no mutable shared state to corrupt.
- PRIVACY IS A PREDICATE EVALUATED INSIDE THE REALTIME SERVER, and the durable read path returns a nullable AGE, never an absolute timestamp. One reciprocal boolean gates presence.read/write and broadcast.read/write on `couple:<id>:live` in both directions; `presence_bootstrap()` nulls the age when either partner has opted out. A client that must not see presence never receives the bytes — there is no client-side filter that can be forgotten, and no timestamp on the wire to leak precision.
- EPHEMERAL SIGNALS NEVER ENTER THE WAL, ARE NEVER RETRIED, AND NEVER TRIGGER FCM. Typing, zone, room, geo and bye exist only as broadcast frames or CRDT payloads, with one send attempt and a 5 s lifespan; if the recipient is not connected they are dropped by design. Enforced structurally: no presence table is in the publication after Stage L, and the only `net.http_post` triggers in the schema are on reach_events, messages, care_nudges and call_invites — asserted by a test that enumerates triggers. Corollary: presence introduces no notification, no foreground service and nothing visible in the launcher, preserving the deliberate disguise.
- THE CHANNEL TOPIC BOUNDS THE RECIPIENT SET TO 2 BY CONSTRUCTION. `couple:<couple_id>:live` and `couple:<couple_id>:msg` are never shared across couples, so fan-out is linear in users at every scale and cannot become quadratic. The quadratic fan-out that drove Discord's Manifold/relays/passive-sessions work structurally does not arise.

## Scale ceiling
**Model, stated so it can be argued with.** Users = individuals, 2 per couple. Peak concurrency **8% of registered** — a mobile-social rule of thumb, **INFERRED**, and for a couples app where both partners tend to be active in the same evening window the real figure could plausibly be 2x. Instrument it before trusting any number below (open decision 7). Billable messages = events x (recipients + 1). **Correction from the previous revision: presence bills 3 per event, not 2** — presence diffs are batched at `PRESENCE_BROADCAST_PERIOD_IN_MS=1500` and delivered to every subscriber on the topic *including the originator*; there is no `self: false` for presence. Broadcast with `self: false` bills 2.

**Presence-domain event budget, per user per 30-minute session**

| Signal | Events | Transport | Billable |
|---|---|---|---|
| presence track/untrack (join, leave, ~2 away transitions, ~6 zone changes at the 15 s floor) | 10 | Presence, x3 | 30 |
| typing start/stop | 8 | Broadcast `self:false`, x2 | 16 |
| room | 10 | Broadcast `self:false`, x2 | 20 |
| bye | 1 | Broadcast `self:false`, x2 | 2 |
| **total** | **29** | | **68** |

At 3 sessions/day → ~204/day → **~6,200 billable messages/user/month for the entire presence domain.** Today's equivalent is ~97,000 — a **~16x reduction** — plus ~60,000 PostgREST reads/user/month that go to approximately zero (18 anchor writes/day and ~10–20 `presence_bootstrap()` calls/day replace a 15 s poll and an 800 ms refetch debounce).

`geo` is excluded from the baseline because it only runs while a map is open. When open it costs up to 15 events/min x 2 = **30 msg/min** — an opt-in surcharge, not a steady-state cost, and it should be priced separately when the live-map feature is sized.

---

**1,000 users (~80 concurrent devices)**
- Connections: 80 of Free's 200, 80 of Pro's 500. Not binding.
- Presence ops: 80 x 10 / 1800 s = 0.44/s, x3 = **1.3 presence msg/s against Free's 20/s cap.**
- Whole presence domain: **~3.0 msg/s against Free's 100/s.**
- Postgres: 80 x 1 anchor / 300 s = **0.27 writes/s**, HOT updates on a narrow unpublished single-row-per-user table. Zero WAL fan-out to Realtime, zero `apply_rls`.
- Channel joins: 80 devices x ~6 foreground cycles/hr x 2 channels = **0.27 joins/s.**
- **Failure mode: none.** For contrast, today's design at this exact scale is ~24 presence writes/s against a documented whole-project ceiling of 30 changes/s with RLS, shared with seven other published tables. **The current app is already over its ceiling at 1,000 registered users, before any other feature does anything.**

**10,000 users (~800 concurrent)**
- Connections: 800 > Pro's capped 500 → **the spend cap must be disabled.** This is the first thing that breaks and it is a billing action, not an architecture change.
- Presence ops: 4.4/s x3 = **13 presence msg/s.**
- Whole presence domain: **~30 msg/s against the 2,500/s tenant ceiling — ~1%.**
- Postgres: 2.7 anchor writes/s. Micro/Small handles it without noticing.
- Channel joins: **2.7/s** steady.
- **Failure mode from presence: none.** The binding constraint is concurrent websockets, which you pay for regardless of how presence is implemented.

**100,000 users (~8,000 concurrent)**
- Connections: 8,000 of the **10,000 hard ceiling** on Pro-no-cap/Team. Team ($599) does **not** raise it. This is the platform wall and it is presence's wall too, because presence requires a live socket by definition.
- Presence ops: 44/s x3 = **133 presence msg/s.** The plan quota is 1,000/s — but **that quota has never been validated by a published benchmark.** Supabase publishes Broadcast benchmarks (250k concurrent, 800k+ msg/s) and **publishes no Presence benchmark at all.** Their own architecture doc states that on connect "the state of that user is sent to all connected Realtime nodes" — presence is a per-tenant, cluster-wide replicated CRDT, so its cost scales with churn x cluster size, not with our 2-member topic. **The previous revision's "still 14x headroom" is withdrawn. The honest verdict at this scale is: unknown above a few thousand concurrent presence keys per tenant, evidence = absence of a published benchmark.** The concurrent-presence-key count is therefore shipped as a metric from Stage E, so the unknown is measured rather than assumed.
- Whole presence domain: **~300 msg/s of the 2,500/s tenant ceiling — ~12%.** The rest of the app must fit in the remaining 88%.
- Postgres: 27 anchor writes/s on a narrow unpublished table — trivially inside a Large instance the app needs anyway.
- **Channel joins are the sleeper and the real first failure, but not for the reason the previous revision gave.** Steady state is 8,000 devices x ~6 cycles/hr x 2 channels = **27 joins/s**, comfortably under the 2,500/s `too_many_joins` quota. The binding constraint at a *correlated* reconnect — a Supabase node restart, a regional carrier flap, a commute ending at 18:00 — is not the quota but **`DB_POOL_SIZE`, which defaults to 5**: five connections gate every private-channel RLS evaluation for the entire project. A pool-bound join **times out rather than being refused**, so the symptom is join latency and client retries, not `too_many_joins`. Supabase's own authenticated benchmark (50,000 users / 100,000 joins with RLS at join, 150,000+ msg/s) suggests this is tunable, but the pool size used in that benchmark is not published. Mitigations: raise `DB_POOL_SIZE` before the private channel ships, keep the policy to one indexed lookup, jitter every rejoin, and measure the join-latency distribution under a 200-client storm (verification 5d). **Residual risk retained; see accepted limits.**
- Under the *current* client behaviour — unconditional `disconnect()` + `connect()` on every resume, tearing down and rejoining 5–10 topics — the same fleet produces **~107 joins/s steady state** and tens of thousands within a second on a correlated event. Supabase names "rapid reconnection loops" as a top cause of manual project suspension (`RealtimeDisabledForTenant`, support ticket to lift). **This is why the conditional resume, the two-channel consolidation and the Full-Jitter rejoin are load-bearing and not polish.**

**Behaviour when the ceiling is exceeded (>10,000 peak concurrent).** Supabase refuses connections with `too_many_connections`. A user who cannot connect is absent from the CRDT, so an observer with a healthy socket renders them **offline** — correct and safe. An observer who cannot connect renders **`unknown`** plus a last-seen age fetched over plain HTTP, which needs no socket. **There is no state in which the system claims someone is online who is not**, and no state in which a link failure is silently rendered as a partner's absence. The product degrades to "WhatsApp with last-seen but no live dot", which is honest degradation rather than incorrectness — a direct consequence of invariants 1 and 2.

**Escape hatch past 10,000:** Enterprise quota, or self-host the Realtime cluster (Elixir/Phoenix, `MAX_CONNECTIONS=16384`/node) against managed Supabase Postgres. Self-hosting would also restore server-side socket-lifecycle observability, at which point the Signal lease pattern (rejected alternative 7) becomes available and the observer-side liveness gate could be replaced by a server-authoritative one.

## Cost
All figures are the **marginal cost attributable to the presence domain**, on top of whatever the rest of the app costs. Overage rates: **$2.50 per 1M Realtime messages** beyond the plan allowance; **$10 per 1,000 peak concurrent connections** in whole 1,000-packages (1,001 connections = 2 packages); egress $0.09/GB uncached. Baseline: **~6,200 billable presence-domain messages/user/month** (§scale), which corrects the previous revision's 4,700 — that figure assumed presence bills 2 per event when it bills 3.

**1,000 users (~80 concurrent)**
- Messages: 1,000 x 6,200 = **6.2M/month.** Free includes 2M with **no overage — it fails closed**, so presence alone does not fit on Free at this scale. On Pro (5M included): 1.2M over x $2.50 = **$3/month.**
- Connections: 80, inside Pro's 500. **$0.**
- Postgres: 0.27 writes/s of HOT updates on a narrow unpublished table — no compute tier change. **$0.**
- Egress: 6.2M x ~200 B = 1.24 GB, inside Pro's 250 GB. **$0.**
- **Presence total: ~$3/month.**
- *What it replaces:* today's presence generates ~97M messages/month at this scale = 95M over x $2.50 = **~$238/month in message overage alone**, plus ~60M PostgREST reads/month, plus a postgres_changes load the platform physically cannot serve. The fix saves **~$235/month at 1,000 users**, and more importantly it is the difference between working and not working.

**10,000 users (~800 concurrent)**
- Messages: 62M → 57M over x $2.50 = **$142.50/month.**
- Connections: 800 peak, 300 over Pro's 500 → 1 package = **$10/month** (spend cap must be off).
- Postgres: 2.7 anchor writes/s. Presence does not drive the compute tier. **$0 attributable.**
- Egress: 12.4 GB, inside 250 GB. **$0.**
- **Presence total: ~$153/month.**
- *What it replaces:* ~970M messages/month = **~$2,420/month** in overage, on an architecture that cannot run at any price because 800 concurrent x 18 writes/min = 240 presence writes/s against a 30–40/s postgres_changes ceiling.

**100,000 users (~8,000 concurrent)**
- Messages: 620M → 615M over x $2.50 = **$1,538/month.**
- Connections: 8,000 peak, 7,500 over the 500 included → 8 packages = **$80/month.** *This line does not scale further — 10,000 is a refusal, not a bill.*
- Egress: 620M x ~200 B ≈ 124 GB. Inside the 250 GB Pro/Team allowance only if media has not already consumed it; at the margin ~**$11/month.**
- Postgres: 27 anchor writes/s — trivially inside a Large instance the app needs anyway. **$0 attributable.**
- **Presence total: ~$1,630/month.**

**Shape of the curve, and the three levers.** Presence cost is ~94% Realtime messages at every scale past 1,000 users, and it is superlinear in *engagement*, not in users. Of the 68 billable messages per session, 30 are presence (billed 3x) and 38 are broadcast (billed 2x).

1. **Coalesce room broadcasts harder** — 3 s minimum interval instead of 1 s plausibly halves the 20-message room line for a barely perceptible loss: 100k-scale presence goes from ~$1,538 to ~$1,290/month in messages.
2. **Drop `zone` from the presence payload entirely** — this is the single largest line, 6 of the 10 presence ops = 18 of the 68 billable messages, and it is billed at the expensive 3x rate. Removing it takes 100k-scale messages to ~$1,140/month. The cost is that a reconnecting observer has no zone fallback when a `room` broadcast expires, so "where they are in the app" degrades to "in the app". Recommended only if the `track_rejected` counter shows the discretionary track path is under pressure (open decision 8).
3. **`self: false` on every broadcast** — already assumed above; it is a flat 33% saving on the broadcast half versus the naive configuration the app uses today. It is **not** available for presence, which is the whole of the F11 correction.

**The line item that disappears entirely:** at 10,000 users today's design does ~7.8M PostgREST reads/day from the 15 s liveness poll alone (800 concurrent x 4/min x 1,440 min) against a Nano's 250 baseline IOPS. That is not a bill, it is an outage. The new design has no presence poll at all — `presence_bootstrap()` fires on start, resume and socket reconnect, roughly 10–20 times per user per day.

**One cost the previous revision did not name:** raising `DB_POOL_SIZE` from its default of 5 consumes direct Postgres connections from the instance's pool (60 on Nano/Micro, 90 Small, 160 Large). At 100k scale a Large instance has room; on Micro it competes with PostgREST and Edge Functions. Budget it as a compute-tier consideration, not a line item.

## Migration
**Nothing here is a rewrite.** Each stage ships alone, leaves the app working, and is revertible — genuinely so, because Stage B installs the revert lever before any user-visible flip. The order is deliberate: the revert lever first, the security fix second, the observer-side correctness gate third, and the old mechanism deleted last.

**Correction to the previous plan, stated plainly.** The previous plan's "Stage 0" claimed standalone security value it did not have — creating a *new* private topic does not make the *existing* public topics private — and its "revert = one boolean" claim was false, because `mobile/lib/core/feature_flags.dart` holds `static const bool` values, build-time only, in a deliberately non-Play-Store sideloaded app with no remote config anywhere in the repo. Reverting a client stage meant rebuild, transfer APK, uninstall/reinstall per device: hours to days during which presence is broken. Both are fixed below.

---

**Stage A — Delete `setChatLastRead` and its 5 s timer. Outright, no replacement.**
`chat_last_read` is parsed at `presence_service.dart:73` and has **zero consumers** in `mobile/lib` — `isActivelyInChat` is `typingInChat && isTrulyOnline` (`presence_service.dart:120`), and the read watermark already lives correctly in `chat_receipts` with a `greatest()` server-side RPC. Those 12 writes/min per open chat are pure write-only waste today. This is the single largest steady-state cost reduction in the app and it depends on nothing. **One deletion, shippable today.** Gate with the `pg_stat_user_tables` probe.

**Stage B — Server-read runtime config, and the merged bootstrap read. (No behaviour change.)**
Create `app_runtime_config` (one row per couple: `presence_source enum('legacy','shadow','new')`, `min_client_build int`) and `presence_bootstrap()`, which returns config + last-seen age in one round-trip. Read on app start, on resume (debounced), and on socket reconnect — over plain HTTP, so it works with a dead socket. Cache the last value; if the read fails and nothing is cached, default to **legacy**. *Standalone value:* every later client stage becomes revertible with one `UPDATE`, per couple rather than per build, and the shadow-mode and dual-write comparisons become individually controllable. **This must ship before any stage that changes user-visible behaviour.** Without it, do not describe stages E–K as revertible.

**Stage C — Close the surveillance hole for real.**
The hole: `screen_presence:<coupleId>`, `capsule_proximity:<coupleId>`, `mood_burst:<coupleId>`, `mood_lamp:<coupleId>` and `call:<coupleId>` are **public** topics — `private: true` has zero hits in `mobile/lib` and there is no `realtime.messages` policy in `supabase/*.sql`. Anyone holding a couple UUID, which `hardening_2026_08.sql` itself notes is "the first path segment of every never-expiring `couple_media` URL", gets a live room-by-room feed plus raw GPS.
The fix, and it is a migration of *consumers*, not a new topic alongside the old ones: stand up `couple:<id>:live` and `couple:<id>:msg` as `private: true` with `realtime.messages` policies, move the consumers of `screen_presence:` and `capsule_proximity:` onto `:live`, and **stop publishing to the legacy topics**. Because flipping privacy on an existing topic name is a breaking change between app versions and this app is sideloaded, the cutover is **version-gated, not time-gated**: each client publishes its build number in the presence payload and in `app_runtime_config.min_client_build`; a client stops writing the legacy topic only once it has *observed* the partner on a build ≥ N, either live in the presence set or via the durable config row. That works without both users being online simultaneously. Raise `DB_POOL_SIZE` in the dashboard **before** this ships, and record the join-latency distribution.
*This is the stage that has standalone security value. If the plan is abandoned here, the room-by-room surveillance feed is closed.*

**Stage D — Observer-side link health, instrumented but not yet load-bearing.**
Register `heartbeatCallback` → `connect()` on `disconnected`/`timeout`. Ship the `unknown` state through the UI (rendered from the *old* mechanism's own staleness, so behaviour barely changes). Ship telemetry: last-inbound-frame age at every resume, flap rate.
**Do NOT yet remove the unconditional `disconnect()`+`connect()` at `app_shell.dart:77-78`.** That call is the accidental workaround that currently masks the stale-snapshot bug; removing it before the gate exists is exactly the "stage ordering reconstructs the bug it was meant to remove" failure. Only after the resume-age telemetry confirms the 50 s threshold does the unconditional reconnect become conditional.

**Stage E — Presence tracking in shadow mode.**
Clients `track()` on `:live`, run the `AWAITING_SELF` self-confirmation loop, compute the gated fold, and implement away, `bye` and the 12 s flap grace — but the UI still renders the old `isTrulyOnline`. Log a disagreement counter `(old, new, cause)` on every divergence, plus `track_rejected` and the concurrent-presence-key count. **Zero user-visible change, and it produces the evidence the last five fixes lacked.** Run for one full release cycle.

**Stage F — Flip the read, per couple.**
`presence_source = 'new'` in `app_runtime_config` switches the UI to the gated fold. Delete the `Timer.periodic(15 s)` poll and the 800 ms refetch debounce (`presence_service.dart:436`, 469-474) — 4 unconditional SELECTs/min/user removed. Still writing the old table; harmless. **Revert is one UPDATE.**

**Stage G — Typing to broadcast-only.**
Delete `setTyping` and `setTypingInChat` from the write path. Adopt 10 s / 3 s / 15 s with session-scoped supersession and no sequence number. One file (`chat_screen.dart`), one screen, gated by `presence_source`.

**Stage H — Split location out of the hot row.**
Narrow `user_location` (label + mode, written on label *change*), precise coordinates onto the `geo` broadcast. Stop writing `latitude`/`longitude`/`location_accuracy`/`location_updated_at` into `presence`. Behind the existing location settings. Also removes the 15 s SELECT-then-upsert-then-third-party-geocode loop at `home_screen.dart:86`.

**Stage I — `presence_session` + the two RPCs, dual-write and dual-read.**
Write the anchor (~6 per session) alongside the old presence row. Read `last_seen_age_seconds` from `presence_bootstrap()` behind the config flag and compare against the old `lastSeenText`; log divergence. Ship the read-path hardening here: singleflight, Full-Jitter retry, refetch on reconnect, disk cache.

**Stage J — Flip last-seen to the RPC. Apply the observer floor. Delete `ServerClock`.**
`displayed_age = min(server_age, monotonic_elapsed_since_observed_departure)`. `server_clock.dart` and every `ServerClock.observe` call site go; the upsert no longer needs `.select('updated_at')`.

**Stage K — Stop writing the old row.**
`setOnline` and its 30 s foreground heartbeat (`main.dart:195-204`) are replaced by the 300 s anchor. `public.presence` now receives zero writes.

**Stage L — Remove `public.presence` from the publication and drop `replica identity full`.**
Two statements — `alter publication supabase_realtime drop table public.presence;` and `alter table public.presence replica identity default;` — and this is where the entire WAL / wal2json / `apply_rls` cost disappears. It is also the test of whether A–K were done properly: if any write path remains, `n_tup_upd` on the table is non-zero and you find out *before* you drop anything. Reversible in one statement.

**Stage M — Drop the columns, then the table.** Only after a full release cycle at Stage L with the disagreement counter at zero. Do not keep the old columns as a read-only fallback: dual sources of truth for presence is how this system got here.

---

**Sequencing constraints, each naming the bug it prevents from being recreated:**

1. **B before F, G, H, I, J, K.** Without the server-read config, a bad stage on the Vivo needs a rebuild-and-sideload cycle measured in days. The design's own diagnosis is that five previous fixes "passed then failed in production"; a multi-day revert turns a failed stage into a multi-week outage.
2. **D before F, and D's *conditional* resume strictly after D's telemetry.** Removing the unconditional reconnect before the liveness gate is live reconstructs the stale-snapshot bug — the same class of error as a stage ordering that recreates total data loss. The gate must exist and the threshold must be measured before the workaround is taken away.
3. **E must not ship in the same release as F.** The whole point of shadow mode is a release cycle of divergence data on real devices with real lifecycle events. Shipping them together reproduces exactly the pattern that produced five failed fixes.
4. **C's cutover is gated on an *observed* partner build, never on a date.** A time-based cutover on a sideloaded app leaves one partner unable to see the other, which is indistinguishable from the bug being fixed.
5. **L only after K is measured at `n_tup_upd = 0`.** Dropping the publication while a write path survives converts a cheap regression into a silent one.
6. **`DB_POOL_SIZE` is raised before C, not after.** The first correlated rejoin storm after a private-channel migration is the worst possible time to discover a 5-connection pool.

**What makes this not a big bang:** at every stage the app is shippable, the old system is intact until Stage K, and the two changes delivering most of the scale win (A and L) are each a handful of lines. Abandoned after A, you have removed the single largest steady-state write in the app. Abandoned after C, you have closed the room-by-room surveillance hole. Abandoned after F, you have removed the poll and the write amplification is already two-thirds gone.

## Verification
**Why two phones on one wifi is worthless evidence, precisely:** at N=2 the `apply_rls` subscriber loop has two entries, the WAL poller is idle, both clocks agree, both processes exit cleanly through `onPause`, and there is exactly one network path with no handoff. Every failure mode in this domain lives outside that point. The design is therefore built so each failure class is checkable at a layer that needs no phone at all. **Nothing below requires two phones on two networks.**

**1. Pure-function tests — no network, no clock, no device.**
- `render(snapshot, monotonic_now) -> online|away|offline|unknown`. Property test: generate random interleavings of `join(u,s1)`, `leave(u,s1)`, `join(u,s2)`, `leave(u,s2)` **including reordering and arbitrary duplication**, and assert the output depends only on the final set. Catches the reconnect race, the duplicate-session bug and Supabase's documented spurious sync join/leave, in milliseconds.
- **The F1 gate, which did not previously exist:** for every generated snapshot, assert that if `monotonic_now - frame_instant > 50 s` OR `!synced`, the output is `unknown` **regardless of the set's contents**. If this test can fail, the gate has been bypassed and a stale snapshot can render as online.
- Assert `render` is total and has no I/O and no wall-clock access — enforced by the seam being the only path the presence widget tree may use, plus a CI rule.

**2. Typing/room receiver property test — the F2 gate, also new.**
Generate random traces of `START(session)`, `STOP(session)`, session rotations with arbitrary new session ids, duplicates and cross-session reordering, and assert:
(i) **no event from a previously-unseen session is ever dropped** — this is the exact bug the sequence-number design produced, where a reconnect reset the sender to 0 while the receiver's watermark sat at 40 and every subsequent typing event was silently discarded for the life of the process;
(ii) a STOP from session A never clears a START from session B;
(iii) in every trace, typing is false within 15 s of the last START.
The previous design's property test covered only the presence fold and structurally could not have caught this.

**3. Clock-hostility test — replaces "were the phones NTP-synced".**
Inject a fake wall clock through a single seam and run the full presence render under: +3 min, −3 min, a 6-hour jump mid-session, a timezone change, a DST boundary. **Assert every rendered output is byte-identical.** The one whitelisted exception — the cold-start cached last-seen — gets its own test asserting it moves at most one coarse bucket under a ±6 h skew and is replaced by the server-computed age within one round-trip. Back both with a CI grep that fails the build on `DateTime.now()` anywhere in the presence package outside that single call site.

**4. SQL invariant tests — no client at all.** Run inside a transaction in the `do $$ ... raise exception ... $$` style already used in `presence_server_time.sql:62-80`:
- Call `presence_anchor()` 100 times in a loop. Assert **exactly 1 row updated, then 0 for the next 99** — the predicate rate limit proven, meaning a hostile or buggy client cannot amplify write volume.
- Open two overlapping transactions, let the one that *started* earlier commit *later*, and assert `last_confirmed_at` never decreases. That is `greatest(existing, now())` proven against Postgres's transaction-start `now()` semantics, not asserted.
- Assert both RPCs accept **no parameters at all**. A signature test is a stronger guarantee than a code review.
- Assert `presence_session` has **no `state`, `ended_at`, `session_id` or `online_since` column**. This is the schema-level proof that the durable store cannot contradict the CRDT.
- Anchor as a user whose `profiles.couple_id` was null at first write, then pair them, then anchor again: assert the partner's `presence_bootstrap()` returns a non-null age. Proves the F13a self-heal.
- Set `share_presence = false` on either side and assert `presence_bootstrap()` returns a null age in both directions.

**5. One process, N simulated clients — the load and semantics harness.** A Dart or Deno harness opening K websockets to the real project with K distinct JWTs, driving the state machine. Zero phones.
- **(a) Tracked-side hard kill, deterministically.** Destroy a client's socket **without a close frame** (`socket.destroy()`/abort, not `close()`), and measure wall-clock time until the peer observes `leave`. **Assert < 90 s and record the actual number.** Doubles as a canary: the 60 s figure comes from Phoenix's default holding because Supabase's `endpoint.ex` sets no `:timeout` — an inference from source. If Supabase changes it, this tells you before users do.
- **(b) OBSERVER-side hard kill — the F1 test, and the one nothing in the previous plan covered.** Destroy the *observing* client's socket without a close frame while the tracked client stays alive and present. Then simulate resume. **Assert the observer renders `unknown`, never `online`, until a fresh `presence_sync` arrives on a socket whose last inbound frame is < 50 s old.** Then assert the same when the observer's heartbeat timer is artificially suppressed (simulating Doze/MIUI throttling) rather than the socket being destroyed — the state must still decay to `unknown`, because staleness is read-time arithmetic and not timer-driven.
- **(c) Track rejection and recovery.** Drive `track()` past `CLIENT_PRESENCE_MAX_CALLS=5 / 30 s` and assert (i) the client detects its own key's absence from `presenceState()` within 3 s, (ii) it retries with Full Jitter until accepted, (iii) `track_rejected` increments, (iv) the final resting zone is published within 15 s. **Also record whether the 5-call window resets on reconnect or is per-client-identity** — until that number exists, the window's scope stays labelled INFERRED rather than asserted.
- **(d) Join storm — measuring the right signal.** 200 clients joining within one second against the real project. Measure the **join latency distribution and timeout rate**, not just the `too_many_joins` count, because a `DB_POOL_SIZE`-bound join times out rather than being refused. Run it once at the default pool size and once at the raised value and record both.
- **(e) Privacy — the corrected assertion.** With `share_presence = false` on either side, assert the peer receives **zero presence frames and zero broadcast frames on `couple:<id>:live`**, while `couple:<id>:msg` continues to deliver chat normally. Then assert the settings toggle's forced rejoin makes it take effect immediately rather than at JWT expiry. (The previous plan's assertion — "the channel join is refused server-side" — contradicted its own §8 mechanism and is deleted.)
- **(f) Session rotation under churn — the F2 field case.** Force 6 reconnects in 10 minutes while typing continuously, and assert the partner renders typing in **every** session. This is the train-with-30-second-gaps scenario that the sequence-number design failed permanently.
- **(g) `bye` semantics.** Assert a `bye` followed by `untrack` produces an offline render in 1.5–3 s; assert a `bye` **without** a subsequent leave produces no state change at all (it is a grace waiver, not a state change); assert a replayed `bye` for an already-departed session is a no-op.

**6. Real hard-kill, Doze and radio loss on one machine, scripted.**
`adb shell am force-stop com.miles.miles` is a genuine LMK-equivalent kill and is scriptable; `adb shell cmd deviceidle force-idle` reproduces Doze; `adb shell svc data disable` / the emulator's network toggle reproduces radio loss; `tc netem` on an emulator reproduces the tunnel/half-open-TCP case. Pair **one** real device against a harness peer and every mobile-lifecycle case becomes deterministic and repeatable on one machine, one network. Run 5(b) against the real device specifically under `force-idle`, because that is the configuration in which the observer's heartbeat timer is genuinely throttled by the OS rather than by the harness.

**7. The regression gate for the whole migration — one query.** Before and after a 10-minute session of typing, navigating, chatting and moving:
`select relname, n_tup_upd from pg_stat_user_tables where relname in ('presence','presence_session','user_location');`
`presence.n_tup_upd` delta must be **0** after Stage K. `presence_session.n_tup_upd` must be ≈ 2 per 10 minutes. If a code path still writes the hot row, this finds it in one command — and it finds it *before* Stage L drops the publication.

**8. Field telemetry — the thing that would have caught "passed then failed in production".** Five counters, batched, cheap:
- **Flap rate** — `offline → online` transitions within 12 s of each other as a fraction of all transitions. ~1% is the alarm; today's unconditional disconnect-on-resume would put it far above that.
- **`track_rejected`** — any track that needed a retry. A non-zero steady-state value means the discretionary path is under pressure and `zone` should come out of the presence payload (open decision 8).
- **`unknown_render_seconds`** — how long users spend in `unknown`. This is the honesty tax of the F1 fix and it must be measured, because a design that is always `unknown` is correct and useless.
- **Last-inbound-frame age at resume** — the distribution that justifies (or corrects) the 50 s threshold and the conditional-reconnect rule.
- **Concurrent presence keys per tenant** — the metric that turns the 100k-scale unknown into a measurement, given that Supabase publishes no Presence benchmark.
- Plus the **disagreement counter** during Stages E and I only: old verdict vs new, with cause.

**What none of this proves.** Whether Supabase's presence CRDT behaves correctly under a genuine cluster netsplit (`permdown_period` = 20 min). That is unobservable from outside and unfixable from inside. **And it is the one case the observer-side liveness gate does not save you**, because the observer's socket is healthy — the CRDT itself is wrong. Failure direction is "presence lingers"; mitigation is the 12 s flap grace plus the durable last-seen path, so the UI degrades to stale-but-honest. **Flagged gap, not a solved problem.**

## Accepted limits
**1. Hard-kill offline latency is 47–72 s and we do not control it.** 60 s Phoenix socket timeout (last frame 0–25 s before death) plus the 12 s flap grace. Supabase's `endpoint.ex` sets no `:timeout`, so the 60 s figure is Phoenix's default holding — an inference from source, which is why harness test 5(a) measures it as a canary. Residual risk: a partner who force-quits or is LMK-killed shows as online for up to 72 s. Mitigation is display-level only — last-seen coarsened to 1-minute granularity so the platform's TTL is invisible.

**2. The observer-side liveness gate is client-side, not server-enforced.** We cannot observe socket lifecycle server-side at all: Edge Functions are stateless and hold no websocket, and there is no Redis. So the "an observer may not render online without a live link" invariant is enforced by a pure function plus a CI rule that the presence widget tree reads state only through it — construction and test, not the server. Residual risk: a build that bypasses the seam can render a stale snapshot as online. This is a one-bad-build risk rather than a one-bad-network risk, and it is materially smaller than the current situation, but it is not the same as server enforcement. It becomes server-enforceable only if we self-host Realtime.

**3. Durable last-seen is accurate to ±5 minutes when the observer was not connected at the moment of departure.** The 300 s anchor with a 240 s predicate means `last_confirmed_at` is uniformly 0–300 s stale at the moment of death. The observer floor (`min(server_age, monotonic_since_observed_departure)`) makes this ~±72 s for an observer who was connected and watching, but a partner on a train with no socket, opening the app 20 minutes later, gets the ±5-minute answer. Residual risk: "last seen 6 minutes ago" when it was really 2. Not closable without either a faster anchor (which is write amplification for a number nobody perceives) or a durable write at lifecycle-pause (which is an HTTP request racing Android's process teardown — rejected as the same category of assumption as "the client sends an ack").

**4. Presence behaviour above a few thousand concurrent presence keys per tenant is unknown.** Supabase publishes Broadcast benchmarks (250k concurrent, 800k+ msg/s) and **publishes no Presence benchmark at all**, while documenting that on connect "the state of that user is sent to all connected Realtime nodes" — a per-tenant, cluster-wide replicated CRDT whose cost scales with churn x cluster size, not with our 2-member topic. The 1,000 presence-msg/s plan quota is therefore an unvalidated number. The previous revision's "14x headroom at 100k users" is withdrawn and replaced with an explicit unknown plus a shipped metric (concurrent presence keys). First symptom would be presence sync latency degrading under churn — unobservable without that metric.

**5. `DB_POOL_SIZE` is a serialization point we can tune but not bound.** Realtime evaluates private-channel RLS on its own pool, default 5, gating every private-channel join project-wide. We raise it, we make the policy one indexed lookup, and we measure join latency under a 200-client storm — but a correlated fleet-wide rejoin (Supabase node restart, regional carrier flap, a commute ending) can still queue joins behind that pool, and the failure mode is join *timeout*, not `too_many_joins`. Every user in such a storm renders their partner as `unknown`, which is correct, but a network blip becomes a fleet-wide "nobody can vouch for anything" event, and the retries resemble the "rapid reconnection loops" Supabase names as a top cause of manual project suspension. Residual risk retained and measured, not eliminated.

**6. Turning off `share_presence` also turns off typing, room and live location, in both directions.** Supabase's `realtime.messages` RLS can distinguish presence from broadcast but **cannot see a broadcast's event name**, which lives in the payload rather than a column. One privacy predicate on `couple:<id>:live` therefore governs all of it. This is a deliberate product limit, not a gap, and the UI copy must state it explicitly. The alternative — a third private channel per couple carrying typing under its own predicate — is available if the coupling proves unacceptable, at the cost of one more join per device.

**7. Private-channel RLS is cached for the connection lifetime.** Toggling privacy off takes effect on rejoin. The settings toggle forces a rejoin, making it immediate in practice; if that forced rejoin fails, the worst-case bound is one JWT expiry (3600 s default). Not closable — the caching is Supabase's, and it is the same property that makes private-channel authorization O(1) per join instead of O(1) per message.

**8. Presence CRDT behaviour under a genuine cluster netsplit is unobservable and unfixable from here.** `permdown_period` is 20 minutes and it is Supabase's config, not ours. This is the one case the observer-side liveness gate does not catch, because the observer's socket is healthy while the CRDT itself is stale. Failure direction is "presence lingers online"; the 12 s grace and the durable last-seen path mean the UI degrades to stale-but-honest rather than wrong, but for up to 20 minutes a user could render as online after a replica loss.

**9. Multi-device presence is correct; multi-device last-seen is a single maximum.** Distinct `<user_id>:<session_id>` keys mean two devices correctly render as one online user, and because the durable row has only `last_confirmed_at` guarded by `greatest()`, a phone going offline can no longer stamp anything that contradicts a still-connected tablet. But "last seen" is one number per human across all devices, which is the right semantic and is stated here so nobody expects per-device detail. Separately, `profiles.fcm_token` is a single column, so signing in on a second device still silently steals push from the first — a push-domain problem this design does not fix and does not worsen.

**10. The server-read config lever does not make everything revertible.** `app_runtime_config` converts every behaviour flip into one `UPDATE`, but a client-side crash loop, a rendering bug outside the flagged path, or a bug in the config-read path itself still requires a rebuild and a manual sideload on each device. On a deliberately non-Play-Store app there is no forced-update channel. Residual risk: the class of bugs the flag does not reach.

**11. The cold-start cached last-seen is the one wall-clock-dependent render in the system.** With no network and no live socket, the client ages a persisted value against the device clock, in ≥1-hour buckets with an "about" qualifier, and replaces it the moment a round-trip succeeds. A ±6-hour device error can move it one bucket. Accepted deliberately in exchange for not showing a blank screen to a user who has been offline for three days, and whitelisted explicitly so the CI clock-hostility rule can fail the build on every other use.

**12. Peak concurrency of 8% of registered users is a rule of thumb, not a measurement.** Every cost and scale figure rests on it. For a couples app where both partners are active in the same evening window the real number could plausibly be double, which moves the 10,000-user line from 800 to 1,600 concurrent and roughly doubles the connection bill. Ship the connected-clients metric from Supabase's Realtime reports before the 1,000-user mark and re-derive the curve.

**13. What this design deliberately does not build:** any fan-out containment whatsoever. No Manifold-equivalent, no relay tier, no passive sessions, no delta-instead-of-snapshot. Discord built all four to survive a quadratic watcher set; ours is size 1. If the product ever grows group presence — a family, a friend circle — none of this transfers and the whole scale section must be redone.

## Open decisions
**1. Two private channels per couple (`:live` and `:msg`), or one?**
This design requires two, because `realtime.messages` RLS cannot see a broadcast's event name, so a single channel forces the privacy toggle to either leak typing or break chat delivery. **Recommendation: two.** The cost is one extra join per device (0.27 joins/s at 1,000 users, 27/s at 100,000) against today's 5–10 topics rejoined on every resume. **This is the top cross-domain decision and needs a single owner** — presence can build `:live` unilaterally, but the join-rate and privacy wins only fully materialise when chat, calling and reach converge on `:msg`.

**2. How does the join-time RLS policy resolve `couple_id` — indexed lookup, or a JWT claim?**
A `custom_access_token_hook` putting `couple_id` in the JWT makes the policy a pure string comparison with **zero database access at join**, which removes the `DB_POOL_SIZE` serialization point entirely. The catch is revocation: JWT claims are stale until refresh, so an unpair would leave the old channel joinable for up to 3600 s unless unpairing also forces a global sign-out. **Recommendation: ship the indexed `profiles` lookup with `(select auth.uid())` wrapped once and `DB_POOL_SIZE` raised, because it is correct today; treat the JWT claim as a measured optimisation to adopt only alongside a forced-sign-out-on-unpair path.** Decide after harness test 5(d) produces the join-latency numbers at both pool sizes.

**3. What does `unknown` look like?**
It is the new state and it will be seen often — on every resume for one round-trip, and for the whole of a train journey. **Recommendation: no dot at all (not grey, not hollow-green) plus the last-seen line, identical in shape to `offline` but never carrying the word "Offline".** The user should not be taught to distinguish them; they should simply never be told "she is online" or "she is offline" when the app cannot vouch for either. Ship `unknown_render_seconds` telemetry from Stage D — if users spend more than a few percent of session time in `unknown`, the 50 s threshold or the reconnect policy needs revisiting, not the UI.

**4. Ship the `away` state, or just online/offline?**
Slack and Discord both have it; Slack's rule is 10 minutes of no activity. It costs one enum value in the presence payload and one interaction timer. **Recommendation: yes, ship it in Stage E.** It is nearly free and it is the honest answer to "the phone is on the kitchen table with the app open" — which in a couples product is a direct source of "she was online and didn't reply".

**5. Ship `bye`, or accept 12–14 s for a clean background?**
`bye` buys a 1.5–3 s clean-background transition for two extra billable messages per session, and its forgery surface is nil (the only forger is your partner, accelerating their own offline transition by 12 s, which they can do by closing the app). **Recommendation: ship it.** The alternative is publishing 12–14 s as the contract for the common case, which will be reported as "the presence fix is slow" and will tempt someone to skip the grace on the first leave — reintroducing the wifi/LTE-handoff flicker the grace exists to kill.

**6. Reciprocity: one toggle, or WhatsApp's split?**
WhatsApp deliberately does *not* make "online" and "last seen" independent — since Aug 2022 the online setting offers only Everyone or Same-as-last-seen. **Recommendation: one reciprocal `share_presence` boolean covering online, last-seen, typing, room and geo.** It is the only version expressible as a single RLS predicate at the fan-out point, which is what makes it enforceable rather than advisory, and with a watcher set of one the free-rider dynamic the reciprocity rule exists to defeat is the entire dynamic. The UI copy must name everything it disables.

**7. Default for `share_zone` ("where they are in the app").**
**Recommendation: OFF by default, opt-in, reciprocal.** This is the creepiest signal in the system and the one most likely to be regretted. Today it is on for everyone *and* rides an unauthenticated public topic — a leaked couple UUID, which is the first path segment of every never-expiring `couple_media` URL, currently yields a live room-by-room feed of a partner's movement through an intimate app. Highest regret asymmetry in the design.

**8. Keep `zone` in the presence payload at all?**
Zone is 6 of the 10 presence ops per session and, billed at presence's 3x rate, 18 of the 68 billable messages — the single largest cost line and the only remaining discretionary `track()` path, i.e. the only remaining exposure to `CLIENT_PRESENCE_MAX_CALLS`. Removing it saves ~$400/month at 100k users and eliminates the discretionary track path entirely, at the cost of the fallback that makes `room` degrade gracefully. **Recommendation: keep it for now with the 15 s floor, and delete it the moment `track_rejected` is non-zero in the field or the message bill becomes the binding constraint.** This is a decision to make with a number, not in advance.

**9. Do we surface the offline-latency contract to users?**
The design gives 1.5–3 s on an announced clean background, 12–14 s unannounced, 47–72 s on a hard kill. **Recommendation: adopt these internally, do not surface them, and coarsen the last-seen display to 1-minute granularity** — never "last seen 12 seconds ago". Minute granularity makes the platform's 60 s TTL invisible and removes an entire category of "it says she's online but she isn't" reports at zero engineering cost.

**10. Multi-device.**
Presence keys are already `<user_id>:<session_id>`, so multi-device works with no change and two devices correctly render as one online user; the durable row's single `greatest()`-guarded column means a second device cannot corrupt last-seen. **Recommendation: keep the key multi-device-ready (it is free) and accept last-seen as one max per human.** The genuinely broken part is `profiles.fcm_token` being a single column, so a second sign-in silently steals push — **a push-domain decision, flagged here, not solved here.** (The previous revision's claim that multi-device "works with no change" was false for the durable row; it is true now only because `state`, `session_id` and `ended_at` were removed from it.)

**11. Instrument concurrency before trusting any cost number.**
Every figure rests on "peak concurrency = 8% of registered", a rule of thumb. **Recommendation: ship the connected-clients metric from Supabase's Realtime reports (available on all plans) before the 1,000-user mark and re-derive the curve from real data.** Cheapest available way to stop the cost model being fiction.

**12. Do we keep `presence.current_screen` and the old columns as a read-only fallback after Stage L?**
**Recommendation: no.** Keeping them creates a second source of truth for a fact that now has exactly one, and dual sources of truth for presence is how this system got here. Drop them in Stage M as planned.
