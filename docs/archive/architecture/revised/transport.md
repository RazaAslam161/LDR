> **Partly superseded by [`../CONTRACT.md`](../CONTRACT.md).** This document was written
> before the cross-domain reconciliation. Where it disagrees with the contract, the
> contract wins. Specifically superseded here:
>
> - **R1** — position allocation — one row, two dense counters; chat stays out of couple_stream
> - **R4** — pg_cron budget — slots are allocated centrally, not per domain
> - **CLIENT-F2** — chat mutation tombstones and the staged revoke/guard ordering
>
> Reasoning: `../RECONCILIATION.md`. Corrections that verification forced:
> `../RECONCILIATION-REPAIRS.md`.

# transport (revised)

## What changed vs v1
## FATAL 1 — "Inline payload violates the design's own headline invariant" (permanent silent divergence)

**Closed, by making the hole unrepresentable rather than by rule.**

The old design let the doorbell carry an optional entity row and applied it when `pos == cursor + 1`, then advanced the cursor. Once past `pos N`, branch 2 (`pos <= cursor → discard`) made N unfetchable forever, and `resync_required` only fires in the opposite direction. A wrong inline copy — stale, truncated, mangled by row-to-json, or forged — was permanent silent data loss.

Two mechanisms close it, and either alone would be sufficient:

1. **The doorbell has no payload channel.** The trigger fires on `couple_stream`, and `couple_stream` has no body column — it holds `couple_id, pos, stream, entity_id, op`. The trigger cannot see the entity row, because it is not a trigger on the entity table. There is no inline copy to be wrong about. The doorbell is `{stream, pos, entity_id}`; `entity_id` is a fetch hint, not content.

2. **THE CURSOR ADVANCES ONLY TO A POSITION THE CLIENT HAS READ FROM THE DATABASE.** This is the load-bearing rule. `pos` from a socket frame is never stored anywhere — not in the cursor, not in a "highest seen" variable, not in a pending-gap set. A doorbell is a single-bit signal: *go read*. The client fetches `couple_stream WHERE couple_id=$1 AND pos > local_cursor ORDER BY pos`, applies rows in order, and advances the cursor to each row's own `pos` after that row's local apply commits.

**Why it cannot regress.** The reconciler has no code path that takes an integer from a socket frame and writes it to the cursor store. Adding one would require adding a parameter that does not exist. A CI test (Stage 9) asserts the doorbell handler's only effect is to enqueue a fetch. And because the advertised `pos` is never retained, a forged, duplicated, replayed, reordered, or absurd (`pos = 2^40`) doorbell costs at most one wasted range query — it can never poison the cursor. This also *removes* the arithmetic three-branch reconciler as a correctness dependency: gaps are no longer detected on the wire, they are detected by the read returning rows.

**Cost paid honestly:** one HTTP round trip per received message that the old design avoided (~60–200 ms on mobile). Mitigated by `entity_id`: when the doorbell's `pos == cursor + 1`, the client issues a single-row read by id instead of a range scan. The sender still renders optimistically from its own local outbox, so the latency is one-sided.

---

## FATAL 2 — "RLS cannot exclude a per-message event name; the doorbell is forgeable"

**Closed by splitting the doorbell onto a topic no client may write.**

The attack is correct and the verification is on disk: `realtime_channel.dart:618-700` — `sendBroadcastMessage` → `send()` pushes over the already-joined channel with no per-message authorization, and falls back to `POST /api/broadcast` with `{topic, payload, event, private}` under the same bearer. Write access is all-or-nothing per topic. Anyone who may send `typing` on a shared `couple:` topic may send `{stream, pos}`.

Topic split (this is now **3** always-on channels, not 2 — see target architecture and re-priced join budget):

| Topic | Client read | Client write |
|---|---|---|
| `cs:{couple_id}` — the stream doorbell | yes | **no INSERT policy exists** |
| `cl:{couple_id}` — typing, screen, Presence track | yes | yes |
| `dev:{user_id}:{device_id}` — revocation, targeted hints | yes (own only) | **no** |
| `rt:{couple_id}:{session_id}` — gestures, game state | yes | yes |

`cs:` and `dev:` are written only by `SECURITY DEFINER` functions calling `realtime.send`, owned by a role that is not subject to RLS on `realtime.messages`.

**Why it cannot regress, even if the write policy is wrong.** This is the point of layering it with the cursor rule. If Realtime's write check on `/api/broadcast` turns out not to enforce the INSERT policy — which I could not verify from disk and have flagged as a Stage-4 gate test — a forged doorbell still cannot cause divergence, because no `pos` from the wire ever reaches the cursor. The topic split reduces forgery from "arbitrary content injection into the partner's UI" to "an attacker can make the partner's phone issue a database read it was entitled to make anyway." That is a rate-limit problem, not a correctness problem, and the client single-flights and rate-caps its catch-up fetches.

**The `mood_burst:` plaintext leak dies with this.** Message content stops travelling on any broadcast topic, because no broadcast topic in the vocabulary carries content.

---

## FATAL 3 — "Stage 1 cannot be shipped: Full Jitter is not injectable, and it depends on a Stage-2 RPC"

**Closed by naming the real injection point, and by reordering the migration so no stage depends on a later one.**

Verified in this session (`C:\Users\razaa\AppData\Local\Pub\Cache\hosted\pub.dev\`):

- `supabase-2.13.0/lib/src/realtime_client_options.dart` — exactly four fields: `eventsPerSecond` (annotated `@Deprecated('Client side rate limit has been removed. This option will be ignored.')`), `logLevel`, `timeout`, `transport`.
- `supabase-2.13.0/lib/src/supabase_client.dart:337-352` (`_initRealtimeClient`) forwards `logLevel, httpClient, timeout, customAccessToken, transport` — **not** `reconnectAfterMs`, **not** `heartbeatIntervalMs`.

The attack's conclusion ("not injectable through `Supabase.initialize`") is right. But it is injectable *after* construction, and this is the mechanism the revision names:

- `realtime_client-2.8.0/lib/src/realtime_client.dart:113` — `late RetryTimer reconnectTimer;` — a **public, non-final field**, assigned once in the constructor (`:205-211`) and thereafter only used via `reconnectTimer.reset()` / `.scheduleTimeout()` (`:242, :300, :524, :548`). Replacing the instance replaces the ladder.
- `realtime_client-2.8.0/lib/src/realtime_client.dart:103` — `int heartbeatIntervalMs = ...` — also a public non-final field; the `Timer.periodic` is created in `_onConnOpen` (`:524-529`), so assigning before the first connect takes effect.
- `reconnectAfterMs` (`:118`) is public and mutable but **useless after construction**, because `RetryTimer` captured the function value at `:210`. Anyone "fixing" jitter by assigning that field ships a no-op. Stated explicitly so it is not attempted.

`RetryTimer` and its `TimerCalculation` typedef live in `src/retry_timer.dart`, which `lib/realtime_client.dart` does **not** re-export. So the transport must import `package:realtime_client/src/retry_timer.dart` directly (an `implementation_imports` lint, not an error) and **pin `realtime_client` to an exact version**, with a unit test that fails if `reconnectTimer` is no longer assignable. This is a dependency-shape change with a named maintenance cost, not a one-line config change — priced as such in the migration.

**Ordering fixed.** The old Stage 1 deleted the forced `disconnect()/connect()` at `app_shell.dart:70-79` and replaced it with a `sync_head` probe that Stage 2 created. Deleting it early is exactly the constraint-4 violation the brief warns about: that call exists because the socket dies silently in doze with no close event, and `realtime_client`'s heartbeat is a `Timer.periodic` Android throttles while backgrounded — so removing it before a working probe exists regresses recovery from ~1 s to up to two heartbeat intervals (~50 s) of silent non-delivery on every resume. In the revised plan the forced disconnect **stays untouched until Stage 5**, which is the first stage where `sync_head` exists *and* the probe is self-answering.

---

## SERIOUS, also closed

- **#3 unfalsifiable probe → storm.** `sync_head` now calls `realtime.send({nonce}, 'probe', 'cs:'||couple_id)` before returning. A doorbell is *guaranteed*, so its absence is proof. Priced: ~10 probes/user/day × 3 = 30 billable/user/day.
- **#4 ServerClock starved by Stage 5 while joins are gated on it.** The clock-arithmetic gate is deleted outright — a gate whose input is a device clock is not a gate. Replaced by `auth.refreshSession()` before the first join after any cold start or any socket gap; the **server** asserts token validity. Separately, `sync_head` returns `server_now` and feeds `ServerClock`, and that lands in Stage 3 — *before* Stage 6 deletes the presence heartbeat that is currently its only caller (`presence_service.dart:206`).
- **#5 compaction floor with no source; bootstrap with no checkpoint.** Adds `couple_member_cursor(couple_id, user_id, device_id, applied_pos)` advanced by a `greatest()` RPC. Floor = `min(applied_pos)` over devices seen in 30 days, hard cap 90 days. Bootstrap is defined: read `head_pos = H` **first**, page entity tables filtered `stream_pos <= H`, then set `local_cursor := H`. Per-device rows prevent Matrix's two-readers bug.
- **#6 WebRTC signalling on a topic with no positions.** Call signalling moves into the stream (`stream='call'`, entity `call_signals`), so ICE inherits commit order, durability, and gap-free catch-up. The ring path is explicitly made socket-free: FCM → HTTP read of `call_signals` by `call_id` → answer via an RPC that appends. No channel join is in the ring critical path. Glare resolves on `pos` — a total order both peers already have, server-assigned.
- **#7 nothing stops a direct write bypassing allocation.** Position allocation moves into **BEFORE INSERT/UPDATE/DELETE triggers on each streamed entity table**, so PostgREST, RPC, and the SQL editor are all covered. `stream_pos` is `NOT NULL` on every streamed table. CI asserts a trigger exists for every table in the stream vocabulary. The old design's "one trigger instead of 28" was true only of the doorbell and silently hid ~28 append triggers; they are now in the stage plan.
- **#8 `DB_POOL_SIZE=5` ignored.** Named as an explicit operational dependency (raise to ≥20). The join policy is one PK-indexed lookup, wrapped `(select ...)`, `TO authenticated`. And joins are staggered over a **server-supplied `join_budget_ms`** returned by `sync_head` — tunable without an app release.
- **#9 cost errors.** The "don't subscribe the sender to its own doorbell — flat 33%" lever is **deleted**; it is unachievable on a shared topic. The 100k WebRTC exit is re-priced: it is conditional on the peer connection being non-relayed, and the unconditional exit is self-hosted Realtime. `couple_stream` storage and the `pg_cron` job are in the cost table. The token bucket is sized in **bytes/s** against `TENANT_MAX_BYTES_PER_SECOND=100_000`.
- **#10 literal defects.** `dev:`/`rt:` predicates use `LIKE`, not `=` against a string containing `%`. The token bucket sits **above** `sendBroadcastMessage`, and the transport refuses to send when the channel is not `joined` — which is precisely when the SDK silently REST-falls-back (`realtime_channel.dart:633-668`). Security sequencing is flipped: the live leaks (`call:` SDP/ICE, `capsule_proximity:` raw GPS every 4 s, `mood_burst:` plaintext, `mood_lamp:none` cross-tenant) close in **Stage 1** on the *current* topic names, not in Stage 8 behind the largest refactor.
- **#11 Stage 7 big bang; transport component homeless.** The transport singleton is introduced in Stage 2, rooted in `main()` above `MilesApp` — so it survives `showRealApp.value = false`, which `main.dart:213-231` forces on every `paused`/`hidden`/`detached`. Feature migration is one feature per ship, each keeping its old `.channel()` behind a flag for one release. Sign-out teardown is explicit.

## Target architecture
## The one mechanism

**The socket says only "go read." The database says what.** Every socket frame is a signal to issue a query; no socket frame ever becomes stored state, and no integer from a socket frame is ever retained. Under that rule a dropped, duplicated, reordered, delayed, replayed, or **forged** frame costs at most one redundant HTTP request. That is what makes it sound to run over Supabase Broadcast, which is documented at-most-once, unacknowledged, with a 72-hour / 25-message replay cap.

---

## A. Channel topology — 3 always-on, 1 conditional

| Topic | Lifetime | Private | Client read | Client write | Carries |
|---|---|---|---|---|---|
| `cs:{couple_id}` | while paired & signed in | yes | yes | **no** | `stream` doorbell `{stream, pos, entity_id}`; `probe` `{nonce}`; `revoked` |
| `cl:{couple_id}` | while paired & signed in | yes | yes | yes | Presence track/untrack, `typing`, `screen`, receipt-watermark hint |
| `dev:{user_id}:{device_id}` | while signed in | yes | own only | **no** | session revocation, forced-resync command, targeted ring hint |
| `rt:{couple_id}:{session_id}` | only while an interactive surface is open | yes | yes | yes | gestures, game state, player position |

Four topics, three of them always-on. Channel count is a function of the **tenant and trust boundary**, never of the feature list: `cs:` is server-write-only, `cl:` is couple-writable, `dev:` is one user, `rt:` is a bounded-lifetime high-rate surface. Splitting `cs:` from `cl:` is the direct fix for the forgeable-doorbell flaw, and it costs one extra join per device — it does **not** change billable message count, which is per send plus per receiver regardless of how topics are arranged.

Features register handlers on these channels. **No feature calls `.channel()`.** That deletes the six hand-rolled `realtimeResumed.addListener` resubscribers and both known races (`partner_here_badge.dart:59` not awaiting `removeChannel`; `touch_trace_canvas.dart:89` using `unsubscribe()` then immediate re-`channel()`) by making them unwritable — there is no channel for those widgets to mismanage. It also makes `mood_lamp:none` unrepresentable: a topic string cannot be constructed without a non-null couple id.

`session_id` is a random UUID minted by the initiator and exchanged over `cs:`/`cl:`. It is **not** a security boundary — the RLS predicate is `LIKE 'rt:' || couple_id || ':%'`, so any member may join any session. It exists to bound channel lifetime, nothing more. Stated so nobody relies on it.

---

## B. Transport selection — a decision procedure

1. **Must it survive the recipient being offline, and must it never be lost?**
   → **Yes**: it is a durable row carrying a `stream_pos`, plus a `couple_stream` position. The socket carries only the doorbell. Chat, reach, capsules, call signalling, the Closer set, deletes and purges.
   → No: continue.
2. **Is it a monotone watermark (idempotent, order-free, self-correcting)?**
   → **Yes**: it does **not** enter the stream. Read-receipt and delivery watermarks are `greatest()`-advanced rows read on catch-up, hinted over `cl:` at ≤1/s. A lost hint costs latency; a lost watermark is impossible because the next read repairs it. This removes ~25 stream appends and ~50 DB writes per user per day versus the previous design.
   → No: continue.
3. **Is it a property of holding a live connection?**
   → **Yes**: **Presence** on `cl:`. Online/away only. `CLIENT_PRESENCE_MAX_CALLS=5` per `CLIENT_PRESENCE_WINDOW_MS=30000` makes anything faster impossible, so nothing else is eligible. (The current 5 s `chat_last_read` re-stamp already violates this cap and must go regardless.)
   → No: **client Broadcast** — `cl:` if low-rate, `rt:` if high-rate.

**Nothing is on `postgres_changes`.** The `supabase_realtime` publication ends with zero `public` tables. Source-verified consequence (`replication_poller.ex`): with an empty publication the `postgres_cdc_rls` poller refuses to create a replication slot at all, so the 100 ms poll and the wal2json decode leave your database entirely — and with them `apply_rls`, whose `array_agg(sub) FROM realtime.subscription WHERE sub.entity = entity_` loop is over **every subscriber to that table project-wide** and evaluates the `couple_id` filter *inside* the loop. That loop is the reason the current app is past its ceiling at ~100 concurrently-active users.

---

## C. The couple stream — dense, commit-ordered positions

**`couple_cursor`** — `couple_id uuid primary key`, `next_pos bigint not null default 0`, `fillfactor=70` so the increment is a HOT update.

**`couple_stream`** — `couple_id uuid`, `pos bigint`, `stream text` (`'chat' | 'reach' | 'capsule' | 'call' | 'closer' | …`), `entity_id uuid null`, `op text` (`'insert' | 'update' | 'delete' | 'purge'`), `created_at timestamptz default now()` *(display only, never compared — `now()` is transaction-start time and is not monotonic across overlapping transactions)*. PK `(couple_id, pos)`.

**Every streamed entity table gains `stream_pos bigint not null`** and an index on `(couple_id, stream_pos)`.

**Allocation.** A `BEFORE INSERT OR UPDATE OR DELETE ... FOR EACH ROW` trigger on each streamed entity table does, inside that row's own transaction:

```
UPDATE couple_cursor SET next_pos = next_pos + 1
 WHERE couple_id = <row's couple_id> RETURNING next_pos
```

then sets `NEW.stream_pos` and inserts the matching `couple_stream` row.

Consequences, and why they are structural rather than conventional:

- **Positions are dense.** A rolled-back transaction releases its position rather than burning it — unlike `nextval`.
- **Positions become visible in position order.** The row lock on `couple_cursor` makes a second appender block until the first commits or aborts, so P+1 cannot be readable before P. This is Synapse's rule ("the largest stream ID where all transactions with equal or smaller ID have completed") obtained free from the two-writer tenant shape.
- **No write path can bypass it.** Because allocation is a trigger and not an RPC, `chat_repository.dart`'s four plain PostgREST inserts (lines 228/249/279/309), any future screen, and the SQL editor are all covered. This is the direct fix for "the row commits, is never advertised, never appears in a gap fetch, and both clients report caught-up."
- Serialisation is **per couple**, with exactly two writers at human speed. Free at 2 writers; unacceptable at 2,000. **Label this as a deliberate exploitation of the tenant shape so nobody ports it to a group-chat product.**
- **No long-running work may occur in a transaction that has allocated a position.** Media goes to Storage first; only the row insert is in the transaction.

**`messages.seq` is retired as a cursor.** It is `nextval('public.messages_seq_seq')`, a project-global sequence (`receipts_v2.sql:28-31`): a couple's positions are sparse so gap arithmetic is impossible, and `nextval` assigns at INSERT but reveals at COMMIT, so two partners sending within the same few milliseconds can commit out of order and a `WHERE seq > cursor` reader advances past a row it never saw. `seq` stays as the receipt ordering key (`ack_delivered`/`ack_read` already use `greatest()` correctly and that logic is sound); it is never again used as a sync cursor.

---

## D. Deletes and the hard purge

Ground truth: `clear_conversation_everyone()` **hard-deletes every message row for a couple**. A cursor design must survive rows vanishing beneath the cursor.

- **A stream position survives its entity.** The reconciler treats a missing entity as normal: the `couple_stream` row *is* the position; the entity row is the payload. Advance regardless. A range read that joins to entity tables and gets nulls is not an error.
- **Per-row deletes** append `op='delete'` with the `entity_id`. This closes the rows-resurrect-on-reinstall gap that `research/mobile.md` flags against the existing `deleteForEveryone` RPC.
- **The bulk purge appends exactly one position**, `op='purge'`, and the per-row delete trigger is suppressed for that statement via a transaction-local flag (`set_config('miles.bulk_purge','1',true)`) that the trigger checks. Otherwise clearing a 50k-message history would append 50k positions.
- **`couple_cursor.next_pos` never decreases.** A purge does not rewind positions; it is a forward event like any other.
- Note: the purge holds the `couple_cursor` row lock for the duration of the DELETE, briefly blocking the partner's sends. Acceptable; stated.

---

## E. The doorbell

**One** `AFTER INSERT` trigger, on `couple_stream` only, calling `realtime.send(jsonb_build_object('stream', NEW.stream, 'pos', NEW.pos, 'entity_id', NEW.entity_id), 'stream', 'cs:'||NEW.couple_id, private => true)`.

Properties, all source-verified in the research:

- `realtime.send` inserts into `realtime.messages` **inside the appending transaction**, and Realtime reads it from the WAL only after commit. A position can never be advertised before it is readable; a rolled-back append advertises nothing.
- `realtime.send` catches its own exceptions and reports via `pg_notify` rather than raising, so a Realtime-side failure can never roll back the user's write.
- The payload is drawn entirely from `couple_stream` columns. The trigger has no access to the entity row. **There is no inline-copy path to get wrong.**

`realtime.messages` is daily-partitioned with partitions dropped after 3 days, so the doorbell spool has bounded growth, no bloat, and no vacuum debt.

---

## F. Authorization

Every topic is `config: {private: true}`, gated by RLS on `realtime.messages`. The verdict is computed once at join — Realtime runs one probe under the joiner's JWT and rolls it back — and **cached for the connection lifetime**. So authorization cost is O(joins), bounded by a quota you can see and stagger against, instead of O(subscribers × row changes), bounded by nothing.

Policy shapes (prose):

- **broadcast read**, `TO authenticated`: `realtime.topic() = 'cs:' || (select public.current_user_couple_id())::text` OR `= 'cl:' || (select public.current_user_couple_id())::text` OR `LIKE 'dev:' || (select auth.uid())::text || ':%'` OR `LIKE 'rt:' || (select public.current_user_couple_id())::text || ':%'`.
- **broadcast write**, `TO authenticated`: the `cl:` and `rt:` terms **only**. There is deliberately no INSERT policy matching `cs:` or `dev:`.
- **presence read/write**, `TO authenticated`: the `cl:` term, additionally requiring the *viewer's* `share_last_seen = true` — WhatsApp's reciprocity rule enforced at the fan-out point rather than by the receiving client. Because the verdict is cached, a toggle takes effect on the next join; stated.

**Mandatory and separately valuable:** `current_user_couple_id()` is called **unwrapped** in every policy in the repo (verified across `breath_events.sql`, `messages.sql`, `capsules.sql`, `reach_events.sql`, `intimacy_*.sql`, `20260627_call_invites.sql`, `hardening_2026_08.sql`). Wrap every call as `(select public.current_user_couple_id())` so Postgres treats it as an InitPlan evaluated once per statement, and add `TO authenticated` everywhere. Documented deltas: 179 ms → 9 ms, 178,000 ms → 12 ms on a complex policy, and 170 ms → <0.1 ms from `TO authenticated` alone. This is a pure win on the REST path independent of everything else here.

It matters doubly at join time. **Realtime's authorization pool defaults to `DB_POOL_SIZE=5`** — five connections gate every private-channel join for the entire project. `current_user_couple_id()` is `select couple_id from profiles where id = auth.uid()`, a primary-key index lookup, so a wrapped policy is one index probe. **Raising `DB_POOL_SIZE` to ≥20 in the dashboard is a named operational dependency of this design, not an assumption.** Stage 0 measures actual join throughput; the join stagger is sized from that measurement, not from a guess.

**Revocation.** `leave_couple()` additionally calls `realtime.send({}, 'revoked', 'cs:'||couple_id)`; both transports tear down all couple channels and purge local couple data. Residual staleness is bounded by the JWT lifetime — see accepted limits.

---

## G. Reconnect, resubscribe, catch-up, caught-up

### The transport component

A **process-lifetime singleton constructed in `main()` before `runApp`**, above `MilesApp`. This is mandatory, not stylistic: `main.dart:213-231` forces `MilesApp.showRealApp.value = false` on every `paused`/`hidden`/`detached` for the disguise cover, which unmounts `AppShell` and everything under it. A transport mounted under `AppShell` dies with the cover on every background — taking the socket, the resume probe and Presence with it. This is already why the ring path is dead on cold start (`inventory/calls.md:7`).

It is **headless**: no UI, no notification, no Telecom/ConnectionService registration, no launcher-visible surface. The launcher disguise (activity-alias, app named "News") is untouched by anything in this document.

It owns: the socket, the reconnect loop, the four channel lifecycles, the cursor store, the catch-up single-flight, and the single outbound send path. Sign-out calls `Transport.shutdown()` explicitly from the session provider's `signedOut` handler — the only teardown path, which fixes the current non-`autoDispose` `call:` and `screen_presence:` channels that outlive sign-out until process kill.

### State machine

```
SIGNED_OUT ──sign in──► TOKEN_ASSERT ──refreshSession ok──► CONNECTING
                             ▲  │ refresh fails                  │ socket open
                             │  └────────► BACKOFF ◄─────────────┤ fail
                             │               │ Full Jitter       │
                             │               ▼                   ▼
                             └──────── TOKEN_ASSERT           JOINING
                                                                 │ 3 channels joined (staggered)
                                                                 ▼
                                                            RECONCILING
                                                                 │ head fetched, range drained
                                                                 ▼
                                                               LIVE ──probe fails──► CONNECTING
```

### Rules

1. **No join happens until the server has asserted the token.** On cold start, and after any socket gap longer than a few minutes, call `auth.refreshSession()` and gate joining on it succeeding. **No clock arithmetic anywhere.** The old design compared `session.expiresAt` against `ServerClock`, whose only feed (`presence_service.dart:206`) the presence migration deletes — a 3-minutes-slow phone would have joined with a dying token, and because the verdict is cached that channel is *silently* unauthorized until the next reconnect. The SDK will not surface it: `supabase_client.dart:375-394` forwards `tokenRefreshed`/`signedIn`/`initialSession` to `realtime.setAuth` but **catches and silently swallows `FormatException: InvalidJWTToken`**, with the comment "on app launch after the app has been closed for a while." So the transport calls `setAuth` itself with the freshly-refreshed token and asserts each channel reaches `joined`; `channelError`/`timedOut` is a socket replacement, not a warning.
2. **Full Jitter backoff**, `random(0, min(30_000, 1000 * 2^attempt))`, installed by replacing `client.realtime.reconnectTimer` with a `RetryTimer` built over a jittered `TimerCalculation`. The SDK default is deterministic `1000 << (tries-1)` capped at 10 s (`retry_timer.dart` — **no jitter term exists in the file**), so every device that dropped on the same tick retries on the same tick, against a joins/sec quota that **refuses** (`too_many_joins`) rather than queues. Supabase names sustained reconnect loops as a top cause of manual project suspension (`RealtimeDisabledForTenant` — connections refused, existing subscriptions silently stop delivering, support ticket to lift).
3. **Backoff resets on a successful `sync_head`, never on a connectivity event.** `connectivity_plus`' own README says connectivity is not reachability. Resetting on connectivity means every device leaving the same tunnel resets to attempt-0 on the same tick.
4. **Joins are staggered over `join_budget_ms`**, a value returned by `sync_head` and therefore tunable server-side without an app release. Each channel joins at `random(0, join_budget_ms)`. Sized from measured join throughput, not from the msg/s quota.
5. **The resume probe replaces the forced disconnect.** `sync_head(couple_id, device_id, nonce, applied_pos)` → **before returning**, calls `realtime.send({nonce}, 'probe', 'cs:'||couple_id, private => true)`; returns `{head_pos, floor_pos, server_now, join_budget_ms}`. A doorbell is therefore *guaranteed*, so its absence within the window is genuine proof the socket is dead — this is what makes the probe falsifiable when the partner is asleep, which the previous "wait for a doorbell after draining backlog" test was not. On absence: `disconnect()` then `connect()`. Single-flighted, minimum 10 s between probes per device, so returns from the camera and photo picker (constant, per the app's own `systemOverlayActive` guard) do not each cost a probe.
6. **Single-flight the catch-up**, keyed `(couple_id)`. Resume, connectivity change, socket `onOpen`, FCM tickle and the probe reply all fire within ~200 ms and would otherwise produce five identical fetches.
7. **`heartbeatIntervalMs`** is set explicitly on the client (public mutable field) rather than left at the 25 s default, because the heartbeat is a `Timer.periodic` that Android throttles in the background — the probe, not the heartbeat, is the liveness authority.

### Catch-up

On any doorbell, probe reply, resume, connectivity gain, or FCM tickle:

- Fetch `couple_stream WHERE couple_id=$1 AND pos > local_cursor ORDER BY pos LIMIT 500`, left-joined to entity tables.
- Apply rows in `pos` order. **After each row's local apply commits, advance the cursor to that row's `pos`.** A crash between fetch and apply replays the range; it can never skip it.
- A missing entity is normal (deleted or purged) — advance.
- Page until a short page.
- Fast path: if a doorbell's `pos == local_cursor + 1`, read that one entity by `entity_id` and advance to the entity's own `stream_pos`.
- Report `applied_pos` to `couple_member_cursor` via a `greatest()` RPC at the end of a drain and on app pause (~2 writes/device/session).

**Caught-up is decidable with no clock, no ack, and no round trip beyond `sync_head`:** `local_cursor == head_pos`. The UI shows a syncing affordance only while `head_pos > local_cursor` — never a full-screen spinner, because local data is already rendered.

**Bailout.** If `local_cursor < floor_pos`, `sync_head` returns `resync_required`. Bootstrap is then explicitly ordered:

1. Read `head_pos = H` from `sync_head`.
2. Page each entity table with `stream_pos <= H`, ordered by `stream_pos`.
3. Set `local_cursor := H`.
4. Doorbells arriving during (2) are ordinary forward gaps, drained after (3).

Reading `H` **before** paging is the whole point: reading it after would silently skip everything appended during a multi-minute bootstrap on a train. This is PowerSync's consistent-checkpoint rule applied to the one path that needs it. The bootstrap is paged with visible progress, never a spinner.

### Retention and compaction

`couple_member_cursor(couple_id, user_id, device_id, applied_pos, updated_at)`, PK `(couple_id, user_id, device_id)`, advanced only by an RPC using `greatest()` so it cannot move backwards, RLS `using (user_id = auth.uid())` on write.

`pg_cron` deletes `couple_stream` rows with `pos <= min(applied_pos)` over devices with `updated_at` within 30 days, with a hard 90-day floor past which a lagging device gets `resync_required`. **Per-device** rows are what prevent device A's advance from pushing the floor past device B and giving B `resync_required` on every second launch — Matrix's documented two-readers bug. Entity tables are never compacted; a resync loses nothing.

---

## H. The outbound send path

One send path in the transport, the only caller of `sendBroadcastMessage` in the app, with:

- **A global token bucket sized in BYTES per second**, budgeted under `TENANT_MAX_BYTES_PER_SECOND = 100_000` — 100 KB/s for the whole project at the self-host default. This, not msg/s, is the limit that binds first: `touch:` binds `photo`/`frame`/`neon`/`reaction_gif` and `touch_trace_canvas.dart` / `touch_map_screen.dart` stream continuous gesture data with nothing throttling them today. Breaching it costs a `tenant_events` **disconnect**, not a dropped frame.
- **A per-topic latest-wins coalescing tick** for positional data (gesture point, cursor, player position) — never a queue, because a stale gesture is worth less than the bandwidth it consumes. Signal's `TypingSendJob(maxAttempts=1, lifespan=5s, memoryOnly=true)` is the reference shape.
- **A hard 8 KB payload ceiling.** Anything larger goes to Storage and the broadcast carries a reference.
- **A refusal to send when the channel is not `joined`.** This is what actually closes the SDK's silent REST fallback: `realtime_channel.dart:633-668` routes `send()` to `POST /api/broadcast` whenever `!canPush`, which is exactly during the reconnect burst when rate limiting matters most, and per `inventory/calls.md:68` is already how the callee's answer leaves today — one POST per ICE candidate. If a REST send is genuinely wanted, it is an explicit `httpSend` through the same bucket, separately budgeted.

Typing uses Signal's constants verbatim: `STARTED` on first keystroke, refresh every 10 s while typing, `STOPPED` after 3 s idle, receiver expires at 15 s from local receipt (the 1.5× ratio gives exactly one missed refresh of tolerance). **Typing never touches Postgres and never generates an FCM push** — today it does both, costing 2 upserts + 2 WAL fan-outs + 2 partner SELECTs per burst *on top of* the broadcast that already rendered the dots.

---

## I. Call signalling in the stream

Call signalling is a durable, ordered, exactly-once-in-order requirement (RFC 8838), so it belongs in the stream, not on `rt:`. `rt:` carries no positions and lives only while an interactive surface is open — which is precisely when a ringing call's surface is not open.

- `stream='call'`, one `couple_stream` row per signal, `entity_id` → a `call_signals` table carrying `call_id`, `kind` (`offer|answer|ice|end`), and the SDP or candidate.
- ICE inherits commit-ordered positions, ordering, durability and gap-free catch-up. A cold-started callee gets the **full** candidate set from one catch-up query, replacing today's "caller re-sends its entire `_localCandidates` list on receiving the answer" hack (`inventory/calls.md:42`), which is unbounded and undeduped.
- **The ring path never blocks on Realtime.** FCM carries `{couple_id, call_id, head_pos}`; the callee reads `call_signals` by `call_id` over plain HTTP and appends its answer via an RPC. Channel joins happen in parallel, off the critical path. This is what keeps the revision from adding two private joins and an HTTP round trip inside a 35 s caller timer that `inventory/calls.md:70` already says "routinely does not fit."
- **Glare resolves on `pos`** — a total order over a value both peers already have, server-assigned, no clock. The lower `pos` offer wins.
- `rt:` keeps gestures and game state only.

The call *state machine* (busy, declined, reconnecting, cancellation, notification dismissal) belongs to the calling domain; this document specifies only the transport contract it rests on.

---

## J. What moves off postgres_changes, quantified

| | Before | After |
|---|---|---|
| `onPostgresChanges` call sites | 16 (verified this session) | 0 |
| `.channel(` call sites | 29 (verified) | 4, all in the transport |
| Public tables in `supabase_realtime` | ~28 | 0 → poller creates **no replication slot** |
| REPLICA IDENTITY FULL tables | ~28 | 0 (DEFAULT) |
| Authorization work per row change on **your** Postgres | O(all project subscribers to that table) | O(1) insert into `realtime.messages` |
| Documented throughput | 30 changes/s (RLS, 500 clients); 40/s on a 16XL | 10,000 msg/s (broadcast-from-DB benchmark, 80,000 concurrent) |
| Presence DB writes | ~18/user/min chat-open, ~3/user/min idle | ~2 per session per user |
| Channel joins per app resume | 1 close + 1 open + N leaves + N joins, N=5–10 | 0 (probe passes) or 3 (socket replaced) |
| Always-on channels per device | 5 (→10 peak) | 3 (→4) |

**The number that moves against you:** `postgres_changes` bills 1 message per listening client (2 per couple); broadcast bills 1 send + 1 per receiver (3 per couple). **+50% per event.** Swamped by the event-count collapse, but stated because it is the term that surprises people.

**Presence-attributable billable messages — the largest single line.** Today, at a conservative all-day average of 3 presence writes/user/min × 2 recipients ≈ **259,000 billable/user/month**; at the 18 writes/min chat-open rate, ~1.04M. **The Free tier's entire 2M monthly allowance is consumed by presence heartbeats at ~11 users — or at 2 users if they actually chat.** After migration: ~16 transitions/day × 3 ≈ 1,440/user/month. ~180× reduction, and the single highest-leverage change in the system.

## Invariants
- POSITION ORDER IS COMMIT ORDER, AND ALLOCATION IS UNBYPASSABLE. A position is allocated only by a BEFORE INSERT/UPDATE/DELETE trigger on the entity table, doing `UPDATE couple_cursor SET next_pos = next_pos + 1 ... RETURNING` inside that row's own transaction. The row lock makes a second appender block until the first commits or aborts, so P+1 cannot become readable before P. Because it is a trigger and not an RPC, PostgREST inserts (chat_repository.dart:228/249/279/309), future screens and the SQL editor are all covered — there is no write path that can commit an entity row that is never advertised and never appears in a catch-up read. Enforced by: Postgres trigger + CI assertion that every table in the stream vocabulary has an append trigger and a NOT NULL stream_pos.
- THE CURSOR ADVANCES ONLY TO A POSITION THE CLIENT HAS READ FROM THE DATABASE. A `pos` arriving on the socket is never stored — not in the cursor, not in a highest-seen variable, not in a pending-gap set. The doorbell is a one-bit signal meaning 'go read'. The cursor moves to a row's own `pos` only after that row's local apply commits. Therefore a dropped, duplicated, reordered, replayed, absurd or FORGED doorbell costs at most one redundant range query, and can never cause divergence — including in the case where Realtime's write-deny on the doorbell topic turns out not to hold. Enforced by construction: the reconciler has no code path from a socket frame to the cursor store.
- THE DOORBELL CARRIES NO STATE, BECAUSE IT HAS NOWHERE TO CARRY IT FROM. The trigger fires on couple_stream, which holds only couple_id, pos, stream, entity_id, op. It is not a trigger on the entity table and cannot see the entity row. The payload is {stream, pos, entity_id}; entity_id is a fetch hint whose only effect is to turn a range read into a single-row read. Enforced by construction: table shape, not policy.
- THE DOORBELL TOPIC IS NOT CLIENT-WRITABLE. `cs:{couple_id}` and `dev:{user_id}:{device_id}` have a SELECT policy on realtime.messages and deliberately no INSERT policy; they are written only by SECURITY DEFINER functions calling realtime.send, owned by a role not subject to those policies. Client-writable ephemeral traffic (typing, screen, Presence, gestures) lives on `cl:` and `rt:`. This is the fix for the fact that Realtime caches one per-topic verdict at join and cannot condition it on a per-message event name — verified in realtime_client 2.8.0: sendBroadcastMessage pushes over the joined channel with no per-message check, and the REST fallback posts {topic,payload,event,private} under the same bearer.
- A POSITION CANNOT BE ADVERTISED BEFORE IT IS READABLE, AND A REALTIME FAILURE CANNOT ROLL BACK A USER WRITE. realtime.send inserts into realtime.messages inside the appending transaction; Realtime reads it from the WAL only after commit, so a rolled-back append advertises nothing. realtime.send catches its own exceptions and reports via pg_notify rather than raising. Both source-verified in the Phase-1 research.
- A STREAM POSITION SURVIVES ITS ENTITY. clear_conversation_everyone() hard-deletes every message row for a couple, so rows disappear beneath cursors as a matter of routine. The couple_stream row is the position; the entity row is the payload. A catch-up read that joins to a missing entity advances anyway. Per-row deletes append op='delete'; the bulk purge appends exactly one op='purge' position with the per-row trigger suppressed by a transaction-local flag. couple_cursor.next_pos never decreases.
- NO CLOCK ENTERS ANY CONTROL DECISION. created_at is display-only and is never compared — Postgres now() is transaction-start time, identical for every statement in a transaction and not monotonic across overlapping transactions. Ordering is `pos`. Freshness of the token is asserted by auth.refreshSession() succeeding, not by arithmetic on session.expiresAt against a device clock. Liveness is a server-generated nonce, not a timeout on a timestamp. Glare is resolved on `pos`.
- NO CHANNEL IS JOINED UNTIL THE SERVER HAS ASSERTED THE TOKEN. On cold start and after any long gap the transport calls auth.refreshSession(), calls realtime.setAuth with that token itself, and asserts each channel reaches `joined`. This exists because the join verdict is cached for the connection lifetime, so a channel joined with a stale JWT is silently unauthorized — it does not error, it stops being right — and because supabase 2.13.0 (supabase_client.dart:375-394) catches and silently swallows FormatException: InvalidJWTToken exactly in the cold-start window. Enforced server-side: the refresh either succeeds at the auth server or the join does not happen.
- LIVENESS IS DECIDED ONLY BY A PROBE THAT IS GUARANTEED TO PRODUCE A DOORBELL. sync_head calls realtime.send({nonce},'probe','cs:'||couple_id) before returning. Absence of that doorbell within the window is proof the socket is dead; a quiet partner cannot manufacture a false negative, which is what made the previous 'wait for a doorbell after draining backlog' test unfalsifiable and turned every 30-second gap into a socket teardown. Enforced server-side: the probe originates in the RPC, not in the client.
- THE SOCKET HAS NO AUTHORITY. Every position is obtainable over HTTP via sync_head plus a couple_stream range read; FCM carries {couple_id, head_pos} and drives the same path. A socket that will not connect, will not join, or is disconnected by a quota is a latency ceiling, never a correctness one. This is what satisfies 'nothing may depend on a reliable socket' — the socket is removed from the correctness argument entirely.
- AUTHORIZATION COST IS O(JOINS), NOT O(SUBSCRIBERS x ROW CHANGES), AND THE POOL THAT SERVES IT IS A NAMED DEPENDENCY. Realtime computes the verdict once per join and caches it; joins/sec is a quota you can see and stagger against, with the stagger window supplied by the server as join_budget_ms. postgres_changes evaluates RLS per subscriber per row change inside apply_rls, whose loop is over every subscription to that table project-wide and is unimprovable by compute (30 -> 40 changes/s from Micro to 16XL). DB_POOL_SIZE must be raised from its default of 5 and the chosen number recorded; the join policy is one primary-key lookup wrapped as (select ...) with TO authenticated.
- A TOPIC NAME IS NOT A CAPABILITY. Every channel is private and RLS-gated at join. The couple UUID is already public — it is the first path segment of every couple_media URL — so any design in which knowing it grants access is already breached. Today it grants live SDP and ICE, raw GPS every 4 seconds, and message plaintext. A topic string is also unconstructible without a non-null couple id, which makes the cross-tenant `mood_lamp:none` topic unrepresentable rather than fixed.
- EPHEMERAL STATE NEVER ENTERS THE WAL AND NEVER WAKES A DEVICE. Typing, screen, gestures, cursors and liveness have no durability and no audit requirement. Anything written to a published table becomes a WAL record decoded by wal2json on your own database CPU and then multiplied by subscriber count; anything that generates an FCM push burns quota and battery for a signal worthless late. Monotone watermarks (delivered/read) also stay out of the stream: they are greatest()-advanced rows read on catch-up, because a watermark cannot be lost, only delayed.
- COMPACTION IS GATED ON A SERVER-SIDE PER-DEVICE APPLIED POSITION, AND BOOTSTRAP IS BOUNDED BY A CHECKPOINT READ BEFORE IT STARTS. couple_member_cursor(couple_id, user_id, device_id, applied_pos) is advanced only by a greatest() RPC. pg_cron deletes couple_stream rows at or below min(applied_pos) over devices seen in 30 days, hard floor 90 days. Per-device rows stop one device pushing the floor past another. Resync reads head_pos = H first, pages entity tables filtered stream_pos <= H, then sets the cursor to H — reading H afterwards would silently skip everything appended during the bootstrap.
- THERE IS EXACTLY ONE SUPABASE CLIENT, ONE SOCKET, AND ONE CHANNEL OWNER, ROOTED ABOVE THE DISGUISE COVER. The transport is a process-lifetime singleton constructed in main() before runApp, because main.dart:213-231 forces showRealApp = false on every paused/hidden/detached and unmounts AppShell with it. It is headless: no UI, no notification, no Telecom registration — the launcher disguise is untouched. Features register handlers and never call .channel(). Enforced by a static CI test asserting no source file outside the transport constructs a channel topic or calls sendBroadcastMessage.
- OUTBOUND RATE IS SHAPED IN EXACTLY ONE PLACE, ABOVE THE SDK. A single send path applies a byte-rate token bucket sized under TENANT_MAX_BYTES_PER_SECOND = 100 KB/s project-wide, a per-topic latest-wins coalescing tick, and an 8 KB payload ceiling — and refuses to send when the channel is not joined, which is exactly when the SDK silently falls back to POST /api/broadcast (realtime_channel.dart:633-668). This is the one invariant in this document that is NOT server-enforceable; see accepted limits.

## Scale ceiling
Assumption throughout: users = individuals, 2 per couple, 1 device each, peak concurrency **8% of registered** — a mobile-social rule of thumb that Stage 0 exists to replace with a measurement. Three always-on channels per device.

### 1,000 users (~80 peak concurrent devices)
- 240 channels. A total correlated reconnect is 240 joins; against Pro's 500 joins/s quota, and against an authorization pool raised to 20 (~2,200 evals/s at 9 ms, ~10,000/s at 2 ms for a PK lookup), this fits with large headroom even without stagger.
- Steady-state ~5 msg/s. Postgres: publication empty, no replication slot, no poller, no wal2json. Presence writes ~11/min project-wide.
- **No architectural pressure of any kind.** Free's 100 msg/s would technically fit; its 2M/month allowance would not.

### 10,000 users (~800 peak concurrent devices)
- Exceeds Pro's capped 500 connections → the **spend cap must be disabled**. 2,400 channels.
- Steady-state ~50 msg/s. Peak with 5% of devices in an interactive session at 10 events/s: 40 × 10 × 3 = **1,200 msg/s** against the 2,500/s no-spend-cap ceiling — fits with ~2× headroom.
- **The binding limit is join capacity under correlated reconnect, not msg/s.** 2,400 joins arriving in a Full-Jitter-spread burst against an authorization pool of 5 at ~9 ms is ~550 evals/s — a ~4.4 s minimum spread; joins queue behind the pool, hit the client's 10 s channel timeout, get retried, and amplify into `too_many_joins`. The previous design's stated "~2× headroom" was measured against the wrong quota, and its verification assertion (`p99 join spread > 400 ms`) was calibrated to the same wrong number.
- **Two things make it fit, and both are explicit dependencies rather than assumptions:** `DB_POOL_SIZE` raised to ≥20 in the dashboard, and `join_budget_ms` returned by `sync_head` — a server-tunable stagger window, default 10,000 ms at this scale, adjustable without an app release.
- **Failure mode if either is omitted:** `too_many_joins` → retry amplification → sustained reconnect loops, which Supabase documents as a top cause of manual suspension (`RealtimeDisabledForTenant`: connections refused, existing subscriptions silently stop delivering, support ticket to lift). That is the honest ceiling — an outage with a human in the loop, not graceful degradation.
- **What still works during that outage:** everything. Every position is reachable over HTTP.

### 100,000 users (~8,000 peak concurrent devices)
- 24,000 channels. 8,000 connections is **80% of the 10,000 hard cap**, which Team ($599) does not raise. A viral day or a push-induced thundering herd goes over, and over means `too_many_connections` — a refusal, not a larger invoice.
- 24,000 joins in a correlated reconnect at ~2,200 evals/s needs ~11 s of spread; `join_budget_ms` = 30,000. Workable, but it means 30 seconds to full socket coverage after a regional event — during which the app is fully functional over HTTP.
- Steady-state ~170 msg/s. **Peak with 5% in interactive sessions: 400 × 10 × 3 = 12,000 msg/s — roughly 5× over the 2,500 msg/s Team ceiling. Hard stop, not an overage.**
- **The binding term is interactive-session broadcast, not chat.** Chat, presence, receipts and probes together are ~170 msg/s; gesture/game/watch-together traffic is ~70× that at peak. It is also the term with the widest error bar — the 2-sessions-per-week assumption is a guess.
- Exits, in order of preference:
  1. **Self-host Realtime** (Elixir, `MAX_CONNECTIONS=16384`/node) against managed Postgres. Removes the connection cap, the msg/s cap and the suspension risk. The design ports unchanged because it uses only documented Realtime primitives. **This is the recommendation, and it replaces the previous document's recommendation.**
  2. **Move `rt:` onto the WebRTC data channel — but only when the peer connection is not relayed.** The app's own `CallStatsMonitor` already resolves the selected candidate pair and reports relay-vs-p2p, so this is a measurable runtime gate, not an assumption. For relayed pairs it falls back to `rt:`. The previous document priced this exit at zero; it is not zero (see cost), and it depends on TURN, whose own fallback banner currently reads that calls only work on the same wifi.
  3. Enterprise quota.

### The ceiling already breached today
None of the above is the current problem. On the present design, `postgres_changes` demand exceeds supply at **~100 concurrently-active users** (~0.3N changes/s from presence alone against 30/s supplied with RLS at 500 clients), and the published curve degrades as clients are added: 1,500 clients → 10 changes/s, 3,000 → 5. At 1,000 users you are 5–45× over a ceiling that money does not move — Micro to 16XL is a ~370× price increase for 30 → 40 changes/s. Separately, presence heartbeats alone exhaust Free's 2M monthly messages at **~11 users**. **The app is past its architectural ceiling at two-digit user counts today, and the only reason it has not manifested is that it has two users** — two clients is the best case for the `apply_rls` loop, which is precisely why two test phones cannot reveal it.

## Cost
All figures Supabase list price. **Billable messages = events × (recipients + 1)** — a couple topic with both clients joined bills **3** per broadcast. Connections bill on **peak for the cycle**, in whole 1,000-packages at $10.

### Event budget per user per day, rebuilt bottom-up

| Source | Events/day | Billable/day |
|---|---|---|
| Chat messages sent → doorbell on `cs:` | 25 | 75 |
| Receipt watermark hints on `cl:` (coalesced ≤1/s; **not** stream appends) | 25 | 75 |
| Typing (Signal cadence ≈ 3 per composed message) | 75 | 225 |
| Presence transitions (8 sessions × 2) | 16 | 48 |
| Screen/misc control | 20 | 60 |
| **Liveness probes** (≤1 per 10 s, ~10/day) — *new line, was missing* | 10 | 30 |
| **Subtotal — chat-only user** | ~171 | **~513** |
| Interactive sessions (touch/games/watch-together): 2/week × 3 min × 10 Hz, amortised | ~500 | ~1,500 |
| **Total — user who uses interactive features** | ~671 | **~2,013** |

**~15k–60k billable messages/user/month; planning midpoint 30,000.** Higher than research/supabase.md's 18,000, because that figure never priced the interactive-canvas features — the largest, most variable, and only designable-away term.

Moving receipts out of the stream (they are monotone watermarks, so the cursor buys nothing) removes ~25 stream appends and ~50 durable writes per user per day versus the previous design, at no correctness cost.

### 1,000 users
| Line | $/mo |
|---|---|
| Pro base | 25.00 |
| Messages: 30M − 5M included = 25M × $2.50/M | 62.50 |
| Peak connections ~80, under Pro's 500 | 0 |
| Compute Micro, covered by Pro's $10 credit | 0 |
| `couple_stream` storage + `pg_cron` compaction (~0.9 MB/user/yr pre-compaction; near zero for active couples) | ~0 |
| **Total** | **~$88/mo** |

Free is not viable and is not close: 30M against a 2M allowance with no overage — it fails closed. On the *current* design Free fails at ~11 users on presence heartbeats alone.

### 10,000 users
| Line | $/mo |
|---|---|
| Pro base (spend cap **disabled**) | 25.00 |
| Messages: 300M − 5M = 295M × $2.50/M | 737.50 |
| Peak connections ~800 → 1 package | 10.00 |
| Compute Small | 15.00 |
| `couple_stream` + compaction | ~2 |
| **Total** | **~$790/mo** |

Messages are **93% of the bill**. On the current `postgres_changes` design this configuration does not exist at any price.

### 100,000 users
| Line | $/mo |
|---|---|
| Pro base | 25.00 |
| Messages: 3B − 5M = 2,995M × $2.50/M | 7,487.50 |
| Peak connections ~8,000 → 8 packages | 80.00 |
| Compute Large | 110.00 |
| Egress ~2 TB private media, mostly uncached | 157.50 |
| Storage ~2 TB | 40.00 |
| `couple_stream` (~90 GB/yr pre-compaction, far less after) + `pg_cron` | ~20 |
| **Total** | **~$7,920/mo — and Team does not grant the 12,000 msg/s peak this requires.** |

### Corrections to the previous cost model

1. **"Do not subscribe the sender to its own doorbell — a flat 33% cut" is deleted.** It is unachievable: the doorbell is a DB broadcast to a shared topic and Realtime has no per-recipient suppression. A *real* variant exists — send the doorbell to the partner's `dev:` topic instead of `cs:`, billing 1 send + 1 receiver = 2 — but it requires the trigger to enumerate the partner's devices from `couple_member_cursor`, it degenerates back to 3 when the partner has two devices, and it only touches the doorbell line (~15% of a chat-only user's messages, less once interactive traffic dominates). Listed as an option, not a plan.
2. **The WebRTC-data-channel exit is not free.** `inventory/calls.md:35` records Cloudflare Realtime TURN as billed on **relayed bandwidth**, with no server-side quota, no per-user cap and no per-call credential scoping, and credentials cached 24 h in plaintext SharedPreferences. The brief's own scenario — two strangers, different carriers, symmetric NAT — is 100% relayed, so routing the ~500 daily interactive events through it would push 75% of the message volume onto metered relay for exactly those users. The `$7,487 → ~$1,800` line in the previous document was not a saving. Before this exit can be load-bearing: price relay GB at the projected gesture volume, add a server-side per-user credential-mint cap, and scope credentials per call. Until then the 100k exit is self-hosted Realtime.
3. **The token bucket is sized in bytes, not messages.** The previous design correctly identified `TENANT_MAX_BYTES_PER_SECOND=100_000` as binding and then sized the bucket in msg/s and planned for 12,000 msg/s. 100 KB/s project-wide is the number the bucket is built against; whether the hosted plans enforce that exact figure project-wide is **unverified** and is flagged, not assumed.

**Cost is ~90% Realtime messages at every scale past 1,000 users, and it is superlinear in engagement rather than in users.** The budget is set by the rate limits in the transport's send path, not by growth.

## Migration
Ten stages. Each is independently shippable, independently revertible, and depends only on stages before it. **No stage deletes a recovery mechanism before its replacement exists** — that is the specific failure the previous plan committed and the reason it is reordered.

**Stage 0 — Observability. No behaviour change.**
Instrument through a logging hook: joins attempted/succeeded/rejected, **measured joins per second**, socket opens per user-hour, time-to-caught-up on resume, and `head_pos − local_cursor` at resume. Dump the **actual** `pg_publication_tables` for `supabase_realtime` — `inventory/realtime.md` warns the repo is not the source of truth, and three tables the client subscribes to (`care_nudges`, `love_reasons`, `cycle_events`) have no checked-in definition or publication membership, meaning four live subscriptions may be delivering nothing right now and nobody would know. Add a server-read `app_config` row so later stages have a **remote kill switch** (`feature_flags.dart` is build-time only and cannot roll anything back without a release). **You have never had a baseline. Get one before changing anything.**

**Stage 1 — Close the live data leaks. Highest value per risk; ship first.**
1a (server, additive): RLS policies on `realtime.messages` for the **current** topic names — `call:<id>`, `capsule_proximity:<id>`, `mood_burst:<id>`, `mood_lamp:<id>`, `screen_presence:<id>`, `touch:<id>` and the rest. In the same migration, wrap every `current_user_couple_id()` call site as `(select public.current_user_couple_id())` and add `TO authenticated` across all existing policies — **a pure win on the REST path regardless of anything else here** (179 ms → 9 ms; 170 ms → <0.1 ms). Raise `DB_POOL_SIZE` to ≥20 and record the number.
1b (client, flag-gated): add `config: {private: true}` to those channels; call `auth.refreshSession()` before the first join; fix `mood_lamp:none` to refuse to construct a topic without a couple id.
This is a small diff and it is **the only change on the list that closes a breach rather than preparing for one**: today `call:<coupleId>` carries live SDP and ICE, `capsule_proximity:<coupleId>` broadcasts raw GPS every 4 s, and `mood_burst:<coupleId>` carries message plaintext, all joinable by anyone with the anon key and a couple UUID that is the first path segment of every `couple_media` URL. The previous plan scheduled this last, behind the largest client refactor.

**Stage 2 — The transport singleton and the reconnect loop. Client only.**
Introduce the transport in `main()` **above `MilesApp`**, owning the socket and the reconnect loop only; features keep their own channels. Replace `client.realtime.reconnectTimer` with a `RetryTimer` over Full Jitter `random(0, min(30_000, 1000·2^n))`; set `heartbeatIntervalMs` explicitly. This requires `import 'package:realtime_client/src/retry_timer.dart'` (an `implementation_imports` lint), an **exact version pin** on `realtime_client`, and a unit test that fails if `reconnectTimer` stops being assignable — priced as a dependency-shape change, not a one-line config change. Define sign-out teardown. **Do not touch `app_shell.dart:70-79`.** The forced disconnect is the only doze recovery that exists, and deleting it here would trade a reconnect storm for up to ~50 s of silent non-delivery on every resume.

**Stage 3 — The stream, write side only. Nothing reads it.**
Create `couple_cursor`, `couple_stream`, `couple_member_cursor`. Add `stream_pos` and a `BEFORE INSERT/UPDATE/DELETE` append trigger to `messages` **only**. Add `sync_head` returning `{head_pos, floor_pos, server_now, join_budget_ms}` — **without** the probe broadcast yet. Wire `server_now` into `ServerClock` **now**, so its feed exists before Stage 6 deletes `presence_service.dart:206`, its only current caller. Backfill positions in `(created_at, id)` order — structurally identical to the existing `seq` backfill at `receipts_v2.sql:33-46`, so the pattern is already proven in this repo. Zero user-visible change; reversible by dropping three tables.

**Stage 4 — Chat only, dual-path. The template for every subsequent stream.**
Add `cs:{couple_id}`, the doorbell trigger on `couple_stream`, and the read-only write policy. **Gate test first:** assert a signed-in member cannot broadcast to `cs:` over the socket *or* over `POST /api/broadcast`. If that assertion fails, the design is still correct (no `pos` from the wire reaches the cursor) but the finding must be recorded and the doorbell rate-limited on the client. Chat subscribes to **both** the doorbell and the existing `messages:{id}` postgres_changes, dedupes by message id (`chat_screen.dart`'s `_ids` set already does this), and reconciles from the stream. Run both a week and measure in the field: the new path is correct when the doorbell arrives before or with the postgres_changes event for 100% of messages and gap-detected count matches socket-drop count. **Then delete the postgres_changes leg.**

**Stage 5 — The self-answering probe replaces the forced disconnect.**
Add the `realtime.send({nonce},'probe','cs:'||couple_id)` call inside `sync_head`. Only now delete `app_shell.dart:70-79` and replace it with the probe. This is the earliest point at which deleting it is safe, because both `sync_head` and a guaranteed doorbell now exist. Probe fires ≤1 per 10 s per device, single-flighted; probe absence → force `disconnect()`/`connect()`.

**Stage 6 — Presence off Postgres. Largest single win.**
`track`/`untrack` on `cl:{couple_id}`; write last-seen on the `leave` event and app pause only. Delete the 30 s heartbeat (`main.dart:191-209`), the 5 s `chat_last_read` write (`chat_screen.dart:495` — `chat_receipts` already carries the read watermark and `inventory/realtime.md:88` flags it as redundant), the 15 s liveness poll, and the presence-row dependency in the 15 s location timer. Drop `presence` from the publication; `REPLICA IDENTITY DEFAULT`. Removes ~1,600× of presence write volume and ~180× of presence-attributable billable messages. The current 5 s re-stamp violates Presence's 5-calls-per-30 s cap and has to go regardless.

**Stage 7 — Remaining streams, one per ship.** reach, capsules, the Closer set, then **call signalling** (`call_signals` + `stream='call'`, ring path over HTTP, glare on `pos`). Stage-4 pattern each time. After the last: `ALTER PUBLICATION supabase_realtime DROP TABLE` for everything remaining and `REPLICA IDENTITY DEFAULT` across ~28 tables; the poller then declines to create a replication slot.

**Stage 8 — Deletes, purge and compaction.** Per-row delete tombstones; `clear_conversation_everyone` rewritten to append one `op='purge'` position with the row trigger suppressed; the `couple_member_cursor` reporting RPC; the `pg_cron` compaction job; the `resync_required` bootstrap path. Deliberately after the streams exist, because a compaction job with no cursor reports would delete rows a device still needs.

**Stage 9 — Feature migration onto `cl:`/`rt:`, one feature per ship.**
This is where the previous plan's Stage 7 was a big bang: 29 `.channel(` sites and 6 hand-rolled resubscribers in one unrevertable PR, because the whole mechanism is that features stop calling `.channel()`. Split it: each feature moves to a transport-registered handler with its old channel left in place behind the Stage-0 remote flag for one release. Consolidation becomes N small reverts instead of one large one. The two known races (`partner_here_badge.dart:59`, `touch_trace_canvas.dart:89`) are deleted rather than fixed as their features migrate.

**Stage 10 — CI enforcement.** Assert `pg_publication_tables` for `supabase_realtime` contains zero `public` tables; assert every table in the stream vocabulary has an append trigger and a `NOT NULL stream_pos`; assert no source file outside the transport constructs a channel topic or calls `sendBroadcastMessage`; assert `realtime.reconnectTimer` is still assignable on the pinned SDK version. Mechanically checkable invariants are worth more than review conventions.

**Rollback posture.** Stages 0, 3, 4 (server half), 8 and 10 are additive. Stages 1, 2, 5, 6, 7, 9 each touch one subsystem and revert either by a flag flip (1b, 9) or by re-enabling a leg deliberately left in place for a release. **There is no point in the sequence where both the old and the new path for any signal are absent, and no point where a recovery mechanism is removed before its replacement is live.**

## Verification
**Premise: every previous fix passed on two NTP-synced phones on one wifi and then failed in production, because that setup cannot produce any of the actual failure modes.** Two legitimate members cannot test an authorization boundary. A healthy wifi cannot produce a silently-dead socket. Two humans cannot tap send within the same millisecond on demand. A carriage of commuters cannot be simulated by two phones. Every check below runs on one machine, or one machine plus one phone over USB.

**1. Two clients in one process, local stack.** `supabase start`; one Dart test binary; two `SupabaseClient` instances signed in as the two partners of a synthetic couple, plus a third unrelated user.
- Partner B joins `cs:{X}` and `cl:{X}` → succeeds. **The third user joins either → rejected at join.** Structurally untestable with two phones, because both phones are legitimate members. This is the check that would have caught SDP, ICE and raw GPS being readable by anyone with a couple UUID.
- **Write-deny gate (Stage 4 blocker):** partner B, joined to `cs:{X}`, attempts `sendBroadcastMessage` → must be rejected; then B `POST`s `{topic:'cs:X', event:'stream', payload:{...}, private:true}` to `/api/broadcast` under its own bearer → must be rejected. If either succeeds, record it as a confirmed platform finding and rate-cap the doorbell handler; the design remains correct because no wire `pos` reaches the cursor, and test 3b proves that independently.
- Static test over the source: no topic string is constructible without a couple id (kills `mood_lamp:none`); no `.channel(`/`sendBroadcastMessage` outside the transport.

**2. Deterministic fault injector as the transport's only seam.** A `TransportFault` hook that can (a) drop the socket, (b) **hold it open while swallowing all inbound frames** — the Android-doze silent death, which a healthy wifi never produces, (c) delay or fail `sync_head`, (d) present an expired JWT at join, (e) **force the SDK's `canPush == false` REST fallback path**. Every historical multi-week outage in this app is one of (a)–(d), and none is reachable by unplugging wifi. Assertions: under (b) the probe detects death within its window and replaces the socket; under (d) no channel is joined and `refreshSession` is attempted; under (e) the transport refuses the send rather than silently POSTing.

**3. Property tests against local Postgres.**
- **3a — position invariant.** K concurrent transactions appending to one couple with randomised commit delays and rollbacks. Assert: positions form a dense prefix `1..N` with no holes; a reader polling `pos > cursor` never observes P before P−1; replaying any observed prefix yields the identical entity set. **Run the same test against the current `nextval('messages_seq_seq')` design and it must fail** — that converts "there is a silent message-loss bug when both partners send simultaneously" from an assertion into a reproducible failure.
- **3b — forged/absurd doorbells (this is the fatal-flaw-1 regression guard).** Feed the reconciler doorbells with `pos` values that are stale, duplicated, one-ahead, wildly ahead (`2^40`), and referencing nonexistent `entity_id`s, interleaved with real appends. Assert the cursor equals `max(pos actually read from the database)` at every step, that no forged value is ever persisted, and that the final entity set matches the database exactly.
- **3c — hard purge under the cursor.** Append 500 chat positions, drain to cursor=500, run `clear_conversation_everyone`, assert: exactly one new position is appended, the cursor does not rewind, a re-fetch of the old range returns stream rows with missing entities and advances rather than erroring, and both clients converge on empty.
- **3d — bootstrap checkpoint.** Start a resync while a writer appends continuously. Assert the client reads `head_pos` before paging, that no position in `(0, H]` is missed, and that appends during the bootstrap are drained afterwards.
- **3e — compaction with two devices.** Device A advances `applied_pos` to head while device B stays at 10. Assert compaction floors at 10; assert B never receives `resync_required`; assert B does after the 90-day cap.
- **3f — append bypass.** Insert directly into each streamed entity table via raw SQL, bypassing every RPC. Assert `stream_pos` is populated and a `couple_stream` row exists. This is the test that catches "the row commits, is never advertised, and both clients report caught-up."

**4. Reconciler unit tests, no network.** In-order, duplicate, far-ahead, below-retention, entity-missing, purge, and `resync_required` sequences. Assert `resync_required` is reached rather than an unbounded backfill.

**5. Reconnect-storm simulation, one process.** 200 transport instances against the local stack; drop all at t=0; measure the join-arrival histogram. **Two corrections to the previous plan's version of this test:** (i) the assertion is not a hardcoded `p99 > 400 ms` but `p99 spread ≥ N_joins ÷ measured_joins_per_sec` from Stage 0, because the binding limit is the authorization pool, not the msg/s quota; (ii) the local self-host default is `TENANT_MAX_JOINS_PER_SECOND=100`, so the test must raise it (or scale N down) or it fails for the wrong reason before it measures jitter. It must still fail deterministically on the current code, where `retry_timer.dart` returns `firstDelay << shiftAmount` with **no jitter term in the file**.

**6. Glare and ring, single device.** Two in-process clients append `offer` positions concurrently; assert both resolve on the lower `pos` and exactly one call proceeds. Ring path: assert the callee reaches `ringing` from an FCM payload with **no channel join at all** — HTTP read of `call_signals` only.

**7. Single-phone Doze and radio tests, scripted.** `adb shell dumpsys deviceidle force-idle` (real Doze), `adb shell cmd connectivity airplane-mode enable/disable` (real radio drop), `adb shell am kill <pkg>` (real LMK). Partner side is a Dart process on the laptop. Also assert the transport survives `showRealApp = false`: background the app, confirm the socket and cursor persist and a doorbell delivered while the cover is up is drained on return.

**8. Field telemetry as the actual verification.** Joins attempted/succeeded/rejected, measured joins/s, time-to-caught-up per resume, probe round-trip latency (the nonce gives a free sample), gap-drain size, `resync_required` count, REST-fallback count (should be zero), and the `head_pos − local_cursor` histogram at resume. **A fix is verified when the field histogram moves, not when it works on the desk.** None of this exists today, which is exactly why "it worked on two phones" was the only evidence available.

---

**Flagged gaps — nothing above has been executed.** I ran no tests. What I verified mechanically in this session, with commands and output shown in-session:
- `grep -rn "\.channel(" mobile/lib | wc -l` → **29**; `onPostgresChanges` → **16**; `sendBroadcastMessage|httpSend` → **31**.
- `supabase-2.13.0/lib/src/realtime_client_options.dart` — exactly four fields, `eventsPerSecond` deprecated-and-ignored; `supabase_client.dart:337-352` forwards neither `reconnectAfterMs` nor `heartbeatIntervalMs`.
- `supabase_client.dart:375-394` — forwards `tokenRefreshed`/`signedIn`/`initialSession` to `realtime.setAuth` and **silently swallows `FormatException: InvalidJWTToken`**.
- `realtime_client-2.8.0/lib/src/realtime_client.dart:103,113,118,203-211` — `heartbeatIntervalMs` and `reconnectTimer` are public mutable fields; `reconnectAfterMs` is captured by value at construction and is a no-op if assigned later. `lib/realtime_client.dart` does **not** export `src/retry_timer.dart`.
- `realtime_client-2.8.0/lib/src/retry_timer.dart` — `firstDelay << shiftAmount` capped at `maxDelay`; **no jitter term in the file**.
- `realtime_channel.dart:618-700` — `send()` falls back to `POST /api/broadcast` with `{topic, payload, event, private}` under the same bearer when `!canPush`.
- `supabase/receipts_v2.sql:28-31` — `messages.seq` is a project-global `nextval`; `:78-110` — `ack_delivered`/`ack_read` are `SECURITY DEFINER` with `greatest()`.
- `supabase/clear_chat_everyone.sql` — `clear_conversation_everyone()` hard-`DELETE`s every message row for the couple.
- `supabase/schema.sql:105-114` — `current_user_couple_id()` is STABLE SECURITY DEFINER, called **unwrapped** in every policy; `hardening_2026_08.sql:57-70` — `guard_couple_id` blocks client writes to `profiles.couple_id`.
- `mobile/lib/core/services/server_clock.dart` + `grep -rn "ServerClock"` — `observe` has exactly **one** caller, `presence_service.dart:206`; `_offset` is `Duration.zero` and `_known` false until then.
- `mobile/lib/main.dart:213-231` — `showRealApp.value = false` on `paused`/`hidden`/`detached`; `mobile/lib/features/shell/app_shell.dart:62-80` — unconditional `realtime.disconnect()/connect()` on resume.
- `mobile/lib/core/feature_flags.dart` — build-time constants only; there is no remote kill switch today.

Everything else — throughput factors, cost tables, scale ceilings — is arithmetic over Supabase's published benchmarks and quotas as recorded in the Phase-1 research, applied to the cadences in the Phase-1 inventory. **It is not measurement of this app.** The 8% peak-concurrency assumption and the 2-interactive-sessions-per-week assumption are the two inputs that most move the cost table, and both are guesses that Stage 0 exists to replace.

## Accepted limits
**1. Outbound rate cannot be server-enforced. This is the one invariant that is client-honoured.**
The SDK removed its own client rate limit (`eventsPerSecond` is deprecated and ignored) and Supabase's limits are **project-wide**: `TENANT_MAX_BYTES_PER_SECOND = 100_000`, `TENANT_MAX_EVENTS_PER_SECOND`, `TENANT_MAX_JOINS_PER_SECOND`. There is no per-couple byte cap to hide behind. **Residual risk: one stale or modified APK streaming ungated gesture data can trip the project-wide ceiling and cause `tenant_events` disconnects for other couples, and sustained abuse is a documented cause of manual suspension.** Partial mitigations, none complete: the send path is the only caller of `sendBroadcastMessage` and refuses when the channel is not joined (closing the SDK's silent REST fallback); the highest-rate traffic can be removed from Realtime entirely at scale; and the blast radius is bounded to latency, because the durable HTTP path is unaffected and no data is lost. **It cannot be closed on this platform.** The honest statement is that a rogue client degrades everyone's latency and loses nobody's data.

**2. Authorization staleness after a break-up is bounded by the JWT lifetime, not by the unpair.**
Realtime computes the channel verdict once at join and caches it for the connection lifetime, disconnecting only when the JWT expires. `leave_couple()` nulls `couple_id` on both profiles and the client calls `auth.refreshSession()`, and this design adds a `revoked` broadcast that makes a cooperating client tear down immediately. **Residual risk: an ex-partner running a modified client can keep reading `cs:`/`cl:` on an already-open connection for the remainder of its access token's life — up to the JWT TTL, 3600 s by default.** Closable only by shortening the JWT TTL (which buys reconnect churn on exactly the correlated-reconnect path that is already the binding scale limit) or by a Realtime-side revocation primitive that does not exist. Given `hardening_2026_08.sql` shows the project already treats post-break-up access as critical, this is worth a deliberate decision rather than a default (see open decisions).

**3. `join_budget_ms` is a capacity hint, not an enforced quota.**
It is server-supplied and therefore tunable without a release, but a client that ignores it joins immediately. **Residual risk: at 10k+ users a fleet of old builds can still produce a join burst that saturates the authorization pool, and the failure mode is `too_many_joins` → retry amplification → possible manual suspension.** Supabase provides no server-side per-client join admission control. The only real defences are the raised `DB_POOL_SIZE`, the small always-on channel count, and the fact that the app remains fully functional over HTTP while joins are refused.

**4. Doorbell write-deny is unverified against the REST broadcast endpoint.**
I verified from the SDK source that `send()` falls back to `POST /api/broadcast` with the user's bearer, but I could not verify from disk whether that endpoint enforces the `realtime.messages` INSERT policy for private topics. **Residual risk if it does not: a member can inject forged `{stream, pos}` frames onto `cs:`.** The consequence is bounded to wasted database reads by construction, because no `pos` from the wire ever reaches the cursor — that is exactly why the cursor rule is layered under the topic split rather than relying on it. Stage 4 is gated on a test that answers this; if the answer is "not enforced", the finding is recorded and the doorbell handler is rate-capped.

**5. One extra HTTP round trip per received message, deliberately.**
Killing the inline payload costs ~60–200 ms of receive latency that the previous design avoided. Mitigated by `entity_id` (single-row read instead of a range scan) and by the sender's optimistic local echo, so it is one-sided. **This is a conscious trade of latency for the removal of a permanent-silent-divergence class, and it should not be quietly reintroduced later as an optimisation.**

**6. Per-couple append serialisation is a tenant-shape exploit.**
The `couple_cursor` row lock is free with two writers at human speed and unacceptable at hundreds of concurrent writers per tenant. **It does not generalise to group chat.** Also: a bulk purge holds that lock for the duration of its DELETE, briefly blocking the partner's sends.

**7. The 100k msg/s ceiling is not closed, only relocated.**
Peak interactive-session broadcast is ~12,000 msg/s against a 2,500 msg/s Team ceiling — a hard stop, not an overage. The recommended exit (self-hosted Realtime) is an operational commitment, and the alternative exit (WebRTC data channel) is conditional on the peer connection being non-relayed and is unpriced until Cloudflare TURN relay bandwidth is measured. **The 2-interactive-sessions-per-week assumption driving this number is a guess with the widest error bar in the document.**

**8. Nothing here has been executed.** No test in the verification plan has been run. The design's correctness arguments rest on source reading (cited, with file and line) plus published Supabase benchmarks — not on measurement of this app.

## Open decisions
**1. Where the join-time couple lookup comes from: `profiles` or a JWT claim.**
The authorization pool (`DB_POOL_SIZE`, default 5) is the binding limit on correlated reconnect. A custom access-token hook putting `couple_id` into the JWT would make the join policy `realtime.topic() = 'cs:' || (auth.jwt() ->> 'couple_id')` — zero table access, removing `profiles` from the join hot path entirely.
*Recommendation:* **do not do it.** A JWT claim cannot be revoked; it would make accepted-limit 2 (post-break-up staleness) strictly worse and unfixable, on a product where a dissolved relationship's archive is the highest-stakes data. Instead: wrap the existing helper as `(select public.current_user_couple_id())` — it is a single primary-key index probe — raise `DB_POOL_SIZE` to ≥20, and size the join stagger from the throughput Stage 0 actually measures. Revisit only if measurement shows the pool binding after the raise, and if so pair the claim with a shortened JWT TTL and accept the reconnect churn explicitly.

**2. JWT TTL.**
Default 3600 s bounds post-unpair authorization staleness. Shortening it to e.g. 900 s cuts that window 4× and costs 4× the token-refresh-driven reconnects, which lands on the same join-capacity limit that is already the scale ceiling.
*Recommendation:* keep 3600 s until Stage 0 gives real join-throughput numbers, then decide with data. Document the 1-hour window in the privacy copy either way — it is a user-visible property of "disconnect", not an implementation detail.

**3. Where interactive-session traffic runs at scale.**
~75% of the message bill and the sole cause of the 100k hard stop.
*Recommendation:* build `rt:` on Supabase Broadcast now — simple, correct, and right through 10k users — behind an interface so the transport can be swapped without a feature rewrite. When measured peak crosses ~1,000 msg/s, take **self-hosted Realtime** as the primary exit. Use the WebRTC data channel only as a **conditional** optimisation gated on `CallStatsMonitor` reporting a non-relayed candidate pair, and only after Cloudflare TURN gains a server-side per-user credential mint cap and per-call scoping. The previous document made the data channel the recommendation and priced it at zero; that was wrong for exactly the users the brief names — two strangers, different carriers, symmetric NAT, 100% relayed.

**4. Per-device topics and push tokens.**
`profiles.fcm_token` is a single scalar column today, so a second sign-in silently steals push from the first, and `couple_member_cursor` is already per-device.
*Recommendation:* **per-device from day one**, everywhere. The topic name is embedded in an RLS policy and widening it later is a migration under load; the cursor table is already keyed that way; and the single-token column is an active bug in the ring path independent of this design. Move push tokens to a per-device table in Stage 1 or 2.

**5. Compaction floor and the 90-day cap.**
Gating on `min(applied_pos)` over devices seen in 30 days means a partner who stops opening the app pins the log until the 90-day cap.
*Recommendation:* floor at `min(applied_pos)` over devices with `updated_at` inside 30 days, hard 90-day cap, then force `resync_required`. State the product consequence plainly: a partner offline >90 days re-bootstraps and **loses nothing** — the entity tables are intact — but the resync is a large paged read that must show progress, not a spinner.

**6. Whether to shift the doorbell to per-device topics for the 33% billing cut.**
The previous document's "don't subscribe the sender to its own doorbell" lever is deleted as unachievable. The achievable variant is sending the doorbell to the partner's `dev:` topic (1 send + 1 receiver = 2 instead of 3), which requires the trigger to enumerate devices and degenerates back to 3 for a two-device partner.
*Recommendation:* **no, initially.** It touches only the doorbell line — ~15% of a chat-only user's messages and less once interactive traffic dominates — and it couples the doorbell trigger to device registration, which is new machinery in the one place the design most wants to stay boring. Revisit if the doorbell line ever exceeds ~30% of the bill.

**7. Free vs Pro, immediately.**
*Recommendation:* **Pro now, and not for connections.** Two reasons in order: (a) on the current design presence heartbeats alone exhaust the 2M free monthly allowance at ~11 users; (b) the "Private Channel Subscription RLS Execution Time" and "Broadcast-from-Database replication lag" reports are **Pro-and-above only** — on Free you cannot observe whether the new path is falling behind, so you would run the entire migration blind on exactly the two metrics that say whether it worked.

**8. Whether to patch the `messages.seq` cursor hazard before Stage 3.**
The global `nextval` can reveal P+1 before P and permanently lose a message when both partners send within a few milliseconds. Stage 3 fixes it properly.
*Recommendation:* **do not attempt an interim patch.** The only "mitigation" available is fetching `>= cursor − K` with a dedupe window, which is a guess dressed as a fix and would mask the property test in Stage 3 that proves the real thing. Ship Stage 3 sooner instead, and **flag it as a known live data-loss path in the meantime** rather than pretending it is covered.

**9. `realtime_client` version pinning.**
Jitter is installed by replacing `client.realtime.reconnectTimer`, which requires an implementation import of a non-exported file and depends on that field remaining public and mutable.
*Recommendation:* pin `realtime_client` to an exact version, add the unit test that fails if the field stops being assignable, and open an upstream issue asking that `RealtimeClientOptions` forward `reconnectAfterMs` and `heartbeatIntervalMs`. If upstream accepts it, delete the private import. Treat the fork option as a last resort — an unmaintained fork of the socket layer is a worse liability than one lint suppression and one test.
