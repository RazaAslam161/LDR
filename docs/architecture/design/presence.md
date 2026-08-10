# PRESENCE — online/offline, last seen, typing, and "where they are in the app" (zone/screen sharing), including the privacy controls and the location-sharing writes that currently ride the same row.

## Current design
**How it works today, precisely.**

Everything is one Postgres row. `public.presence` (E:\LDR\supabase\presence_and_mood.sql) has PK `user_id`, ~24 columns spanning online flag, last_seen, typing, typing_in_chat, mood, mood_color, latitude, longitude, location_accuracy, location_label, location_sharing_mode, location_updated_at, current_activity, current_screen, body_photo_path, avatar_emoji, checkin_photo_url/at, chat_last_read, app_last_active_at, updated_at. It is `replica identity full` and in the `supabase_realtime` publication (presence_and_mood.sql:42-48).

Every presence fact is the same call: `PresenceService._upsert` (presence_service.dart:174-214) does `upsert({user_id, couple_id, updated_at, [app_last_active_at], ...patch}, onConflict:'user_id').select('updated_at')` — a full round-trip returning the server timestamp, which feeds `ServerClock.observe` (an NTP-style round-trip-midpoint offset estimator, server_clock.dart).

A `BEFORE INSERT OR UPDATE` trigger `presence_stamp_server_time` (presence_server_time.sql:22-49) overwrites `updated_at` with `now()`, and overwrites `app_last_active_at` with `now()` **only when the client sent a changed value**. So the server owns WHEN, the client owns WHETHER a write counts as activity.

Verified writers and cadences:
- `setOnline(true)` every 30 s from `Timer.periodic` in main.dart:195-204, foreground only.
- `setChatLastRead` every 5 s while the chat is open (chat_screen.dart:495) = 12 writes/min.
- `setTyping(true)` on first keystroke, `setTyping(false)` 1500 ms after the last (chat_screen.dart:592-609) — *plus* a redundant broadcast on `mood_burst:<coupleId>` that is the path actually rendering the dots.
- `setLocation` every 15 s while Home is mounted (home_screen.dart:86) = 4 writes/min, each preceded by a SELECT of the user's own row to re-read the mode, a GPS fix, and a third-party reverse-geocode.
- `setScreen` on every navigation (presence_route_observer.dart:132-148), which *also* fires a broadcast on `screen_presence:<coupleId>`.
- `setMood`, `setBodyPhoto`, `setAvatarEmoji`, `setCheckinPhoto` ad hoc.

The read side (`PartnerPresenceNotifier`, presence_service.dart:391-499) subscribes `presence:<coupleId>` via `RealtimeService.coupleTable` — `onPostgresChanges(event: all, filter: couple_id=eq.X)` — **throws the payload away**, starts an 800 ms debounce, then issues a fresh PostgREST `SELECT ... eq(couple_id).neq(user_id).order(updated_at desc).limit(1)`. On top of that it runs an unconditional `Timer.periodic(15 s)` refetch (line 436) so the freshness getters decay when a hard-killed partner writes nothing. Freshness is decided on the client: `isTrulyOnline = ServerClock.now().difference(app_last_active_at).inSeconds <= 45` (line 126-135).

Supabase Presence is not used anywhere: `grep -rn "\.track(\|presenceState\|onPresenceSync" lib/` returns **zero hits**. Presence is 100% Postgres today.

**Why it fails at scale — the arithmetic.**

Trace one `setChatLastRead`. It produces: (1) one PostgREST round-trip; (2) one WAL record carrying the **entire old and new row** because of `replica identity full` — ~24 columns including GPS coordinates, on a write that changed one timestamp; (3) wal2json decode via `pg_logical_slot_get_changes` running **on your own Nano instance**; (4) `realtime.apply_rls`, which does `array_agg(sub) from realtime.subscription sub where sub.entity = 'public.presence'::regclass` — **every presence subscriber project-wide**, because the `couple_id=eq.X` filter is evaluated *inside* the loop and does not shrink it; (5) an RLS prepared-statement execution per matching subscriber, where the predicate is `couple_id = public.current_user_couple_id()` and that helper is a `SECURITY DEFINER` subquery on `profiles` (schema.sql:105); (6) two websocket frames, because the filter is on `couple_id` so the writer receives their own echo; (7) up to two PostgREST SELECTs, one per client, after the 800 ms debounce.

At ~18 writes/user/minute with a chat open, and Supabase's documented ceiling of **30 changes/sec with RLS at 500 clients — and 40/sec even on a 16XL** (a 370× compute increase buys 1.3×), the whole-project postgres_changes budget is consumed by roughly **100 concurrently-chatting users**, and that budget is shared with `messages`, `chat_receipts`, `reach_events`, `capsules`, `body_touches`, `intimacy_signals` and the Closer set. At 1,000 registered users (~80 concurrent on an 8% concurrency model) presence alone is ~24 writes/sec. **The app is at its postgres_changes ceiling at roughly one thousand registered users, before any other feature does anything.**

Independently of throughput, the correctness is wrong in four ways that N=2 testing structurally cannot see:

1. **`is_online` is a lie by construction.** A force-killed app never writes `false`. The code's own comment says so (presence_service.dart:78-80). The workaround is the 45 s freshness window, which replaces a lie with a clock comparison.
2. **The clock comparison still has a device clock in it.** `ServerClock.now()` = `DateTime.now().toUtc() + offset`, and the offset is zero until the first heartbeat lands. Worse, `lastSeenText` (line 152) uses **raw `DateTime.now().toUtc()`** with no correction at all — so the boolean is skew-corrected and the string beside it is not.
3. **Ephemeral state is durable and replicated.** Typing — sub-second, worthless in 3 seconds — is written to a replicated 24-column row, and each write triggers the partner's debounced full-row SELECT. Two DB upserts + two WAL fan-outs + two partner SELECTs per typing burst, on top of the broadcast that already rendered the dots in milliseconds.
4. **Realtime is used as an expensive doorbell for a query.** Every change costs a WAL record, a wal2json decode, an O(all-subscribers) RLS loop, a websocket frame, *and then* a PostgREST query per subscriber — for data that was already in the payload.

And the reason five point-fixes passed on two NTP-synced phones and then failed: at N=2 the `apply_rls` loop has two entries, the poller is idle, the WAL is empty, both clocks agree, both processes exit cleanly, and both sockets are on one wifi. Every failure mode in this domain is invisible at N=2. **Two-phone testing does not sample the space where the bugs live.**

## Target architecture
**The one structural move: online stops being a value anyone writes, and becomes membership of a live authorized socket.** Everything else follows.

---

### 1. What is ephemeral, what is durable, and where each lives

| Fact | Nature | Home | Never |
|---|---|---|---|
| online / away | ephemeral, derived from a socket | Supabase Realtime **Presence** (Phoenix.Tracker CRDT, in-memory, never touches Postgres) | any table |
| zone (coarse: which area of the app) | ephemeral, slow-changing | Presence payload | any table |
| room (fine: "the Vault", "Truth or Dare") | ephemeral, fast-changing | **Broadcast** on the same channel | any table |
| typing | ephemeral, keystroke-rate | **Broadcast** | any table, any FCM path |
| live coordinates (precise) | ephemeral, foreground-only | **Broadcast** | any table |
| coarse location label (city) | durable, changes hourly at most | narrow `user_location`, **not** in the publication | `presence` |
| **last seen** | durable — the ONLY durable presence fact | narrow `presence_session`, **not** in the publication | — |
| privacy preferences | durable, rarely written | `presence_prefs` | — |

Everything on one private channel per couple: **`couple:<couple_id>`**, `config: {private: true, presence: {key: "<user_id>:<session_id>"}}`. One topic, not five. The current topics `presence:<id>` (postgres_changes), `screen_presence:<id>` (public broadcast) and the presence half of `mood_burst:<id>` all collapse into it.

---

### 2. Data model

**Ephemeral — presence payload (5 keys, cap is 10 per object):**
```
key: "<user_id>:<session_id>"          session_id = fresh uuid v4 per channel join
{ u: user_id, s: session_id, st: "online"|"away", z: <zone 0..8>, d: "android" }
```
No timestamps. Nothing in this payload is compared to anything.

**Ephemeral — broadcast events on `couple:<id>`:**
```
typing  { s: session_id, n: seq, t: bool }
room    { s: session_id, n: seq, r: string|null }
geo     { s: session_id, n: seq, lat, lon, acc }     // precise mode, map open, both directions
```
`seq` is a per-session monotonic integer starting at 0. It is an ordinal, not a clock.

**Durable — `presence_session` (narrow, unpublished, no replica identity full):**
```
user_id            uuid primary key references profiles(id) on delete cascade
couple_id          uuid                          -- for RLS only
session_id         uuid
state              text  -- 'online' | 'away' | 'offline'
online_since       timestamptz                   -- server now()
last_confirmed_at  timestamptz not null default now()   -- server now(); the watermark
ended_at           timestamptz                   -- server now(), set on clean leave
```

**Durable — `presence_prefs`:**
```
user_id        uuid pk
share_presence boolean not null default true   -- reciprocal: online + last-seen + typing
share_zone     boolean not null default false  -- "where they are in the app", opt-in
```

**Durable — `user_location` (split out of the hot row):** `user_id pk, couple_id, label text, mode text, updated_at timestamptz`. Written on *label change*, not every 15 s. Coordinates are never persisted at all.

---

### 3. Write path — two RPCs, both `SECURITY DEFINER`, neither takes a timestamp

**`presence_mark(p_session uuid, p_state text)`** — called on session start, on the online↔away transition, and on clean leave. Upsert on `user_id`:
```
session_id        := excluded.session_id
state             := excluded.state
online_since      := case when old.session_id is distinct from new.session_id
                          then now() else old.online_since end
last_confirmed_at := greatest(old.last_confirmed_at, now())
ended_at          := case when new.state = 'offline' then now() else null end
```

**`presence_anchor()`** — the crash backstop for last-seen. Called every 300 s ± 30 s jitter while foregrounded. It is a guarded UPDATE, not an upsert:
```
update presence_session set last_confirmed_at = now()
 where user_id = (select auth.uid())
   and last_confirmed_at < now() - interval '240 seconds'
```
A client calling this in a loop updates **zero rows** and produces **zero WAL**. The cadence is enforced by the predicate, not by client good behaviour.

Roughly 2 transition writes + 6 anchor writes per 30-minute session. Compare 540 writes today.

---

### 4. Read path — the server does the subtraction

**`presence_last_seen()`** returns, for the caller's partner:
```
{ user_id, state, last_seen_age_seconds int|null }
last_seen_age_seconds = extract(epoch from now() - greatest(last_confirmed_at, coalesce(ended_at,'epoch')))::int
```
Nulled when the partner's `share_presence` is false. **The absolute timestamp never leaves the server.** The client renders `age + monotonic_elapsed_since_response` — `Stopwatch`, not `DateTime.now()`. A device six hours wrong renders identical output.

`ServerClock` (server_clock.dart, ~90 lines) is deleted. There is nothing left to correct.

Called once per chat/profile open and once on resume. Not on a timer. The 15 s poll and the 800 ms refetch debounce in `PartnerPresenceNotifier` both die — that is 4 unconditional SELECTs/min/user removed outright.

---

### 5. Observer derivation — a pure fold, never a mutated boolean

```
online(state: Set<PresenceKey>, u: UserId) -> bool
    = state.any(k => k.startsWith(u + ":"))
zone(state, u) = the payload of the most recently joined key with that prefix
```
Recomputed **from `presenceState()` in full** on every sync/join/leave event. The diff is a wakeup, never the source. Supabase documents that sync can emit spurious join/leave; that cannot produce a wrong answer here because the answer is a pure function of the current set.

**Flap suppression:** when the last key for a user disappears, start a 12 s monotonic grace timer before rendering offline. A join within the grace cancels it with no repaint. This kills the visible offline-flicker on wifi↔LTE handoff, JWT-refresh rejoin, and camera/picker return.

---

### 6. State machine

```
DISCONNECTED ──socket open+channel join authorized──▶ CONNECTING
CONNECTING   ──track() accepted──────────────────────▶ ONLINE
ONLINE       ──10 min no user interaction────────────▶ AWAY
AWAY         ──any interaction───────────────────────▶ ONLINE
ONLINE|AWAY  ──lifecycle paused──▶ LEAVING ──untrack + presence_mark('offline')──▶ DISCONNECTED
ONLINE|AWAY  ──socket death / LMK / force-stop / radio loss / tenant refusal──▶ DISCONNECTED
```
`DISCONNECTED` is the default and the terminal state of every failure. `AWAY` is Slack's and Discord's split of *activity* from *connectivity* — the app being open on a table in another room is not "here".

---

### 7. Exact timing numbers

| Timer | Value | Justification |
|---|---|---|
| Transport heartbeat (client→server) | **25,000 ms** | platform default, `realtime_client` `defaultHeartbeatIntervalMs`. Keep. |
| Transport TTL (server closes socket) | **60,000 ms** | Phoenix default; Supabase's `endpoint.ex` sets `max_frame_size`/`active_n`/`fullsweep_after` but **no `:timeout`**. Ratio 2.4× — satisfies "TTL ≥ 2× heartbeat". Not ours to tune. |
| ⇒ hard-kill offline detection | **35–60 s** | 60 s from last received frame; last frame was 0–25 s before death. |
| ⇒ with 12 s flap grace | **47–72 s** | the honest product contract for a hard kill. |
| Clean background → offline | **≤2 s** | explicit `untrack()`; the common case. |
| Phoenix.Tracker cluster heartbeat / down_period / permdown | 15 s / 30 s / 20 min | Supabase's, not ours. `down_period` is 2× the heartbeat by construction; the 20-min permdown is why a brief netsplit does not mass-evict. |
| Discretionary `track()` budget | **token bucket cap 2, refill 1 per 15 s** | platform cap is `CLIENT_PRESENCE_MAX_CALLS=5` per `CLIENT_PRESENCE_WINDOW_MS=30000`, **on every plan including Enterprise**. Reserve 2 for join+leave, leave headroom. Pending zone is coalesced (trailing edge) and always flushed, so the resting zone is published within ≤15 s no matter how fast the user navigates. |
| Away threshold | **10 min** no interaction, foregrounded | Slack: "After 10 minutes with no activity, the user is automatically marked as away." |
| Durable last-seen anchor | **300 s ± 30 s jitter**, predicate at **240 s** | Sole job: bound last-seen error after a hard kill. 5 min is below any human-meaningful last-seen granularity and is **5× the 60 s socket timeout** — mirroring Signal's discipline of an 11-minute TTL against a 30-second sweep. The slow knob must never be the detector. |
| Typing STARTED → first send | **immediate, no leading debounce** | Signal `TypingStatusSender`; latency is the entire point of the feature. |
| Typing refresh while typing | **10,000 ms** | Signal `REFRESH_TYPING_TIMEOUT`. |
| Typing pause → STOPPED | **3,000 ms** | Signal `PAUSE_TYPING_TIMEOUT`. Today's 1,500 ms flickers on anyone who pauses mid-sentence. |
| Typing receiver expiry | **15,000 ms from local receipt (monotonic)** | Signal `RECIPIENT_TYPING_TIMEOUT`. 1.5× the refresh = exactly one missed refresh of tolerance. Today's 4 s expires before the 10 s refresh — a stuck-off indicator by construction. |
| Typing send policy | **1 attempt, 5 s lifespan, never retried, never persisted** | Signal `TypingSendJob`: `maxAttempts(1)`, `setLifespan(5s)`, `setMemoryOnly(true)`. A late typing indicator is worse than a missing one. |
| Room broadcast | on change, **min interval 1 s**, trailing coalesce | bounded by human navigation; the floor stops a nav-loop bug from consuming the tenant msg/s budget. |
| Room receiver expiry | **90 s from receipt (monotonic)** | on expiry the UI falls back to the presence `zone`, which is *more* correct, not less — so no keepalive broadcast is needed at all. |
| Live `geo` broadcast | **≥5 s and moved >25 m** while a map is open; **4 s hard floor** | replaces the unconditional 15 s write + SELECT + geocode. |
| Channel (re)join backoff | **`random(0, min(10s, 250ms × 2^attempt))`** | AWS Full Jitter. Discord mandates jittering the first heartbeat by `heartbeat_interval × random(0,1)` explicitly to prevent reconnect storms; Supabase enforces joins/sec as a hard quota and returns `too_many_joins`. |
| Resume handling | **do not disconnect**; debounce lifecycle bursts to 1 action / 400 ms | today AppShell calls `realtime.disconnect()` + `connect()` unconditionally on *every* resume including camera/picker returns. Under a membership model that is a literal, visible offline flicker on the partner's screen every time you attach a photo. |

---

### 8. Privacy — one reciprocal boolean, enforced in the Realtime server

RLS on `realtime.messages` gating the private channel `couple:<id>`:
- **`presence.write`** allowed iff caller is a member of that couple **and** `presence_prefs.share_presence` for the caller is true.
- **`presence.read`** allowed iff the same predicate.

One boolean, both directions. This is WhatsApp's rule — *"if you don't share your last seen, you can't see other contacts' last seen either"* — and it is the reason it exists: it removes the free-rider equilibrium where both hide and both watch. In a couples app the watcher set is one person, so that dynamic is the whole dynamic. Supabase's `presence_handler.ex` evaluates `policies.presence.read`/`.write` **inside the Realtime server**, which makes this genuinely equivalent to Discord's server-side `invisible` — the payload never reaches a client that should not have it.

`share_zone` is separate and **defaults off**. "Where they are in the app" is the creepiest signal in the system and today it rides an *unauthenticated* topic (`screen_presence:<coupleId>`), so anyone who guesses the couple UUID — which appears as the first path segment of every `couple_media` URL — gets a live room-by-room feed. Making every topic private is Stage 0 of the migration for that reason alone.

**Honest caveat:** private-channel RLS is evaluated at join and cached for the connection lifetime. Toggling `share_presence` off does not take effect until a rejoin. Mitigation: the settings toggle forces a channel rejoin, making it immediate in practice; the worst-case bound absent that is one JWT expiry (3600 s default).

---

### 9. Ephemeral signals never wake a device

No presence, zone, room, typing or geo path may reach an FCM trigger. Today this holds structurally — the four `net.http_post` triggers are on `reach_events`, `messages`, `care_nudges` and `call_invites` only, and none on `presence` (verified). The rule is to keep it that way, and it is Signal's `ephemeral` Envelope flag: `if (!destinationPresent && !message.getEphemeral())` gates the push, so a typing indicator is dropped rather than queued or pushed when the recipient is offline.

## Invariants
- Online is not a value any client can write. It is set membership in an in-memory CRDT keyed to a live, RLS-authorized socket. Every failure mode — Android LMK, force-stop, crash, radio loss, battery death, netsplit, tenant suspension, JWT expiry — either removes the key or refuses the join, so every failure converges on OFFLINE. There is no code path that can make a user appear online, therefore no bug can.
- last_confirmed_at := greatest(existing, now()) where now() is the SERVER'S transaction timestamp and the client supplies no timestamp field at all. A replayed, delayed, reordered or forged anchor cannot move the last-seen watermark backwards, and cannot move it forwards past the server's own clock either. Both directions are closed.
- The anchor's cadence is enforced by a WHERE last_confirmed_at < now() - interval '240 seconds' predicate. A client anchoring in a tight loop updates zero rows and emits zero WAL. Write amplification is bounded by the server, not by the client behaving.
- No wall clock appears on either side of any freshness comparison, in either direction. 'Online' involves no comparison at all. 'Last seen' ships as a server-computed integer age; the client adds only monotonic elapsed time since the response arrived. This is mechanically checkable: inject a wall clock ±6 hours and every rendered output must be byte-identical.
- The observed online/zone state is a pure function of the CURRENT presence set, recomputed in full on every event — never a boolean mutated by a diff. Duplicated, reordered or spurious join/leave events (which Supabase documents Presence can emit on sync) cannot produce a wrong answer, because the answer does not depend on event history.
- Presence keys are '<user_id>:<session_id>' with a fresh session_id per channel join. A late leave from a superseded connection can only remove its own key. This is the stronger form of Signal's compare-and-swap on lease ownership: instead of guarding a mutable lease, there is no mutable shared state to corrupt.
- Every discretionary track() call passes through a token bucket of capacity 2 refilling 1 per 15 s, against a hard platform cap of 5 calls per client per 30 s on all plans. The cap cannot be exceeded regardless of navigation speed; the pending value is coalesced trailing-edge and always flushed, so the terminal state is always published.
- Ephemeral signals never enter the WAL, are never retried, and never trigger FCM. Typing, zone, room and coordinates exist only as broadcast frames with a 5 s lifespan and one attempt; if the recipient is not connected they are dropped by design. A stale typing indicator is a worse product than a missing one.
- Privacy is a predicate evaluated inside the Realtime server at channel join, on a single reciprocal boolean, and the durable read path returns a nullable AGE and never an absolute timestamp. A client that must not see presence never receives the bytes — there is no client-side filter that can be forgotten, and no timestamp on the wire to leak precision.
- The channel topic bounds the recipient set to 2 by construction (couple:<couple_id>). Fan-out is linear in users at every scale and cannot become quadratic, because no topic in this design is shared across couples. The quadratic fan-out that drove Discord's Manifold/relays/passive-sessions work structurally does not arise.
- Ordering of ephemeral events is decided by a per-session monotonic ordinal (seq), never by a timestamp. A STOP that overtakes a START is dropped at the receiver because seq <= lastSeenSeq; combined with the 15 s receiver expiry, a stuck typing indicator is impossible in both directions without any acknowledgement.

## Why this mirrors the top tier
**Signal (current design) — online as a property of an open socket.** `RedisMessageAvailabilityManager` defines presence as *"Clients are considered 'present' if they have an open WebSocket connection"*, held in-process, with displacement events carrying a serverId; its own javadoc says it *"cannot guarantee at-most-one behavior"* — best-effort by design. We take exactly this definition, and we get the liveness detection for free because Supabase Presence is Phoenix.Tracker and the BEAM's process monitors do it at process granularity (research §3, mechanism 2).

**Deliberate difference from Signal:** Signal owns its sockets, so it can run `pruneMissingPeers()` every 30 s and clear leases with the dead peer's own ID as a CAS token. We cannot observe socket lifecycle server-side *at all* — Deno Edge Functions are stateless and hold no websocket, and there is no Redis. So we take Supabase's 60 s socket timeout as a **given contract we measure, not a knob we tune**, and we state the resulting 47–72 s hard-kill latency as a product fact instead of pretending we control it. Signal's structural discipline — an 11-minute TTL as a crash backstop against a 30-second sweep as the detector — becomes ours as a **300 s durable anchor (backstop for last-seen) against the 60 s socket timeout (the actual detector)**. Two independently tuned knobs; the slow one is never the detector. Collapsing them into one number is what forces the choice between flapping and staleness.

**Signal — CAS on lease ownership.** `renew_presence.lua` and `clear_presence.lua` both guard on `redis.call("GET", presenceKey) == presenceUuid` before EXPIRE/DEL, so a late disconnect handler from an old connection cannot delete a newer connection's presence. **We go one step further and remove the need for CAS**: keying presence on `<user_id>:<session_id>` and deriving online as a pure fold over the current set means there is no mutable shared value to compare-and-swap. This is the "one mechanism instead of five patches" the brief asks for — it eliminates the reconnect-race, the duplicate-session, the reordered-diff and the spurious-sync bug classes simultaneously.

**Signal-Android — typing, adopted essentially verbatim.** `REFRESH_TYPING_TIMEOUT = 10s`, `PAUSE_TYPING_TIMEOUT = 3s`, `RECIPIENT_TYPING_TIMEOUT = 15s` (1.5× = exactly one missed refresh of tolerance), STARTED sent immediately with no leading debounce, and `TypingSendJob` with `maxAttempts(1)`, `setLifespan(5s)`, `setMemoryOnly(true)`. Critically, `TypingStatusRepository` **ignores the embedded sender timestamp entirely** and expires from a local timer at receipt — freshness measured against a clock you control, over an interval you measured locally. **Deliberate difference:** Signal serialises with a per-thread job queue (`"TYPING_" + threadId`) to stop a STOP overtaking a START; this app has no local job manager, so we substitute a per-session monotonic `seq` with receiver-side drop of `seq <= lastSeenSeq` — the same guarantee achieved with an integer instead of a queue.

**Signal — server-authoritative time with named provenance.** `TextSecure.proto` carries `client_timestamp = 5` and `server_timestamp = 10` as distinct wire fields, and `MessagesManager` does `.setClientTimestamp(clientTimestamp == 0 ? serverTimestamp : clientTimestamp).setServerTimestamp(serverTimestamp)` — the client's claim is preserved separately and never overwrites the authoritative value. **Deliberate improvement:** we don't ship a timestamp for freshness at all. We ship a server-computed *age*. Signal keeps `client_timestamp` because it must display the sender's intent; presence has no such need, so removing the second clock removes the naming problem along with the bug.

**Signal — ephemeral never wakes a device.** `MessageSender`: `if (!destinationPresent && !message.getEphemeral())` gates the push. Our equivalent rule — no presence/typing/zone path touches an FCM trigger — is currently satisfied structurally (the four `net.http_post` triggers are on `reach_events`, `messages`, `care_nudges`, `call_invites` only) and must stay that way.

**Slack — away is an activity state, not a connectivity state.** *"After 10 minutes with no activity, the user is automatically marked as away."* We adopt the 10-minute threshold and the split. Slack's other lesson — `presence_change` is not dispatched at all without an explicit `presence_sub`, and `presence_sub` has replace semantics ("all subscription requests require the entire subscription list each invocation") — we adopt in spirit: the observer's state is always the whole set, never an increment.

**Discord — jitter and non-1000 close codes.** The first heartbeat is delayed by `heartbeat_interval × random(0,1)` explicitly to avoid synchronized reconnect storms; a missing ACK is a *"zombied"* connection closed with a non-1000 code to signal RESUME intent. We adopt Full Jitter on channel rejoin (`random(0, min(10s, 250ms × 2^attempt))`) — and it is load-bearing, not polish, because Supabase enforces joins/sec as a hard quota and returns `too_many_joins`. Discord's `invisible` ("Invisible and shown as offline") is the model for server-side privacy suppression, and its `since` field — *"used only for display"*, never to decide liveness — is the model for how a client-supplied value may be treated.

**WhatsApp — reciprocity, server-enforced.** *"If you don't share your last seen, you can't see other contacts' last seen either."* Since Aug 2022 "who can see when I'm online" offers only Everyone or Same-as-last-seen — deliberately *not* fully independent. We collapse to one reciprocal boolean because it is the only version expressible as a single RLS predicate at the fan-out point, and because with a watcher set of one the free-rider dynamic is the entire dynamic.

**Where we deliberately differ from all of them: we build no fan-out containment at all.** Discord's Manifold (one cross-node message per node instead of thousands), relays at 15,000 sessions each, passive sessions (~90% suppression, ~3× capacity) and delta-instead-of-snapshot (`passive_update_v1` was 35.61% of gateway bytes for ~2% of dispatches) exist to solve quadratic fan-out — *"1,000 online users = 1M notifications; 100,000 users = 10 billion."* Slack needed Flannel (4M connections, 600K queries/sec) and an API-breaking change before presence was tractable. **Our watcher set is 1.** Building any of that would be solving a problem we do not have. Every one of those engineering efforts is deliberately declined, and the entire body of presence-scaling literature reduces, for a couples app, to: get the timing discipline right, keep presence out of Postgres, and pay for sockets.

**And the option worth naming: Signal ships no presence at all.** No online indicator, no last-seen — a product decision that deletes this whole subsystem. We reject it because presence is the emotional core of a long-distance-couple product, but the privacy toggle should make it trivially easy for a user to choose Signal's answer for themselves.

## Scale ceiling
Model, stated so it can be argued with: users = individuals, 2 per couple; **peak concurrency 8% of registered** (mobile social rule of thumb, INFERRED — instrument it before trusting it); billable messages = events × (recipients + 1), so a couple channel bills **2 per event** (1 send + 1 receive). Presence-domain event budget per user per 30-min session: 2 presence transitions + ~6 zone changes + ~8 typing events + ~10 room broadcasts ≈ 26 events ≈ **52 billable messages**. At 3 sessions/day → **~4,700 messages/user/month for the entire presence domain.** Today's equivalent is ~97,000 — a **~20× reduction** — plus ~60,000 PostgREST reads/user/month that go to roughly zero.

**1,000 users (~80 concurrent devices)**
- Connections: 80 of Free's 200, 80 of Pro's 500. Not binding.
- Presence ops: 80 × 8 ops/1800 s = 0.36/s, ×2 delivery = **0.7 presence msg/s against Free's 20/s cap — 28× headroom.**
- Whole presence domain: ~2.3 events/s × 2 = **4.6 msg/s against Free's 100/s.**
- Postgres: 80 × 1 anchor/300 s = **0.27 writes/s** on a narrow, unpublished table. Zero WAL fan-out, zero Realtime work, zero `apply_rls`.
- **Failure mode: none. There is no presence-shaped failure at this scale.** For contrast, today's design at this exact scale is ~24 presence writes/sec against a documented whole-project ceiling of 30 changes/sec with RLS — shared with seven other published tables. **The current app is already over its ceiling at 1,000 registered users.**

**10,000 users (~800 concurrent)**
- Connections: 800 > Pro's capped 500 → **spend cap must be disabled** to reach the 10,000 ceiling. This is the first thing that breaks, and it is a billing action, not an architecture change.
- Presence ops: 3.5/s × 2 = **7 presence msg/s against the 1,000/s Pro-no-cap presence cap — 140× headroom.**
- Whole presence domain: ~46 msg/s against the 2,500/s tenant ceiling — **~2%**.
- Postgres: 2.7 anchor writes/s. Micro/Small handles it without noticing. Durable last-seen reads ≈ 1/s.
- **Failure mode at the edge: none from presence.** The binding constraint is concurrent websockets, which is what you pay for regardless of how presence is implemented.

**100,000 users (~8,000 concurrent)**
- Connections: 8,000 of the **10,000 hard ceiling** on Pro-no-cap/Team. Team ($599) does **not** raise it. This is the platform wall and it is presence's wall too, because presence requires a live socket by definition.
- Presence ops: 35/s × 2 = **70 presence msg/s against 1,000/s — still 14× headroom.** Presence is not what breaks.
- Whole presence domain: **~460 msg/s of the 2,500/s tenant ceiling — ~18%.** The rest of the app must fit in the remaining 82%.
- **Channel joins are the sleeper and the real first failure.** 8,000 devices × ~6 foreground/background cycles/hour × 1 join = **13 joins/s** under this design — comfortably under 2,500/s. Under the *current* client behaviour (unconditional `disconnect()`+`connect()` on every resume, tearing down and rejoining 5–10 topics) the same load is **~107 joins/s steady-state**, and a correlated event — a regional network flap, a Supabase restart, a commute ending — produces a burst of tens of thousands within a second. `too_many_joins` is a refusal, and Supabase names *"rapid reconnection loops"* as a top cause of manual project suspension (`RealtimeDisabledForTenant`, support ticket to lift). **This is why the resume-debounce, the one-channel consolidation and the Full-Jitter rejoin are load-bearing parts of this design and not polish.**

**Behaviour when the ceiling is exceeded (>10,000 peak concurrent):** Supabase refuses connections with `too_many_connections`. Presence degrades as follows: every user who could not connect renders as **offline** — which is the correct and safe answer. There is no state in which the system claims someone is online who is not. The last-seen path keeps working because it is a plain PostgREST read that does not need the socket, so the product degrades to "WhatsApp with last-seen but no live dot" rather than to lying. **The failure mode is honest degradation, not incorrectness** — which is the direct consequence of invariant 1.

Escape hatch past 10,000: Enterprise quota, or self-host the Realtime cluster (Elixir/Phoenix, `MAX_CONNECTIONS=16384`/node) against managed Supabase Postgres. Note that Supabase publishes Broadcast benchmarks (250k concurrent, >800k msg/s) but **publishes no Presence benchmark at all** — that absence is itself a signal, and it is a reason to keep the presence payload minimal and the transition rate low even though the quota headroom looks enormous.

## Cost
All figures are the **marginal cost attributable to the presence domain**, on top of whatever the rest of the app costs. Overage rates: **$2.50 per 1M Realtime messages** beyond the plan's included allowance; **$10 per 1,000 peak concurrent connections** in whole 1,000-packages; egress $0.09/GB uncached.

**1,000 users (~80 concurrent)**
- Presence-domain messages: 1,000 × 4,700 = **4.7M/month**. Free includes 2M with **no overage — it fails closed**, so presence alone does not fit on Free. Pro includes 5M, so presence fits inside the allowance and its **marginal message cost is $0**; if the whole app is at ~18M/month, presence's proportional share of the $32.50 overage is **~$8.50/month**.
- Connections: 80, inside Pro's 500. **$0.**
- Postgres: 0.27 writes/s on a narrow unpublished table — no compute tier change. **$0.**
- Egress: 4.7M × ~200 B = 0.94 GB, inside Pro's 250 GB. **$0.**
- **Presence total: ~$0–9/month.**
- *What it replaces:* today's presence generates ~97M messages/month at this scale (1,000 × 97,000) = **$237.50/month in message overage alone**, plus ~60M PostgREST reads/month, plus a postgres_changes load that the platform physically cannot serve. So the fix is **~$230/month saved at 1,000 users**, and more importantly it is the difference between working and not working.

**10,000 users (~800 concurrent)**
- Messages: 10,000 × 4,700 = **47M/month** → 42M over the 5M included × $2.50/M = **$105/month**.
- Connections: 800 peak, 300 over Pro's 500 → 1 package = **$10/month** (and the spend cap must be off).
- Postgres: 2.7 anchor writes/s. Still Micro/Small; presence does not drive the compute tier. **$0 attributable.**
- Egress: 47M × 200 B = 9.4 GB, inside 250 GB. **$0.**
- **Presence total: ~$115/month.**
- *What it replaces:* ~970M messages/month = **$2,412/month** in overage, on an architecture that cannot run at all because 800 concurrent × 18 writes/min = 240 presence writes/sec against a 30–40/sec ceiling.

**100,000 users (~8,000 concurrent)**
- Messages: 100,000 × 4,700 = **470M/month** → 465M over × $2.50/M = **$1,163/month**.
- Connections: 8,000 peak, 7,500 over the 500 included → 8 packages = **$80/month**. *This line does not scale further — 10,000 is a refusal, not a bill.*
- Egress: 470M × 200 B ≈ 94 GB. Inside the 250 GB Pro/Team allowance if media does not already consume it; at the margin **~$8/month** at $0.09/GB uncached.
- Postgres: 27 anchor writes/s on a narrow unpublished table — trivially inside a Large instance the app needs anyway for other reasons. **$0 attributable.**
- **Presence total: ~$1,250/month.**

**The shape of the curve, and the two levers.** Presence cost is ~93% Realtime messages at every scale past 1,000 users, and it is superlinear in *engagement*, not in users. The two levers that actually move it:

1. **Cut events, not users.** The 26-events-per-session budget is dominated by typing (8) and room broadcasts (10). Coalescing room broadcasts harder — say a 3 s minimum interval instead of 1 s — plausibly halves that line for a barely perceptible loss, taking 100k-scale presence from ~$1,163 to ~$800/month.
2. **Do not deliver the sender's own echo.** Supabase bills 1 send + 1 message per receiving client. Broadcast `self: false` (and client-side filtering of your own presence key, which the fold already does) means a couple channel bills **2 per event, not 3** — this is already assumed in the numbers above, and it is a flat 33% saving versus the naive configuration the app uses today.

**The line item that disappears entirely:** at 10,000 users today's design does ~7.8M PostgREST reads/day from the 15 s liveness poll alone (800 concurrent × 4/min × 1,440 min), against a Nano's 250 baseline IOPS. That is not a bill — it is an outage. The new design has no presence poll at all.

## Migration
**Nothing here is a rewrite.** Each stage ships alone, is independently revertible in one commit or one SQL statement, and leaves the app working. The order is deliberate: the new mechanism is built and *observed* before anything depends on it, and the old one is deleted last.

**Stage 0 — Make the couple channel private and authorized. (No behaviour change.)**
Create `couple:<couple_id>` as a `private: true` channel with the RLS policy on `realtime.messages` gating `topic` to the caller's couple via a `SECURITY DEFINER` helper. Nothing subscribes yet. *Standalone value:* this is the fix for the existing hole where `screen_presence:<coupleId>`, `call:<coupleId>` and `mood_lamp:none` are unauthenticated topics that anyone holding a couple UUID (visible in every `couple_media` URL path) can watch. **Ship this first regardless of the rest of the plan.**

**Stage 1 — Presence tracking in shadow mode.**
Clients `track()` on the new channel and compute `online_new` from the presence fold, but the UI still renders the old `isTrulyOnline`. Log a disagreement counter: `(old, new, cause)` on every divergence. **Zero user-visible change, and it produces the evidence the last five fixes lacked.** Run for one release cycle on the two real users plus the load harness. This is where the away state, the token bucket and the flap grace also land.

**Stage 2 — Flip the read.**
UI reads the presence fold. Delete the `Timer.periodic(15 s)` poll and the 800 ms refetch debounce from `PartnerPresenceNotifier` (presence_service.dart:436, 469-474) — that alone removes 4 unconditional SELECTs/min/user. Still writing the old table; harmless. Revert = one boolean.

**Stage 3 — Typing to broadcast-only.**
Delete `setTyping` and `setTypingInChat` from the write path. Adopt 10 s / 3 s / 15 s plus the per-session `seq`. One file (`chat_screen.dart`), one screen, independently revertible.

**Stage 4 — Delete `setChatLastRead`.**
"Actively in chat" becomes `zone == chat` from the presence payload. The read watermark already lives correctly in `chat_receipts` with a `greatest()` server-side RPC. **This removes 12 writes/min per open chat**, the single largest steady-state cost in the app. Gate with the `n_tup_upd` probe from the verification section.

**Stage 5 — Split location out of the hot row.**
New narrow `user_location` (label + mode, written on label *change*), and precise coordinates onto the `geo` broadcast. Stop writing `latitude`/`longitude`/`location_accuracy`/`location_updated_at` into `presence`. Behind the existing location settings, so it is independently shippable and independently reversible. *Also removes the 15 s SELECT-then-upsert-then-geocode loop.*

**Stage 6 — Introduce `presence_session` + the two RPCs, dual-write.**
Write both the new session row (~2 transitions + 6 anchors per session) and the old presence row. Read `last_seen_age_seconds` from `presence_last_seen()` behind a flag and compare against the old `lastSeenText` string; log divergence.

**Stage 7 — Flip last-seen to the new RPC. Delete `ServerClock` entirely.**
`server_clock.dart` and every `ServerClock.observe` call site go. The upsert no longer needs `.select('updated_at')`.

**Stage 8 — Stop writing the old row.**
`setOnline` and its 30 s foreground heartbeat (main.dart:195-204) are replaced by the 300 s anchor. At this point `public.presence` receives zero writes.

**Stage 9 — Remove `public.presence` from the publication and drop `replica identity full`.**
```
alter publication supabase_realtime drop table public.presence;
alter table public.presence replica identity default;
```
**Two statements, and this is where the entire WAL/wal2json/apply_rls cost disappears.** It is also the test of whether Stages 3–8 were done properly: if any write path remains, `n_tup_upd` on the table will be non-zero and you find out before you drop anything. Reversible in one statement.

**Stage 10 — Drop the columns, then the table.**
Only after a full release cycle at Stage 9 with the disagreement counter at zero.

**What makes this not a big bang:** at every stage the app is shippable, the old system is intact until Stage 8, and the two changes that deliver essentially all of the scale win (Stage 4, Stage 9) are each a handful of lines. If the plan is abandoned after Stage 4 you have still removed ~two-thirds of the presence write volume; if it is abandoned after Stage 0 you have still closed the room-by-room surveillance hole.

**Sequencing constraint worth naming:** Stage 1 must not ship in the same release as Stage 2. The whole point of shadow mode is a release cycle of divergence data on real devices with real lifecycle events. Shipping them together reproduces exactly the pattern that produced five failed fixes.

## Verification
**Why two phones on one wifi is worthless evidence, stated precisely:** at N=2 the `apply_rls` subscriber loop has two entries, the WAL poller is idle, both clocks agree, both processes exit cleanly through `onPause`, and there is exactly one network path with no handoff. Every failure mode in this domain lives outside that point. The design is therefore built so that each failure class is checkable at a layer that does not need a phone at all.

**1. Pure-function tests — no network, no clock, no device.**
The observer's derivation is `online(Set<PresenceKey>, UserId) -> bool` and `zone(Set<PresenceKey>, UserId)`. Property test: generate random interleavings of `join(u,s1)`, `leave(u,s1)`, `join(u,s2)`, `leave(u,s2)` **including reordering and arbitrary duplication**, and assert the output depends only on the final set. This is the test that catches the reconnect-race, the duplicate-session bug and Supabase's documented spurious sync join/leave — all three at once, in milliseconds, with zero devices. If this test can fail, the fold has been replaced by a mutated boolean somewhere.

**2. Clock-hostility test — the one that replaces "were the phones NTP-synced".**
Inject a fake wall clock through a single seam and run the full presence render under: +3 min, −3 min, a 6-hour jump mid-session, a timezone change, a DST boundary. **Assert every rendered output is byte-identical across all of them.** This is only possible to pass because the design permits nothing but monotonic elapsed time and server-computed ages. Back it with a CI grep that fails the build on `DateTime.now()` anywhere in the presence package, with the sole exception of formatting an absolute date older than 7 days.

**3. SQL invariant tests — no client at all.**
Run inside a transaction, in the same `do $$ ... raise exception ... $$` style already used in `presence_server_time.sql:62-80`:
- Call `presence_mark` with a replayed old session, then a current one, then the old one again. Assert `last_confirmed_at` **never decreases**. That is `greatest(existing, now())` proven, not asserted.
- Call `presence_anchor()` 100 times in a loop. Assert **exactly 1 row updated**, then 0 for the next 99 — the predicate rate limit proven, meaning a hostile or buggy client cannot amplify write volume.
- Assert both functions accept **no timestamp parameter at all**. A signature test is a stronger guarantee than a code review.

**4. One process, N simulated clients — the load and semantics harness.**
A Dart or Deno harness opening K websockets to the real project with K distinct JWTs, driving the state machine. Zero phones. Scenarios that matter:
- **(a) The hard kill, deterministically.** Destroy a client's socket **without a close frame** (`socket.destroy()` / abort, not `close()`), and measure wall-clock time until the peer observes `leave`. This is the exact case two-phone testing cannot produce on demand, and it is the case that has been broken. **Assert < 90 s and record the actual number.** This doubles as a canary: the 60 s figure comes from Phoenix's default holding because Supabase's `endpoint.ex` sets no `:timeout` — an inference from source. If Supabase changes it, this test tells you before users do.
- **(b) Rate-limit proof.** Drive zone changes as fast as the app can produce them and assert (i) no presence call is ever rejected, and (ii) the final resting zone is published within 15 s. Proves the token bucket against `CLIENT_PRESENCE_MAX_CALLS=5 / 30 s`.
- **(c) Join storm.** 200 clients joining within one second, then measure observed `too_many_joins`. Establishes the actual join-rate headroom, which is the constraint that trips first at scale.
- **(d) Privacy.** Flip `share_presence` false and assert the channel join is **refused server-side** and no presence bytes reach the peer. Then assert the toggle-forces-rejoin path makes it take effect immediately rather than at JWT expiry.

**5. Real hard-kill and Doze on one machine, scripted.**
`adb shell am force-stop com.miles.miles` is a genuine LMK-equivalent kill and is scriptable; `adb shell cmd deviceidle force-idle` reproduces Doze; `adb shell svc data disable` / emulator network toggle reproduces radio loss; `tc netem` on an emulator reproduces the tunnel. Pair one real device against a harness peer and you get deterministic, repeatable measurement of every mobile-lifecycle case — on one machine, one network.

**6. The regression gate for the whole migration — one query.**
Before and after a 10-minute session of typing, navigating, chatting and moving:
```
select relname, n_tup_upd from pg_stat_user_tables
 where relname in ('presence','presence_session','user_location');
```
`presence.n_tup_upd` delta must be **0** after Stage 8. `presence_session.n_tup_upd` must be ≈ 8. If a code path still writes the hot row, this finds it in one command — and it finds it *before* Stage 9 drops the publication.

**7. Field telemetry — the thing that would have caught "passed then failed in production".**
Ship two counters, batched, cheap:
- **Flap rate:** count of `offline → online` transitions observed within 12 s of each other, as a fraction of all transitions. This single number tells you whether presence is actually working on real networks. A threshold of ~1% is the alarm; today's unconditional disconnect-on-resume would put it far above that.
- **Disagreement counter** (Stages 1 and 6 only): old-mechanism verdict vs new, with cause. This is the evidence that lets you flip a stage with confidence instead of hope.

**What none of this proves:** whether Supabase's presence CRDT behaves correctly under a genuine cluster netsplit (`permdown_period` = 20 min). That is unobservable from outside and unfixable from inside; the mitigation is that the failure direction is "presence lingers", and the 12 s flap grace plus the durable last-seen path mean the UI degrades to stale-but-honest rather than wrong. **Flagged gap, not a solved problem.**

## Rejected alternatives
**1. Keep the Postgres heartbeat table, just slow the cadence (30 s → 120 s).** Rejected — it does not remove the class. `apply_rls` costs O(*all* subscribers to the table) filter evaluations per row change, on a **single-threaded** poller, and the documented ceiling is 30 changes/sec with RLS at 500 clients and **40/sec even on a 16XL**. A 370× compute increase buys 1.3×. There is no amount of money that fixes it. And slowing the cadence directly degrades the product: offline detection latency *is* the interval.

**2. `UNLOGGED` presence table.** Rejected — it skips the WAL, which means Realtime cannot see it at all, which means you need a poll to read it, which reintroduces the 4 SELECTs/min/user you were trying to delete. It still generates MVCC dead tuples on every UPDATE, and on Supabase it is truncated on crash recovery. Arguably correct semantics for presence, wrong on every practical axis.

**3. A `pg_cron` sweeper doing `UPDATE ... WHERE last_seen < now() - interval '45 seconds'`.** This is the DIY version of the server-side sweeper Supabase will not give us. Rejected — it needs sub-minute cadence (paid tier), it **writes N rows per tick, which is more WAL than the heartbeats it is policing**, Supabase's own guidance is ≤8 concurrent jobs each ≤10 minutes, `cron.job_run_details` has no documented retention and grows forever on a 500 MB database, and it does nothing at all for the read path.

**4. Supabase Presence for typing indicators.** Rejected as **impossible, not merely unwise**: 5 presence calls per client per 30 seconds, on every plan including Enterprise. A 3-second pause debounce alone exceeds it. Supabase's own docs say presence is for *"slow-changing state such as online/offline status"* and warn that calling `track()` rapidly *"will flood the channel and cause performance problems"*. Typing goes on Broadcast; there was never a choice.

**5. An application-level heartbeat broadcast (ping every 15–20 s) to speed hard-kill detection.** Would cut the worst case from ~60 s to ~40 s. Costs 3–4 broadcasts/min/user × 2 recipients ≈ **350,000 messages/user/month — roughly 75× the entire rest of the presence budget** — to improve a number no user perceives. Rejected on arithmetic. It would also reintroduce client-timer-driven liveness, which is the mechanism we are removing.

**6. A foreground service or `WorkManager` to keep the socket alive while backgrounded.** Rejected — backgrounded *should* read as offline, because that is what a user means by "online". It destroys battery, and on a deliberately disguised private app a persistent notification defeats the disguise outright. The research is explicit: *"Do not add a foreground service to keep presence alive — that's the wrong trade for a private app and it will destroy battery."*

**7. Redis / Upstash for Signal-style leases (`SETEX` + CAS renew/clear + peer sweep).** This is the theoretically correct answer and it is what Signal actually built. Rejected here because (a) Supabase Realtime *already is* an ephemeral in-memory store with the same semantics, (b) we cannot observe socket connect/disconnect server-side at all, so we could not write the leases at the moments that make the pattern work, and (c) it adds a paid component plus an Edge Function hop with a 2 s CPU cap on the hot path. Revisit only if we ever self-host Realtime — at which point we would own the socket lifecycle and the whole pattern becomes available.

**8. Broadcast-from-database (`realtime.broadcast_changes`) for presence.** Correct for durable events — messages, receipts, reach — and it should be adopted there. Wrong for presence: it still routes every heartbeat through the WAL, benchmarks at **~10,000 msg/s versus 800,000 for client broadcast**, and critically it gives you no leave-on-socket-death. It solves fan-out cost, not the liveness problem.

**9. Keeping "where they are in the app" purely on Broadcast with a join-time state request.** Rejected because it makes reading current state depend on the *other client answering* — a two-clients-online dependency for a state read, which violates the brief's constraint 2. Presence sync replays the zone from the CRDT for free. The fine-grained room stays on broadcast precisely because its absence degrades gracefully to the zone.

**10. Signal's answer: ship no presence at all.** Genuinely the strongest option on privacy, cost and complexity — Signal has no online indicator and no last-seen, and adopting it deletes this entire document and the whole class of bugs with it. Rejected because presence is the emotional core of a long-distance-couple product; it is the feature, not a decoration on it. But it is worth naming that the cheapest presence is the one you do not build, and it is the reason the privacy toggle should make choosing Signal's answer trivially easy for any individual user.

## Open decisions
**1. Ship the `away` state, or just online/offline?**
Slack and Discord both have it; Slack's rule is 10 minutes of no activity. It costs one enum value in the presence payload and one interaction timer, and it changes the meaning of the green dot from "the app is open" to "the person is there". **Recommendation: yes, ship it in Stage 1.** It is nearly free and it is the honest answer to "the phone is on the kitchen table with the app open", which in a couples product is a direct source of "she was online and didn't reply".

**2. Reciprocity: one toggle or WhatsApp's split?**
WhatsApp deliberately does *not* make "online" and "last seen" independent — since Aug 2022 the online setting offers only Everyone or Same-as-last-seen. **Recommendation: one reciprocal `share_presence` boolean covering online + last-seen + typing.** It is the only version expressible as a single RLS predicate at the fan-out point, which is what makes it enforceable rather than advisory, and with a watcher set of one the free-rider dynamic the reciprocity rule exists to defeat is the entire dynamic.

**3. Default for `share_zone` ("where they are in the app").**
**Recommendation: OFF by default, opt-in, reciprocal.** This is the creepiest signal in the system and the one most likely to be regretted. Today it is on for everyone *and* rides an unauthenticated topic — a leaked couple UUID (which appears as the first path segment of every `couple_media` URL) currently yields a live room-by-room feed of a partner's movement through an intimate app. This is the decision with the highest regret asymmetry in the whole design.

**4. What is the stated product contract for offline latency, and do we surface it?**
The design gives **≤2 s on a clean background** (the common case) and **47–72 s on a hard kill** (bounded by Supabase's 60 s socket timeout, which we do not control). **Recommendation: adopt those numbers internally, and coarsen the last-seen display to 1-minute granularity** — never "last seen 12 seconds ago". Minute granularity makes the platform's 60 s TTL invisible to users and removes an entire category of "it says she's online but she isn't" reports at zero engineering cost.

**5. One channel for the whole couple, or a presence-specific topic?**
**Recommendation: one channel, `couple:<id>`.** Channel joins/sec is the quota that trips first at scale, and the app currently rejoins 5–10 topics on every app resume including every camera and photo-picker return. But this decision crosses into the chat and calling domains and needs a single owner to land. **Flag this as the top cross-domain decision** — presence can be built on `couple:<id>` unilaterally, but the join-rate win only materialises when the other domains converge on it too.

**6. Multi-device.**
The presence key is already `<user_id>:<session_id>`, so multi-device works with no change and two devices correctly render as one online user. But `profiles.fcm_token` is a single column, so signing in on a second device silently steals push from the first. **Recommendation: keep the presence key multi-device-ready (it is free), and treat the per-device token table as a separate push-domain decision.** Also accept that `presence_session` keyed on `user_id` means a second device overwrites `online_since` — `greatest()` protects `last_confirmed_at`, so last-seen stays correct, which is the part that matters.

**7. Instrument concurrency before trusting any of the cost numbers.**
Every figure here rests on "peak concurrency = 8% of registered users", which is a rule of thumb, not a measurement. For a couples app where both partners tend to be active in the same evening window, the real figure could plausibly be 2× that — which moves the 10,000-user line from 800 to 1,600 concurrent and roughly doubles the connection bill. **Recommendation: ship the connected-clients metric read from Supabase's Realtime reports (available on all plans) before the 1,000-user mark, and re-derive the curve from real data.** This is the single cheapest way to stop the cost model being fiction.

**8. Do we keep `presence.current_screen` / the old columns as a read-only fallback after Stage 9?**
**Recommendation: no.** Keeping them creates a second source of truth for a fact that now has exactly one, and dual sources of truth for presence is how this system got here. Drop them in Stage 10 as planned.
