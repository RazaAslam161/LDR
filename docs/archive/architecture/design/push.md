# Push notification delivery (FCM) — the trigger → pg_net → edge function → per-invocation OAuth → FCM chain that carries every user-visible event in the app

## Current design
**Verified shape, from the code, not the docs.**

Four `AFTER INSERT ... FOR EACH ROW` triggers each call `net.http_post` to a hardcoded URL:
- `reach_notify_on_insert` on `reach_events` (`E:/LDR/supabase/fcm_push.sql:33`) — posts a bare `to_jsonb(new)`, no `kind` wrapper
- `care_notify_on_insert` on `care_nudges` (`E:/LDR/supabase/20260628_care_call_push.sql:40`)
- `call_notify_on_insert` on `call_invites` (`20260628_care_call_push.sql:65`)
- `message_notify_on_insert` on `messages` (`E:/LDR/supabase/message_push.sql:35`)

All four POST to `https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify` with `Content-Type` only — **no Authorization header**, and no `timeout_milliseconds`, so pg_net's documented 2000 ms default applies.

`E:/LDR/supabase/functions/reach-notify/index.ts` then does, per invocation:
1. `getAccessToken()` (L51-90): imports the PKCS8 service-account key, RS256-signs a JWT with `exp: now+3600`, POSTs `oauth2.googleapis.com/token`, and **throws the 1-hour token away**. No module-scope cache.
2. Two PostgREST queries — recipient (`profiles.id, fcm_token`, L140-143) and sender (`profiles.display_name`, L149-153).
3. One `fcm.googleapis.com/v1/.../messages:send`.

Three outbound HTTPS round trips per event, one of them an RSA sign plus a Google token exchange, on a cold V8 isolate, in the critical path of a ring.

**Why it fails, mechanism by mechanism.**

1. **Fire-and-forget with no obligation record.** pg_net is async, post-commit, ~200 req/s project-wide, responses GC'd after 6 h, and *no automatic retry is documented* (`research/supabase.md:147`). A cold start past 2000 ms, an OAuth blip, an FCM 503/429 → the push is gone permanently with no row anywhere saying it was owed.

2. **The function reports success while failing 100%.** Every error path returns HTTP 200 (index.ts:128, 134, 146, 212, 218). The comment says "200 so the webhook doesn't retry-storm". Monitoring sees a healthy function during a total outage. The only evidence is `net._http_response`, which `message_push.sql:39-44` itself names as the sole diagnostic — and it is deleted after 6 hours.

3. **Synchronously coupled to the write path per row.** A `clear_conversation_everyone` or any bulk insert fires one pg_net POST per row into a 200 req/s budget.

4. **`profiles.fcm_token` is one scalar column** (`fcm_push.sql:7`). Second device silently steals the first's pushes; one device's `UNREGISTERED` nulls the token for *all* of them (index.ts:208); `setFcmToken` (`supabase_repository.dart:392-400`) stamps `fcm_token_updated_at` from the **device clock**.

5. **Confirmed privacy leak.** `profiles_select_self_or_partner` (`E:/LDR/supabase/schema.sql:117-120`) is `for select using (id = auth.uid() or couple_id = current_user_couple_id())` with **no column restriction**. `fcm_token` lives on `profiles`. The partner can read the other's FCM registration token over PostgREST — a stable device identifier.

6. **`from_name` ships the partner's real `display_name` in cleartext** through Google (index.ts:154, 165) on a device whose entire product premise is a disguised launcher — and it is never displayed, because the notification text comes from `currentNotificationStyle()` (`reach_notifications.dart:70-72`).

7. **TTL is wrong in both directions.** `ttl: "30s"` for reach/care/call (index.ts:179). For a Reach or a care nudge, 31 seconds in a tunnel means FCM *discards* it and never mentions it again — designed data loss.

8. **No collapse keys at all.** Every push is non-collapsible, so the 100-pending cap applies, and at the cap **all** stored messages are discarded (`research/push.md:40`). `onDeletedMessages` appears nowhere in the codebase (grep of `core/services`: zero hits).

9. **The app is actively training FCM to downgrade it — and the damage lands on calls.** Every chat message is sent `priority: "high"`, and `_onForeground` deliberately posts *nothing* for `type == 'message'` (`fcm_service.dart:139-146`). Android 13+ "downgrades high-priority messages if an app consistently sends them without resulting in a notification" (`research/push.md:36`), and a downgraded message **cannot start a foreground service** — `ForegroundServiceStartNotAllowedException`. Chat volume is therefore burning the exact privilege the call ring depends on. The two "unrelated" broken features share one root cause.

10. **Zero instrumentation.** Grep of `mobile/lib/core/services` for `sentTime`, `originalPriority`, `priority`, `onDeletedMessages`, `getActiveNotifications` and notification `.cancel(` returns **zero hits**. Nothing anywhere records that a push was attempted, accepted, received, or displayed.

11. **Channel-creation asymmetry.** `FcmService.init()` creates reach, care and call channels in the foreground (`fcm_service.dart:51-53`). `buildMsgChannel()` has exactly one call site in the entire codebase — inside the background isolate (`reach_notifications.dart:265`). The message channel is only ever born in the background, which is the precise Android 13 trap (`research/push.md:101`, `:212`).

12. **The function is publicly invocable.** pg_net sends no Authorization header and the function verifies nothing, so `verify_jwt` must be off. Anyone can POST `{kind:'call', record:{...}}` and ring an arbitrary device (`inventory/calls.md:25`).

## Target architecture
**One mechanism: a transactional outbox whose payload is a watermark, drained by a leased worker that takes no input from its caller.**

That single sentence removes the whole class: no-retry, invisible failure, per-row HTTP coupling, unauthenticated ring injection, and duplicate pushes — all by construction.

---

### Data model

**`push_devices`** — replaces `profiles.fcm_token`.
`device_id uuid PK` (minted on first run, secure storage), `user_id`, `token text`, `token_hash bytea`, `platform`, `app_version`, `fcm_state ∈ {active, unregistered, quarantined}`, `last_token_at`, `last_ack_at`, `last_seen_at`, `consecutive_unacked int`, `health jsonb`.
Indexes: `unique(token_hash)` **globally, not per user** — an FCM token migrating between installs must be *stolen* from the old row, or a user's messages go to someone else's phone.
RLS: `using (user_id = (select auth.uid()))` for all verbs. **No partner read.** This is what closes the leak at `schema.sql:117-120`; the fix is to move the column out of `profiles`, not to patch the policy.

**`push_outbox`** — the decoupler.
`id bigint identity PK`, `dedupe_key text unique` (`'<class>:<domain_row_id>:<user_id>'`), `user_id`, `couple_id`, `event_class ∈ {call, reach, care, message}`, `priority_rank smallint`, `stream_seq bigint` (message class only), `domain_row_id uuid`, `state ∈ {pending, inflight, sent, superseded, dead}`, `attempts int`, `not_before timestamptz`, `lease_until timestamptz`, `lease_owner uuid`, `delivered_to uuid[]`, `fcm_message_id text`, `last_error text`, `last_error_class ∈ {retryable, terminal, throttled}`, `created_at`, `terminal_at`.
Indexes: partial `(priority_rank, not_before, id) where state='pending'`; partial `(lease_until) where state='inflight'`.

**`push_receipts`** — the only true end-to-end signal.
PK `(device_id, fcm_message_id)`, plus `event_class`, `sent_time_ms bigint` (FCM's `RemoteMessage.sentTime`, stored as an **opaque label compared only by equality**), `received_at timestamptz default now()` (**server clock**), `priority smallint`, `original_priority smallint`, `displayed boolean`.

---

### Write path

Two triggers per source table, at **different granularities**:
- `AFTER INSERT FOR EACH ROW` → one `INSERT INTO push_outbox`. Pure local write, same transaction as the domain row. **No network in a trigger, ever again.**
- `AFTER INSERT FOR EACH STATEMENT` → one pg_net wake. A 500-row bulk insert is now **one** HTTP call instead of 500.

`priority_rank`: call=0, reach=1, care=2, message=3. A ring never queues behind a chat backlog. One `ORDER BY` clause; it is the difference between a call that rings and one that doesn't.

The outbox row is per **(event, recipient user)** with `device_id` unset. Devices are expanded at *claim* time, so a phone registered between write and send still gets woken, and a phone deleted in between is never attempted. Materialising devices at enqueue would snapshot a stale list.

---

### Drain: two paths, only one of which may be trusted

**Path A — latency.** The statement trigger's pg_net wake POSTs an **empty body** to `push-drain`. If it times out, cold-starts past pg_net's 2 s default, or never fires, **nothing is lost** — the row is still `pending`. pg_net stops being a delivery mechanism and becomes an optimisation.

**Path B — the floor.** `pg_cron` every 10 s invokes the same function. Correctness depends only on Path B. pg_cron is already in this project (`breath_events.sql:34-37`, `reach_pulses.sql:32-34`), so this is not a new dependency.

**Claim** is one statement in a `SECURITY DEFINER` RPC:
```
with c as (select id from push_outbox
            where state='pending' and not_before <= now()
            order by priority_rank, not_before, id
            for update skip locked limit $n)
update push_outbox o set state='inflight', lease_owner=$owner,
       lease_until = now() + $lease, attempts = attempts + 1
  from c where o.id = c.id returning o.*;
```
`FOR UPDATE SKIP LOCKED` is the entire concurrency story: N workers never collide and never block. A **sweeper** in the same tick returns `inflight` rows with `lease_until < now()` to `pending` with backoff.

**Coalescing at claim time.** `message`-class rows for the same `(user_id, couple_id)` collapse into one send carrying the **greatest** `stream_seq`; the rest go to `superseded` in the same statement. Safe because the payload is a watermark: "you are behind at least to seq 91" subsumes every "seq 87". This is Telegram's `pts` applied to the doorbell.

---

### The worker (`push-drain`, one Edge Function)

- **Module-scope OAuth cache** with a 300 s refresh margin, plus a **negative cache** (5 s backoff on exchange failure) so a cold-start storm cannot hammer Google's token endpoint. Deno isolates persist across warm invocations; this removes 200–300 ms from every push.
- **Bounded-concurrency fan-out**, ~8–16 in flight. There is no true FCM v1 batch endpoint (the legacy one is dead; `sendMulticast` is a client-side loop) — so "batching" here honestly means amortising the isolate, the OAuth token and the DB round trips across N sends, not one HTTP call for N devices.
- **Per-device rate guard** against FCM's 240/min, 5,000/hr, and collapsible 20-burst + 1-per-3-min (`research/push.md:42`). Defer rather than send. Without this, a retry bug self-throttles into *invisibility* — FCM accepts, the device never receives.
- **Error classification** — the thing that today does not exist:
  - `UNREGISTERED` / `INVALID_ARGUMENT` / 404 → **terminal, that device only**: delete the `push_devices` row. Never touches a sibling device.
  - `SENDER_ID_MISMATCH` → terminal + alarm (wrong Firebase project).
  - 429, 500, 503, network, timeout → **retryable**: exponential backoff with jitter, honour `Retry-After`.
  - `attempts >= max` → `dead`. **Dead-letter is a state on a queryable row, not a deleted row.**
- **Class deadlines, not just retry budgets.** A `call` row whose `now() > created_at + 45s` is marked `superseded`, never sent — a ring that lands after the caller gave up is worse than silence. A `message` retries for hours.
- **The worker reads its work from the outbox and takes nothing from the request body.** This is what makes the current "anyone can ring anyone's phone" hole unreachable: an unauthenticated wake can only cause the worker to drain its own committed rows. A shared secret is still added, but as defence in depth, not as the fix.

---

### Per-class parameters (derived from event semantics, not guessed)

| class | priority | ttl | collapse_key | always ends in a notification |
|---|---|---|---|---|
| call | high | **0s** — "now or never, best latency, never stored" | `c:<couple_id>` | yes (FSI or heads-up) |
| reach | high | 600s | `r:<couple_id>` | yes |
| care | normal | 86400s | `n:<couple_id>` | yes |
| message | **normal** | 86400s | `m:<couple_id>` | yes |

Exactly **four** collapse keys — the documented per-device maximum. A fifth makes eviction arbitrary.

**Message drops to normal priority, and this is the most important parameter in the design.** Today every chat message is high-priority and deliberately produces no notification in the foreground (`fcm_service.dart:139-146`) — the exact pattern Android 13+ penalises with a HIGH→NORMAL downgrade, and a downgraded message cannot start a foreground service. Chat volume is spending the privilege that calls need. A chat message tolerates a Doze window (and `ttl=86400s` means FCM *stores* it until Doze ends); a ring does not. **Priority and foreground-suppression may no longer be chosen independently.**

---

### Payload

Data-only (already correct — the only way the background isolate runs, and the only way the disguise stays on-device), but stripped to:
`{ t: "c"|"r"|"n"|"m", cid: <couple_id>, s: <stream_seq>, rid: <domain_row_id> }`

**`from_name` is deleted.** It is transmitted through Google in cleartext, leaks the partner's real name off a deliberately-disguised device, and is never displayed. In a two-person app the client already knows the partner's name locally.

---

### Client contract

1. **All four channels created in `FcmService.init()`.** Move `buildMsgChannel()` out of the background isolate.
2. **Branch on `RemoteMessage.getPriority()`** before anything needing high-priority privileges (Signal's exact guard). Priority is a property of the *received* message, not of what was sent.
3. **Post the notification first** (cheap, no network, inside FlutterFire's 30 s window), **then** enqueue a **single-flight coalescing catch-up** — 1 running + 1 queued, newest wins. N pushes → ≤2 fetches.
4. **Ack** with `messageId`, `sentTime`, `priority`, `originalPriority`, 3 s timeout, buffered to SharedPreferences on failure. Never blocks the notification.
5. **A persisted per-couple cursor + catch-up on every foreground, socket open and push wake** is the durable substitute for `onDeletedMessages`. It makes the *entire* loss class — force-stop, TTL expiry, collapse eviction, the 100-cap, Doze — recoverable on next open.
6. On high-priority fetch timeout, post Signal's content-free fallback verbatim: *"You may have new messages."*
7. Token registration writes `push_devices` keyed by the device UUID. Sign-out deletes **that device's row only**.

---

### Health and what the user is told

Report on every foreground into `push_devices.health`: `isBackgroundRestricted()` (CDD §3.5.1 [C-1-6] — the one portable signal a CTS-passing MIUI/ColorOS/OneUI build must honour), `isIgnoringBatteryOptimizations()`, `getAppStandbyBucket()` (RARE/RESTRICTED = **network disabled**), `areNotificationsEnabled()`, `canUseFullScreenIntent()`, `Build.MANUFACTURER`, and Android 15's `ApplicationStartInfo.wasForceStopped()`.

**The strongest signal is server-derived and needs no device API at all:** K sends to a device with zero matching `push_receipts` rows. Three consecutive unacked sends spanning >10 min → `fcm_state='quarantined'`. That is a per-device detector of the exact failure everyone has been guessing about.

Messages, in order of honesty:
- Notifications off → *"Notifications are turned off for this app."* + settings intent. One tap, actually fixable.
- Background-restricted / RARE bucket → *"Your phone has put this app to sleep. You won't get messages or calls until you open it."* + manufacturer deep link.
- `wasForceStopped()` → *"Your phone stopped this app. Swiping it away from Recents does that. Nothing can wake it until you open it again."* No fix exists; say so.
- FSI revoked → *"Calls will arrive as a notification, not a full-screen ring."*
- Quarantined → *"We sent N alerts to this phone yesterday and none arrived."* + OEM steps.
- And the global truth this design earns: **"When your phone blocks this app, we still show you everything the moment you open it — nothing is lost, it's just late."** That is only true because push is a hint and the cursor is the delivery.

The three phones in play — IN2015 (OnePlus, 5/5 severity), OnePlus 7 (5/5), Vivo (3/5) — are the worst tier. This screen is not optional.

---

### Sequence: call, callee force-stopped, Doze, OnePlus

1. `call_invites` INSERT → row trigger writes `push_outbox(class=call, rank=0)` **in the same transaction** → statement trigger fires one wake.
2. Worker claims (SKIP LOCKED, 20 s lease). Token from module cache, 0 RTT. Expands to the callee's active devices.
3. Sends data-only, high, `ttl=0s`, `collapse_key=c:<couple>`.
4. 200 → `state=sent`, `fcm_message_id` stored, `delivered_to += device`.
5. 503 → back to `pending`, `not_before = now()+1s`. Past `created_at+45s` → `superseded`, and `call_invites.push_state` lets the **caller** see it. Today the caller is told nothing (`_insertInvite` is unawaited with an empty catch).
6. Device wakes; high priority in Doze grants temporary network + partial wakelock. Handler checks `getPriority()==HIGH` before FGS, rings, acks.
7. Force-stopped: nothing runs, `ttl=0` message discarded. Outbox says `sent`; `push_receipts` is empty. Three of those → quarantine → the caller is honestly told her phone isn't receiving alerts.

## Invariants
- **The notification obligation commits with the domain row or not at all.** The row trigger writes to a local table inside the same transaction, so there is no interval in which a message exists and its obligation does not. pg_net cannot provide this: it defers the request to COMMIT and then keeps no record of intent, so a committed transaction whose HTTP call fails leaves nothing behind to retry (research/supabase.md:147, :181).
- **A row is claimable only when `state='pending' AND not_before <= now()`, and the claim atomically flips it to `inflight` with a lease.** A worker that dies mid-send cannot lose work: the sweeper returns any row whose `lease_until < now()` to `pending`. A row leaves the queue only on a positive outcome or an explicit terminal state — never by omission. `FOR UPDATE SKIP LOCKED` makes N concurrent workers correct without coordination, so horizontal scaling requires no new mechanism.
- **Retry never re-sends to a device that already produced an FCM message id**, because the worker sends only to `active_devices − delivered_to`. Duplicate notification on retry is therefore impossible, not merely unlikely.
- **Superseding is safe because the push payload is a monotone watermark, not a message.** A push carrying `stream_seq = 91` subsumes every pending push carrying a lower seq, so collapsing N message-class rows into one loses nothing by construction. This is Telegram's `pts` and Matrix's `next_batch` applied to the doorbell (research/delivery.md:185).
- **Every high-priority push this system emits terminates in a user-visible notification, because only `call` and `reach` are high-priority and both always post one.** Foreground suppression is only ever applied to normal-priority classes. This makes the Android 13+ HIGH→NORMAL downgrade heuristic structurally unreachable, which is what preserves the app's ability to start a foreground service for a ring (research/push.md:36).
- **The worker's input is the outbox; the request body is discarded.** An unauthenticated or forged wake can therefore only cause the worker to drain rows that some authorised writer already committed. The current 'anyone can POST and ring an arbitrary phone' hole is removed by the shape of the call, not by adding a check that could later be misconfigured.
- **A given FCM token string exists on at most one `push_devices` row project-wide** (`unique(token_hash)`), and a terminal FCM error mutates only the row for the device that produced it. One device going `UNREGISTERED` can no longer silence a user's other phones — the current single-column design fails this by construction (index.ts:208 nulls the shared column).
- **Delivery evidence uses two server clocks and never a device clock.** `fcm_accepted_at` and `push_receipts.received_at` are both Postgres `now()`; `RemoteMessage.sentTime` is stored as an opaque label compared only by equality, never by `<`. End-to-end latency is therefore correct on a phone whose clock is a year off — which matters because `setFcmToken` (supabase_repository.dart:398) already stamps a device clock into the database today.
- **Push is a hint whose loss costs latency, never data.** The FCM payload cannot carry user content (it holds a class tag, a couple id and an integer), so the durable Postgres row plus a persisted monotonic cursor is the sole source of truth. A dropped, collapsed, TTL-expired, quota-throttled or force-stop-discarded push is recovered by the next catch-up fetch. This is the invariant that makes every OEM failure survivable and it is what licenses the honest user-facing promise 'nothing is lost, it's just late.'
- **The payload contains no user-authored content and no human-readable identifier.** Privacy is a property of the payload, not of the notification configuration — so it holds regardless of lock-screen settings, OEM logging, or what Google retains. The current design violates this by shipping the partner's real `display_name` through FCM for a value it never displays (index.ts:154).

## Why this mirrors the top tier
**Primary mirror: Signal's push architecture**, which is verifiable open source and is documented in `research/push.md:6-16` from `FcmSender.java`, `FcmReceiveService.java` and `FcmFetchManager.kt`.

Adopted directly:
- **Content-free data-only push.** Signal ships literally one key with an empty value; Google, FCM logs and the lock screen learn "a push happened" and nothing else. This design carries a class tag, a couple id and an integer.
- **Server-side queue is truth, push is a doorbell.** Signal drains its queue after being woken; the push never carries the message.
- **Client-side coalescing.** Signal's `SerialMonoLifoExecutor` (1 running + 1 queued, newest wins) turns N pushes into ≤2 fetches. Adopted verbatim as the catch-up single-flight, which is what makes at-least-once push delivery idempotent at the application layer.
- **`getPriority()` branch before any foreground-service start**, because priority is a property of the received message, not of what was sent.
- **Instrument every receipt with `messageId`, `sentTime`, `priority` and `originalPriority`** — Signal logs both priorities specifically so a silent Android downgrade is visible. This app currently logs none of the five (grep of `core/services` returns zero hits).
- **The last-resort fallback verbatim**: on a high-priority fetch timeout, post a content-free "You may have new messages."

**Secondary mirror: the Telegram/Matrix watermark-cursor model** (`research/delivery.md:179-186`) for the state machine — a server-assigned monotonic integer, never a clock; cursor advance as the ack; watermarks that only move forward, so replay and reordering are absorbed rather than defended against. This is what makes superseding safe.

**Tertiary: the transactional outbox pattern** — the obligation is a row that commits with the business row. `research/supabase.md:167` states the requirement explicitly: "any design that puts delivery on pg_net must own its own dead-letter query, or failures are structurally invisible."

---

**Where this deliberately differs from Signal, and why:**

1. **No authenticated websocket drain.** Signal wakes into a `WebSocketDrainer` with a 5-minute budget, backed by a foreground service. This app cannot: Supabase Realtime is 200 concurrent connections on Free and 10,000 on Pro-no-cap (`research/supabase.md:119`), and a permanent foreground-service notification would destroy the disguise — `research/push.md:17` documents exactly that cost for Telegram-FOSS. **So the drain is a plain REST cursor query (`seq > cursor`), not a socket drain.** For a 1:1 app this is strictly simpler and strictly better: no per-device queue, no TTL sweeper, no `queue/empty` marker (`research/delivery.md:213` — "the expensive parts of the top-tier designs... are all things a 1:1 non-E2EE app on Postgres genuinely does not need").

2. **Signal sends no collapse key and a 28-day TTL; this design uses four collapse keys and per-class TTLs.** Signal can afford non-collapsible pushes because a real per-device queue sits behind them. This app has no such queue, so the collapse key is doing the coalescing work that Signal's queue does. Different mechanism, same invariant: N wake-ups reduce to one fetch.

3. **Signal sends message pushes high-priority; this design sends them normal.** Signal is a registered calling/messaging app at enormous scale with the standing to absorb the downgrade heuristic. This app is privately distributed, disguised, and — per `research/push.md:103` — a strong candidate for having `USE_FULL_SCREEN_INTENT` revoked at install. It cannot afford to spend high-priority budget on chat and then discover the ring can't start a foreground service. This is a deliberate downgrade of chat latency to buy call reliability.

4. **Signal has no per-device health telemetry surfaced to the peer.** This design adds quarantine detection from `last_ack_at` and can tell the *caller* that the callee's phone isn't receiving alerts. For a two-person app that is a product feature; for Signal's threat model it would be a metadata leak.

## Scale ceiling
**Model:** users are individuals, 2 per couple. Pre-coalescing, roughly 46 push-worthy events/user/day (≈40 chat messages received, 2 reaches, 2 nudges, 2 calls). Post-coalescing — message class capped at one push per device per 30 s, and a burst of 10 messages in one conversation becoming one doorbell — **≈15 pushes/user/day**. That 3x reduction is a design output, not an assumption; it falls out of the watermark payload.

**FCM itself never breaks.** The project quota is 600,000 messages/minute (`research/push.md:42`) — four orders of magnitude above 100k users. The binding limits are per-device (240/min, 5,000/hr; collapsible 20 burst + 1 per 3 min), which a couples app reaches only via a bug. The worker's rate guard exists so that a bug costs a deferred send instead of an invisible throttle.

---

**1,000 users — comfortable, and the push domain fits inside the free tier.**
- 15k pushes/day = 0.17/s average, ~1.7/s at evening peak.
- Edge invocations: pg_cron at 10 s = 259k/month, plus wakes. **Design decision that makes this fit: the wake fires only for `call` and `reach`.** A chat message tolerates the 10 s cron floor; a ring does not. That drops wakes to ~4k/day ≈ 120k/month. Total ≈ **380k/month, inside Free's 500k**.
- Outbox at ~200 B/row with 24 h retention ≈ 3 MB steady. Negligible against 500 MB.
- **Failure mode: none in this domain.** The app hits Pro for Realtime reasons long before push becomes a constraint (`research/supabase.md:264` puts the free tier's real capacity at ~110 users on the message quota).

**10,000 users — needs Pro; push is still not the constraint.**
- 150k pushes/day = 1.7/s average, ~17/s peak.
- Edge invocations ≈ 1.2M/month → inside Pro's 2M.
- Outbox + receipts ≈ 300k rows/day; 24 h retention on `sent`, 30 d on `dead` ≈ 60 MB live.
- **Failure mode: token rot, not throughput.** Firebase reports apps neglecting token hygiene lose **~15% of messages to inactive devices** (`research/push.md:126`). Without `last_ack_at` quarantine that 15% is completely invisible — it is the failure that will actually bite, and it is a data-hygiene problem, not a capacity one.

**100,000 users — the design still holds, but three things move.**
- 1.5M pushes/day = 17/s average, ~170/s peak.
- Edge invocations ≈ 3M/month → 1M over Pro's included 2M.
- Postgres: 1.5M outbox inserts + 1.5M updates + 1.5M receipt inserts ≈ 52 writes/s. Nano's 250 baseline IOPS is too tight; needs Small/Medium compute — which the app needs anyway.
- pg_net now carries only wakes (~5/s) against its documented ~200 req/s ceiling (`research/supabase.md:147`). **This is the entire point of moving it off the per-event path** — at 100k users the current design would be attempting 17/s sustained and ~170/s at peak through a 200/s budget shared with everything else, with silent loss above it.

---

**The ordered list of what actually breaks, and how:**

1. **≈30k users (~500k pushes/day)** — Edge invocation count and the 2 s **CPU** limit per request (the real ceiling, not the 150 s wall clock — `research/supabase.md:145`) force a choice: longer cron interval (worse p50) or larger batches (fine). Not a wall. Bound each invocation by a ~20 s wall-clock budget and let the lease sweeper pick up the remainder.

2. **≈130k users (~2M pushes/day)** — one worker per 10 s tick can no longer drain. **The fix requires no new mechanism**: `SKIP LOCKED` already makes K concurrent workers correct, so run K cron jobs. Supabase guidance caps this at 8 concurrent jobs (`research/supabase.md:149`), and two are already taken by `breath_events` and `reach_pulses`. **Ceiling ≈ 6 workers.**

3. **Past ~6 workers** — shard the outbox on `hashtext(user_id) % K` with one cron job per shard, or move the worker off Edge Functions to a long-running process. This is the stated exit criterion, not a surprise.

**The failure mode at the ceiling is the important part: this design does not fail by dropping pushes. It fails by getting slower**, and that degradation is a single queryable number — `p95(claim_time − created_at)` on `push_outbox`. Rows accumulate in `pending` and are eventually delivered late; nothing is lost, because the row is the obligation and the cursor is the delivery. Compare the current design, whose failure mode at *any* scale is silent permanent loss with an HTTP 200 in the logs.

**Honest caveat:** the 15 pushes/user/day figure is inferred from an assumed 40 received messages/user/day. If real usage is 200 messages/day, every number above multiplies by ~2 (coalescing absorbs most of the difference, which is precisely why it is in the design). Stage 0 measures the real rate before anything depends on the estimate.

## Cost
**The headline: FCM has no marginal money cost at any scale in this document.** It is free on both Spark and Blaze, no per-message charge, no message cap (`research/push.md:221`). Every cost below is Supabase-side. **The correct architecture is essentially free — this has been a design problem, not a budget problem, and no amount of spending would have fixed the current one.**

---

**1,000 users**
- FCM: **$0**
- Edge Functions: ~380k invocations/month — inside Free's 500k and Pro's 2M. **$0**
- Database: outbox+receipts ≈ 3 MB steady with 24 h/30 d retention. **$0**
- Egress: 15k pushes/day × ~200 B ≈ 90 MB/month Supabase→Google. **$0**
- **Push-domain marginal cost: $0.** Realistic total bill $25/mo (Pro), driven entirely by Realtime — `research/supabase.md:264` computes ~$58/mo at 1k users with messages dominating. None of that is this domain.

**10,000 users**
- FCM: **$0**
- Edge Functions: ~1.2M/month — inside Pro's 2M included. **$0**
- Database: ~300k rows/day; ≈60 MB live within Pro's 8 GB disk. **$0**
- Egress: ~0.9 GB/month, against Pro's 250 GB. **$0**
- **Push-domain marginal cost: $0** on top of Pro. Total bill ~$500–560/mo (`research/supabase.md:266-271`), ~85% Realtime messages — again, not this domain.

**100,000 users**
- FCM: **$0**
- Edge Functions: ~3M/month → 1M over Pro's 2M × $2/M = **$2/mo**
- Database: ~4.5M writes/day, ~600 MB live at 24 h retention. Compute Large ~$110/mo — needed for the app regardless, so attribute ~$0–30 here.
- Egress: 1.5M × 200 B/day ≈ 9 GB/month. **~$0** (Pro includes 250 GB).
- **Push-domain marginal cost: ~$5–15/mo** all-in.

---

**What the current design costs, in the currency that matters.** Not dollars — latency and loss. A per-invocation RS256 sign plus a Google token exchange is 200–300 ms of wall clock on the critical path of every ring, thrown away immediately (the token is valid 3,600 s). Module-scope caching removes it for **$0** and is a five-line change. Every transient FCM 503, every OAuth blip, and every cold start past pg_net's 2 s default is a permanently lost call or message today, and none of it appears in any metric.

**One optional line item, and my recommendation is to skip it.** FCM BigQuery export for delivery analytics requires the **Blaze** plan (`research/push.md:221`); Spark gets only the BigQuery sandbox. At 100k users and ~1 KB/row that is ~45 GB/month ≈ $1/mo storage plus query cost. **Don't buy it.** The client ack in `push_receipts` gives strictly better data at strictly lower latency: BigQuery export propagates for up to **48 hours** and the aggregated Data API is **7 days of history delayed up to 5 days** (`research/push.md:88, :90`) — useless for "why didn't her phone ring twenty minutes ago", which is the only question anyone actually asks.

**Retention is the only cost that grows unattended**, and it is bounded by policy, not by luck: `sent` and `superseded` 24 h, `dead` 30 days, `push_receipts` 30 days, swept by the same pg_cron pattern already used in `breath_events.sql:37`. Note the trap from `research/supabase.md:149`: `cron.job_run_details` has **no documented retention or cleanup** and grows forever on a 500 MB database. Prune it in the same job.

## Migration
**A big-bang rewrite here would be a failed design, and it is also unnecessary — every stage below is independently shippable and independently revertible.** The order is chosen so that shipping *only* stage 0 still leaves the system better, and so that no stage is validated by opinion.

---

**Stage 0 — Observability first, zero behaviour change. (~1 day.)**
This stage exists because every previous fix was validated with no data.
- Add `push_receipts`. Background handler posts one row: `messageId`, `sentTime`, `priority`, `originalPriority`, 3 s timeout, buffered to SharedPreferences on failure.
- Cache the OAuth token in module scope inside the existing `reach-notify` (five lines, no schema change, immediate p50 win).
- Move `buildMsgChannel()` from `reach_notifications.dart:265` into `FcmService.init()` beside the other three.
- **Then wait a week and read the data** before changing anything else. You will learn: the true per-user push rate, the real arrival rate per device, and — from `originalPriority != priority` — whether Android is already downgrading you. Every later decision, including whether `message` really should drop to normal priority, is settled by this stage rather than argued.

**Stage 1 — `push_devices`, dual-write. (~2–3 days.)**
- Create the table with `unique(token_hash)` and owner-only RLS.
- Client registers to `push_devices` **and** keeps writing `profiles.fcm_token`. Backfill existing tokens.
- `reach-notify` reads `push_devices` first, falls back to `profiles.fcm_token`.
- Multi-device works from this point, and the partner-readable-token leak (`schema.sql:117-120`) is closed for every new registration.
- `profiles.fcm_token` is *not* dropped yet — that is stage 4, so a rollback is a config flip.

**Stage 2 — Outbox and worker, in shadow. (~3–5 days.)**
- Add `push_outbox`, the row triggers that write to it, and the `push_claim` RPC.
- Add `push-drain` + pg_cron. **Leave the four pg_net triggers running.**
- The worker runs in **shadow mode**: it claims rows, expands devices, builds the exact FCM request — and does not send. It records what it *would* have sent.
- Reconcile shadow output against `net._http_response` and `push_receipts`. **This is how the worker is verified without a second phone**: any divergence is a bug in the new path, found before it can affect a user.

**Stage 3 — Cut over one class at a time. (~1 day each.)**
- Order: **care → message → reach → call**. Lowest stakes first, the ring last, when the machinery has already run in production for three classes.
- Each flip = drop one pg_net trigger + enable real sends for that class in the worker + apply that class's priority/TTL/collapse-key parameters.
- A `push_config` row per class holds `enabled` and the send parameters, so a bad flip is an `UPDATE`, not a redeploy — and a rollback is measured in seconds, at 3 a.m., by someone who is not the author.

**Stage 4 — Cleanup. (~1 day.)**
- Drop `profiles.fcm_token` and `fcm_token_updated_at` (which also removes the device-clock write at `supabase_repository.dart:398`).
- Drop `notify_reach`, `notify_care`, `notify_call`, `notify_message`.
- Add the statement-level wake trigger (replacing per-row wakes) and the retention cron, including pruning `cron.job_run_details`.
- Add the shared secret on `push-drain`. Note this is defence in depth only — the worker already ignores its request body, so the "anyone can ring any phone" hole closed in stage 3.

**Stage 5 — Health, quarantine, and user comms. (~3–5 days.)**
- Device health reporting into `push_devices.health` on every foreground.
- Quarantine detection from `last_ack_at`.
- The OEM onboarding/diagnostics screen with per-manufacturer deep links.
- The caller-side "their phone may not be getting alerts" surface — gated on the open decision below.

---

**Two properties that make this safe.** First, the outbox is *additive* until stage 3: it accumulates rows that nothing consumes, so stages 1–2 cannot break delivery even if they are wrong. Second, no stage requires the client and the server to ship together — the client ack in stage 0 works against the old backend, and the outbox in stage 2 works against the old client. **Nothing in this plan needs a coordinated release**, which matters for an app distributed privately with no forced-update channel.

**Prerequisite that is not in this domain but blocks the whole thing.** `inventory/rest.md:262-269` rates schema management **fatal**: 43 loose SQL files applied by hand, four live tables with no DDL, no `migrations/`, no `config.toml`. Every table in this design must land as a numbered migration, or stage 2 becomes the 44th unreproducible file and there is still no staging environment to verify stage 3 in. **Do that first or accept that verification stays production-only.**

## Verification
**The premise: the receiving device's OS state was always the interesting variable, and the second phone never was.** Two NTP-synced phones on one wifi exercise exactly the code path that already works. Everything below runs on zero or one device.

---

**Level 1 — Pure SQL, no app, deterministic.** The outbox is a state machine in Postgres, so test it in Postgres (pgTAP or plain assertion SQL in CI):
- Insert a `messages` row in a transaction, **roll back** → assert zero outbox rows. Proves the same-transaction invariant, which is the one pg_net structurally cannot satisfy.
- Insert and commit → assert exactly one outbox row with the expected `dedupe_key`. Insert the same domain row twice → assert the unique constraint absorbs it silently.
- **Two `psql` sessions calling `push_claim` concurrently → assert disjoint result sets.** Proves `SKIP LOCKED`. No application code involved.
- Backdate `lease_until`, run the sweeper → assert the row returns to `pending`, `attempts` unchanged, `not_before` backed off.
- Insert 10 message-class rows for one user, run coalescing → assert 1 `pending` carrying `max(stream_seq)` and 9 `superseded`.
- Insert a `call` row with `created_at` 60 s in the past → assert the claim marks it `superseded`, **not** `sent`. A ring must never be delivered after the caller gave up.
- Insert an outbox row for a user with two devices, mark one `delivered_to` → assert the next claim targets only the other.

**Level 2 — The worker against a fake FCM.** Point the endpoint at a stub that returns on demand: 200, 404 `UNREGISTERED`, 503, 429 with `Retry-After`, `SENDER_ID_MISMATCH`, and a 5 s hang. Assert the resulting `push_outbox.state`, `attempts`, `not_before`, and `push_devices.fcm_state` for each.
**This is the decisive level.** These are the exact paths every production failure takes, and *no amount of real-device testing can exercise them* — you cannot make Google return 503 on command. The current design has never had a single one of these paths executed, which is precisely why every fix "passed".

**Level 3 — One device, adversarial, via adb.** A single phone reproduces nearly every documented failure:
- `adb shell dumpsys deviceidle force-idle` → Doze. Assert normal-priority is held and high-priority arrives.
- `adb shell am set-standby-bucket com.miles.miles restricted` → network is *disabled* in this bucket. Assert the app reports it in `health` and the user is told.
- `adb shell am force-stop com.miles.miles` → assert **no** push arrives, assert the `push_receipts` gap, assert quarantine fires after three, and assert the catch-up fetch on next open recovers everything. This last assertion is the one that proves the "nothing is lost, it's just late" promise is true rather than marketing.
- `adb shell am get-standby-bucket com.miles.miles` to confirm bucket transitions.
- Revoke POST_NOTIFICATIONS in settings → assert health report and in-app prompt.
- Android 14 device, FSI revoked → assert graceful degradation to a heads-up notification with a direct `PendingIntent` (never `startActivity()` from the receiver — Android 12 blocks the trampoline).
- **The "sender" is a `curl` that inserts an outbox row directly.** No second phone, no second network, no second human.

**Level 4 — A production canary that never sleeps.** A pg_cron job every 15 minutes enqueues a `probe`-class outbox row targeting one dedicated internal device. If no matching `push_receipts` row lands within 60 s, write to `push_alerts`.
**This is the direct answer to "the fix passed and then failed in production."** The probe exercises the entire live path — trigger, outbox, claim, OAuth cache, FCM, device wake, ack — continuously, forever, with nobody testing anything. Every previous silent regression would have been caught within 15 minutes.

**Level 5 — Two SLIs that replace argument with a number.**
- `p50/p95 of (push_receipts.received_at − push_outbox.fcm_accepted_at)` per class per device. **Both timestamps are Postgres `now()`**, so this is correct on a phone whose clock is a year off.
- `1 − count(push_receipts) / count(push_outbox where state='sent')` per device over 24 h — the true drop rate, per device, which is the number nobody has ever had.
Neither needs a second phone, a second network, or a synchronised clock. "Is push working?" becomes a `SELECT`.

---

**Flagged gap, stated plainly rather than papered over.** None of the above proves the notification was *visually presented* — only that the background isolate ran and acked. `plugin.show()` returns normally even when the channel is disabled. The mitigation is to poll `NotificationManager.getActiveNotifications()` ~500 ms after posting and set `push_receipts.displayed` from it; that closes most of the gap. **Whether a human noticed the notification is not mechanically checkable and I am not going to claim otherwise** — that one needs the OEM onboarding screen and honest copy, not telemetry.

**Second flagged gap.** Levels 1–2 need a reproducible schema to run in CI. Today `E:/LDR/supabase` is 43 hand-applied files with no `migrations/` directory (`inventory/rest.md:262-269`), so there is no environment to run them against. Until that is fixed, levels 1–2 can only run against production, which defeats their purpose. **That is the single hardest prerequisite in this whole design and it is not optional.**

## Rejected alternatives
**1. Keep pg_net and add retry by sweeping `net._http_response`.**
Rejected on a structural point, not a preference: `net._http_response` records the *response*, not the *intent*. A request that never fired — because the transaction committed and pg_net dropped it, or the 200 req/s ceiling was hit — leaves nothing to sweep. You cannot reconstruct an obligation from a missing row. Compounding it, responses are garbage-collected after 6 hours (`research/supabase.md:147`), so by the time anyone investigates "she never got it last night", the evidence is gone. `message_push.sql:39-44` already names this table as the sole diagnostic; that is the bug, not the fix.

**2. Supabase Queues / pgmq.**
Rejected for v1, and it is the closest call. It is a real queue with visibility timeouts and it would work. It loses on two grounds. First, it adds an extension dependency to a project whose schema management is already rated **fatal** (`inventory/rest.md:262-269`) — 43 hand-applied files, no migrations directory, four live tables with no DDL at all. Second, and more decisive: **a plain table is queryable.** "Why didn't she get it?" is a `SELECT ... WHERE user_id = ... ORDER BY created_at DESC` against `push_outbox`, with `attempts`, `last_error` and `last_error_class` right there. A queue's internals are opaque, and opacity is the exact failure this whole redesign is correcting. `FOR UPDATE SKIP LOCKED` gives everything pgmq would. Revisit at ~100k users if the sharded-cron path gets ugly.

**3. Supabase Database Webhooks instead of triggers.**
Rejected: identical fire-and-forget semantics, *plus* the configuration lives in the dashboard rather than in SQL — which is precisely the unreproducibility already rated fatal. `research/push.md:220` notes the documented Supabase pattern "specifies no retry logic, no delivery guarantees, no queuing and no dead-letter handling — that layer does not exist and must be built."

**4. Call FCM directly from Postgres (pg_net + pgjwt to mint the OAuth token).**
Rejected: it puts the service-account private key inside the database, and RS256 signing in plpgsql is fragile and unpleasant to rotate. It would eliminate the Edge Function invocation cost entirely — which at 100k users is $2/month. Not worth it. A private key belongs in a secret store, read by one function.

**5. A persistent authenticated websocket as the background transport (the full Signal/Telegram model).**
Rejected on documented numbers. Supabase Realtime is 200 concurrent connections on Free and 10,000 on Pro-without-spend-cap (`research/supabase.md:119`); at 1,000 users a foreground-only socket already approaches the free cap, and a *background* socket would need a permanent foreground service. `research/push.md:17` documents what that costs: Telegram's FOSS build must show a permanent foreground-service notification because it cannot use FCM. **For an app whose entire premise is a disguised launcher, a permanent "app is running" notification is not a tradeoff — it is the end of the product.** Realtime stays the foreground transport; FCM stays the background transport.

**6. A `notification` (non-data) FCM payload for chat, so the OS is guaranteed to draw something.**
Rejected on three independent grounds: `onMessageReceived` is **not** called for notification-only messages when the app is backgrounded (`research/push.md:26`), so the disguise cannot be applied and the process never runs; the payload text is drawn by the OS in the clear, which is fatal for a private app; and notification messages "are always collapsible and will ignore the `collapse_key` parameter" (`research/push.md:30`), destroying the only mechanism controlling the 4-key budget.

**7. Per-message collapse keys.**
Rejected: FCM stores exactly **four** distinct collapse keys per device, and beyond that "FCM only keeps four collapse keys, with no determining factor on which keys are kept" (`research/push.md:40`). Per-message keys would make eviction arbitrary and would starve the `call` key via the 20-burst / 1-per-3-minutes collapsible throttle.

**8. Requesting a battery-optimization exemption as the answer to OEM killing.**
Rejected: Google's own acceptable-use table lists "Real-time messaging app using FCM high priority" as explicitly **Not Acceptable** — "Use FCM instead" (`research/push.md:60`). Even granted, it buys only network access and a partial wakelock during Doze; jobs, syncs and regular alarms remain deferred, and it does **nothing** against force-stop or Huawei's PowerGenie whitelist. Every vendor page in the catalogue reads "no known solution on dev end."

**9. Marking a message "delivered" when FCM accepts it.**
Rejected, and worth naming because it is the tempting shortcut that would make the receipts feature look finished. FCM's 200 means Google accepted the message, not that a device received it. Under Doze, TTL expiry, collapse eviction, the 100-pending discard, or force-stop, FCM returns 200 and the device gets nothing. Delivery is owned by the recipient device and is written only from `push_receipts` — this is `research/delivery.md:184` ("DELIVERED AND READ HAVE DIFFERENT OWNERS") and it is why the ack is not optional garnish.

## Open decisions
**1. Does chat really drop to normal priority? — Recommend YES, but decide with Stage 0's data.**
The case for: Android 13+ downgrades HIGH→NORMAL for apps whose high-priority pushes don't produce notifications (`research/push.md:36`), and a downgraded message cannot start a foreground service. Today every chat message is high-priority and `fcm_service.dart:139-146` deliberately shows nothing in the foreground — the app is training FCM to downgrade it, and the cost lands on the ring. The case against: a couples app's chat *feels* urgent, and normal priority means Doze-window delay (bounded, and `ttl=86400s` means FCM stores it rather than dropping it).
**Recommendation: ship normal, then read `originalPriority != priority` from `push_receipts`.** If downgrades were never happening on these devices, revert with one `push_config` UPDATE. This is a decision that should be made from a week of measurements, and Stage 0 exists specifically so it can be. It is currently being made by accident.

**2. Do you tell the sender that the recipient's phone is unreachable? — Recommend YES, carefully.**
This is the highest-value product output of the entire design and it directly answers "she never texted me": after quarantine, the caller sees *"their phone may not be getting alerts right now."* But it is also a surveillance signal about a partner's device state, in an app built around concealment, and `research/delivery.md` cites the Careless Whisper paper on exactly how receipt timing leaks screen-on/off state.
**Recommendation: surface it only at the quarantine level (aggregate, ≥3 consecutive unacked sends over >10 minutes), never per-message, and never with a timestamp.** "Their phone may not be getting alerts" is a device-health fact; "delivered 3 seconds ago" is a behavioural tracker. This is a product decision for the owner, not an engineering default.

**3. How opaque should `couple_id` be in the payload? — Recommend leave it for v1.**
Treating `couple_id` as a secret is already a fiction: it is the first path segment of every never-expiring public `couple_media` URL (`inventory/chat.md:7`, and `hardening_2026_08.sql:25` admits it). Adding an opaque per-device `thread_ref` costs one column and one lookup, but it hardens a door in a wall that has a hole in it.
**Recommendation: fix the public bucket first; add `thread_ref` when the id is actually secret.** If the owner wants it now, it is cheap — say so and do it.

**4. Quarantine threshold. — Recommend 3 consecutive unacked sends spanning >10 minutes.**
Too aggressive and a subway ride quarantines a healthy device; too loose and a force-stopped phone goes undetected for days. The 10-minute span requirement is what prevents a burst of three pushes in one dead spot from tripping it.
**Recommendation: ship 3/10min, then tune from the real ack-rate distribution.** This number cannot be chosen correctly before Stage 0.

**5. Retention. — Recommend `sent`/`superseded` 24 h, `dead` 30 d, `push_receipts` 30 d.**
Enough to debug last night; not enough to grow. **And prune `cron.job_run_details` in the same job** — `research/supabase.md:149` notes it has no documented retention and grows forever on a 500 MB database.

**6. Cron budget. — Recommend one job for this domain.**
Supabase guidance is ≤8 concurrent jobs, ≤10 min each (`research/supabase.md:149`). `breath_events` and `reach_pulses` already hold two. Fold drain + lease sweep + retention into one `push-drain` invocation, staged internally, so this domain costs one of the remaining six. That budget is also the horizontal-scaling ceiling identified in the scale section — spending it carelessly now caps you at ~130k users later.

**7. The blocking prerequisite the owner must accept or reject: fix schema reproducibility first.**
`inventory/rest.md:262-269` rates this **fatal** — 43 hand-applied files, no `migrations/`, no `config.toml`, four client-referenced tables with no DDL anywhere. Without it, the three new tables become files 44–46, levels 1–2 of the verification plan have no environment to run in, and stage 3's per-class cutover cannot be rehearsed anywhere but production.
**Recommendation: do it before Stage 2.** It is boring, it is not this domain, and it is the reason every previous fix could only be validated by pointing two phones at each other. This is the decision that determines whether any of the rest is verifiable.
