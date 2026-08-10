# push (revised)

## What changed vs v1
FATAL 1 — "every class gets a collapse_key, so chat volume drains the app-wide collapsible bucket (20 burst, +1 per 3 min) and the ring is deferred to death."
CLOSED. Exactly one class is collapsible now: `message`, key `m:<couple_id>`. `call`, `reach` and `care` carry no collapse key at all, so they are governed only by the per-device 240/min and 5,000/hr limits and can never be starved by chat. Two further mechanisms make even the message bucket non-binding: (a) the worker keeps a server-side mirror of FCM's documented collapsible bucket per device — capacity 12 (deliberate headroom under FCM's 20), refill 1 per 180 s — and never emits a collapsible send without a token, so we cannot consume faster than FCM refills; (b) the claim RPC drops any message-class row whose watermark is already covered by every active device's reported cursor, so a foregrounded device on a live socket costs zero tokens. The class-aware rate guard is now explicit: rank 0 (`call`) and rank 1 (`reach`) bypass the guard entirely and are never deferred — a deferred ring is a failed ring. `call` also moves from `ttl:"0s"` to `ttl:"45s"`, matching its class deadline, so a 20-second tunnel yields a stored-then-delivered ring instead of a discarded one, and staleness is decided by a server-computed age at resolve time rather than by FCM throwing the message away. It cannot regress because the collapse key is a per-class column in `push_config` with a CHECK that permits a non-null key only when `ttl_seconds >= 3600`, and because the bypass is `priority_rank <= 1`, a property of the row, not of a code path.

FATAL 2 — "the watermark is `messages.seq`, a global `nextval` (receipts_v2.sql:31) whose assignment order is not its visibility order, so `WHERE seq > cursor` loses rows permanently."
CLOSED, and the mechanism is not `messages.seq` at all. A new per-couple, commit-ordered integer `cseq` is added to all four event tables, assigned by a BEFORE INSERT trigger from a single-statement upsert against a dedicated `couple_seq(couple_id, last_seq)` counter. The counter row lock is held from assignment until COMMIT, so for a given couple, assignment order is *identical* to commit order: if `cseq = 42` is visible, the transaction that took 41 released the lock before 42 was assigned and is therefore already committed. A reader doing `cseq > cursor` cannot skip a row, by construction and on the server. `messages.seq` is left in place untouched for the existing chat UI and is never used by the push recovery path, so this design's promise does not depend on another domain fixing it. The catch-up is also now a loop: it pages until a page returns fewer than `limit` rows, persisting the cursor per page, so a 3-day backlog costs pages, not truncation (the current `.limit(500)` with no continuation at chat_repository.dart:189 is a second, independent truncation and is replaced).

FATAL 3 — "the watermark and therefore 'nothing is lost, it's just late' covers `message` only; reach/care/call have no cursor and a Reach that outlives its TTL is gone."
CLOSED. `cseq` is drawn from ONE counter per couple and stamped on `messages`, `reach_events`, `care_nudges` and `call_invites` alike, so there is exactly one watermark, one cursor and one catch-up for the whole app. The catch-up RPC returns rows from all four tables above the cursor in `cseq` order, together with a server-computed `age_seconds` per row so the client decides "ring now" vs "show as history" without ever consulting its own clock. That makes a short TTL a decision about *interruption*, not about the *record*: `reach` moves to `ttl=86400s` (the record always survives) with a 600 s server-computed liveness window (past that it renders as "she reached for you" history rather than a full-screen alarm). The failure the design opened by diagnosing — 31 seconds in a tunnel and the Reach is gone forever — is now impossible for all four classes, not one.

SERIOUS 4 (token-steal primitive) — CLOSED. `push_devices` is unique on `(user_id, token_hash)`, never globally, and no row is ever reassigned across `user_id`. A cross-user duplicate is tolerated and resolved by the only authenticated signal that exists — FCM returning `UNREGISTERED` to the stale holder — which the classifier already treats as terminal-for-that-device. Separately, the read side is closed in Stage 1, not Stage 4: a BEFORE UPDATE trigger on `profiles` moves any written `fcm_token` into `push_devices` and sets the column to NULL in the same statement, so the partner-readable column (`schema.sql:117-120` has no column restriction) is empty at rest from the first migration, with no client release required.

SERIOUS 5 (quarantine lies during the RARE bucket; the latency SLI measures buffer flush) — CLOSED. Quarantine is computed only from high-priority (`call`/`reach`) sends, the only ones granted temporary network in Doze, and any late-flushing ack retroactively clears it. Four conditions are now reported separately instead of collapsed into one: `token_dead`, `force_stopped`, `notifications_denied`, `net_restricted`. Only the two unambiguous ones (`token_dead`, `force_stopped`) are ever surfaced to the partner. The ack now carries `ack_delay_ms`, a monotonic `elapsedRealtime()` interval — not a wall clock — so the server derives `received_at = now() − ack_delay_ms` and excludes acks with a delay above 60 s from the latency percentile, reporting them separately as buffered.

SERIOUS 6 (the outbox trigger can now fail the user's message send) — CLOSED as an invariant, not a test. Both trigger writes are structurally unfailable on well-formed input: the counter is one `INSERT … ON CONFLICT DO UPDATE … RETURNING` on a dedicated table with no other writer; the outbox insert is `ON CONFLICT (dedupe_key) DO NOTHING` with no foreign keys out of `push_outbox` into any table, no CHECK that can fail on a well-formed row, and no reference to a table any background job writes. All retention is partition DROP, never DELETE, so the reclaim path takes no lock a writer can block on.

SERIOUS 7 ("duplicate notification is impossible" is false) — CLOSED by restatement plus a mechanism. The claim is now: at-least-once at the transport, exactly-once at the display. The client contract mandates a stable notification id as a pure function of `rid` for all four classes (the codebase already does this by accident at reach_notifications.dart:71), and the call handler treats a second wake for an already-ringing `call_id` as a no-op. Server-side the worker writes `fcm_message_id` and `delivered_to` before returning; a crash between FCM's 200 and that write is an accepted duplicate the client absorbs.

SERIOUS 8 (the canary needs a second phone and cannot detect the outage it exists to detect) — CLOSED by splitting it three ways: a pure-SQL pg_cron alarm with no HTTP in it that fires on `max(now() − created_at) where state='pending'`; an external dead-man's-switch pinger against a health endpoint, which alarms on *silence* and therefore survives total pg_net/pg_cron/Edge death; and an emulator-with-Play-Services canary on CI instead of an OEM handset in a drawer. Every `net.http_post` now sets `timeout_milliseconds` explicitly, and `push-drain` acknowledges as soon as it has claimed, so `net._http_response` stops filling with `timed_out=true` and stays usable as a diagnostic.

MINOR 9 (outbox rows outliving domain rows) — CLOSED. The claim RPC re-validates existence by joining `push_outbox` to its source table on `domain_row_id` and marking missing rows `superseded` in the same statement, which is what makes the design survive `clear_conversation_everyone()`'s hard DELETE (clear_chat_everyone.sql). The wrong justification for the statement-level wake ("a bulk insert fires one POST per row") is deleted; it is a DELETE, and all four triggers are AFTER INSERT. The wake exists for invocation-count economics and is now debounced by a non-blocking advisory lock.

MINOR 10 (cost arithmetic) — CLOSED. Receipts are daily-partitioned at 7 days (not 30) and sized explicitly at every scale; the client ack appears as a first-class request and egress line; and the message-class latency floor imposed by the cron tick is stated as a declared tradeoff with its own SLI and a `push_config` knob, rather than discovered in production.

## Target architecture
## What this replaces

Today four `AFTER INSERT … FOR EACH ROW` triggers each call `net.http_post` to a hardcoded URL (`fcm_push.sql:33`, `message_push.sql:35`, `20260628_care_call_push.sql:40,:65`) with no Authorization header and no `timeout_milliseconds`, so pg_net's documented 2000 ms default applies. `functions/reach-notify/index.ts` then mints a fresh RS256 service-account JWT and exchanges it at Google per invocation, does two PostgREST lookups, calls FCM once, and returns HTTP 200 on every error path (`:128, :134, :146, :212, :218`). pg_net has no documented retry and GCs responses after 6 h. The recipient's token is one scalar column on `profiles` (`fcm_push.sql:7`) readable by the partner through `profiles_select_self_or_partner` (`schema.sql:117-120`, no column restriction). `from_name` ships the partner's real display name through Google and is never displayed, because notification text comes from `currentNotificationStyle()`. Every chat message is sent `priority:"high"` while `_onForeground` deliberately posts nothing for `type=='message'` (`fcm_service.dart:139-146`) — the exact pattern Android 13+ penalises with a HIGH→NORMAL downgrade, and a downgraded message cannot start a foreground service, which is the privilege the ring depends on. `buildMsgChannel()` has one call site in the whole codebase, inside the background isolate (`reach_notifications.dart:265`) — the Android 13 first-channel-in-background trap.

## One sentence

**A per-couple commit-ordered integer makes every user-visible event recoverable by a cursor; push becomes a doorbell carrying only that integer, emitted by a leased worker draining a transactional outbox and taking no input from its caller.**

---

## 1. The watermark: `cseq`

`couple_seq(couple_id uuid primary key, last_seq bigint not null default 0)` — a dedicated counter table with exactly one writer type.

Each of `messages`, `reach_events`, `care_nudges`, `call_invites` gains `cseq bigint not null`. A BEFORE INSERT trigger assigns it from a single statement: insert `(couple_id, 1)` on conflict do update set `last_seq = couple_seq.last_seq + 1` returning `last_seq`.

**Why this is the whole design.** The counter row lock is taken during the INSERT and held until COMMIT. For one couple, therefore, assignment order *is* commit order: a reader that can see `cseq = 42` is guaranteed that the transaction holding 41 committed before 42 was even assigned. `WHERE couple_id = ? AND cseq > cursor ORDER BY cseq` cannot skip a row. This is the property a bare Postgres sequence does not have and cannot be given — `messages.seq` (`receipts_v2.sql:31`) is one global `nextval` assigned at INSERT, so 105 can become visible before 104 commits and a `.gt('seq')` reader loses 104 forever. `messages.seq` is left alone; nothing in this design reads it.

Contention: two writers per couple, holding the lock for the duration of a single-statement PostgREST insert. Different couples never touch the same row. No deadlock is reachable because no transaction takes two counters.

**Rows disappearing beneath the cursor is a non-event.** `clear_conversation_everyone()` hard-deletes every message row for a couple (`clear_chat_everyone.sql`). The cursor is an integer, not a row pointer: a deleted row is simply absent from the next page, the cursor still advances past it, and no later row is skipped. There is nothing to tombstone.

**Catch-up RPC** (`fetch_since(p_cursor bigint, p_limit int)`, SECURITY DEFINER, couple scoped by `auth.uid()`): returns rows from all four tables above the cursor, ordered by `cseq`, each tagged with its class and with a server-computed `age_seconds` (`extract(epoch from now() - created_at)`), plus `server_now` and `has_more`. The client pages until `has_more` is false, persisting the cursor after each page. No device clock enters any comparison anywhere.

## 2. Devices: `push_devices`

`device_id uuid PK` (minted on first run, secure storage), `user_id`, `token text`, `token_hash bytea`, `platform`, `app_version`, `fcm_state ∈ {active, unregistered, quarantined}`, `last_token_at`, `last_ack_at`, `last_seen_at`, `cursor_seq bigint default 0`, `collapsible_tokens smallint default 12`, `collapsible_refill_at timestamptz`, `unacked_hp_sends int`, `first_unacked_hp_at`, `health jsonb`.

- **Unique `(user_id, token_hash)`. Never global, never reassigned across users.** A token appearing under two users is tolerated; the stale holder's send returns `UNREGISTERED`, which is the only authenticated ownership signal FCM offers, and the classifier deletes that row only.
- RLS `using (user_id = (select auth.uid()))` for every verb. No partner read, ever.
- Registration goes through a SECURITY DEFINER RPC that writes `user_id := auth.uid()` and stamps `last_token_at := now()`. The device cannot choose whose row it writes, and no device clock reaches the database (today `setFcmToken` stamps `fcm_token_updated_at` from `DateTime.now()` at `supabase_repository.dart:396-398`).
- `cursor_seq` is advanced through a `greatest()`-only RPC, writable only by the owning user. It is an optimisation input, never an invariant: a device that lies about its cursor suppresses only its own doorbells, and the row remains recoverable by catch-up.

**The `profiles.fcm_token` leak closes in the first migration, not the last.** A BEFORE UPDATE trigger on `profiles` moves any non-null written `fcm_token` into `push_devices` (legacy writers get a deterministic `device_id` derived from `(user_id, token_hash)`) and sets `new.fcm_token := null`, `new.fcm_token_updated_at := null`. The column is empty at rest, so the unrestricted partner-readable policy has nothing to leak, and no client release is needed to get there.

## 3. Obligation: `push_outbox`

`id bigint identity PK`, `dedupe_key text unique` (`'<class>:<domain_row_id>:<user_id>'`), `user_id`, `couple_id`, `event_class ∈ {call, reach, care, message}`, `priority_rank smallint` (call 0, reach 1, care 2, message 3), `watermark bigint` (the row's `cseq`), `domain_row_id uuid`, `state ∈ {pending, inflight, sent, superseded, dead}`, `attempts`, `not_before`, `lease_until`, `lease_owner`, `delivered_to uuid[]`, `fcm_message_id`, `fcm_accepted_at`, `last_error`, `last_error_class ∈ {retryable, terminal, throttled}`, `created_at`, `terminal_at`. Daily range partitions on `created_at`.

Indexes: partial `(priority_rank, not_before, id) where state='pending'`; partial `(lease_until) where state='inflight'`.

One shared AFTER INSERT FOR EACH ROW trigger function, parameterised per table with the class name and the recipient column (`call_invites.callee_id`; the other couple member otherwise), writes exactly one row per (event, recipient user) with `device_id` unset. **Devices are expanded at claim time, not at enqueue** — a phone registered between write and send still gets woken; a phone deleted in between is never attempted.

**The trigger cannot fail the user's write.** It is `ON CONFLICT (dedupe_key) DO NOTHING`; there are no foreign keys out of `push_outbox` into any table; no CHECK can fail on a well-formed row; and no background job ever writes to it — retention is partition DROP. This is an invariant, not a test assertion: the notification obligation commits with the domain row, and its failure modes are limited to those that also mean the domain row could not be written.

## 4. Drain

**Path A (latency).** A statement-level AFTER INSERT trigger fires one pg_net wake with an **empty body** and an explicit `timeout_milliseconds`. It is debounced without blocking anyone: the function takes `pg_try_advisory_xact_lock` on a fixed key and, if it cannot, returns immediately. A skipped wake costs nothing. This is invocation-count economics — nothing more. (The original claim that a bulk operation fires one POST per row was wrong: `clear_conversation_everyone` is a DELETE and all four existing triggers are AFTER INSERT.)

**Path B (floor).** `pg_cron` on a `push_config`-driven interval (10 s default) invokes the same function. pg_cron is already used by `breath_events.sql:34-37` and `reach_pulses.sql:32-34`.

Neither path is trusted. Both are pg_net, and a project-wide pg_net failure stops both — the real property is not "Path B is safe" but **self-healing across ticks plus an out-of-band dead-man's switch** (§8). A row that is never woken and never cronned stays `pending` and is visible as a number.

**Claim** is one SECURITY DEFINER statement: select `state='pending' AND not_before <= now()` ordered by `(priority_rank, not_before, id)` `FOR UPDATE SKIP LOCKED LIMIT n`, then update those rows to `inflight` with a lease and `attempts+1`, returning them. N workers never collide and never block. A sweeper in the same tick returns `inflight` rows with `lease_until < now()` to `pending` with backoff.

Three things happen inside the same claim statement, so they cannot be skipped by a code path:
1. **Existence re-check.** Rows whose `domain_row_id` no longer exists in the source table become `superseded`. This is what survives `clear_conversation_everyone` in the 24 h window that `ttl=86400s` opens.
2. **Coalescing.** `message`-class rows for the same `(user_id, couple_id)` collapse to the one carrying the greatest `watermark`; the rest become `superseded`. Safe because the payload is a monotone watermark — "you are behind at least to 91" subsumes every "87".
3. **Cursor skip.** A row becomes `superseded` when every active device of the recipient already reports `cursor_seq >= watermark`. A foregrounded device on a live socket costs zero pushes and zero collapsible tokens.

**Class deadlines.** A `call` row past `created_at + 45 s` is marked `superseded` and never sent, and `call_invites` carries a `push_state` the caller can see — today `_insertInvite` is unawaited with an empty catch and the caller is told nothing.

## 5. The worker (`push-drain`, one Edge Function)

- **Module-scope OAuth cache** with a 300 s refresh margin plus a negative cache (5 s backoff on exchange failure). Removes an RS256 sign and a Google token exchange — 200–300 ms — from the critical path of every ring.
- **Acknowledges the wake as soon as it has claimed**, then sends in the background of the same isolate. This is what keeps `net._http_response` free of `timed_out=true` and therefore usable as a diagnostic.
- **Bounded-concurrency fan-out**, ~8–16 in flight. There is no true FCM v1 batch endpoint; "batching" here honestly means amortising the isolate, the token and the DB round trips.
- **Class-aware rate guard.** `priority_rank <= 1` (`call`, `reach`) **bypasses the guard entirely** — a deferred ring is a failed ring. `care` and `message` may be deferred. Per-device 240/min and 5,000/hr are respected for all classes.
- **Server-side mirror of FCM's collapsible bucket** on `push_devices`: capacity 12 (headroom under FCM's documented 20), refill 1 per 180 s. A collapsible send requires a token. We therefore cannot consume the bucket faster than FCM refills it, and the bucket exists only for `message`.
- **Non-collapsible outstanding cap** of 8 unacked sends per device for `reach`/`care` (superseded beyond that), so the 100-pending cliff — which discards *all* stored messages at once — cannot be reached by a quiet device. `call` is exempt: at ~2/day it cannot approach the cap alone and must always be attempted.
- **Error classification.** `UNREGISTERED`/`INVALID_ARGUMENT`/404 → terminal, that device only, delete that `push_devices` row and never a sibling. `SENDER_ID_MISMATCH` → terminal + alarm. 429/5xx/network/timeout → retryable, exponential backoff with jitter, honour `Retry-After`. `attempts >= max` → `dead`, which is a state on a queryable row, not a deleted row.
- **`fcm_message_id`, `fcm_accepted_at` and `delivered_to` are written before the worker returns.** A crash between FCM's 200 and that write produces a duplicate, which is absorbed at the display (§7).
- **The worker reads its work from the outbox and discards the request body.** The current hole — anyone can POST `{kind:'call', record:{…}}` and ring an arbitrary phone (`inventory/calls.md:25`) — is removed by the shape of the call. A shared secret is added later as defence in depth, never as the fix.

## 6. Per-class parameters

| class | rank | FCM priority | ttl | collapse_key | live window (server-computed) |
|---|---|---|---|---|---|
| call | 0 | high | 45 s | **none** | 45 s |
| reach | 1 | high | 86400 s | **none** | 600 s |
| care | 2 | normal | 86400 s | **none** | always live |
| message | 3 | normal | 86400 s | `m:<couple_id>` | always live |

**Exactly one collapse key, on the one class with volume.** Collapsible messages are throttled to a burst of 20 per app per device refilling 1 per 3 minutes — *per app*, not per key. Making all four classes collapsible would have let chat volume drain the ring's delivery budget exactly as it currently drains the ring's priority budget. `call`, `reach` and `care` are non-collapsible and are governed only by 240/min and 5,000/hr.

**A collapse key may exist only where FCM actually stores the message.** Enforced by a CHECK on `push_config`: `collapse_key is null or ttl_seconds >= 3600`. Collapse replaces a *stored pending* message; on a `ttl=0` send it is pure cost.

**`call` is `ttl=45s`, not `ttl=0s`.** `ttl=0` is now-or-never and discards; 45 s lets FCM store and deliver a ring through a short tunnel, and staleness is then decided by the server-computed `age_seconds`, not by FCM silently dropping it.

**`message` is normal priority, and that is deliberate.** Android 13+ downgrades HIGH→NORMAL for apps whose high-priority pushes do not produce notifications, and a downgraded message cannot start a foreground service. Today every chat message is high and the foreground handler shows nothing (`fcm_service.dart:139-146`). Priority and foreground-suppression may no longer be chosen independently: **only classes that always end in a user-visible notification may be high**, which is `call` and `reach`, both of which always post one. That makes the downgrade heuristic structurally unreachable.

## 7. Payload and client contract

Data-only — the only shape that runs the background isolate when the app is backgrounded, and the only way the disguise stays on-device. Stripped to `{ t: "c"|"r"|"n"|"m", cid, w: <cseq>, rid }`.

**`from_name` is deleted.** It transits Google in cleartext, carries the partner's real display name off a deliberately disguised device, and is never rendered — the notification text comes from `currentNotificationStyle()`.

1. **All four channels created in `FcmService.init()`**, using the existing disguised names. `buildMsgChannel()` moves out of the background isolate (`reach_notifications.dart:265`).
2. **Branch on `RemoteMessage.getPriority()`** before anything requiring high-priority privileges, and on `canUseFullScreenIntent()` before a full-screen ring; degrade to a heads-up notification with a direct `PendingIntent` (never `startActivity()` from a receiver — Android 12 blocks the trampoline).
3. **Post the notification first** (no network, well inside FlutterFire's 30 s window), **then** run a single-flight coalescing catch-up: 1 running + 1 queued, newest wins. N pushes → ≤2 fetches.
4. **Notification id is a stable pure function of `rid`** for all four classes, and the call handler treats a second wake for an already-ringing `call_id` as a no-op. This, not the server, is what makes redelivery invisible.
5. **Ack** with `messageId`, `sentTime` (opaque label, compared only by equality), `priority`, `originalPriority`, and `ack_delay_ms` — the difference between two `SystemClock.elapsedRealtime()` readings, a monotonic interval, never a wall clock. 3 s timeout, buffered to SharedPreferences on failure, never blocking the notification.
6. **Catch-up runs on every foreground, socket open, push wake and `onDeletedMessages`**, pages until short, and advances `cursor_seq` per persisted page. This is the durable substitute for `onDeletedMessages` and it makes force-stop, TTL expiry, collapse eviction, the 100-cap and Doze all recoverable on next open.
7. On a high-priority fetch timeout, post the content-free fallback: "You may have new messages."
8. Sign-out deletes that device's `push_devices` row only.

## 8. Receipts, health, and what is said out loud

`push_receipts` — PK `(device_id, fcm_message_id)`, plus `event_class`, `sent_time_ms` (opaque), `ack_delay_ms`, `received_at` derived server-side as `now() − ack_delay_ms`, `inserted_at default now()`, `priority`, `original_priority`, `displayed`. Daily partitions, 7-day retention by DROP.

Health reported into `push_devices.health` on every foreground: `isBackgroundRestricted()` (CDD §3.5.1 [C-1-6], the one portable signal a CTS-passing MIUI/ColorOS/OneUI build must honour), `isIgnoringBatteryOptimizations()`, `getAppStandbyBucket()`, `areNotificationsEnabled()`, `canUseFullScreenIntent()`, `Build.MANUFACTURER`, `ApplicationStartInfo.wasForceStopped()`.

**Four conditions, four remedies, never conflated:**
- `token_dead` — FCM returned UNREGISTERED. Server-authoritative and unambiguous.
- `force_stopped` — `wasForceStopped()` at last foreground. Unambiguous. No fix exists.
- `notifications_denied` — one tap to fix; show a settings intent.
- `net_restricted` — RARE/RESTRICTED bucket or background-restricted. **Network is disabled in these buckets while `plugin.show()` still works**, so the phone can be receiving and displaying and be unable to ack.

`unreachable_suspected` (quarantine) is computed **only from high-priority `call`/`reach` sends**, the only ones granted temporary network in Doze: ≥3 consecutive with no receipt, spanning >10 minutes. Any late-flushing ack clears it retroactively.

**Only `token_dead` and `force_stopped` are ever surfaced to the partner.** `unreachable_suspected` and `net_restricted` are surfaced to the device's own owner and to diagnostics, never to the caller — because the server genuinely cannot distinguish "not delivered" from "delivered, displayed, cannot ack".

Copy, in order of honesty: notifications off → "Notifications are turned off for this app" + settings intent. Background-restricted/RARE → "Your phone has put this app to sleep. You won't get messages or calls until you open it" + manufacturer deep link. `wasForceStopped()` → "Your phone stopped this app. Swiping it away from Recents does that. Nothing can wake it until you open it again." FSI revoked → "Calls will arrive as a notification, not a full-screen ring." And the promise this architecture actually earns: **"When your phone blocks this app, we still show you everything the moment you open it — nothing is lost, it's just late."** That is true only because push carries a watermark and the cursor is the delivery, and it is now true for all four classes, not one.

The three phones in play — IN2015 (OnePlus, 5/5), OnePlus 7 (5/5), Vivo (3/5) — are the worst tier. The OEM onboarding screen is not optional.

## 9. Sequence: call, callee in Doze on a OnePlus, then force-stopped

1. `call_invites` INSERT. BEFORE trigger takes `cseq` from `couple_seq` (lock held to COMMIT). AFTER trigger writes `push_outbox(class=call, rank=0, watermark=cseq)` in the same transaction. Statement trigger tries the advisory lock and fires one empty-bodied wake with an explicit timeout.
2. Worker claims under `SKIP LOCKED` with a 20 s lease, acks the wake, expands to the callee's active devices, existence-checks `call_invites`, skips any device already at `cursor_seq >= watermark`.
3. Sends data-only, high, `ttl=45s`, **no collapse key**, rate guard bypassed because rank 0.
4. 200 → `state=sent`, `fcm_message_id` and `fcm_accepted_at` written before return, `delivered_to += device`.
5. 503 → back to `pending`, `not_before = now()+1s`. Past `created_at+45s` → `superseded`, and `call_invites.push_state` lets the caller see it.
6. Device wakes; high priority in Doze grants temporary network and a partial wakelock. The handler checks `getPriority()==HIGH` and `canUseFullScreenIntent()`, posts under a notification id derived from `rid`, rings, then acks with `ack_delay_ms`.
7. Force-stopped instead: nothing runs, the stored ring expires at 45 s. Outbox says `sent`, receipts are empty. Three such high-priority sends over >10 minutes → `unreachable_suspected`; the next foreground reports `wasForceStopped()` and the caller is told the one true thing. When the callee finally opens the app, `fetch_since(cursor)` returns the missed call, the missed reaches, the nudges and every message, each with a server-computed age, so the call renders as a missed-call entry and the messages render as messages.

## 10. Where this deliberately differs from Signal

No authenticated websocket drain — Supabase Realtime is 200 concurrent on Free, and a permanent foreground-service notification (Telegram-FOSS's price for having no FCM) would end the product, which is built on a disguised launcher. The drain is a REST cursor query. Signal sends no collapse key behind a real per-device queue; this design has no such queue, so exactly one collapse key does that coalescing work. Signal sends chat high-priority at a scale that absorbs the downgrade heuristic; this app cannot afford to spend high-priority budget on chat and then find the ring cannot start a foreground service.

## Invariants
- Per couple, cseq assignment order is commit order, because the counter row lock taken in the BEFORE INSERT trigger is held until COMMIT. If a reader can see cseq=N, every cseq<N for that couple is already visible. Therefore `WHERE couple_id=? AND cseq > cursor` can never skip a row. This is a property of Postgres row locking, not of client behaviour, and it is exactly what a bare `nextval` sequence (messages.seq, receipts_v2.sql:31) does not have.
- The notification obligation commits with the domain row, and the trigger that writes it cannot abort the domain write. `ON CONFLICT (dedupe_key) DO NOTHING`, no foreign keys out of push_outbox, no CHECK that can fail on a well-formed row, and no background job writes to the table — retention is partition DROP, never DELETE. A push-path fault can therefore never present to the user as 'your message did not send'.
- A row is claimable only when `state='pending' AND not_before <= now()`, and the claim atomically flips it to `inflight` with a lease. A worker that dies mid-send loses no work: the sweeper returns any row whose `lease_until < now()` to `pending`. A row leaves the queue only on a positive outcome or an explicit terminal state, never by omission. `FOR UPDATE SKIP LOCKED` makes K concurrent workers correct with no coordination.
- A collapse key is attached only to a class whose TTL is long enough for FCM to store the message, enforced by a CHECK on push_config (`collapse_key is null or ttl_seconds >= 3600`). Collapse only ever replaces a stored pending message, so on a short-TTL send it is pure cost against the collapsible throttle.
- Exactly one class in the app is collapsible. `call`, `reach` and `care` carry no collapse key and are therefore governed only by the per-device 240/min and 5,000/hour limits, never by the per-app-per-device 20-burst / 1-per-3-minute collapsible throttle. Chat volume cannot consume the ring's delivery budget, and the worker's server-side mirror of that bucket (capacity 12, refill 1 per 180 s) means the app cannot consume the collapsible budget faster than FCM refills it.
- Rows of priority_rank <= 1 (call, reach) bypass the rate guard entirely and are never deferred. Deferral is available only to care and message. This is a property of the claimed row, not of a branch in the worker.
- Every high-priority push this system emits terminates in a user-visible notification, because only `call` and `reach` are high-priority and both always post one. Foreground suppression is applied only to normal-priority classes. The Android 13+ HIGH→NORMAL downgrade heuristic is therefore structurally unreachable, which is what preserves the ability to start a foreground service for a ring.
- The worker's input is the outbox; the request body is discarded. An unauthenticated or forged wake can only cause the worker to drain rows an authorised writer already committed. The current 'anyone can POST and ring an arbitrary phone' hole is removed by the shape of the call, not by a check that could later be misconfigured.
- A given FCM token exists on at most one row per user (`unique(user_id, token_hash)`) and a row is never reassigned across users. A terminal FCM error mutates only the row for the device that produced it, so one device going UNREGISTERED can never silence a user's other phones, and no user can cause another user's device row to be deleted. Cross-user token collision is resolved only by FCM's own UNREGISTERED response, which is the sole authenticated ownership signal available.
- profiles.fcm_token is NULL at rest from the first migration onward, because a BEFORE UPDATE trigger relocates any written value into push_devices in the same statement. The unrestricted partner-readable SELECT policy at schema.sql:117-120 therefore has nothing to disclose, with no client release required to make that true.
- Push is a hint whose loss costs latency, never data — for all four classes. The payload carries a class tag, a couple id, an opaque row id and one integer; it cannot carry user content. The durable Postgres rows plus one per-couple cursor are the sole source of truth, and the catch-up covers messages, reaches, nudges and call invites alike. A dropped, collapsed, TTL-expired, throttled or force-stop-discarded push is recovered on next open.
- Every timestamp used in a comparison is a Postgres clock value. `fcm_accepted_at` and `push_receipts.inserted_at` are `now()`; `received_at` is derived as `now() − ack_delay_ms` where `ack_delay_ms` is a monotonic elapsedRealtime interval, not a wall clock; `RemoteMessage.sentTime` is stored as an opaque label compared only by equality; liveness of an event is a server-computed `age_seconds` returned by the catch-up RPC. The design is correct on a phone whose clock is a year off.
- Delivery is at-least-once at the transport and exactly-once at the display. The server may re-send after a crash between FCM's 200 and the `delivered_to` write; the notification id is a stable pure function of `rid` for all four classes and the call handler no-ops a second wake for an already-ringing call_id, so a duplicate wake produces no duplicate UI.
- A message is never marked delivered because FCM accepted it. FCM's 200 means Google accepted the message. Delivery is owned by the recipient device and is written only from push_receipts.
- The payload contains no user-authored content and no human-readable identifier. Privacy is a property of the payload, so it holds regardless of lock-screen settings, OEM logging, or what Google retains.
- Claim-time validation is part of the claim statement, not a code path: rows whose domain row no longer exists become `superseded`, message-class rows collapse to the greatest watermark, and rows whose recipients are all already at or past that watermark are dropped. None of these can be forgotten by a worker deployment.

## Scale ceiling
**Model.** Users are individuals, 2 per couple. Pre-coalescing ≈46 push-worthy events/user/day (≈40 chat messages received, 2 reaches, 2 nudges, 2 calls). Three server-side reducers apply: message-class supersede-to-greatest-watermark, the cursor skip for devices already caught up (a foregrounded partner on a live socket costs zero pushes), and the collapsible pacing. **≈12 pushes/user/day.** That is a design output, not an assumption — it falls out of the watermark payload. It is measured in Stage 0 before anything depends on it.

**FCM itself never breaks.** The project quota is 600,000 messages/minute, four orders of magnitude above 100k users. The binding limits are per-device (240/min, 5,000/hr; collapsible 20 burst + 1 per 3 min), and the design mirrors the collapsible bucket server-side with headroom so a bug costs a deferred `message` rather than an invisible throttle. `call` and `reach` are non-collapsible and cannot be throttled by chat at all.

---

**1,000 users — comfortable; the push domain fits inside Free.**
- 12k pushes/day = 0.14/s average, ~1.4/s at evening peak.
- Edge invocations: pg_cron at 10 s = 259k/month, plus debounced wakes fired only for `call` and `reach` (≈4k/day ≈ 120k/month). **≈380k/month, inside Free's 500k.**
- `push_outbox` 12k rows/day at ~250 B, 24 h retention ≈ 3 MB. `push_receipts` 12k/day × 7 days ≈ 84k rows ≈ 15 MB with its index. `cseq` costs one bigint plus one index per event table — single-digit MB.
- Client acks: 12k PostgREST writes/day. Supabase does not meter API request count; the cost is ~200 B each of egress (≈70 MB/month) and 0.14 inserts/s of Postgres write load.
- **Failure mode in this domain: none.** The app hits Pro for Realtime reasons long before push becomes a constraint — the free tier's real capacity is ~110 users on the Realtime message quota.

**10,000 users — needs Pro; push is still not the constraint.**
- 120k pushes/day = 1.4/s average, ~14/s peak.
- Edge invocations ≈ 1.2M/month, inside Pro's 2M.
- `push_outbox` ≈ 120k rows/day (~30 MB live at 24 h). `push_receipts` ≈ 840k rows live at 7 days ≈ 150 MB with index. Egress from acks ≈ 0.7 GB/month against Pro's 250 GB.
- **Failure mode: token rot, not throughput.** Firebase reports apps neglecting token hygiene losing ~15% of messages to inactive devices. Without `last_ack_at` quarantine that 15% is invisible. It is a data-hygiene problem, not a capacity one.

**100,000 users — the design holds; three things move.**
- 1.2M pushes/day = 14/s average, ~140/s peak.
- Edge invocations: 259k cron + debounced wakes. The debounce (one wake per 2 s project-wide, via a non-blocking advisory lock) caps wakes at ≤1.3M/month regardless of user count. **Total ≈1.5M/month, inside Pro's 2M** — the debounce is what makes this fit, and it is the reason wake count stops scaling with users.
- Postgres writes: 1.2M outbox inserts + ~1.2M updates + 1.2M receipt inserts + 1.2M `couple_seq` updates ≈ 55 writes/s. Nano's 250 baseline IOPS is too tight; Small/Medium compute is needed — which the app needs anyway.
- Storage: `push_outbox` ≈ 300 MB live at 24 h; `push_receipts` ≈ 8.4M rows live at 7 days ≈ 1.5–2 GB with the `(device_id, fcm_message_id)` PK index. Both are daily-partitioned and reclaimed by DROP, so there is no vacuum debt from 1.2M deletes/day. Against Pro's 8 GB this fits with room; at 30-day receipt retention it would not, which is why retention is 7 days.
- pg_net now carries only wakes (≤0.5/s) against its documented ~200 req/s ceiling. **This is the entire point of moving it off the per-event path** — the current design at 100k users would attempt 14/s sustained and ~140/s at peak through a 200/s budget shared with everything else, with silent loss above it.

---

**Ordered list of what actually breaks:**

1. **≈30k users** — the Edge Function's 2 s **CPU** limit per request (the real ceiling, not the 150 s wall clock) forces a choice between a longer cron interval and larger batches. Not a wall: bound each invocation by a ~20 s wall-clock budget and let the lease sweeper pick up the remainder.
2. **≈150k users** — one worker per tick can no longer drain. **No new mechanism is needed:** `SKIP LOCKED` already makes K concurrent workers correct, so run K cron jobs. Supabase guidance caps concurrent jobs at 8 and `breath_events` and `reach_pulses` already hold two, so the ceiling is ~6 workers minus whatever else is added. Folding drain + sweep + retention into one invocation keeps this domain's cost at one job.
3. **Past ~6 workers** — shard `push_outbox` on `hashtext(user_id) % K` with one cron job per shard, or move the worker off Edge Functions to a long-running process. Stated exit criterion, not a surprise.

**Declared latency cost, not discovered in production.** Because the wake fires only for `call` and `reach`, the pg_cron interval is the delivery floor for `message` and `care`: at the 10 s default that is a p50 of ~5 s and a p99 of ~10 s **for a backgrounded recipient in good network**. A foregrounded recipient is served by the Realtime socket and sees none of it; a Dozing recipient's latency is dominated by FCM and the maintenance window, not by the tick. The interval is a `push_config` value, so a Pro project can run a 2 s tick (≈1.3M invocations/month) or enable `message` wakes, and there is an SLI for it (§Verification). This tradeoff is bought deliberately to stay inside Free's 500k invocations.

**The failure mode at the ceiling is the important part: this design does not fail by dropping pushes, it fails by getting slower** — and that degradation is one queryable number, `p95(claim_time − created_at)` on `push_outbox`, which is also what the pure-SQL alarm watches. The current design's failure mode at any scale is silent permanent loss with an HTTP 200 in the logs.

**Honest caveat.** The 12 pushes/user/day figure rests on ≈40 received messages/user/day. If real usage is 200/day, every number multiplies by roughly 1.5–2 — coalescing and the cursor skip absorb most of the difference, which is precisely why they are in the design rather than beside it.

## Cost
**Headline: FCM has no marginal money cost at any scale in this document.** It is free on Spark and Blaze, no per-message charge, no message cap. Every cost below is Supabase-side. **The correct architecture is essentially free — this has been a design problem, not a budget problem, and no amount of spending would have fixed the current one.**

---

**1,000 users**
- FCM: **$0**
- Edge Functions: ~380k invocations/month (259k cron + ~120k debounced call/reach wakes) — inside Free's 500k and Pro's 2M. **$0**
- Database: `push_outbox` ~3 MB live (24 h), `push_receipts` ~15 MB live (7 d), `cseq` columns + indexes single-digit MB, `push_devices` negligible. **$0**
- Client acks: 12k PostgREST writes/day. Request count is not metered; egress ≈70 MB/month, write load 0.14/s. **$0**
- Egress, Supabase→Google: 12k × ~200 B/day ≈ 72 MB/month. **$0**
- **Push-domain marginal cost: $0.** Realistic total bill ~$58/mo (Pro), driven entirely by Realtime message volume. None of that is this domain.

**10,000 users**
- FCM: **$0**
- Edge Functions: ~1.2M/month — inside Pro's 2M included. **$0**
- Database: outbox ~30 MB live, receipts ~150 MB live, within Pro's 8 GB. **$0**
- Client acks: 120k writes/day ≈ 0.7 GB/month egress against Pro's 250 GB; 1.4 inserts/s. **$0**
- **Push-domain marginal cost: $0** on top of Pro. Total bill ~$500–560/mo, ~85% Realtime messages — again, not this domain.

**100,000 users**
- FCM: **$0**
- Edge Functions: ~1.5M/month, **inside Pro's 2M — $0.** (The wake debounce is what holds this flat; without it, per-event wakes would be ~3M/month and cost ~$2/mo. Cheap either way, but the debounce also protects pg_net's 200 req/s ceiling, which is not a money problem.)
- Database: ~4.8M writes/day; ~300 MB live outbox + ~1.5–2 GB live receipts at 7-day retention. Within Pro's 8 GB. Compute Large ~$110/mo is needed for the app regardless; attribute ~$0–30 here for the 55 writes/s this domain adds.
- Client acks: 1.2M writes/day ≈ 36M/month. Not metered per request; ~7 GB/month egress inside Pro's 250 GB; 14 inserts/s counted in the compute line above.
- Egress to Google: 1.2M × ~200 B/day ≈ 7 GB/month. **~$0**
- **Push-domain marginal cost: ~$0–30/mo** all-in, dominated by the compute tier the app needs anyway.

**Retention is the only cost that grows unattended, and it is bounded by policy rather than luck.** `push_outbox` daily partitions with `sent`/`superseded` reclaimed at 24 h and `dead` kept 30 days; `push_receipts` daily partitions at 7 days. **Reclaim is partition DROP, never DELETE** — that is both a cost decision (no vacuum debt on a 1.2M-row/day table) and a correctness one (a DELETE takes locks a domain writer could block on, which would turn the notification system into a chat outage). Also prune `cron.job_run_details` in the same job: it has no documented retention and grows forever on a 500 MB database.

**What the current design costs, in the currency that matters.** Not dollars. A per-invocation RS256 sign plus a Google token exchange is 200–300 ms on the critical path of every ring, thrown away immediately although the token is valid 3,600 s. Module-scope caching removes it for $0. Every transient FCM 503, every OAuth blip and every cold start past pg_net's 2 s default is a permanently lost call or message today, and none of it appears in any metric.

**One optional line item; skip it.** FCM BigQuery export requires Blaze. At 100k users and ~1 KB/row that is ~36 GB/month ≈ $1/mo storage plus query cost. The client ack in `push_receipts` gives strictly better data at strictly lower latency: BigQuery export propagates for up to 48 hours and the aggregated Data API is 7 days of history delayed up to 5 days — useless for "why didn't her phone ring twenty minutes ago", which is the only question anyone actually asks.

## Migration
**Every stage is independently shippable and independently revertible, and the order is chosen so that no stage re-opens something an earlier stage closed.** Two ordering rules are load-bearing and were violated by the previous plan: (i) the partner-readable token column is neutralised in Stage 1, not Stage 4, because `push_devices`' uniqueness rule would otherwise turn a read-only leak into a write primitive for three stages; (ii) the watermark and its catch-up land in Stage 2, *before* any class is cut over to a watermark payload in Stage 4, because "nothing is lost, it's just late" is a lie until the cursor exists for that class.

---

**Stage 0 — Observability and three free wins. Zero behaviour change. (~1 day.)**
This stage exists because every previous fix was validated with no data.
- Add `push_receipts` (daily partitions, 7-day retention). The background handler posts one row: `messageId`, `sentTime`, `priority`, `originalPriority`, `ack_delay_ms` from two `elapsedRealtime()` readings, 3 s timeout, buffered to SharedPreferences on failure.
- Cache the OAuth token in module scope inside the existing `reach-notify` — five lines, no schema change, immediate p50 win.
- Move `buildMsgChannel()` from `reach_notifications.dart:265` into `FcmService.init()` beside the other three.
- Set `timeout_milliseconds` explicitly on all four existing `net.http_post` calls so `net._http_response` stops being ambiguous.
- **Then wait a week and read the data.** You learn the true per-user push rate, the real arrival rate per device, and — from `originalPriority != priority` — whether Android is already downgrading you. Every later parameter decision is settled by this rather than argued.
- *Must not undo:* nothing; this stage is purely additive.

**Stage 1 — `push_devices`, and close the leak now. (~2–3 days.)**
- Create `push_devices` with `unique(user_id, token_hash)` and owner-only RLS, plus the SECURITY DEFINER registration RPC that writes `auth.uid()` and stamps `now()`.
- Backfill existing `profiles.fcm_token` values.
- Add the BEFORE UPDATE shim on `profiles`: relocate any written `fcm_token` into `push_devices` (legacy device_id derived deterministically from `(user_id, token_hash)`) and null the column and `fcm_token_updated_at` in the same statement. **The leak closes here, with no client release**, and the device-clock write at `supabase_repository.dart:396-398` stops reaching the database.
- `reach-notify` reads `push_devices` and fans out to every active row. Multi-device works from this point.
- *Rollback:* disable the shim trigger; the client re-registers on every foreground, so the old path is restored within one app open. That bound is the honest cost of closing the leak early, and it is stated rather than papered over.
- *Must not undo:* the uniqueness rule must never be widened to a global `unique(token_hash)`, and no code path may reassign a row across `user_id`.

**Stage 2 — The watermark and the cursor, for all four classes. (~3–5 days.)**
- Add `couple_seq`, add `cseq` to `messages`, `reach_events`, `care_nudges`, `call_invites`, backfill per couple in `created_at` order, seed the counter to `max`, then set NOT NULL and add `(couple_id, cseq)` indexes.
- Add the BEFORE INSERT assignment trigger and the `fetch_since` RPC returning all four classes with `age_seconds`, `server_now` and `has_more`.
- Ship the server first — the columns accumulate and nothing reads them. Ship the client after: persisted per-couple cursor, paging loop that continues until a short page, catch-up on foreground, socket open, push wake and `onDeletedMessages`, and rendering that decides live-vs-history from the server's `age_seconds`.
- **This is the stage that makes the promise true**, and it must be verified (Level 1 concurrency test) before Stage 4 begins.
- *Must not undo:* the chat catch-up must move off `.gt('seq', …)` (chat_repository.dart:183-189) and must not regain a bare `.limit(500)` without a continuation loop.

**Stage 3 — Outbox and worker, in shadow. (~3–5 days.)**
- Add `push_outbox` (daily partitions), the per-table AFTER INSERT trigger, the claim RPC with its three in-statement validations, `push_config`, and `push-drain` on pg_cron. **Leave the four pg_net triggers running.**
- The worker runs in shadow: it claims, expands devices, applies the rate guard and the collapsible bucket, builds the exact FCM request, and does not send. It records what it would have sent.
- Reconcile shadow output against `net._http_response` and `push_receipts`. **This is how the worker is verified without a second phone**: any divergence is a bug in the new path found before it can reach a user.
- *Must not undo:* the outbox is additive here; if it is wrong, delivery is unaffected.

**Stage 4 — Cut over one class at a time. (~1 day each.)**
- Order: **care → message → reach → call.** Lowest stakes first; the ring last, after the machinery has run in production for three classes.
- Each flip is one transaction: drop that class's pg_net trigger (DDL) and set `push_config.enabled` with that class's priority / TTL / collapse-key / rank (DML). There is never a window in which both paths send, and never one in which neither does.
- `push_config` holds the parameters, so a bad flip is an `UPDATE` — a rollback measured in seconds, at 3 a.m., by someone who is not the author.
- *Must not undo:* `message` cannot be flipped before its catch-up shipped in Stage 2, and no class may be given a collapse key with a TTL under an hour (enforced by the CHECK, not by review).

**Stage 5 — Cleanup and hardening. (~1 day.)**
- Drop `profiles.fcm_token`, `fcm_token_updated_at` and the shim trigger.
- Drop `notify_reach`, `notify_care`, `notify_call`, `notify_message`.
- Add the debounced statement-level wake (advisory-lock gated, `call`/`reach` only) and the retention job: partition DROP for outbox and receipts, plus pruning `cron.job_run_details`.
- Add the shared secret on `push-drain` — defence in depth only; the "anyone can ring any phone" hole closed in Stage 4 when the last pg_net trigger died, because the worker already ignores its request body.

**Stage 6 — Health, quarantine, alarms, user comms. (~3–5 days.)**
- Health reporting into `push_devices.health` on every foreground; the four conditions computed separately.
- Quarantine from high-priority sends only, with retroactive clearing.
- The pure-SQL staleness alarm, the external dead-man's-switch pinger, and the CI emulator canary.
- The OEM onboarding/diagnostics screen with per-manufacturer deep links, and the partner-facing surface restricted to `token_dead` and `force_stopped` — gated on the open decision below.

---

**Two properties that keep this safe.** The outbox is additive until Stage 4, so Stages 1–3 cannot break delivery even if they are wrong. And no stage requires the client and the server to ship together: Stage 0's ack works against the old backend, Stage 2's server half works against the old client, and Stage 3's outbox works against the old client. **Nothing here needs a coordinated release**, which matters for an app distributed privately with no forced-update channel.

**Blocking prerequisite, not in this domain.** Schema management is rated fatal in `inventory/rest.md:262-269`: 43 loose SQL files applied by hand, four live tables with no DDL anywhere (`care_nudges` among them — this design adds a trigger and a column to a table that has no definition in the repo), no `migrations/`, no `config.toml`. Without it, these tables become files 44–48, Levels 1–2 of the verification plan have no environment to run in, and Stage 4's per-class cutover cannot be rehearsed anywhere but production. **Do it before Stage 2** — Stage 2 is the first stage that alters existing tables rather than adding new ones, and it is the first that cannot be rolled back by dropping a table.

## Verification
**Premise: the receiving device's OS state was always the interesting variable, and the second phone never was.** Two NTP-synced phones on one wifi exercise precisely the code path that already works. Everything below runs on zero or one device.

**Level 1 — Pure SQL, deterministic, in CI (pgTAP or plain assertion SQL).**
- **The commit-order test, which is the whole design.** Session A `BEGIN`, insert a message for couple C, do not commit. Session B insert a message for the same couple — assert it *blocks*. Commit A, then commit B. Assert `A.cseq < B.cseq` and that a reader taking a snapshot between the two commits sees A and not B. Then the inverse: assert there is no interleaving in which a committed row with `cseq = N` coexists with an uncommitted `cseq < N` for the same couple. This is the test the previous design could not have written, because `nextval` fails it.
- Insert a domain row in a transaction and **roll back** → assert zero outbox rows and no counter advance visible. Proves the same-transaction invariant that pg_net structurally cannot satisfy.
- Insert and commit → exactly one outbox row with the expected `dedupe_key`. Insert the same domain row twice → the unique constraint absorbs it and the domain insert still succeeds (proves the trigger cannot fail a user write).
- **Two `psql` sessions calling the claim RPC concurrently → disjoint result sets.** Proves `SKIP LOCKED`. No application code.
- Backdate `lease_until`, run the sweeper → row returns to `pending`, `attempts` unchanged, `not_before` backed off.
- Insert 10 message-class rows for one user, claim → 1 `pending` carrying `max(watermark)`, 9 `superseded`.
- Insert a `call` row with `created_at` 60 s in the past → the claim marks it `superseded`, **not** `sent`.
- Insert an outbox row, then delete the domain row (simulating `clear_conversation_everyone`) → the claim marks it `superseded` and never builds a send.
- Set every active device's `cursor_seq` at or above a row's watermark → the claim drops it.
- Set `push_devices.collapsible_tokens = 0` → a `message` row defers; a `call` row sends anyway. Proves the rank ≤ 1 bypass.
- Insert 12 message-class rows for a device with 12 tokens, then a 13th → assert the 13th is deferred by ≥180 s, and that no non-collapsible class was affected.
- `fetch_since(0)` after inserting one row of each class → four rows in `cseq` order, each with a plausible `age_seconds` and `server_now`, `has_more=false`. Insert 501 rows with `limit=200` → three pages, third short, cursor monotone, no row returned twice or skipped.
- Attempt, as user A, to insert a `push_devices` row with user B's `token_hash` → assert it creates A's own row and does **not** delete or reassign B's. Then assert `select fcm_token from profiles` returns NULL for every row.

**Level 2 — The worker against a fake FCM. The decisive level.**
Point the endpoint at a stub returning on demand: 200; 404 `UNREGISTERED`; 503; 429 with `Retry-After`; `SENDER_ID_MISMATCH`; and a 5 s hang. Assert the resulting `push_outbox.state`, `attempts`, `not_before`, `last_error_class`, and `push_devices.fcm_state` for each. Assert `UNREGISTERED` on one device leaves the user's sibling device untouched. Assert the crash boundary explicitly: kill the worker between the stub's 200 and the `delivered_to` write, run the sweeper, and assert the re-send happens and that both sends carry the **same** `rid` — i.e. that the client-side dedupe key is what absorbs it.
**These are the exact paths every production failure takes, and no amount of real-device testing can exercise them** — you cannot make Google return 503 on command. The current design has never executed one of them, which is precisely why every fix "passed".

**Level 3 — One device, adversarial, via adb. The "sender" is a `curl` that inserts a domain row.**
- `adb shell dumpsys deviceidle force-idle` → assert normal-priority is held and high-priority arrives.
- `adb shell am set-standby-bucket <pkg> restricted` → network is disabled in this bucket. Assert the notification still displays, the ack buffers, `health` reports `net_restricted`, and **no quarantine fires and nothing is shown to the partner**. This is the regression test for the false-accusation bug.
- `adb shell am force-stop <pkg>` → assert no push arrives, assert the receipts gap, assert quarantine fires after three high-priority sends over >10 min, assert `wasForceStopped()` is reported on next open, and assert the catch-up recovers **a message, a reach, a nudge and a missed call**. That last assertion is what proves "nothing is lost, it's just late" for all four classes rather than for one.
- Send the same push twice with one `rid` → assert exactly one notification and, for a call, exactly one ring.
- Revoke POST_NOTIFICATIONS → assert `notifications_denied` in health and the in-app prompt.
- Android 14 with FSI revoked → assert graceful degradation to a heads-up notification with a direct `PendingIntent`, never `startActivity()` from the receiver.
- Cold-install with the app never foregrounded, then push a `message` → assert the notification displays, which is the Android 13 channel-in-background trap the `buildMsgChannel()` move fixes.

**Level 4 — Detection that does not ride the chain it watches.** Three independent pieces, because the previous single canary could not detect its own outage and needed a phone in a drawer:
1. **A pure-SQL pg_cron job with no HTTP in it**: if `max(now() − created_at) where state='pending'` exceeds 2 minutes, insert into `push_alerts`. This detects a dead worker, a dead Edge deployment or a dead pg_net, because it depends on none of them.
2. **An external dead-man's switch.** Any free uptime pinger hits a `push-health` endpoint that returns 500 when `push_alerts` is non-empty or the oldest pending row is stale, and **the pinger alarms on silence**. This is the only mechanism that survives total project death (pg_cron down, pg_net down, Edge down), and it is the direct answer to "the fix passed and then failed in production". `push_alerts` therefore has a named reader; a table nobody queries reproduces the invisibility being fixed.
3. **The device leg runs on an Android emulator with Play Services on a CI box**, not a physical OEM handset that MIUI/OxygenOS will force-stop within a week. The probe SLI is split into `fcm_accepted` and `device_acked` so a dead canary device is distinguishable from a dead pipeline.

**Level 5 — Three SLIs that replace argument with a number.**
- `p50/p95 (push_receipts.received_at − push_outbox.fcm_accepted_at)` per class per device, where `received_at = inserted_at − ack_delay_ms` and rows with `ack_delay_ms > 60 s` are excluded and reported separately as buffered. Both terms are Postgres clock values and the correction is a monotonic interval, so this is true latency on a phone whose clock is a year off — the previous formulation measured buffer-flush delay and called it latency.
- `1 − count(receipts) / count(outbox where state='sent')` per device over 24 h — the true drop rate, per device.
- `p50/p95 (claim_time − created_at)` per class — the queue-latency number, which is also what the Level 4 alarm watches, and which makes the declared `message` cron-tick floor a measured value rather than an assumption.

None of these needs a second phone, a second network, or a synchronised clock. "Is push working?" becomes a `SELECT`.

---

**Flagged gap, stated plainly.** None of the above proves the notification was *visually presented* — only that the isolate ran and acked. `plugin.show()` returns normally when the channel is disabled. Polling `NotificationManager.getActiveNotifications()` ~500 ms after posting and setting `push_receipts.displayed` closes most of it. **Whether a human noticed it is not mechanically checkable and I will not claim otherwise.**

**Second flagged gap.** Levels 1–2 need a reproducible schema to run in CI. `E:/LDR/supabase` is 43 hand-applied files with no `migrations/`, and `care_nudges` — a table this design adds a trigger and a column to — has no DDL in the repo at all. Until that is fixed, Levels 1–2 can only run against production, which defeats their purpose. **That is the single hardest prerequisite in this design and it is not optional.**

## Accepted limits
**1. Force-stop is unfixable, and this design does not pretend otherwise.** `FLAG_STOPPED` means nothing in the app runs, receivers included, until the user launches it. Android 15 additionally cancels all pending intents. On the three phones in play — IN2015 and OnePlus 7 (both 5/5 on the OEM kill catalogue) and a Vivo (3/5) — swipe-away-from-Recents does this routinely. *Residual risk:* a call to a force-stopped phone does not ring, ever, and there is no server-side mitigation. What the design buys is that the missed call, and everything else, is recovered in full on next open, and that the caller is told the one unambiguous true thing (`force_stopped`) instead of nothing.

**2. Two device states remain indistinguishable from the server: "push not delivered" and "push delivered, notification displayed, device has no network to ack".** In the RARE and RESTRICTED standby buckets network is disabled while `plugin.show()` works fine. *Residual risk:* quarantine can still fire on a phone that is working. The design contains this rather than closing it — quarantine is computed only from high-priority classes (the only ones granted temporary network), late acks clear it retroactively, and **nothing but `token_dead` and `force_stopped` is ever shown to the partner**. The cost is that a genuinely unreachable phone in a bucket-restricted state produces no partner-facing warning. That is the correct trade in an app built around concealment: a false accusation about a partner's device is worse than silence.

**3. Duplicate display is possible in one window.** If the worker receives FCM's 200 and dies before writing `delivered_to`, the sweeper re-sends. *Residual risk:* a second wake. The stable `rid`-derived notification id makes it a no-op for the notification, and the call state machine no-ops a second wake for a ringing `call_id` — but a duplicate haptic in the sub-second window before the first wake has registered its state is possible. "Duplicate notification is impossible" was false and is not claimed.

**4. `message` has a declared latency floor.** Because the wake fires only for `call` and `reach` (to stay inside Free's 500k Edge invocations), the pg_cron interval is the floor for `message` and `care`: p50 ≈5 s, p99 ≈10 s at the 10 s default, **for a backgrounded recipient in good network**. A foregrounded recipient is served by the socket; a Dozing one is dominated by FCM. This is bought deliberately, is a `push_config` value, and has its own SLI. It is not free and it is not hidden.

**5. The collapsible bucket still exists for `message`.** Under sustained chat to a backgrounded, acking device, the server-side bucket (12 tokens, refill 1 per 180 s) drains and message doorbells fall toward one per three minutes. *Residual risk:* an individual chat message can be up to ~3 minutes late to notify in that regime. Nothing is lost — every doorbell carries the newest watermark and the catch-up returns the whole backlog — and `call` and `reach` are unaffected because they are non-collapsible. Removing the collapse key entirely would trade this for the 100-pending-non-collapsible cliff, which discards *all* stored messages at once; that is the worse failure.

**6. `cseq` guarantees commit order per couple, not global order, and it costs a row lock.** A couple's two writers serialise on `couple_seq` for the duration of a single-statement insert. *Residual risk:* if a domain insert is ever batched into a long transaction, the partner's insert blocks for that transaction's lifetime. Mitigation is a `statement_timeout` and a rule that domain inserts are single-statement, but the rule is a convention, not a constraint — this is the one place the design depends on how a future writer is written.

**7. `messages.seq` is left in place and is now a second, differently-ordered integer.** Push and recovery use `cseq` only, so the promise does not depend on `seq`. But `chat_receipts.delivered_seq`/`read_seq` still compare `seq`, and `seq` order can differ from `cseq` order for two concurrent inserts. *Residual risk:* a read-tick can render against a slightly different order than the message list. It is a display inconsistency, not data loss, and retiring `seq` belongs to the messaging domain.

**8. Google still learns the metadata.** The payload carries no content and no human-readable identifier, but FCM sees that a push happened, to which device, when, with which priority and TTL, and it sees `couple_id`. Treating `couple_id` as secret is already fiction — it is the first path segment of every never-expiring public `couple_media` URL. An opaque per-device `thread_ref` is cheap and deferred (see open decisions).

**9. Whether a human saw the notification is not mechanically checkable**, and the `getActiveNotifications()` poll only proves the OS held it.

**10. Everything here is gated on schema reproducibility.** 43 hand-applied SQL files, no `migrations/`, and `care_nudges` — which this design puts a trigger and a column on — has no DDL in the repo at all. Until that is fixed, Levels 1–2 of the verification plan can only run against production. That is stated as a blocking prerequisite, not a nice-to-have.

## Open decisions
**1. Does chat really drop to normal priority? — Recommend YES, decide with Stage 0's data.**
Android 13+ downgrades HIGH→NORMAL for apps whose high-priority pushes don't produce notifications, and a downgraded message cannot start a foreground service. Today every chat message is high and `fcm_service.dart:139-146` deliberately shows nothing in the foreground — the app is training FCM to downgrade it, and the cost lands on the ring. Against: a couples app's chat *feels* urgent, and normal priority means a bounded Doze delay (`ttl=86400s` means FCM stores rather than drops).
**Recommendation: ship normal, then read `originalPriority != priority` from `push_receipts`.** If downgrades were never happening on these devices, revert with one `push_config` UPDATE. Stage 0 exists so this is measured rather than argued; today it is being decided by accident.

**2. Do you tell the sender the recipient's phone is unreachable? — Recommend YES, but only for two conditions.**
This is the highest-value product output and it answers "she never texted me". It is also a surveillance signal about a partner's device state, in an app built around concealment, and receipt timing is a documented screen-state side channel.
**Recommendation: surface only `token_dead` and `force_stopped` to the partner** — the two conditions the server can state without lying — and never with a timestamp, never per-message. `unreachable_suspected` and `net_restricted` go to the device's own owner and to diagnostics only, because the server cannot distinguish "not delivered" from "delivered, displayed, cannot ack" in the RARE bucket. This is a product decision for the owner, not an engineering default, and the previous design's version of it would have told a partner a false thing about a working phone.

**3. Quarantine threshold. — Recommend 3 consecutive unacked high-priority sends spanning >10 minutes, with retroactive clearing.**
Too aggressive and a subway ride quarantines a healthy device; too loose and a force-stopped phone goes undetected for days. The 10-minute span is what prevents three pushes in one dead spot from tripping it, and restricting the input to `call`/`reach` is what prevents normal-priority chat (which gets no temporary network grant) from generating false positives.
**Recommendation: ship 3/10min, then tune from the real ack-rate distribution.** This number cannot be chosen correctly before Stage 0.

**4. Cron interval, and whether `message` gets a wake. — Recommend 10 s and no message wake on Free; 2 s or message wakes on Pro.**
This is the declared `message` latency floor (p50 ≈5 s). At 10 s the domain fits in Free's 500k invocations; at 2 s it needs Pro's 2M. Both are `push_config` values.
**Recommendation: start at 10 s, watch `p95(claim_time − created_at)`, and move it the day the app is on Pro.** State the number in the SLI dashboard so the tradeoff is visible rather than discovered.

**5. How opaque should `couple_id` be in the payload? — Recommend leave it for v1.**
Treating it as secret is already fiction: it is the first path segment of every never-expiring public `couple_media` URL, which `hardening_2026_08.sql:25` admits. An opaque per-device `thread_ref` costs one column and one lookup, but it hardens a door in a wall that has a hole in it.
**Recommendation: fix the public bucket first; add `thread_ref` when the id is actually secret.** If the owner wants it now, it is cheap — say so and do it.

**6. Retention. — Recommend `push_outbox` 24 h for `sent`/`superseded` and 30 d for `dead`; `push_receipts` 7 d.**
7 days on receipts, not 30: the debugging question is always "last night", and 30 days is what took the storage line off by ~20x at 100k users. Reclaim by partition DROP, never DELETE — that is a correctness decision as much as a cost one, because a DELETE takes locks a domain writer can block on. **And prune `cron.job_run_details` in the same job**; it has no documented retention and grows forever on a 500 MB database.

**7. Cron budget. — Recommend one job for this domain.**
Supabase guidance is ≤8 concurrent jobs, ≤10 min each; `breath_events` and `reach_pulses` already hold two. Fold drain + lease sweep + retention into one `push-drain` invocation, staged internally. That budget is also the horizontal-scaling ceiling identified in the scale section — spending it carelessly now caps you at ~150k users later.

**8. The blocking prerequisite the owner must accept or reject: fix schema reproducibility before Stage 2.**
43 hand-applied files, no `migrations/`, no `config.toml`, and four client-referenced tables with no DDL — including `care_nudges`, which this design adds a column and a trigger to. Without it, these tables become files 44–48, Levels 1–2 of the verification plan have no environment, and Stage 4's per-class cutover cannot be rehearsed anywhere but production. Stage 2 is the first stage that alters existing tables rather than adding new ones, so it is the first that cannot be rolled back by dropping a table.
**Recommendation: do it before Stage 2.** It is boring, it is not this domain, and it is the reason every previous fix could only be validated by pointing two phones at each other.
