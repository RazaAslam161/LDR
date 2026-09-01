# Realtime transport layer (Supabase Realtime: channel topology, transport selection, channel authorization, reconnect/resubscribe, gap detection, caught-up semantics)

## Current design
## What exists today, precisely

**One socket, many channels — the one thing that is right.** `SupabaseService.client` (E:\LDR\mobile\lib\core\supabase_service.dart) is a singleton, so every topic multiplexes onto one websocket. Billing and quota are per socket, so this is already correct and must be preserved.

**Everything above the socket is wrong in four specific ways.**

### 1. Channel count is a function of feature count, not tenant count
Per inventory/realtime.md: 5 always-on channels per paired user (`presence:<coupleId>`, `profile-sync:<coupleId>`, `reach_events:<coupleId>` on postgres_changes; `call:<coupleId>`, `screen_presence:<coupleId>` on broadcast), rising to a peak observed 10 (Chat tab + a pushed game). 29 `.channel(` call sites, 16 `onPostgresChanges` (verified: `grep -rn "\.channel(" mobile/lib | wc -l` → 29; `onPostgresChanges` → 16). Two mounted capsule screens create two channels on the same topic because Supabase never dedupes by topic — `chat_broadcast_service.dart` exists solely to work around that.

### 2. postgres_changes is structurally over its ceiling already
`realtime.apply_rls` loads `array_agg(sub) FROM realtime.subscription sub WHERE sub.entity = entity_` — **every subscriber to that table project-wide** — and evaluates the `couple_id=eq.X` filter *inside* the loop (source-verified, research/supabase.md §1). The filter does not shrink the loop. Documented throughput: 30 changes/s with RLS at 500 clients, 40/s even on a 16XL (~370× the price for 1.3× the throughput), 0.1/s at 100k clients.

`public.presence` takes ~18 writes/user/minute during an open chat (30 s heartbeat + 5 s `chat_last_read` + 15 s location + typing start/stop + every navigation), all to one row, with REPLICA IDENTITY FULL across ~28 tables. Demand at N concurrently-chatting users ≈ 0.3N changes/s. **The supply is 30/s. The break point is ~100 concurrently-active users, and the published curve gets worse as clients are added (1,500 clients → 10/s; 3,000 → 5/s), so the gap widens quadratically.** This is not a future problem; it is a present one that two test phones cannot reveal because two clients is the best case for the loop.

### 3. Every channel is a public room keyed by a public UUID
Verified: `grep -rn "private: true\|\.track(\|setAuth" mobile/lib` returns **nothing**, and `grep -rl "realtime.messages\|broadcast_changes\|realtime.send" supabase/` returns **nothing**. Zero private channels, zero Presence, zero RLS on `realtime.messages`. So `call:<coupleId>` carries SDP and ICE candidates on a topic anyone can join by guessing a UUID; `capsule_proximity:<coupleId>` broadcasts raw GPS every 4 s on the same footing; `mood_lamp:none` is a **global cross-tenant topic** whenever couple is null. The couple UUID is not secret — inventory/realtime.md:123 records that it is the first path segment of every `couple_media` URL.

### 4. The reconnect storm is manufactured by the client, on purpose, on every resume
`app_shell.dart:70-79` calls `realtime.disconnect()` then `realtime.connect()` **unconditionally** on every `AppLifecycleState.resumed` — including returns from the camera and photo picker, which the app itself documents as constant. `onOpen` then ticks `realtimeResumed`, which synchronously fires every listener. Verified: 6 hand-rolled `realtimeResumed.addListener` sites outside the canonical `ManagedSubscription` (presence_service.dart:407, partner_here_badge.dart:44, chat_screen.dart:312, touch_trace_canvas.dart:84, cycle_screen.dart:59, app_shell.dart:57). Two are known-broken (partner_here_badge.dart:59 does not await `removeChannel`; touch_trace_canvas.dart:89 uses `unsubscribe()` then immediate re-`channel()`) — precisely the duplicate-topic "joined but dead" race that `realtime_service.dart:76-95` documents as fixed.

**Cost per resume: 1 close + 1 open + N phx_leave + N phx_join, N = 5–10.** And the backoff underneath has no jitter. Verified in `C:\Users\razaa\AppData\Local\Pub\Cache\hosted\pub.dev\realtime_client-2.8.0\lib\src\retry_timer.dart`:
```dart
final delay = firstDelay << shiftAmount;   // 1000 << (tries-1)
return delay > maxDelay ? maxDelay : delay; // capped 10_000
```
Deterministic 1s/2s/4s/8s/10s. No `RealtimeClientOptions` is passed at `Supabase.initialize` (verified: zero matches in mobile/lib), so this default stands. Every device that dropped at the same instant retries on the same tick — the correlated-retry case AWS Full Jitter exists for, hitting a quota that **refuses** (`too_many_joins`) rather than queues. Supabase names reconnect loops as a top cause of manual project suspension (`RealtimeDisabledForTenant`, support ticket to lift).

### 5. A silent authorization hole on cold start
`supabase-2.13.0/lib/src/supabase_client.dart:375-394` does forward `tokenRefreshed`/`signedIn`/`initialSession` to `realtime.setAuth` — so the manual-setAuth advice in research/mobile.md is stale for this version. **But** it catches `FormatException: InvalidJWTToken` and silently swallows it, with the comment "on app launch after the app has been closed for a while." Because Realtime caches the authorization verdict for the connection lifetime, a channel joined in that window is silently unauthorized until the next reconnect. Today that is invisible because no channel is private; the moment they are, it becomes the dominant cold-start failure.

### 6. The cursor is not safe
`messages.seq` is `nextval('public.messages_seq_seq')` — a **project-global** sequence (E:\LDR\supabase\receipts_v2.sql:28-31). Two consequences: (a) a couple's positions are sparse, so arithmetic gap detection is impossible — the client can ask "give me > cursor" but can never know it *missed* something; (b) `nextval` is assigned at INSERT, visibility at COMMIT, so two partners sending simultaneously can commit out of order — the client fetches `>104`, sees 105, advances to 105, and **104 is lost permanently**. This is delivery.md's "A CURSOR MUST NEVER BE PUBLISHED PAST AN UNCOMMITTED WRITE" (Synapse's rule). It is silent, rare, and unreachable on two phones unless both users tap send within the same few milliseconds.

**Net: the transport is used as an expensive doorbell for a query, with no authorization, no gap detection, and a client that maximises join rate per user-minute.**

## Target architecture
## The one mechanism

**The transport carries positions, never state. Every socket event is a cursor advertisement; the durable log is the only source of truth.** Under this rule a dropped, duplicated, reordered, or forged broadcast is a *latency* bug, not a correctness bug — which is what makes it safe to run over at-most-once unacknowledged PubSub, and what makes every quota breach degrade latency instead of losing data.

---

## A. Channel topology — 2 always-on + 1 conditional

| Topic | Lifetime | Private | Carries |
|---|---|---|---|
| `couple:{couple_id}` | while paired & signed in | yes | `stream` doorbell (DB-originated), Presence track/untrack, `typing`, `screen` (client, rate-capped) |
| `device:{user_id}:{device_id}` | while signed in | yes | call ring targeted at one device, session revocation, forced-resync command |
| `rt:{couple_id}:{session_id}` | only while an interactive surface is open | yes | high-frequency client broadcast: gestures, game state, player position, WebRTC signalling |

`session_id` is a random UUID minted by the initiator and exchanged over `couple:`, so the high-rate topic is **not derivable from the couple UUID** even by a member.

**Why 2, not 27.** The count is now a function of the tenant boundary, not the feature list. Two channels means two subscription lifecycles in the entire app, owned by one component; features register *handlers* on a shared channel and never touch `.channel()`. This deletes the 6 hand-rolled resubscribe copies and both known races structurally — there is no channel for `partner_here_badge` or `touch_trace_canvas` to mis-manage. It also removes the duplicate-topic problem that `chat_broadcast_service.dart` exists to work around.

**Why not 1.** `couple:` is readable by 2 users; `device:` by exactly 1. Different RLS predicates require different topics. Per-device (not per-user) from day one, because the topic name is embedded in the RLS policy and widening it later is a migration under load.

---

## B. Transport selection — a decision procedure, not a feature table

1. **Must it survive the recipient being offline?**
   → **Yes**: it is a durable row + a stream position. The socket carries only `{stream, pos}` via **broadcast-from-database**. Chat, reach, receipts, call invites, capsules, the entire Closer set.
   → No: continue.
2. **Is it a property of holding a live connection?**
   → **Yes**: **Presence**. Online/away only. Bounded by 5 `track()` calls per client per 30 s — that cap makes anything faster impossible, so nothing else is eligible.
   → No: **client Broadcast**, on `couple:` if low-rate (typing, screen), on `rt:` if high-rate.

**Nothing is on postgres_changes. The `supabase_realtime` publication ends with zero public tables.** Source-verified consequence (`replication_poller.ex`): with an empty publication the `postgres_cdc_rls` poller *refuses to create a replication slot at all* — the 100 ms poll and the wal2json decode leave your database entirely. That is the whole class of bug removed by one mechanism, not five patches.

---

## C. The couple stream — a gap-free, commit-ordered cursor

Two new tables.

**`couple_cursor`** — `couple_id uuid primary key`, `next_pos bigint not null default 0`. `fillfactor=70` so the increment is a HOT update.

**`couple_stream`** — `couple_id uuid`, `pos bigint`, `stream text` ('chat' | 'reach' | 'receipt' | 'closer' | 'call' | …), `entity_id uuid`, `op text` ('insert' | 'update' | 'delete'), `created_at timestamptz default now()` *(display only, never compared)*. PK `(couple_id, pos)`.

**Position allocation.** Every append does, **inside the same transaction as the entity write**:
```
UPDATE couple_cursor SET next_pos = next_pos + 1
 WHERE couple_id = $1 RETURNING next_pos
```
The row lock serialises appends per couple. Therefore:
- positions are **dense** — a rolled-back transaction releases its position rather than burning it, unlike `nextval`;
- positions become **visible in position order**, because a second appender blocks until the first commits or aborts.

Serialisation is per couple, with exactly 2 writers appending at human speed, so this costs nothing globally. It would be unacceptable at 2,000 writers per tenant; it is free at 2.

**Tombstones live in the stream** (`op='delete'`), so deletes are expressible in the cursor and rows do not resurrect on reinstall — the gap research/mobile.md flags against the existing `deleteForEveryone` RPC.

**Extra write cost, stated honestly:** 2 extra writes (one stream insert, one cursor update) per durable event. Durable events are human-rate (~25/user/day), so at 10k users that is ~3 writes/sec project-wide. Trivial, and it buys the only gap-free cursor obtainable on this platform.

---

## D. The doorbell

**One** AFTER INSERT trigger, on `couple_stream` only, calling `realtime.send(payload, 'stream', 'couple:'||couple_id, private => true)`.

Payload: `{stream, pos}`, plus **optionally** the entity row inline. The inline copy is applied *only* when `pos == local_cursor + 1`; on any gap it is discarded and the client fetches. So inline payload is a pure latency optimisation that can never become the only path to data — and message plaintext stops travelling on `mood_burst:<coupleId>`, an unauthenticated topic, which it does today.

Hanging the trigger off `couple_stream` rather than off each entity table gives three properties for free:
- one trigger to review instead of ~28;
- `realtime.broadcast_changes`/`realtime.send` inserts into `realtime.messages` **within the transaction**, so Realtime reads it via the WAL only after commit — a position can never be advertised before it is readable, and a rolled-back append advertises nothing;
- `realtime.send` catches its own exceptions and reports via `pg_notify` instead of raising (source-verified), so a Realtime failure can never roll back the user's write.

---

## E. Authorization

Every topic is `config: {private: true}`, gated by RLS on `realtime.messages`. Documented: the verdict is computed once at join (insert → read → rollback under the user's JWT) and **cached for the connection lifetime** — so authorization cost is O(joins), bounded by a quota you control, instead of O(subscribers × row changes), bounded by nothing.

Policy shape (prose):
- **read** (`extension = 'broadcast'` and `'presence'`): `realtime.topic()` equals `'couple:' || (select public.current_user_couple_id())`, or `'device:' || (select auth.uid()) || ':%'`, or matches `'rt:' || (select public.current_user_couple_id()) || ':%'`. `TO authenticated`.
- **write**: same predicate **minus** the `stream` event on `couple:` — the doorbell is DB-originated only, so a client cannot forge a position advertisement.
- **presence read**: additionally requires the *viewer* to have `share_last_seen = true`, giving WhatsApp's reciprocity rule server-side (research/presence.md: privacy is enforced at the fan-out point, never by the receiving client).

**Mandatory fix, applies to the join path and to every existing REST policy:** `current_user_couple_id()` is called unwrapped in every policy in the repo (verified across breath_events.sql, messages.sql, capsules.sql, reach_events.sql, intimacy_*.sql, 20260627_call_invites.sql, hardening_2026_08.sql). Wrap as `(select public.current_user_couple_id())` so Postgres treats it as an InitPlan evaluated once per statement. Documented deltas: 179 ms → 9 ms, and 178,000 ms → 12 ms on a complex policy; `TO authenticated` 170 ms → <0.1 ms. This matters more than it looks: Realtime's authorization pool defaults to **`DB_POOL_SIZE=5`** — five connections gate every private-channel join for the entire project, so join-time RLS latency is the binding constraint on exactly the reconnect burst you most need to survive.

---

## F. Reconnect, resubscribe, gap detection, caught-up

**Delete the forced disconnect.** `app_shell.dart:70-79` goes away. Resume is not evidence the socket is dead. Replace with a **liveness probe over HTTP**:

`sync_head(couple_id)` RPC → `{head_pos, server_now}`.

State machine on the transport (one component, one instance):

```
DISCONNECTED ──connect()──► CONNECTING ──socket open──► JOINING
     ▲                          │                          │
     │                    fail (Full Jitter backoff)        │ all channels joined
     │                          ▼                          ▼
     └──────────────────── DISCONNECTED              RECONCILING
                                                          │ head_pos fetched, gap drained
                                                          ▼
                                                       LIVE  ──probe fails──► DISCONNECTED
```

Rules:
1. **On resume**: fire `sync_head` first. If it returns and `head_pos == local_cursor` and the socket reports connected, do nothing at all — **zero joins for the common resume**, which today costs 10 leaves + 10 joins. If `head_pos > local_cursor`, drain the gap over HTTP *and* verify a doorbell arrives; if no doorbell arrives within the probe window, the socket is silently dead (the documented Android-doze failure: throttled heartbeats, socket drops, "your application then stops receiving events without any explicit error message") → replace it.
2. **Backoff = AWS Full Jitter**, `random(0, min(30_000, 1000 * 2^attempt))`, injected via `RealtimeClientOptions.reconnectAfterMs` at `Supabase.initialize` — a parameter this app currently does not pass at all. Documented effect: Full Jitter cuts total calls by more than half vs un-jittered under 100 contending clients.
3. **Jitter the join too**, `random(0, 500) ms` per channel after socket open. The joins/sec quota is what a synchronised reconnect saturates, and it refuses rather than queues.
4. **Backoff resets on a successful `sync_head`, never on a connectivity event.** `connectivity_plus`' own README: connectivity is not a guarantee of reachability. Resetting on connectivity means every device leaving the same tunnel resets to attempt-0 on the same tick.
5. **Singleflight the catch-up**, keyed `(couple_id, stream)`. `onResume` + connectivity change + socket `onOpen` fire within ~200 ms and would otherwise produce three identical fetches.
6. **Gate joins on token freshness.** Do not join any channel until `session.expiresAt`, measured against the existing `ServerClock` offset (E:\LDR\mobile\lib\core\services\server_clock.dart — already correctly designed), exceeds the join timeout. Because the verdict is cached for the connection lifetime, joining with a stale token yields a channel that is silently unauthorized until the next reconnect — the worst possible failure shape, and the exact window the SDK's swallowed `InvalidJWTToken` opens on cold start.

**Gap detection — three decidable branches, no "probably fine".** On `{stream, pos}`:
- `pos == local_cursor + 1` → apply (inline payload if present), advance cursor **after the local apply commits**.
- `pos <= local_cursor` → already applied; discard idempotently.
- `pos > local_cursor + 1` → hole. Fetch `couple_stream WHERE couple_id=$1 AND pos > local_cursor ORDER BY pos LIMIT 500`, joined to entity tables, paging until a short page.

**Caught-up is decidable locally with no clock and no round trip:** `local_cursor == head_pos`. The UI shows a syncing affordance only while `head_pos > local_cursor`, never a full-screen spinner, because the local data is already rendered.

**Bailout:** if `local_cursor < min(pos)` retained, `sync_head` returns `resync_required` and the client re-bootstraps that stream. Telegram's `differenceTooLong`; PowerSync's checksum-mismatch path. Retention is compacted by `pg_cron` gated on `min(both partners' cursors)` — never a fixed age — with a hard 90-day cap past which the lagging partner is forced to resync.

---

## G. Client-side rate limiting, in the transport, not in each feature

`TENANT_MAX_BYTES_PER_SECOND = 100_000` — 100 KB/s for the **whole project** at the self-host default; breaching it costs a `tenant_events` **disconnect**, not a dropped message. Today `touch_trace_canvas.dart` and `touch_map_screen.dart` stream continuous gesture data with nothing throttling them, and `touch:` binds `photo`/`frame`/`neon`/`reaction_gif`.

One outbound send path, with:
- **per-topic coalescing tick**, latest-wins for positional data (gesture point, cursor, player position) — never a queue, because a stale gesture is worse than a dropped one. Same reasoning as Signal's `TypingSendJob`: `maxAttempts(1)`, `lifespan(5s)`, `memoryOnly(true)`.
- **a global token bucket** sized under the plan's msg/s.
- **a hard 8 KB payload ceiling**; anything larger goes to Storage and the broadcast carries a reference. The byte-rate ceiling binds long before the 256 KB / 3,000 KB payload ceiling.

Typing uses Signal's constants verbatim: send `STARTED` immediately on first keystroke, refresh every 10 s while typing, `STOPPED` after 3 s idle, receiver expires at 15 s from local receipt. The 1.5× receiver/sender ratio gives exactly one missed refresh of tolerance. **Typing never touches Postgres and never generates an FCM push** — today it does both, costing 2 upserts + 2 WAL fan-outs + 2 partner SELECTs per typing burst on top of the broadcast that already rendered the dots.

---

## H. What moves off postgres_changes, quantified

| | Before | After | Factor |
|---|---|---|---|
| `onPostgresChanges` call sites | 16 (verified) | 0 | — |
| Public tables in `supabase_realtime` publication | ~28 | 0 | poller creates **no replication slot** |
| REPLICA IDENTITY FULL tables | ~28 | 0 (DEFAULT) | full old+new row per UPDATE → gone |
| Authorization work per row change, on **your** Postgres | O(all project subscribers to that table): 1 deallocate+prepare, N filter evals, M RLS executions | O(1) insert into `realtime.messages` | at 1,000 presence subscribers: **1,000 → 1** |
| Documented throughput | 30 changes/s (RLS, 500 clients); 40/s on a 16XL | 10,000 msg/s (broadcast-from-DB benchmark, 80,000 concurrent) | **~333×** |
| Presence DB writes | ~18/user/min chat-open, ~3/user/min idle | ~2 per session per user | **~1,600×** at 1,000 chatting users (18,000/min → ~11/min) |
| Channel joins per app resume | 1 close + 1 open + N leaves + N joins, N=5–10 | 0 (probe passes) or 2 (worst case) | **5–10×**, usually ∞ |
| Always-on channels per user | 5 (→10 peak) | 2 (→3) | 2.5–3.3× |

**The one number that moves against you:** postgres_changes bills 1 message per listening client (2 per couple); broadcast bills 1 send + 1 per receiver (3 per couple). **+50% per event.** It is swamped by the event-count collapse below — but state it, because it is the term that surprises people.

**Presence-attributable billable messages, the number that matters most:** today, at a conservative all-day average of 3 presence writes/user/min × 2 recipients = ~259,000 billable messages/user/month. At the 18 writes/min chat-open rate it is ~1.04M/user/month. **The Free tier's entire 2M monthly allowance is consumed by presence heartbeats at ~11 users — or at 2 users if they actually chat.** After the migration: ~16 presence transitions/day × 3 = ~1,440/user/month. **~180× reduction**, and it is the single highest-leverage change in the whole system.

## Invariants
- POSITION ORDER IS COMMIT ORDER. A stream position is allocated by `UPDATE couple_cursor SET next_pos = next_pos + 1 ... RETURNING` inside the same transaction as the entity write. The row lock makes a second appender block until the first commits or aborts, so position P+1 cannot become visible before P. A reader that has seen P has therefore seen every position <= P — 'caught up' is `local_cursor == head_pos`, decidable with no clock, no ack, and no round trip. This is what `nextval` cannot give: nextval assigns at INSERT and reveals at COMMIT, so two partners sending simultaneously can commit out of order and the reader advances past a position it never saw.
- A POSITION CANNOT BE ADVERTISED BEFORE IT IS READABLE. The doorbell is an AFTER INSERT trigger on `couple_stream` calling `realtime.send`, which writes into `realtime.messages` inside the appending transaction; Realtime reads it from the WAL only after commit. A rolled-back append advertises nothing, and there is no ordering between trigger and commit to get wrong. `realtime.send` also catches its own exceptions and reports via pg_notify rather than raising, so a Realtime-side failure can never roll back the user's write.
- THE TRANSPORT CARRIES POSITIONS, NEVER STATE. Every socket event is `{stream, pos}`; an inline row copy is applied only when `pos == local_cursor + 1` and is discarded on any gap. Therefore a dropped, duplicated, reordered, replayed, or delayed broadcast is a latency bug and never a correctness bug — which is what makes it sound to run notification over at-most-once unacknowledged PubSub with a 72-hour / 25-message replay buffer.
- GAPS ARE DETECTED ARITHMETICALLY, NOT PROBABILISTICALLY. Because positions are dense per couple, `expected == received` is a local decision with exactly three branches — equal: apply; lower: already applied, discard idempotently; higher: a hole exists, fetch the difference — plus one explicit bailout (`resync_required` when the cursor falls below the retained floor). There is no 'probably fine' branch, and the client never infers a gap from socket state.
- THE CURSOR ADVANCES ONLY AFTER THE LOCAL APPLY COMMITS. A crash between fetch and apply replays the range; it can never skip it. The inverse ordering — advance then apply — is the classic silent-data-loss bug and is the reason the existing global `seq` cursor is unsafe today.
- A TOPIC NAME IS NOT A CAPABILITY. Every channel is private; Realtime evaluates the RLS predicate against the joiner's JWT at join and rolls the probe back, so possession of a couple UUID grants nothing. This is non-negotiable rather than defensive: the couple UUID is already public — it is the first path segment of every couple_media URL — so any design where knowing it grants access is already breached. Today it grants live SDP, ICE candidates, raw GPS every 4 seconds, and message plaintext.
- AUTHORIZATION COST IS O(JOINS), NOT O(SUBSCRIBERS x ROW CHANGES). Realtime computes the policy verdict once per channel join and caches it for the connection lifetime; joins/sec is a quota you can see, budget for, and jitter against. postgres_changes evaluates RLS per subscriber per row change inside `apply_rls`, whose loop is over every subscription to the table project-wide, bounded by nothing you control and unimprovable by compute (30 -> 40 changes/s from Micro to 16XL).
- NO CHANNEL IS JOINED UNTIL THE TOKEN HAS PROVEN REMAINING LIFETIME, MEASURED AGAINST THE SERVER-DERIVED CLOCK. Because the authorization verdict is cached for the connection's lifetime, a channel joined with a stale JWT is silently unauthorized until the next reconnect — it does not error, it just stops being right. The SDK swallows `FormatException: InvalidJWTToken` on cold start after a long close (supabase-2.13.0/lib/src/supabase_client.dart:381-386), so the check must be the client's, and it must happen before the join rather than after.
- THE SOCKET IS NEVER TRUSTED TO REPORT ITS OWN HEALTH. Liveness is established by an HTTP `sync_head` round trip returning the stream head; a socket that has not delivered a doorbell for a known-advanced head within the probe window is replaced. Correctness never depends on this, because every socket event is a cursor advertisement whose content is also obtainable over HTTP — the socket is a latency optimisation with no authority.
- EPHEMERAL STATE NEVER ENTERS THE WAL AND NEVER WAKES A DEVICE. Typing, screen, gestures, cursors and liveness have no durability requirement and no audit requirement. Anything written to a published table becomes a WAL record decoded by wal2json on your own database CPU and then multiplied by the subscriber count; anything that generates an FCM push burns quota and battery for a signal that is worthless late. Signal's `ephemeral` envelope flag and its `TypingSendJob(maxAttempts=1, lifespan=5s, memoryOnly=true)` are the reference shape.
- PRESENCE IS A DERIVED PROPERTY OF A LIVE CONNECTION, NOT AN INDEPENDENTLY WRITABLE FACT. No client can assert 'I am online' as durable state; it can only hold a connection open and `track()`. This makes offline the default and failure-safe outcome — crash, force-stop, LMK, radio loss and netsplit all converge on offline without any component having to succeed at anything. Durable last-seen is written on transition only (~2 writes per session per user), never on a heartbeat.
- OUTBOUND RATE IS ENFORCED IN ONE PLACE, ABOVE EVERY FEATURE. A single send path applies a per-topic latest-wins coalescing tick, a global token bucket, and an 8 KB payload ceiling. Breaching `TENANT_MAX_BYTES_PER_SECOND` (100 KB/s project-wide) costs a `tenant_events` disconnect, not a dropped frame — so the limit cannot be left to each feature to respect, and a stale positional frame is worth less than the bandwidth it consumes.
- THERE IS EXACTLY ONE SUPABASE CLIENT, ONE SOCKET, AND ONE COMPONENT THAT OWNS CHANNEL LIFECYCLE. Channel count is a function of the tenant boundary (2, or 3 with an interactive session), never of the feature count. Features register handlers; they never call `.channel()`. Supabase does not dedupe by topic, so every additional owner is another opportunity for a duplicate joined-but-dead channel — the app currently has six hand-rolled resubscribe implementations and two of them are broken.

## Why this mirrors the top tier
**Closest mirror: Telegram's MTProto update system** (core.telegram.org/api/updates, corroborated by the gotd Go implementation, both cited in research/mobile.md). Telegram persists `{pts, qts, date, seq}` plus a per-channel `pts`; every update carries the position it advances to; the client decides locally — `local_seq+1 == seq_start` apply, `>` discard as redelivery, `<` buffer and call `updates.getDifference` — with `ChannelDifferenceTooLong` as an explicit unrecoverable-resync state. The `{stream, pos}` doorbell, the three-branch reconciler, `sync_head`, and `resync_required` are that system, adapted.

**Also mirrored:** Linear's reconnect handshake (compare `lastSyncId`, request the missing delta range, per the CTO-endorsed reverse-engineering repo); PowerSync's rule that data is only made visible at a consistent checkpoint boundary, never mid-stream; Signal's post-2024 presence definition ("clients are considered present if they have an open WebSocket connection") rather than its retired 11-minute Redis lease; Synapse's stream-position rule that a published position must be "the largest stream ID where all transactions with equal or smaller ID have completed."

**Where this deliberately differs, and why:**

1. **Position allocation is a row-lock increment inside the client's own transaction, not a server-assigned counter.** Telegram, Signal and Linear all have a server process between the client and storage that can assign order. Supabase does not — the client talks PostgREST directly. `nextval` is the tempting substitute and it is wrong: it assigns at INSERT and reveals at COMMIT, so it can reveal P+1 before P. The row lock buys commit-ordered density at the cost of serialising appends **per couple**, which is free with 2 writers and would be unacceptable with 2,000. This is a deliberate exploitation of the tenant shape, and it should be labelled as such so nobody ports it to a group-chat product.

2. **The payload is optional; the position is mandatory.** Telegram ships the update inline and uses `pts_count` to cover multi-event updates, because MTProto has acknowledged transport. Supabase Broadcast is documented at-most-once with no acks and a 72-hour / 25-message replay cap, so inline-as-the-only-path would be a correctness bet on unacknowledged PubSub. Inline is kept purely as a latency win, gated on `pos == cursor + 1`.

3. **Full Jitter rather than Signal's ±25% proportional jitter.** Signal's `BackoffUtil` uses `2^min(attempt,30) * 1000 * (0.75 + random()*0.5)`, which is adequate because Signal's contention is thousands of clients against an endpoint that queues. Here the binding limit is a hard joins/sec quota that **refuses** (`too_many_joins`), and refusal plus a deterministic ladder is a loop — and Supabase names reconnect loops as a top cause of manual project suspension. AWS's own simulation (100 contending clients, 10 ms mean / 4 ms variance) shows Full Jitter cutting total calls by more than half versus un-jittered; that is the right trade when the failure mode is a support ticket rather than a slow recovery.

4. **No CRDT, no OT, no vector clocks.** Figma explicitly rejected both — OT as "a combinatorial explosion of possible states", CRDTs as designed for decentralised systems where "with an authoritative server we can simplify our system by removing this extra overhead". Chat is an append-only per-author log with a server-assigned position; the hard CRDT problem does not arise. The one CRDT in the design is Phoenix.Tracker underneath Supabase Presence, which is free and which is used only for the thing it is for.

5. **Presence keeps last-seen; Signal deletes the feature.** Signal has no presence and no last-seen at all — the cleanest possible answer, and the one this product cannot take. So the split every other researched system uses is adopted instead: ephemeral store for "is online" (Presence CRDT, in-memory, batched at `PRESENCE_BROADCAST_PERIOD_IN_MS=1500`, never in the WAL), durable store for "when last seen", written on transition only.

6. **Discord's entire fan-out stack is deliberately not built.** Manifold, relays at 15k sessions, passive sessions, delta-not-snapshot — all of it exists to fight quadratic fan-out (100,000 online users = 10 billion notifications). The watcher set here is **1**. Building any of that would be solving a problem this product does not have; the effort belongs entirely on the timing discipline, the position invariant, and the join-rate budget.

## Scale ceiling
Assumption throughout: users = individuals, 2 per couple, peak concurrency **8% of registered** (mobile social rule of thumb — instrument it rather than trust it).

### 1,000 users (~80 peak concurrent devices)
- 160 channels (2/device). A total reconnect puts 160 joins into a burst against a 500/s Pro limit — fits with 3× headroom.
- Steady-state msg/s: ~80 × 0.02 events/s × 3 ≈ 5/s. Free's 100/s would technically fit; its 2M/month allowance would not.
- Postgres: publication empty, no replication slot, no poller, no wal2json. Presence writes ~11/min project-wide.
- **Works comfortably. No architectural pressure of any kind.**

### 10,000 users (~800 peak concurrent)
- Exceeds Pro's capped 500 connections → **spend cap must be disabled** to reach the 10,000 ceiling. 1,600 channels.
- Steady-state ~50 msg/s. Peak during interactive sessions (assume 5% of devices in a touch/game session at 10 events/s): 40 devices × 10 × 3 = **1,200 msg/s**, against the 2,500/s no-spend-cap ceiling. Fits, with ~2× headroom.
- **A correlated reconnect — a Supabase restart, a regional carrier event — puts 1,600 joins into a burst. At 2,500 joins/s that fits *only because of jitter*.** Without it, the library's deterministic 1s/2s/4s ladder aligns every device onto the same ticks and the burst is a spike, not a spread.
- **Failure mode if jitter is omitted: `too_many_joins` → clients without backoff loop → sustained reconnect loops are a documented cause of manual suspension (`RealtimeDisabledForTenant`): connections refused, existing subscriptions silently stop receiving events, support ticket required to lift.** That is the honest ceiling at this scale — not degradation, an outage with a human in the loop.

### 100,000 users (~8,000 peak concurrent)
- 16,000 channels; 8,000 connections is **80% of the 10,000 hard cap**, which Team ($599) does not raise. A viral day or a push-induced thundering herd puts you over, and over means `too_many_connections` — a refusal, not a larger invoice.
- Steady-state ~170 msg/s. **Peak with 5% in interactive sessions: 400 devices × 10 events/s × 3 = 12,000 msg/s — roughly 5× over the 2,500 msg/s Team ceiling. This is a hard stop, not an overage.**
- **The binding term is interactive-session broadcast, not chat.** Chat, presence and receipts together are ~170 msg/s at this scale; the gesture/game/watch-together traffic is 70× that at peak.
- Three exits, in order of preference:
  1. **Move `rt:` onto the WebRTC data channel.** The app already establishes peer connections for calls and already has Cloudflare TURN wired (`app_secrets` + the `turn-credentials` edge function). Peer-to-peer gesture data costs the Realtime cluster nothing and removes the dominant term entirely, at zero new infrastructure. **This is the recommendation.**
  2. Self-host Realtime (Elixir, `MAX_CONNECTIONS=16384`/node) against managed Postgres. The design ports unchanged — it uses only documented Realtime primitives.
  3. Enterprise quota.

### What does *not* break at any of these ceilings
The application. Every failure above is a socket that will not connect, will not join, or gets disconnected — and the transport carries only positions. A user whose socket is refused still receives every message: on resume, on FCM tickle, on the foreground probe, via `sync_head` + the `couple_stream` fetch, which is an HTTP path that does not involve Realtime at all. **That is the answer to "nothing may depend on a reliable socket": the socket is deleted from the correctness argument entirely, so its ceiling is a latency ceiling.**

### The ceiling that is already breached today
None of the above is the current problem. On the present design, `postgres_changes` demand exceeds supply at **~100 concurrently-active users** (0.3N changes/s demanded from presence alone vs 30/s supplied with RLS at 500 clients), and the published curve degrades as clients are added — 1,500 clients → 10 changes/s, 3,000 → 5 changes/s. At 1,000 users you would be 5–45× over a ceiling that no amount of money moves (30 → 40 changes/s from Micro to 16XL, a 370× price increase). Separately, presence heartbeats alone exhaust the Free tier's 2M monthly messages at **~11 users**. The app is past its architectural ceiling at two-digit user counts, today, and the only reason it has not manifested is that it has two users.

## Cost
All figures Supabase list price. Billable messages = **events × (recipients + 1)** — a couple channel with both clients subscribed bills **3** per broadcast. Connections bill on **peak for the cycle**, in whole 1,000-packages at $10 each.

**Event budget per user per day, post-migration (built bottom-up, not inherited):**
| Source | Events/user/day |
|---|---|
| Chat messages sent | 25 |
| Receipt watermark advances (coalesced ≤1/s) | 25 |
| Typing (Signal cadence: START + refresh/10s + STOP ≈ 3 per composed message) | 75 |
| Presence transitions (8 sessions × 2) | 16 |
| Screen/misc control | 20 |
| **Subtotal — chat-only user** | **~160** |
| Interactive sessions (touch/games/watch-together): 2/week × 3 min × 10 Hz, amortised | ~500 |
| **Total — user who uses interactive features** | **~660** |

So **~480 billable/day (chat-only) to ~1,980 billable/day (interactive)** = **14k–60k billable messages/user/month**. Planning midpoint **30,000/user/month**. Note this is *higher* than research/supabase.md's 18,000 estimate, because that figure did not price the interactive-canvas features — which are the single largest and most variable term, and the only one that can be designed away (see the WebRTC exit).

### 1,000 users
| Line | $/mo |
|---|---|
| Pro base | 25.00 |
| Messages: 30M − 5M included = 25M × $2.50/M | 62.50 |
| Peak connections: ~80, under Pro's 500 | 0 |
| Compute: Micro ~$10, covered by Pro's $10 credit | 0 |
| Egress: ~20 GB media, under Pro's 250 GB | 0 |
| **Total** | **~$88/mo** |

Free tier is **not** viable and is not close: 30M messages against a 2M allowance, with no overage — it fails closed. On the *current* design Free fails at ~11 users on presence heartbeats alone.

### 10,000 users
| Line | $/mo |
|---|---|
| Pro base (spend cap **disabled**) | 25.00 |
| Messages: 300M − 5M = 295M × $2.50/M | 737.50 |
| Peak connections: ~800 → 300 over 500 → 1 package | 10.00 |
| Compute: Small | 15.00 |
| Egress: ~200 GB, under 250 GB | 0 |
| **Total** | **~$790/mo** |

Messages are **93% of the bill**. On the *current* postgres_changes design this configuration does not exist at any price — you would be 40–80× past a ceiling that money cannot move.

### 100,000 users
| Line | $/mo |
|---|---|
| Pro base | 25.00 |
| Messages: 3B − 5M = 2,995M × $2.50/M | 7,487.50 |
| Peak connections: ~8,000 → 7,500 over → 8 packages | 80.00 |
| Compute: Large | 110.00 |
| Egress: ~2 TB private media, mostly uncached → (2,000 − 250) × $0.09 | 157.50 |
| Storage: 2 TB → (2,000 − 100) × $0.0213 | 40.00 |
| **Total** | **~$7,900/mo — *if* Supabase grants 12,000 msg/s, which Team does not.** |

### The two levers, in order of leverage
1. **Move interactive sessions to the WebRTC data channel.** Removes ~500 of the ~660 daily events — **~75% of the message bill**. At 10k users: $737 → ~$180. At 100k: $7,487 → ~$1,800, *and* it removes the 12,000 msg/s hard stop. One lever fixes both the cost curve and the platform ceiling.
2. **Do not subscribe the sender to its own doorbell.** The stream position the sender already knows locally needs no echo; suppress it and a couple broadcast bills 2 instead of 3 — **a flat 33% cut** on the DB-broadcast path.

Compute, storage and egress are rounding errors below ~50k users. **Cost is ~90% Realtime messages at every scale past 1,000 users, and it is superlinear in engagement rather than in users** — so the budget is set by the rate limits you put in the transport's send path, not by growth.

## Migration
**A big-bang rewrite here would fail, and the design is built to avoid one.** Eight stages, each independently shippable, each independently revertible, none requiring the next to be correct. Stages 1, 2, 3 and 5 are each worth shipping even if the rest is abandoned.

**Stage 0 — Observability. Changes no behaviour.**
Pass `RealtimeClientOptions` at `Supabase.initialize` (E:\LDR\mobile\lib\core\supabase_service.dart:14 — currently passes none) with a logging hook. Instrument: joins attempted/succeeded/rejected, socket opens per user-hour, time-to-caught-up on resume, and `head_pos − local_cursor` at resume. Dump the *actual* `pg_publication_tables` for `supabase_realtime` — inventory/realtime.md warns the repo is not the source of truth, and three subscribed tables (`care_nudges`, `love_reasons`, `cycle_events`) have no checked-in definition or publication membership, so four subscriptions may be delivering nothing today. **You have never had a baseline; get one before changing anything.**

**Stage 1 — Jitter + delete the manufactured storm. Client only, one commit, reverts cleanly.**
Replace `reconnectAfterMs` with Full Jitter. Delete the unconditional `disconnect()/connect()` at app_shell.dart:70-79; replace with the `sync_head` liveness probe. Immediately cuts joins per user-minute on the *existing* topology, with no schema change. **Ship this first — it is the highest value-per-risk change in the list.**

**Stage 2 — The couple stream, write side only. Nothing reads it.**
Create `couple_cursor` and `couple_stream`. Add in-transaction position allocation to `messages` inserts **only**. Backfill positions in `(created_at, id)` order — structurally identical to the existing `seq` backfill at E:\LDR\supabase\receipts_v2.sql:33-46, so the pattern is already proven in this repo. Zero user-visible change. Fully reversible by dropping two tables.

**Stage 3 — Private-channel authorization, alongside the existing public channels.**
Add RLS policies on `realtime.messages` for `couple:`/`device:`/`rt:`. In the same migration, fix every existing policy's `current_user_couple_id()` call site to `(select public.current_user_couple_id())` and add `TO authenticated`. **That half is a pure win on the REST path regardless of anything else in this document** (documented: 179 ms → 9 ms, 170 ms → <0.1 ms). Nothing subscribes to the private topics yet.

**Stage 4 — Chat only, dual-path. This is the template for every subsequent stream.**
Add the `couple:{id}` channel and the doorbell trigger on `couple_stream`. Chat subscribes to **both** the new doorbell and the existing `messages:{id}` postgres_changes, dedupes by message id (the `_ids` set in chat_screen.dart already does this), and reconciles from the stream. Run both for a week and measure in the field: the new path is correct when the doorbell arrives before or with the postgres_changes event for 100% of messages, and when the gap-detected count matches the socket-drop count. **Then delete the postgres_changes leg.** Repeat this shape for every stream.

**Stage 5 — Presence off Postgres. The single largest win; ship it early.**
`track`/`untrack` on `couple:{id}`; write last-seen to Postgres on the `leave` event and on app pause only. Delete: the 30 s heartbeat (main.dart:191-209), the 5 s `chat_last_read` presence write (chat_screen.dart:495 — `chat_receipts` already carries the read watermark properly; inventory/realtime.md:88 flags it as redundant), the 15 s liveness poll (presence_service.dart), and the presence-row dependency in the 15 s location timer. Drop `presence` from the publication and set REPLICA IDENTITY DEFAULT. **Removes ~1,600× of presence write volume and ~180× of presence-attributable billable messages in one ship.** Note the current 5 s re-stamp violates Presence's 5-calls-per-30-s cap and has to go regardless of everything else here.

**Stage 6 — Remaining streams, one per ship.** reach, receipts, call_invites, the Closer set. Stage-4 pattern repeated, each independently verifiable. After the last: `ALTER PUBLICATION supabase_realtime DROP TABLE` for everything remaining, `REPLICA IDENTITY DEFAULT` across the ~28 tables. The poller then declines to create a replication slot at all.

**Stage 7 — Channel consolidation onto `couple:`/`device:`/`rt:`.**
Last, deliberately: it is the largest client refactor and the smallest correctness win, because the correctness wins all landed in stages 1–6. This is where the six hand-rolled `realtimeResumed.addListener` copies and both known races (partner_here_badge.dart:59, touch_trace_canvas.dart:89) get deleted rather than fixed. Also where `mood_lamp:none` — the global cross-tenant topic — becomes unrepresentable, because a topic cannot be constructed without a couple id.

**Stage 8 — CI enforcement.** A test asserting `pg_publication_tables` for `supabase_realtime` contains zero `public` tables, and a static test asserting no source file constructs a channel topic outside the transport component. An empty publication is a mechanically checkable invariant, which is worth more than a code-review convention.

**Rollback posture:** stages 2, 3 and 8 are additive-only. Stages 1, 4, 5, 6 each touch one subsystem and revert to the prior path by re-enabling a leg that was left in place for a week. There is no point in the sequence where both paths are absent.

## Verification
**The premise: every previous fix passed on two NTP-synced phones on one wifi and then failed in production, because that setup cannot produce any of the actual failure modes.** Two legitimate members cannot test an authorization boundary; a healthy wifi cannot produce a silently-dead socket; two humans cannot tap send within the same millisecond on demand; one carriage of commuters cannot be simulated by two phones. Every check below runs without a second phone or a second network.

**1. Two clients in one process, against a local stack.** `supabase start`, one Dart test binary, two `SupabaseClient` instances signed in as the two partners of a synthetic couple. The transport's contract is between a client and the server, not between two phones, so all of it is reachable this way.
- Partner B joins `couple:{X}` → succeeds. **A third user joins `couple:{X}` → rejected at join.** This is the check that catches the guessable-topic class, and it is *structurally untestable* with two phones because both phones are legitimate members. It is also the check that would have caught SDP, ICE and raw GPS being readable by anyone with a couple UUID.
- Static test over the source: no topic string is constructible without a couple id (kills `mood_lamp:none`).

**2. A deterministic fault injector as the transport's only seam.** The transport exposes a `TransportFault` hook that can (a) drop the socket, (b) hold it open while swallowing all inbound frames — the Android-doze silent death, which a healthy wifi *never* produces, (c) delay or fail `sync_head`, (d) present an expired JWT at join. **Every historical multi-week outage in this app is one of those four, and none is reachable by unplugging wifi.** Making them a test fixture is the difference between evidence and anecdote.

**3. Property test on the position invariant, against local Postgres.** Spawn K concurrent transactions appending to one couple's stream with randomised commit delays and randomised rollbacks. After each round assert: (i) positions form a dense prefix `1..N` with no holes; (ii) a reader polling `pos > cursor` never observes P before P−1; (iii) replaying any observed prefix yields the identical entity set. **Run the same test against the current `nextval('messages_seq_seq')` design and it fails** — which converts "there is a silent message-loss bug when both partners send simultaneously" from an assertion in a document into a reproducible failure.

**4. Reconciler unit tests, no network.** Feed the three-branch reconciler synthetic advertisement sequences: in-order, duplicate, out-of-order, far-ahead, below-retention. Assert the outcome each time, including that `resync_required` is reached rather than an unbounded backfill.

**5. Reconnect-storm simulation, one process.** 200 transport instances against the local stack; drop all at t=0; measure the join-arrival histogram. **Assert p99 join spread > 400 ms.** This test fails deterministically on the current code (verified: `retry_timer.dart` returns `1000 << (tries-1)` with no jitter term), which is the point — a test that only passes is decoration.

**6. Single-phone Doze and radio tests, scripted.** `adb shell dumpsys deviceidle force-idle` produces real Doze; `adb shell cmd connectivity airplane-mode enable/disable` produces a real radio drop; `adb shell am kill <pkg>` produces a real LMK. All single-device. The partner side is a Dart process on the laptop. These reproduce production; two phones on wifi do not.

**7. Field telemetry as the actual verification.** Through the same outbox that carries everything else: joins attempted/succeeded/rejected, time-to-caught-up per resume, gap-detected count, resync-required count, and the `head_pos − local_cursor` histogram at resume. **A fix is verified when the field histogram moves, not when it works on the desk.** None of this exists today, which is exactly why "it worked on two phones" was the only evidence available.

---

**Flagged gaps, explicitly.** I ran no tests. Nothing above has been executed. What I verified mechanically in this session, with the commands and their output shown in-session, is only this:
- `grep -rn "\.channel(" mobile/lib | wc -l` → **29**; `onPostgresChanges` → **16**.
- `grep -rn "private: true|RealtimeChannelConfig|\.track\(|presenceState|onPresenceSync|setAuth" mobile/lib` → **no matches** (no private channels, no Presence, no manual setAuth).
- `grep -rl "realtime.messages|broadcast_changes|realtime.send" supabase/` → **no matches** (no broadcast-from-database anywhere).
- `grep -rn "realtimeClientOptions|RealtimeClientOptions" mobile/lib` → **no matches**; 6 hand-rolled `realtimeResumed.addListener` sites outside `ManagedSubscription`.
- `realtime_client-2.8.0/lib/src/retry_timer.dart` — `createRetryFunction` returns `firstDelay << shiftAmount` capped at `maxDelay`; **no jitter term exists in the file**.
- `supabase-2.13.0/lib/src/supabase_client.dart:375-394` — auto-forwards `tokenRefreshed`/`signedIn`/`initialSession` to `realtime.setAuth`, and **silently swallows `FormatException: InvalidJWTToken`**.
- `supabase/receipts_v2.sql:28-31` — `messages.seq` is a project-global `nextval`; `:88-90` — the receipt `greatest()` invariant is present and correct.
- `supabase/schema.sql:105-114` — `current_user_couple_id()` is STABLE SECURITY DEFINER; `grep` confirms it is called **unwrapped** in every policy in the repo.

Everything else in this document — the throughput factors, the cost table, the scale ceilings — is arithmetic over Supabase's published benchmarks and quotas as recorded in the Phase-1 research, applied to the cadences recorded in the Phase-1 inventory. **It is not measurement of this app.** The 8% peak-concurrency assumption and the interactive-session frequency (2/week) are the two inputs that most move the cost table, and both are guesses that Stage 0 exists to replace.

## Rejected alternatives
**1. Keep postgres_changes; just fix the RLS predicates and drop REPLICA IDENTITY FULL.**
The obvious cheap fix, and it loses on structure rather than on constants. `apply_rls` loads `array_agg(sub) FROM realtime.subscription WHERE sub.entity = entity_` — every subscription to that table project-wide — and evaluates the `couple_id` filter *inside* the loop. The cost is O(subscribers) per row change regardless of how fast the predicate is; making it 100× faster moves 30 changes/s to perhaps 60, against a demand of 0.3N. Supabase's own compute curve settles it: Micro → 16XL, a ~370× price increase, buys 30 → 40 changes/s. **Do the RLS fixes anyway — they are a real win on the REST path — but they are not an answer to this problem.**

**2. PowerSync.**
Genuinely the productised version of the client half: sync buckets, checkpoints, per-bucket checksums, an upload queue, and LSN-backed write confirmation, with a first-class Flutter SDK and a documented Supabase integration. Loses on three counts: another paid service and deployment for a two-people-per-tenant app; sync rules must be expressed for each of ~28 tables; and **it does not address the ephemeral or interactive path at all**, so you would still build the entire Realtime design for touch, games, presence and calls — and then operate two sync systems. The DIY equivalent here is one stream table plus a cursor. Revisit if the goal becomes *every* feature offline-first rather than the durable ones.

**3. Self-host Realtime now.**
Removes the 10,000-connection and 2,500 msg/s ceilings and the suspension risk outright. Loses at current scale: an Elixir cluster to operate for two users, and it changes **none** of the client-side invariants that are actually broken — the app would still have no gap detection, no private channels, and a zero-jitter reconnect. It is the right answer at ~100k users and the design ports to it unchanged, because it uses only documented Realtime primitives.

**4. A per-message ack protocol over the socket.**
The instinctive "make the socket reliable" response. Loses to constraint 2 and to constraint 8 simultaneously. Every ack scheme must answer "what if the ack is lost", and the only answer is a durable cursor — at which point the acks are redundant machinery that can itself be buggy. One mechanism (position + cursor) instead of two. XEP-0198 says the quiet part out loud: resending unacked stanzas "might result in duplicates; there is no way to prevent such a result in this protocol" — every duplicate-suppression mechanism worth having lives *above* the transport.

**5. Broadcast the row content instead of the position.**
Saves a round trip, and loses because it puts correctness back on an at-most-once unacknowledged path with a 72-hour / 25-message replay cap: a dropped broadcast becomes a lost message. It also duplicates message plaintext onto the wire in a second place, which is how message content currently ends up on `mood_burst:<coupleId>`, an unauthenticated topic. **Partially adopted instead:** broadcast `{stream, pos}` *plus* an optional inline row, applied only when `pos == local_cursor + 1`. The latency win is kept; the inline copy is never the only path to the data.

**6. Keep one channel per feature and just fix the resubscribe bugs.**
Loses to constraint 8: five patches instead of one mechanism. The inventory found 6 hand-rolled resubscribe implementations and 2 are broken *today*; the seventh will be broken next month, because the pattern is subtle (`removeChannel` must be awaited, `unsubscribe()` only schedules an async leave, and Supabase never dedupes by topic). Two channels means two lifecycles owned by one component, and the bug becomes unwritable rather than fixed.

**7. Supabase Presence for typing indicators.**
Tempting because Presence is free and never touches the WAL. Impossible: **5 `track()` calls per client per 30 seconds on every plan including Enterprise** — one call per 6 seconds. Signal's 3-second pause debounce alone exceeds that during normal typing. Broadcast, with Signal's 10 s / 3 s / 15 s constants.

**8. A `pg_cron` sweeper marking users offline after N seconds.**
The DIY substitute for a presence sweeper you cannot control (`down_period` and `permdown_period` are Supabase's config, not yours). Rejected: it reintroduces the whole reason presence left Postgres — a hot table, MVCC churn, an autovacuum treadmill, and WAL that feeds the replication slot — in order to reclaim a timing contract that Presence's 30 s `down_period` already provides adequately. It also competes for the ≤8-concurrent-job guidance and lands in `cron.job_run_details`, a table with no documented retention that grows unbounded on a 500 MB database.

**9. An `UNLOGGED` presence table.**
Skips the WAL, which sounds like the whole problem solved. It does not: MVCC bloat remains, it does not replicate (so `postgres_changes` cannot deliver from it at all, defeating the purpose), and on Supabase it is truncated on crash recovery. Truncation is arguably *correct* for presence — which is the tell that presence should not be in a durable store in the first place.

## Open decisions
**1. Where interactive-session traffic runs at scale — Supabase Broadcast or the WebRTC data channel.**
This is the highest-stakes open item: it is ~75% of the message bill and the sole cause of the 100k-user hard stop (12,000 msg/s peak vs a 2,500 msg/s Team ceiling).
*Recommendation:* build `rt:` on Supabase Broadcast now — it is simple, it works, and it is right through 10k users — and move it to the WebRTC data channel when measured peak crosses ~1,000 msg/s. The call feature already establishes peer connections and TURN is already provisioned via Cloudflare, so the data channel is the same handshake with a different payload. Design `rt:` behind an interface from day one so the swap is a transport change, not a feature rewrite.

**2. Per-user or per-device topics.**
`profiles.fcm_token` is a single column today — a second sign-in silently steals push from the first. If a user may ever be signed in on two devices, `device:{user_id}` must become `device:{user_id}:{device_id}` and push tokens must move to a per-device table.
*Recommendation:* **per-device from day one.** The topic name is embedded in an RLS policy; widening it later is a migration under load, and it costs nothing to include today.

**3. Compaction floor for `couple_stream`.**
Gating retention on `min(both partners' cursors)` means one partner who stops opening the app pins the log indefinitely.
*Recommendation:* floor at `min(cursors)` with a hard 90-day cap, then force `resync_required` for the lagging partner. State the product consequence plainly: a partner offline >90 days re-bootstraps and loses nothing — the entity tables are intact — but the resync is a large read that should be paged and shown as progress, not a spinner.

**4. Presence privacy enforcement.**
With private channels you can put `share_last_seen = true` on the *viewer* into the presence-read policy, giving WhatsApp's reciprocity rule server-side.
*Recommendation:* do it. It is one predicate, and it is the only enforcement that survives a modified client. Today presence privacy is decided client-side, which is not a control at all.

**5. Whether `postgres_changes` is permitted for anything, ever again.**
*Recommendation:* no, and enforce it in CI — assert `pg_publication_tables` for `supabase_realtime` contains zero `public` tables. A mechanically checkable invariant is worth far more than a convention. **Before trusting any of this, dump the actual publication**: inventory/realtime.md records that the repo is not the source of truth, and three tables the client subscribes to (`care_nudges`, `love_reasons`, `cycle_events`) have no checked-in definition or publication membership — meaning four live subscriptions may be silently delivering nothing right now, and nobody would know.

**6. Free vs Pro, immediately.**
*Recommendation:* **Pro now, and not for connections.** Two reasons, in order: (a) on the current design, presence heartbeats alone exhaust the 2M free monthly allowance at ~11 users; (b) the "Private Channel Subscription RLS Execution Time" and "Broadcast-from-Database replication lag" reports are **Pro-and-above only** — on Free you cannot observe whether the new path is falling behind, so you would be running the entire migration blind on exactly the two metrics that tell you whether it worked.

**7. Whether to fix the `messages.seq` cursor hazard ahead of the full migration.**
The global `nextval` can reveal position P+1 before P, permanently losing a message when both partners send simultaneously. Stage 2 fixes it properly, but Stage 2 is two stages away.
*Recommendation:* do not attempt an interim patch. The only correct interim mitigation is to fetch `>= cursor − K` with a dedupe window, which is a guess dressed as a fix and would mask the property test in Stage 2 that proves the real thing. Ship Stage 2 sooner instead. **Flag it as a known live data-loss path in the meantime** rather than pretending it is covered.
