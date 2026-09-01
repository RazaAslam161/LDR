> **Partly superseded by [`../CONTRACT.md`](../CONTRACT.md).** This document was written
> before the cross-domain reconciliation. Where it disagrees with the contract, the
> contract wins. Specifically superseded here:
>
> - **R4** — pg_cron budget — slots are allocated centrally, not per domain
> - **GRANT-LANDMINE** — the profiles column-grant landmine and its CI assertion
>
> Reasoning: `../RECONCILIATION.md`. Corrections that verification forced:
> `../RECONCILIATION-REPAIRS.md`.

# calling (revised)

## What changed vs v1
FATAL 1 — "ring_ack/accept_call gate on exact state equality, so the second drain cancels the ring."
CLOSED. Both RPCs are now monotone compare-and-set exactly like end_call: `state_ord = greatest(state_ord, N)` with a range guard (`state_ord < 30` for ring_ack, `state_ord < 90` for accept_call), never `= 10` / `= 20`. Monotonicity is no longer an RPC convention at all — a BEFORE UPDATE trigger on `calls` raises unless `NEW.state_ord >= OLD.state_ord` and forces `end_reason = coalesce(OLD.end_reason, NEW.end_reason)`, `created_at`/`expires_at` unchanged. Any future RPC, any hand-run UPDATE, any repair script inherits it. ring_ack returns FOUR codes (`ring`, `accepted`, `already_ended`, `expired`) and accept_call returns `accepted` / `accepted_elsewhere`; "zero rows" is never collapsed into `expired`, and a transport error maps to a distinct client-side `unknown` that is defined to change nothing. Same-device re-accept is `answered_by_device = coalesce(answered_by_device, p_device_id)` — idempotent success, so a fast Answer tap on a single-device couple cannot lose to its own earlier drain. Cannot regress: the monotonicity guard is a table trigger, and the "only `expired`/`already_ended`/`accepted-elsewhere` may cancel a ring" rule is a headless Layer-2 test that feeds the same push twice and asserts the notification survives.

FATAL 2 — "Redial by the same caller is misclassified as glare; `glare_lost` tells the caller to attach to a dead PeerConnection."
CLOSED. `start_call` branches on caller identity BEFORE any tie-break. `live.caller_id = auth.uid()` is a redial, not glare: the live row is ended with `end_reason='superseded'`, no hangup signal is emitted, and the new call is inserted unconditionally. The 128-bit tie-break is reserved for `live.caller_id = the partner`, which is the only case that is actually two humans dialling. And the glare-loser return is now actionable rather than aspirational: it carries the surviving call's id, offer SDP, ICE servers and seq cursor, so the loser answers the call already in flight in one round trip instead of being told to "attach" to something it cannot reconstruct. Cannot regress: Layer-1 SQL test dials twice as the same user against a live row and asserts `started` + `superseded` in both call_id orderings (the old code was a coin flip, so an ordering-blind test catches it).

FATAL 3 — "The ring is gated on a successful server round trip; on the killed-app path a failed fetch means the phone never rings."
CLOSED, and this is the single most important change. The order is inverted: the CallStyle ring is posted from the FCM payload ALONE, with zero network calls, before anything else. The payload carries `{t:'call', cid, v, rem_ms}` — call id, video flag, and the remaining ring window in milliseconds computed server-side at send. The self-cancel timer is armed on `SystemClock.elapsedRealtime()` from `rem_ms`, so it needs neither the network nor the wall clock. `ring_ack` is demoted to a background advisory whose only power is to CANCEL an already-showing ring on a definitive `expired` / `already_ended` / accepted-elsewhere; a timeout or a 500 leaves the ring standing. The offer SDP moved off the ring path entirely and onto the Answer path, where `accept_call` returns offer + ICE servers + seq cursor in ONE round trip at a moment when the user has demonstrably granted attention and the app is launching anyway. Net effect: the killed-app ring needs strictly fewer network operations than today's broken code, not more, and the server-owned freshness gate is preserved — a stale ring is cancelled within a round trip instead of never being shown. Cannot regress: Layer-2 test posts a push with every network call stubbed to throw and asserts the notification is posted; that test is the acceptance gate for the domain.

FATAL 4 — "`unique (couple_id) where state_ord < 90` turns an abandoned dial into a permanent per-couple calling outage."
CLOSED. The index is demoted to a backstop; the reaping authority is `start_call` itself. Every `start_call` takes `pg_advisory_xact_lock` on the couple as its first statement, then reaps before it decides. Note the attack's own suggested repair (`state_ord < 90 and now() >= expires_at`) is WRONG as literally stated — it would reap a live connected call 60 seconds in, because `expires_at` is the RING window and a connected call outlives it. The corrected reaping predicate has three arms: `state_ord < 30 AND clock_timestamp() >= expires_at` (unanswered ring), `state_ord >= 30 AND clock_timestamp() >= keepalive_at + 90s` (accepted call whose parties both went silent), and `clock_timestamp() >= created_at + 4 hours` (unconditional ceiling). `keepalive_at` is bumped by every signal write and by a 15 s `call_keepalive` RPC. A stale row therefore cannot survive the next dial by either partner, so no operator and no cron is on the correctness path. A 30 s pg_cron sweeper runs the identical predicate for telemetry hygiene only, and its interval is now named. Cannot regress: Layer-1 test inserts a row at state 10 with a backdated `expires_at` and a row at state 40 with a fresh `keepalive_at`, then dials — asserts the first is reaped and the dial succeeds, and asserts the second is NOT reaped.

FATAL 5 — "The broadcast trigger runs inside the durable transaction, so a Realtime failure aborts `start_call`."
CLOSED, with a documented Supabase property doing the work. `realtime.broadcast_changes` is dropped. Notification is emitted by the RPC body calling `realtime.send(payload, event, topic, private)` as its last act, wrapped in a `BEGIN … EXCEPTION WHEN OTHERS THEN NULL; END` subtransaction. research/supabase.md:88 documents that `realtime.send` already catches its own exceptions and reports them via `pg_notify` rather than raising, precisely so "a Realtime-side failure cannot roll back your business transaction" — the subtransaction is belt-and-braces for the residue (permission drift, a missing partition surfacing outside `realtime.send`'s own handler). Cannot regress: a Layer-1 test revokes INSERT on `realtime.messages` and asserts `start_call` still commits, still writes the offer signal, and still writes `push_outbox` rows.

SERIOUS, ALSO CLOSED:
• Device-clock timers (flaw 5). No absolute timestamp is ever issued to a client for an expiry decision. The server issues DURATIONS (`rem_ms`, `expires_in_ms`, `client_ttl_seconds`) and the client measures them on `SystemClock.elapsedRealtime()`. If elapsedRealtime goes backwards (reboot), any cached duration is treated as expired. The design's old ServerClock dependency is deleted rather than patched — I verified `ServerClock._offset` is a static in-memory field fed from exactly one call site (presence_service.dart), so it is provably zero in an FCM background isolate; a design that depends on it on the cold-start path is a design that depends on the device clock.
• TURN "late credentials" (flaw 6). Removed as a case: `start_call`, `ring_ack` and `accept_call` all return `ice_servers` from a server-side `turn_cache`, so the dial and the answer each carry their own credentials with zero extra round trips. Where a renegotiation genuinely is required (relay escalation, mid-call restart) the design now names it: an explicit `ice_restart` signal kind, issued by the caller (impolite role read from `calls.caller_id`), ordered by the seq cursor. No more claiming a `setConfiguration()` regather is free.
• RLS vs SECURITY DEFINER (flaw 8). Resolved structurally, not by picking a side. Party membership and self-attribution are enforced by a BEFORE INSERT TRIGGER on `call_signals`, and triggers are NOT bypassed by SECURITY DEFINER — `auth.uid()` reads the request JWT GUC, which a definer function does not change. `seq` is likewise assigned by trigger (it overwrites whatever the caller supplied), so "the client sends the right integer" is not merely disallowed, it is unrepresentable. RLS SELECT policies stay live for the catch-up query, which is direct SQL. Layer-1 tests drive both the RPC path and the direct-table path.
• No dial rate limit (flaw 9). `start_call` rejects with `rate_limited` above 6 dials per couple per caller per 5 minutes, counted in the same transaction. Priority hygiene is enforced in the SENDER: `push_outbox` carries `priority` with `CHECK (priority <> 'high' OR kind = 'call')`, plus a per-device high-priority budget row that refuses beyond 60/hour. Both are server-side; neither is client policy.
• Outbox cadence (flaw 10). Calls get their own pg_cron drain at 1 s with fixed 1/2/4/8 s retries and a hard stop at `expires_at`; a call push is never sent with `ttl=0` — it is abandoned and recorded as `push_abandoned`. Chat and nudges keep the 10 s exponential drain.
• `expires_at` generated column (flaw 11). Replaced with `timestamptz not null default (now() + interval '60 seconds')`, INSERT privilege on the column revoked from `authenticated`, and the BEFORE INSERT trigger overwrites it regardless. A client-supplied value is ignored by construction, tested in Layer 1.
• `device_id` does not exist (flaw 12). Promoted to an S1 prerequisite: a UUID minted on first run into `flutter_secure_storage` (Keystore-backed; the app already ships crypto_core). `device_tokens` is unique on `(user_id, device_id)` with `token` as an updatable attribute, so a token refresh updates a row instead of orphaning one. TURN mint quota keys on `user_id` alone so a device_id reset cannot reset it.
• SDP at rest (flaw 15). `end_call` NULLs every `call_signals.payload` for the call in the same transaction, and the Layer-B broadcast carries `{call_id, seq, kind}` only — no SDP ever enters `realtime.messages` and therefore never inherits its 72 h–4 day retention. Both tables are daily-partitioned with partition DROP, never DELETE.
• Migration big-bang (flaw 7). `call_id` on the wire moves from S6 all the way to S1 as an additive envelope field, gated by a `profiles.client_caps` bit so a keyed pair gets the fix immediately and a mixed pair is exactly the status quo. S3 no longer makes the false "both paths are idempotent under the seq-cursor rule" claim.
• Verification (flaw 14). Layer 3 is split: FSM/signalling runs headless in the Dart VM against a hostile fake channel with NO PeerConnection; media/traversal runs only in the NAT harness. A daily CI contract test hits the LIVE `turn-credentials` function and fails the build on a response-shape change — the one test that would have caught the two-month bug.
• S0 breaks care reminders (flaw 17). S0 now enumerates and updates all four `reach-notify` callers (`notify_reach` in fcm_push.sql, `notify_care` and `notify_call` in 20260628_care_call_push.sql, `notify_message` in message_push.sql) in one migration, with a Layer-1 assertion that no trigger body contains a `net.http_post` to that URL without an Authorization key.
• Cost and scale framing (flaws 13, 16). Cost re-derived with +20% protocol overhead, a `call_events` line with stated retention, a Realtime egress line, and partition-drop pruning. Scale ceiling now LEADS with the device axis.

NOT CLOSED — moved to accepted_limits with residual risk stated: the relay bitrate clamp (unenforceable server-side in a P2P architecture), client-side seq-cursor reconciliation, force-stopped devices, and the CallStyle-vs-disguise tension.

## Target architecture
## The one mechanism

Call setup lives on a durable, ordered, server-authored log in Postgres. FCM is a doorbell that carries enough to RING WITHOUT ASKING PERMISSION. The websocket is a foreground latency optimisation and nothing else. Every ordering, freshness and identity decision is made by a Postgres trigger or an RPC under an advisory lock; every timing decision on a device is a server-issued DURATION measured on a monotonic counter.

The single sentence that distinguishes this from the version that failed review: **the phone rings before it talks to the server, and the server can only ever cancel that ring, never authorise it.**

---

## 1. Data model

**`calls`** — one row per call ATTEMPT; the serialization point.

`id uuid pk` (the call_id, present in every signal) · `couple_id uuid` · `caller_id uuid` · `callee_id uuid` · `video boolean` · `state_ord smallint` (10 dialing, 20 ringing, 30 accepted, 40 connected, 90 ended) · `end_reason text` ∈ {normal, declined, busy, no_answer, media_failed, glare_lost, recall, superseded, accepted_elsewhere, declined_elsewhere, need_permission, expired, lost, signal_gap, rate_limited} · `created_at timestamptz not null default now()` · `expires_at timestamptz not null default (now() + interval '60 seconds')` — a PLAIN column with a server default, not a generated column (`timestamptz + interval` is STABLE, not IMMUTABLE, so a STORED generated column will not create); INSERT on this column is revoked from `authenticated` and the BEFORE INSERT trigger overwrites it unconditionally · `accepted_at`, `connected_at`, `ended_at timestamptz` · `answered_by_device text` · `keepalive_at timestamptz not null default now()` · `signal_seq bigint not null default 0`.

Indexes: `unique (couple_id) where state_ord < 90` — a BACKSTOP, not the gate (see §3 reaping); `(callee_id) where state_ord < 90`; `(couple_id, caller_id, created_at desc)` for the dial budget; `(couple_id, state_ord, expires_at)` for the sweeper.

**`call_signals`** — the durable ordered log. `call_id uuid` · `seq bigint` · `from_user uuid` (null for system rows) · `from_device text` · `to_user uuid` · `kind text` ∈ {offer, answer, ice, end_of_candidates, ice_restart, renegotiate, hangup, busy, accepted_elsewhere, declined_elsewhere, end} · `payload jsonb` · `created_at timestamptz not null default now()`. **Partitioned by range on `created_at`, one partition per day**, with a pg_cron job that CREATEs tomorrow's and DROPs any older than 2 days — copying `realtime.messages`' own shape, because 42M rows/month removed by DELETE is autovacuum debt on a table that also serves the latency-critical catch-up range scan. Index `(call_id, seq)` per partition, plus `(to_user, call_id, seq)`.

Note honestly: because the partition key must participate in any unique constraint, `(call_id, seq)` is a lookup index, not a uniqueness constraint. Uniqueness of `(call_id, seq)` is guaranteed by the counter under the `calls` row lock (§2), not by an index. That is stated so nobody later "fixes" it by adding a global unique index that cannot exist.

**`call_events`** — telemetry spine. `(call_id, device_id, event, at timestamptz default now(), meta jsonb)`; events `push_sent, push_received, ring_shown, ring_cancelled(reason), answered, first_media, ice_pair_type, ended, push_abandoned`; meta carries `Build.MANUFACTURER`, model, API level, `priority`, `originalPriority`, `messageId`, `sentTime`. **Daily-partitioned, 30-day retention by partition drop.** No content, ever.

**`device_tokens`** — `(user_id, device_id)` PRIMARY KEY, `token text not null`, `platform`, `last_seen_at`, `created_at`. Replaces `profiles.fcm_token`, which is a single scalar column and therefore caps every user at one device by construction. Token is an UPDATABLE ATTRIBUTE of the (user, device) pair, so a token refresh updates a row rather than orphaning one. A separate `device_push_budget (user_id, device_id, hour_bucket, high_count)` enforces the high-priority ceiling server-side.

**`push_outbox`** — `(id, user_id, device_id, kind, priority, payload jsonb, attempts, next_attempt_at, deadline_at, state ∈ pending|sent|dead|abandoned, fcm_message_id, last_error)` with `CHECK (priority <> 'high' OR kind = 'call')`. Priority hygiene becomes a database constraint rather than a coding standard.

**`turn_cache`** — one row: the last-known-good ICE server set, `client_ttl_seconds`, `requested_ttl_seconds`, `relay_max_kbps`, `refreshed_at`. Refilled by the edge function; READ by the call RPCs so a dial never costs a second round trip.

**`turn_grants`** — `(id, user_id, device_id, call_id, cf_username, issued_at, client_ttl_seconds, requested_ttl_seconds, revoked_at)` with `CHECK (client_ttl_seconds <= requested_ttl_seconds)`. Signal-Server asserts this two-TTL invariant in a Java `@AssertTrue`; here it is a table constraint, so no code path can issue a client TTL longer than the credential actually lives.

**`device_id` provenance** (it exists nowhere in the app today — grep of `mobile/lib` for `device_id`/`deviceId` returns zero hits): a UUID minted on first run and stored in `flutter_secure_storage` (Android Keystore-backed; the app already ships crypto_core, so this is not a new dependency). It survives "clear data" on most ROMs and is regenerated silently if lost — which is safe because `device_tokens` is keyed `(user_id, device_id)` with the token as an attribute, and the TURN mint quota keys on `user_id` alone so a regenerated device_id cannot reset it.

---

## 2. What the SERVER enforces, and how it cannot be argued with

Three BEFORE triggers do the work that the previous version left to RPC bodies. Triggers are **not** bypassed by `SECURITY DEFINER` — a definer function changes the executing role, not the `request.jwt.claims` GUC that `auth.uid()` reads — so these fire on every write path that will ever exist, including a future repair RPC written by someone who has not read this document.

**T1 `calls_before_insert`** — overwrites `created_at`, `expires_at`, `state_ord`, `signal_seq`, `keepalive_at` with server values regardless of what was supplied; when `auth.uid()` is not null, asserts `caller_id = auth.uid()`, asserts `couple_id = current_user_couple_id()` (the existing SECURITY DEFINER helper in schema.sql), and asserts `callee_id` is the other member of that couple. A client-supplied `expires_at` is therefore not merely ignored by policy, it is impossible.

**T2 `calls_before_update`** — raises unless `NEW.state_ord >= OLD.state_ord`; forces `end_reason = coalesce(OLD.end_reason, NEW.end_reason)`, `created_at = OLD.created_at`, `expires_at = OLD.expires_at`, `answered_by_device = coalesce(OLD.answered_by_device, NEW.answered_by_device)`. Monotonicity and first-writer-wins stop being properties of five RPCs and become a property of the table.

**T3 `call_signals_before_insert`** — (a) assigns `seq` by `update calls set signal_seq = signal_seq + 1, keepalive_at = now() where id = NEW.call_id returning signal_seq`, OVERWRITING whatever the caller passed; (b) sets `created_at = now()`; (c) when `auth.uid()` is not null, asserts `NEW.from_user = auth.uid()` and asserts the caller is a party to `NEW.call_id`; when `auth.uid()` IS null (cron, service role, trigger context) asserts `from_user IS NULL` and `kind` is in the system set {end, accepted_elsewhere, declined_elsewhere, busy}.

That is the answer to "the client sends the right integer is not an invariant": the client cannot send the integer at all. It is also the answer to the RLS-vs-SECURITY-DEFINER contradiction — the party predicate lives in exactly one place, a trigger, and the RLS SELECT policy on `call_signals` (`USING (to_user = (select auth.uid()))`) governs the one path that really is direct SQL, the catch-up query. Write privileges (INSERT/UPDATE/DELETE) on `calls` and `call_signals` are revoked from `authenticated` entirely.

**Why `seq` has no holes.** `seq` is an in-transaction counter on the `calls` row, never a sequence. `nextval` is non-transactional: 105 can become visible to a reader while 104 is uncommitted, and a reader doing `seq > cursor order by seq` advances past 104 and loses it permanently with no error anywhere — this is exactly the defect that `messages.seq` has today (one GLOBAL sequence, receipts_v2.sql:31). The `update … returning` takes a row lock held to COMMIT, so seq-allocation order and commit order are the same total order and a `seq > cursor` reader can never skip. Two writers, ~10 writes each, zero measurable contention.

**Why the cursor survives rows disappearing beneath it.** Pruning is gated on `state_ord >= 90`: `end_call` NULLs payloads for its own call, and the partition sweeper only drops partitions older than two days, by which time every call in them is terminal. A LIVE call's log is therefore never pruned beneath a reader, by construction. If a client sees `cursor < calls.signal_seq` with a missing row, exactly two states are possible: the row is uncommitted and will appear (retry, bounded at 5 s), or `state_ord >= 90` and the call is over (stop). A null `payload` on a fetched row means the same thing: the call ended, reconcile from `calls`. There is no third state in which the client waits forever. (`clear_conversation_everyone()` hard-deletes message rows for a couple; it does not touch `call_signals`, and if a future variant does, it must be gated on `state_ord >= 90` for the same reason.)

---

## 3. The RPCs

Every RPC that touches couple-level state takes `pg_advisory_xact_lock(hashtextextended(couple_id::text, 0))` as its FIRST statement. That, not `now()`, is the serialization point — which matters because Postgres `now()` is transaction-START time, identical for every statement in a transaction and not monotonic across overlapping transactions, so it can never be an ordering authority. Freshness COMPARISONS use `clock_timestamp()` (real current instant, immune to a slow transaction holding a stale `now()`); `expires_at` is stamped from `now()` at insert so that the ring deadline, the push TTL and the `call_events` row in one transaction all agree.

**Reaping (runs inside `start_call`, before it decides).**
```
state_ord < 30  AND clock_timestamp() >= expires_at                      → 90 / 'no_answer'
state_ord >= 30 AND clock_timestamp() >= keepalive_at + interval '90 s'  → 90 / 'lost'
                    clock_timestamp() >= created_at + interval '4 hours' → 90 / 'lost'
```
Three arms, not one. A single `now() >= expires_at` arm would reap a live connected call sixty seconds in, because `expires_at` is the RING window and a six-minute call outlives it by design. `keepalive_at` is bumped by T3 on every signal and by a 15 s `call_keepalive` RPC. **`expires_at` and `keepalive_at` are the reaping authority; `end_call` is only an optimisation.** A 30 s pg_cron job runs the identical predicate for telemetry hygiene — named interval, no correctness depends on it.

**`start_call(p_call_id, p_video, p_offer_sdp)`** → advisory lock → reap → dial budget (`> 6 dials for this (couple, caller) in 5 minutes` → `rate_limited`) → then at most one live row survives:
- **none** → insert → `started`.
- **`live.caller_id = auth.uid()`** → **REDIAL, not glare.** End the live row with `superseded`, emit NO hangup signal (the caller is the only party who could have been servicing it), insert unconditionally → `started`. This branch does not exist in RingRTC because RingRTC's table classifies RECEIVED offers and Signal's UI blocks a second outgoing dial; here the caller is routinely a cold-started process with no memory of its own abandoned attempt, which is the exact scenario this architecture exists for.
- **`live.caller_id = partner`, `state_ord < 30`** → **GLARE.** Compare `p_call_id` against `live.id` as a total order over 128 bits. Greater wins. Winner: end the loser with `glare_lost`, insert → `started`. Loser: return `glare_lost` **plus the surviving call's id, offer SDP, ICE servers and seq cursor**, so the loser answers the partner's in-flight call in the same round trip rather than being told to attach to something it cannot reconstruct.
- **`live.caller_id = partner`, `state_ord >= 30`** → **ReCall.** End the stale leg with `recall`, emit no hangup, insert → `started`. This is the branch whose absence produces "I can't call you back for 30 seconds."
- **different peer** (multi-device / future group) → `busy`, and write a `busy` signal to the caller.

Returns `{status, call_id, expires_in_ms, ice_servers, relay_max_kbps, seq}`. An AFTER INSERT trigger on `calls` writes the offer `call_signals` row and N `push_outbox` rows (one per callee device) **in the same transaction**, then the RPC body emits the Layer-B broadcast (§4) inside an exception block.

**`ring_ack(p_call_id, p_device_id)`** — ADVISORY ONLY. It cannot cause a ring; it can only cancel one.
```
update calls set state_ord = greatest(state_ord, 20)
 where id = $1 and callee_id = auth.uid()
   and state_ord < 30 and clock_timestamp() < expires_at
returning …
```
Four return codes, never two: `ring` (with `expires_in_ms`, `ice_servers`, and opportunistically the offer since it is free in the same round trip), `accepted` (state ≥ 30, carrying `answered_by_device` so this device can tell "me" from "elsewhere"), `already_ended` (state 90), `expired` (past `expires_at` → transition to 90 / `expired`). **Zero rows is never mapped to `expired`.** A transport error is a distinct client-side `unknown` that is defined to change nothing.

**`accept_call(p_call_id, p_device_id)`** —
```
update calls set state_ord = greatest(state_ord, 30),
                 answered_by_device = coalesce(answered_by_device, p_device_id),
                 accepted_at = coalesce(accepted_at, now())
 where id = $1 and callee_id = auth.uid()
   and state_ord < 90
   and clock_timestamp() < expires_at + interval '10 seconds'
returning …
```
A ten-second grace past `expires_at` so a tap at 59.8 s that lands at 60.3 s is honoured. If `answered_by_device = p_device_id` → `accepted`, returning `{offer_sdp, video, caller_id, ice_servers, relay_max_kbps, seq_cursor, expires_in_ms}` — the entire answer path in ONE round trip. Otherwise → `accepted_elsewhere`, and the RPC writes an `accepted_elsewhere` signal to the losing devices only. Re-accepting from the same device is idempotent success, which is what makes a fast Answer tap on a single-device couple safe.

**`decline_call`**, **`end_call(p_call_id, p_reason)`** — `state_ord = greatest(state_ord, 90)`; `end_reason` first-writer-wins (enforced by T2, not by `coalesce` in the body); NULLs every `call_signals.payload` for the call in the same transaction; writes one terminal `end` row; enqueues a cancel push on the SAME collapse key; revokes the call's `turn_grants`.

**`send_signal(p_call_id, p_kind, p_payload)`** — insert; seq and identity by T3; rejected once `state_ord = 90`.

**`call_keepalive(p_call_id, p_device_id)`** — bumps `keepalive_at`, returns `{state_ord, end_reason, signal_seq}`. Called every 15 s in-call and on every foreground; it doubles as the cheap reconciliation probe.

**Client FSM:** `idle, dialing, ringing, accepting, connecting, connected, reconnecting, ended(reason)`. The current enum has no busy, no declined, no reconnecting, and treats decline and hangup as the same wire message.

---

## 4. Transport: three layers, and the ring depends on none of them

**Layer A — the log (truth).** Catch-up is `select seq, kind, from_user, payload from call_signals where call_id = $1 and to_user = auth.uid() and seq > $2 order by seq`, paired with `select state_ord, end_reason, signal_seq from calls where id = $1`. `signal_seq` is the high-water mark that makes a gap decidable (§2).

**Layer B — private per-call broadcast (foreground speed only).** The RPC body calls `realtime.send(payload, 'signal', 'call:'||call_id, true)` wrapped in `begin … exception when others then null; end`. research/supabase.md:88 documents that `realtime.send` already swallows its own exceptions and reports via `pg_notify` specifically so a Realtime failure cannot roll back the business transaction; the subtransaction covers the residue. `realtime.broadcast_changes` is NOT used — it would put the full row, including SDP, into `realtime.messages` and its 72 h–4 day retention.

**The broadcast payload is `{call_id, seq, kind}` and nothing else.** No SDP, no ICE. The seq-cursor rule already forces a fetch on any gap, so carrying the payload buys a round trip only on the two SDP-bearing signals per call and costs a permanent copy of both partners' public IPs in a replicated table. Reconciliation rule: **apply if `seq == cursor + 1`; if `seq > cursor + 1`, fetch.** A dropped, duplicated or reordered broadcast is a latency bug, never a correctness bug.

Authorization is `realtime.messages` RLS evaluated ONCE at join under the user's JWT and cached for the connection lifetime — O(1) per join via a SECURITY DEFINER helper (research/supabase.md:215 documents 11,000 ms → 7 ms for exactly this join-avoidance shape). This is why it is Broadcast-from-Database and not `postgres_changes`, which evaluates RLS per subscriber per change PROJECT-WIDE at a documented ~30 changes/s at 500 clients, degrading as clients are added.

**Layer B is stated to be a FOREGROUND optimisation and nothing more.** A cold-started callee must open a websocket, present a JWT and have Realtime evaluate the join policy — 1–3 s on a cold radio, which is pure overhead on the killed-app path. Killed-app ring latency is a Layer C number and must be reported separately in telemetry, split by whether the app was foregrounded, so a Layer B improvement can never mask a Layer C regression.

**Layer C — FCM (the doorbell, and the tested path).** Data-only, `priority: high`, `collapse_key: 'call'` (three literal keys project-wide — `call`, `msg`, `nudge` — under FCM's hard limit of four distinct keys per device). Payload:
```
{ t: 'call', cid: <uuid>, v: '0'|'1', rem_ms: <int> }
```
No SDP (4 KB limit, no ordering guarantee). No `from_name` — today the app ships the partner's real display name in cleartext to a device whose entire product premise is a disguised launcher. `ttl = ceil(rem_ms/1000)`, clamped to [1, 60]; **never 0** — `ttl=0` discards a push for a device that is in an elevator for three seconds, and the server already owns the freshness gate so a late push is provably harmless. The cancel push reuses `collapse_key: 'call'`, so an undelivered ring push is REPLACED rather than delivered late — the collapse key is doing cancellation work, not just deduplication.

---

## 5. The ring path — the inversion that makes this design work

On `onMessageReceived` / in the background isolate, in this order:

1. **Branch on `RemoteMessage.getPriority()`** before anything privileged. Downgraded → post the notification, do NOT `startForegroundService()` (that throws `ForegroundServiceStartNotAllowedException`). This is Signal's exact check, and priority is a runtime property of the RECEIVED message, not of what was sent.
2. **Post the ring. Immediately. From the payload alone. Zero network calls.** `CallStyle.forIncomingCall()`, `CATEGORY_CALL`, IMPORTANCE_HIGH channel created at FIRST FOREGROUND LAUNCH (Android 13 drops notifications whose channel is first created in the background), `visibility: SECRET`, title/body from the ACTIVE disguise cover, **Answer and Decline actions**, looping ringtone, repeating vibration.
3. **Arm the self-cancel timer at `rem_ms` measured on `SystemClock.elapsedRealtime()`.** No wall clock, no network, no `AlarmManager` RTC. A device whose clock is three minutes fast cannot cancel its own ring.
4. `setFullScreenIntent(pi, true)` gated on a LIVE `canUseFullScreenIntent()` call, not the SharedPreferences mirror the current code reads (only the foreground can refresh it). Miles is genuinely advantaged here: AOSP grants `USE_FULL_SCREEN_INTENT` by default at install on Android 14+, and it is the PLAY STORE, not the OS, that revokes it for non-calling apps — Miles is sideloaded, so the revocation never happens. Still check and degrade, because a user or an OEM ROM can revoke it manually.
5. **Then**, in the background and never blocking step 2: post a `call_events` `push_received` row (with `messageId`, `sentTime`, `priority`, `originalPriority`), and call `ring_ack`. Fetches are single-flight and coalescing (Signal's `SerialMonoLifoExecutor`: 1 running + 1 queued, newest wins), so N duplicate pushes collapse into ≤2 drains — which is now SAFE, because ring_ack is idempotent and monotone.
6. `ring_ack` returning `expired`, `already_ended`, or `accepted` by a different device → CANCEL the ring. Returning `ring` or `accepted`-by-me → leave it. Any transport error → **leave it standing**; the offer will be fetched on Answer.
7. **Answer** → `PendingIntent` bound directly to the Activity (Android 12 blocks `startActivity()` from a receiver) with `setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)` on 14+ → `accept_call` returns offer + ICE servers + cursor in one round trip → `setRemoteDescription` → `createAnswer` → `send_signal('answer')` → trickle.
8. **Decline** → handled entirely in a `BroadcastReceiver` → `decline_call`; the notification is cancelled locally first and the RPC is best-effort.

**Four cancellation owners, each sufficient alone:** the monotonic timer (needs neither network nor clock); the `ring_ack`/`call_keepalive` advisory; the cancel push on the shared collapse key; the notification actions. Today the codebase contains not one `plugin.cancel(...)` call, and `ongoing: true` means the user cannot even swipe it away.

**A dedicated call foreground service**, separate from the location service. Today both use `com.pravera.flutter_foreground_task.service.ForegroundService`, so `start()` silently short-circuits when location sharing is running (the call gets no service and the notification says whatever location set) and `_teardown` unconditionally stops it (killing location sharing). Declare `FOREGROUND_SERVICE_PHONE_CALL` and `foregroundServiceType="phoneCall|microphone|camera"` — the manifest currently declares `location|microphone|camera` with no phoneCall permission, and passes `serviceTypes: [microphone]` even for video, which Android 14+ can refuse camera access for. Implement `Service.onTimeout(startId, fgsType)` → clean hangup (Android 15). Never start it from `BOOT_COMPLETED`.

**OEM survival.** No API fixes this. research/push.md is unambiguous that Samsung/Oppo/Vivo/Huawei catalogue as "no known solution on dev end", and force-stop is an absolute platform wall (`FLAG_STOPPED`: nothing in the app runs, receivers included, until the user launches it directly; Android 15 additionally cancels all pending intents). What ships — **in S1, not S7** — is a diagnostics screen reading `PowerManager.isIgnoringBatteryOptimizations()`, `ActivityManager.isBackgroundRestricted()` (CDD §3.5.1 [C-1-6] — the one portable signal a CTS-passing MIUI/ColorOS/OxygenOS build must honour), `UsageStatsManager.getAppStandbyBucket()`, `areNotificationsEnabled()`, `canUseFullScreenIntent()`, and `ApplicationStartInfo.wasForceStopped()` on 15 — with per-`Build.MANUFACTURER` deep links, a "test your ring" button that round-trips a real push, and one honest sentence: *if you swipe this app away on this phone, calls will not ring.*

---

## 6. Telecom / ConnectionService versus the disguise

**Decision: do not register a `PhoneAccount`.** The manifest declares `android:label="News"` plus four launcher aliases (News, Calculator, Notes, Weather) and the cover is switchable at RUNTIME; the notification builder already renders `currentNotificationStyle()` to match. A self-managed `ConnectionService` registers a `PhoneAccount` whose label is fixed at registration and appears under Settings → Apps → Default apps → Calling accounts. It cannot track a runtime-switchable cover, so the two will drift and the Settings entry becomes a permanent, unremovable tell. Telecom's two documented 5-second deadlines (notification within 5 s of `addCall()`; every remote-surface callback completing within 5 s) also introduce a brand-new teardown failure mode on exactly the slow, battery-restricted OEM devices this app targets. And because FSI is available by default on a sideloaded app, Telecom is not needed for the ring surface at all.

Recovered by hand, to roughly 80%, with no disclosure: `AudioManager` with `MODE_IN_COMMUNICATION`, `STREAM_VOICE_CALL` and `AudioFocusRequest(AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)`; a `TelephonyCallback` to auto-hold-or-end when a GSM call arrives and resume after; a `MediaSession` for Bluetooth headset answer/hangup buttons. **Accepted losses, in writing:** no true hold/swap against a cellular call, no system call log entry, degraded Bluetooth switching, no CallStyle device-forwarding to watches and car head units.

---

## 7. Negotiation, trickle ICE, glare

- **Every signal carries `call_id`.** This does not exist today, and its absence is why a hangup from a call that ended 30 seconds ago tears down the call happening now.
- **Trickle with 200 ms batching** — candidates buffer and go out as one `ice` row carrying an array. ~60 signals/call → ~14. A 5× reduction against both the Realtime msg/s quota and the monthly message budget, at negligible latency cost.
- **Explicit `end_of_candidates`** tagged with the ICE generation (ufrag), per RFC 8838.
- **Explicit `ice_restart` signal kind.** Stated, not denied: changing `iceServers` via `setConfiguration()` affects only the NEXT gathering generation, which on a PeerConnection means a new ufrag and therefore a full offer/answer round trip. Relay escalation is a renegotiation and is modelled as one — the CALLER issues the restart offer (impolite role read from `calls.caller_id`, durable), the callee answers, the seq cursor orders it. The incentive to ever reach it is removed by shipping ICE servers with `start_call` / `accept_call` / `ring_ack` from `turn_cache`, so "late credentials" is not a case that exists.
- **Pre-offer buffering keyed by `call_id`, capped at 30** (Signal's constant), replayed the instant the offer's PeerConnection exists, cleared when a hangup for that `call_id` arrives, evicted for any other `call_id`. Today the code buffers into a single unkeyed, uncapped `_pendingRemote` list.
- **Exactly-once and in-order come free** from `(call_id, seq)` plus the cursor rule. No wire sequence numbers, no serialised-send queue.
- **Perfect negotiation is used for in-call renegotiation only** (camera toggle, ICE restart, future screen share), with caller=impolite / callee=polite read from `calls.caller_id`. Setup glare is resolved once, in `start_call`, at a serialization point.
- **Retire the "re-send every gathered candidate on answer" hack** (`_applyAnswer`). It exists because a cold-started callee missed the first trickle; with a durable log the callee drains from seq 0. It is unbounded, undeduped, and now unnecessary.

---

## 8. TURN: off the critical path, scoped, capped

- **Credentials ride the call RPCs.** `start_call`, `ring_ack` and `accept_call` return `ice_servers` and `relay_max_kbps` from the server-side `turn_cache`. Zero extra round trips on either side; no "acquire in parallel and hope" path; no relay-less fallback. The current 3-second wall-clock budget followed by "proceed relay-less and show a red banner reading *calls only work when both of you are on the same wifi*" is deleted.
- **Two TTLs, enforced by a CHECK constraint** — request 7200 s from Cloudflare, advertise 3600 s to the client, `client_ttl_seconds <= requested_ttl_seconds` as a table constraint on both `turn_cache` and `turn_grants`. The client therefore always refreshes strictly before real expiry, and no code path can violate it.
- **Expiry is a DURATION, never a timestamp.** The server ships `client_ttl_seconds`; the client stores it against `SystemClock.elapsedRealtime()` at receipt. A backwards jump in elapsedRealtime (reboot) marks the cache expired. No wall clock and no `ServerClock` participates — I verified `ServerClock._offset` is a static in-memory field fed from exactly one call site (`presence_service.dart:206`), so it is provably zero in an FCM background isolate, which is the only case that matters.
- **`urls`, `urls_with_ips` (server-resolved literals, v6 bracketed) and `hostname` for SNI**, via `Deno.resolveDns` in the edge function. Removes a DNS round trip on a carrier resolver from call setup and survives DNS-level blocking without weakening certificate validation.
- **Timeout, retry, last-known-good in `turn_cache`**, so a Cloudflare blip is not "no calls". A non-2xx is a hard failure with a named reason, never a silent empty ICE list. `verify_jwt` on the function confirmed ON (there is no `config.toml` in the repo, so today's setting is unverified).
- **Scoping and abuse limits.** One `turn_grants` row per mint, keyed `(user_id, device_id, call_id)`; quota ≤10 mints/user/hour enforced by counting rows in a window on `user_id` alone; revoke via Cloudflare's `POST …/credentials/$USERNAME/revoke` at `end_call`. Max exposure from a lifted credential falls from 24 hours of unmetered relay to one client TTL.
- **Relayed-path bitrate cap: `relay_max_kbps` (default 1000, floor 30), server-supplied so it can be lowered without an APK**, applied the moment `getStats()` reports either selected candidate as `relay`. Signal's `RELAYED_MAX_SEND_RATE`/`MIN_SEND_RATE`. This is the single line that controls the Cloudflare bill — and it is the one thing in this design that the server cannot enforce (see accepted_limits).

---

## 9. Timing budget

| constant | value | owner | on expiry |
|---|---|---|---|
| `RING_WINDOW` | 60 s | `calls.expires_at`, server | reaped to `no_answer` by the next dial or the 30 s sweeper; ring self-cancels on its monotonic timer |
| `ACCEPT_GRACE` | 10 s past `expires_at` | `accept_call`, server | a tap at 59.8 s that lands at 60.3 s is honoured |
| `KEEPALIVE_MISS` | 90 s since `keepalive_at` | server reaper | accepted call → `lost`; the couple slot is freed |
| `CALL_CEILING` | 4 h since `created_at` | server reaper | unconditional backstop |
| `RELAY_ESCALATION` | 8 s after both descriptions set | client | no selected pair → `ice_restart` signal, renegotiate with `iceTransportPolicy: 'relay'` |
| `MEDIA_DEADLINE` | 20 s after `accept_call` | client, both sides | `end_call('media_failed')` — distinct from `no_answer` so telemetry separates "nobody picked up" from "we could not connect" |
| `SIGNAL_GAP` | 5 s | client | `end_call('signal_gap')` rather than hang |

RingRTC uses `MAX_MESSAGE_AGE = 60 s` and `TIME_OUT_PERIOD = 60 s` — one constant for offer freshness and ring duration, so an offer can never be delivered late enough to ring past its own deadline. Ours is one column. Calibration from the callstats corpus: 80% of sessions establish within 5 s, 67% of failures occur after 10 s. The current single hardcoded 35 s covers all of these cases badly.

**Mid-call recovery ladder.** `continualGatheringPolicy: 'gather_continually'` set at construction; on `IceConnectionState.disconnected` enter `reconnecting` (a state that does not exist today — today `onIceConnectionState` only `debugPrint`s) and let continual gathering regather on the existing ICE generation, **no offer/answer needed**, which matters because a WiFi→LTE handover breaks the signalling path at exactly the moment you need it. Only if `disconnected` persists past 8 s escalate to an `ice_restart` signal, and only after refreshing TURN, because a restart needs a NEW allocation and the old credential may no longer mint one (draft-uberti-behave-turn-rest-00). RFC 7675 consent freshness caps a dead path at 30 s regardless.

## Invariants
- A ring is posted before any network operation, and the server can only cancel it. The FCM payload carries {call_id, video, rem_ms} and the client posts the CallStyle notification from that alone; ring_ack is an advisory that runs afterwards and whose only permitted effects are cancellation on 'expired', 'already_ended', or 'accepted' by another device. A transport error maps to a distinct 'unknown' code that is defined to change nothing. Enforced by construction (the ring path executes no network call) and locked by a headless test that stubs every network call to throw and asserts the notification is still posted.
- Call state can only move forward, and the first writer's end_reason wins — enforced by a BEFORE UPDATE trigger on `calls`, not by RPC bodies. The trigger raises unless NEW.state_ord >= OLD.state_ord and forces end_reason = coalesce(OLD.end_reason, NEW.end_reason), created_at = OLD.created_at, expires_at = OLD.expires_at, answered_by_device = coalesce(OLD, NEW). A replayed hangup, a duplicated push, a notification tapped an hour late, or a delayed accept from a device that lost the race cannot resurrect or re-decide a call, and no future RPC can opt out.
- Every state-advancing RPC is idempotent and monotone, never an equality gate. ring_ack is `greatest(state_ord,20) WHERE state_ord < 30`; accept_call is `greatest(state_ord,30) WHERE state_ord < 90` with answered_by_device = coalesce(existing, mine). The second drain of the same push, and a fast Answer tap that races its own ring_ack, are both no-op successes. Zero rows is never mapped to 'expired' — the RPCs return four codes, not two.
- Signal ordering has no holes, because seq is an in-transaction counter under a row lock, never a sequence. `update calls set signal_seq = signal_seq + 1 ... returning` holds the `calls` row lock to COMMIT, so seq-allocation order and commit order are the same total order and a reader doing `seq > cursor order by seq` can never skip a row. A Postgres sequence cannot give this: nextval is non-transactional, 105 becomes visible while 104 is uncommitted, and the reader loses 104 permanently with no error — which is exactly what messages.seq (one global sequence, receipts_v2.sql:31) does today.
- The client cannot supply seq, from_user, created_at, expires_at, or state_ord — a BEFORE INSERT trigger overwrites all of them with server values. Triggers are not bypassed by SECURITY DEFINER (a definer function changes the executing role, not the request.jwt.claims GUC that auth.uid() reads), so this holds on every write path that will ever exist, including RPCs not yet written. 'The client sends the right integer' is not an assumption here because the client cannot send the integer.
- A user can only write signals attributed to themselves, into a call they are a party to — asserted in ONE place, the BEFORE INSERT trigger on call_signals, which fires for RPC writes and direct writes alike. When auth.uid() is null (cron, service role) it requires from_user IS NULL and a kind in the system set. INSERT/UPDATE/DELETE on `calls` and `call_signals` are revoked from `authenticated`; the RLS SELECT policy governs the only path that is genuinely direct SQL, the catch-up query. There is no configuration in which injection is blocked by a policy that the actual write path bypasses.
- An expired or abandoned call can never block a dial, because the dial reaps it. `start_call` takes pg_advisory_xact_lock on the couple, then applies a three-armed reaper — state_ord<30 past expires_at; state_ord>=30 with keepalive_at older than 90 s; anything older than 4 h — and only then evaluates its branches. The partial unique index `unique(couple_id) where state_ord < 90` is a backstop, not the gate. expires_at and keepalive_at are the reaping authority; end_call is only an optimisation; the 30 s pg_cron sweeper runs the same predicate for hygiene and nothing depends on it. Crucially the ring window (expires_at) is NOT applied to accepted calls, so a live six-minute call is not reaped at sixty seconds.
- A caller's own abandoned dial is a redial, not glare. start_call branches on `live.caller_id = auth.uid()` BEFORE any tie-break, ends the stale row with 'superseded', emits no hangup, and inserts unconditionally. The 128-bit tie-break applies only when the live call's caller is the partner. A cold-started caller with no memory of its previous attempt is therefore deterministic, not a coin flip, and the glare-loser return carries the surviving offer, ICE servers and cursor so 'attach to the call in flight' is an action rather than an instruction.
- At most one live call exists per couple, and two concurrent start_call transactions cannot both produce one. The advisory couple lock serializes the read-then-write, the partial unique index backstops it, and the glare tie-break decides WHICH survives — it is not what makes the two sides agree. Signal must run its tie-break independently on two devices because it has no shared transactional store on the call path; we have one, so agreement is structural rather than derived.
- A Realtime failure cannot fail a call. The durable write commits first; the broadcast is emitted by the RPC body via realtime.send inside a `begin ... exception when others then null; end` subtransaction. realtime.send is documented to catch its own exceptions and report via pg_notify precisely so it cannot roll back the business transaction (research/supabase.md:88). realtime.broadcast_changes is not used. Locked by a Layer-1 test that revokes INSERT on realtime.messages and asserts start_call still commits and still writes push_outbox rows.
- No wall-clock reading on any device participates in any call decision. The server issues durations (rem_ms, expires_in_ms, client_ttl_seconds), never absolute instants, and every device-side timer is measured on SystemClock.elapsedRealtime(), which no clock change can move; a backwards jump (reboot) marks any cached duration expired. Server-side, freshness comparisons use clock_timestamp() rather than now(), because now() is transaction-start time and is not monotonic across overlapping transactions — it can never be an ordering or freshness authority. The ring deadline, the offer freshness window and the push TTL remain three readings of one column.
- A live call's log is never pruned beneath its readers, so a cursor cannot be orphaned. Payload nulling happens only in end_call (state 90) and partition drops only touch partitions older than two days. Therefore a gap has exactly two resolutions: the row is uncommitted and will appear (bounded 5 s retry), or `calls.state_ord >= 90` and the call is over. A null payload on a fetched row means the same thing. There is no state in which a client waits forever for a row that was deleted.
- No SDP or ICE payload outlives its call. end_call NULLs every call_signals.payload for the call in the same transaction, the Layer-B broadcast carries only {call_id, seq, kind} so no SDP ever enters realtime.messages and inherits its 72 h-4 day retention, and both call_signals and call_events are daily-partitioned with DROP rather than DELETE. Both partners' LAN and public IPs are therefore not accumulated in a replicated table for an app whose premise is a disguised launcher.
- Knowing a topic name grants nothing. The per-call signalling topic is private; Realtime evaluates realtime.messages RLS once at join under the user's JWT and caches the verdict for the connection lifetime. This replaces today's public `call:<couple_id>` room, which is joinable by anyone holding the anon key and a couple UUID — and couple UUIDs are public, they are the first path segment of every couple_media URL.
- The dial endpoint is rate-limited server-side, and only calls may send high-priority push. start_call rejects with 'rate_limited' above 6 dials per (couple, caller) per 5 minutes, counted in the same transaction. push_outbox carries `priority` with CHECK (priority <> 'high' OR kind = 'call'), plus a per-device hourly high-priority budget. Android 13+ downgrades HIGH to NORMAL for apps whose high-priority pushes do not consistently produce notifications, assessed over 7 days, and a downgraded message cannot start a foreground service — so the mechanism calls depend on is protected by a constraint, not by a coding convention. Today the chat path sends high priority for notifications _onForeground silently discards.
- A TURN credential's advertised lifetime is never longer than its real one, enforced by CHECK (client_ttl_seconds <= requested_ttl_seconds) on turn_cache and turn_grants. Signal-Server asserts this in application code; here no code path can violate it. Relay exposure is bounded by one client TTL rather than the 24 hours today's `ttl: 86400` grants, with per-mint turn_grants rows, a per-user hourly mint quota, and revocation at end_call.
- The signalling socket is never required for a call to ring, and this is now true rather than asserted. The ring is posted from the push payload with no network at all; the offer is fetched on Answer; Layer B is documented as a foreground-only optimisation and its latency is reported separately from the killed-app path so an improvement in one cannot mask a regression in the other. A Realtime outage, a tenant_events throttle or a too_many_connections refusal degrades calling to 'rings the same, connects 1-3 s slower', not to 'calling is down'.
- The client branches on RemoteMessage.getPriority() before any foreground-service start, so a downgraded push degrades to a plain notification instead of throwing ForegroundServiceStartNotAllowedException. Priority is a runtime property of the received message, not of what was sent.
- A ring notification cannot outlive its call. Four independent cancellation owners exist and each is sufficient alone: the monotonic elapsedRealtime timer armed at rem_ms (needs neither network nor clock), the ring_ack/call_keepalive advisory, the cancel push which reuses collapse_key 'call' so an undelivered ring push is replaced rather than delivered late, and the notification actions. Today there is no cancel() call anywhere in the codebase and ongoing:true means the user cannot even swipe it away.

## Scale ceiling
## The ceiling is a handset, not a user count. Read this before the Supabase arithmetic.

**Calling's binding constraint is the fraction of handsets on which a killed app can be woken at all — currently 0 of 3 target devices without user-granted autostart exemptions.** IN2015 (OnePlus, 5/5 dontkillmyapp severity), OnePlus 7 (5/5), Vivo (3/5). Force-stop is an absolute platform contract: `FLAG_STOPPED` means nothing in the app runs, receivers included, until the user launches it directly, and Android 15 additionally cancels all pending intents. research/push.md catalogues Samsung/Oppo/Vivo/Huawei as "no known solution on dev end". This constraint is present at n=2, does not improve with scale, and is unaffected by every table, RPC and index in this document. Supabase quotas do not bind on calling's own traffic until roughly 600,000 users.

**The domain's single headline metric is therefore per-OEM ring success rate for BACKGROUNDED devices**, from `call_events` (`push_sent` → `ring_shown`), reported above p50 latency. The diagnostics screen and the "test your ring" button are S1 deliverables, not S7, because they are the only things in this plan that address the actual ceiling.

## Model for the Supabase arithmetic

2 users/couple, 2 calls/couple/day, 6 min mean, 60% video / 40% audio. Relay rate **35%** — deliberately above the callstats.io corpus figure of 22%, because cross-carrier mobile is near the worst case: carrier-grade NAT is typically address-and-port-dependent, so the STUN-learned server-reflexive candidate is bound to the 5-tuple toward the STUN server and useless to the peer, and two symmetric NATs cannot hole-punch. ~14 signal rows/call after 200 ms batching.

## 1,000 users (500 couples) — comfortable

- 1,000 calls/day, 30,000/month. Signalling ~420k rows/month, daily partitions dropped after 2 days; live table a few thousand rows. Realtime: 14 signals × 2 billable ≈ 28/call ≈ 840k messages/month, now with ~200-byte payloads instead of SDP.
- Concurrent call sockets ≈ 4 calls × 2 = 8. Channel joins ≈ 0.05/s against a free-tier ceiling of 100/s.
- `call_events`: 7 events × 2 devices × 30k calls = 420k rows/month, ~150 MB steady state at 30-day retention.
- **Nothing calling-specific breaks.** The binding Supabase constraint is the rest of the app: research/supabase.md puts free-tier capacity for this codebase at roughly 100–150 users (message quota) or ~150 concurrently-chatting users (the postgres_changes ceiling), whichever hits first. Calling rides on Pro either way.
- **Failure mode if you stay on Free:** 200 concurrent connections is a hard wall with no overage — it fails closed with `too_many_connections`. Under the OLD design the symptom was that foregrounded phones stopped ringing while backgrounded users on the FCM path kept working, which is a diagnosis trap. Under this design that inversion is gone: the ring never uses the socket, so a connection-quota failure shows up as slower connect, not as a ring failure.

## 10,000 users — works on Pro with the spend cap OFF; cost, not capacity, binds

- 10,000 calls/day, 300,000/month. Concurrent call sockets ≈ 166. Joins ≈ 0.5/s. Signalling messages ≈ 8.4M/month. `call_events` ≈ 4.2M rows/month, ~1.5 GB steady at 30-day retention — inside Pro's 8 GB disk but eating a fifth of the headroom, which is why it is partitioned.
- App-wide peak concurrency ≈ 800 devices, exceeding Pro's capped 500 — the spend cap must be disabled to reach 10,000 connections / 2,500 msg/s.
- **First thing to break: money, specifically relayed video egress** (~$300/month, ~93% of calling's marginal bill).
- **Second: the FCM priority-downgrade cliff.** Android 13+ downgrades apps whose high-priority pushes do not consistently produce notifications, over a 7-day window, and the threshold is an unpublished number invisible from the server. The only signal is `originalPriority != priority` on the client. This design narrows the exposure — a dial budget in `start_call`, a CHECK constraint restricting high priority to `kind='call'`, and a per-device hourly budget — but does not eliminate it. Instrument from S2 or you will discover it as "calls started arriving three minutes late on some phones."
- **Failure mode at the ceiling:** if the relay bitrate clamp regresses (a refactor drops the `getStats()` check, or `setParameters` silently fails), the bill roughly triples with no alarm anywhere. Cost has no error code — hence the spend alarm in accepted_limits.

## 100,000 users — calling still fits; the tenant does not

- 100,000 calls/day, 3M/month. Concurrent call sockets ≈ 1,666 of a 10,000 hard ceiling. Joins ≈ 5/s average, maybe 20/s peak, against 2,500/s. Signalling ~42M rows/month, partition-dropped daily, live table ~60k rows. `call_events` ~42M rows/month, ~8–15 GB steady with 30-day retention. Cloudflare credential issuance ~1/s against a documented 500/s floor.
- **Calling is not what breaks.** research/supabase.md puts app-wide peak concurrency at ~8,000 devices and peak throughput at ~12,000 msg/s — roughly 5× past the 2,500/s Team ceiling. That is a hard stop, not an overage: Enterprise or a self-hosted Realtime cluster.
- **The property that matters at that ceiling:** `tenant_events` throttling disconnects clients project-wide. Under this design it degrades calling to "rings identically, connects 1–3 s slower", because the ring path executes no network call at all and the offer arrives on the Answer RPC. Today the identical failure produces total calling failure, because the ring path IS the socket.
- **The escape hatch is a Layer-B-only swap.** Because the log (A) and the push (C) are independent of the transport, moving in-call signalling to a small dedicated service — or self-hosting Realtime — changes one RPC statement and one client subscription. Layers A and C are untouched.
- **The genuinely hard calling ceiling past 100k** is Cloudflare TURN's documented gaps, not throughput: **no RFC 6062 TCP relay allocations** (only TLS wrapping, so a network blocking UDP entirely may have no path) and **no IPv6 relay addresses**, which on increasingly common IPv6-only carriers leaves you dependent on NAT64/464XLAT. Neither is a capacity problem and neither can be paid away. Mitigation is coturn on TCP/TLS 443 as a second ICE server — which is why the NAT harness must include a UDP-blocked scenario before you need it.

## Cost
## Assumptions

Same model as scale_ceiling. Cloudflare Realtime TURN: **$0.05/GB egress, 1,000 GB free — shared between SFU and TURN, not two allowances**. Relayed video at the 1 Mbps cap ≈ 15 MB/min of media, **plus ~20% for protocol overhead**: Opus audio rides alongside the video cap (RELAYED_MAX_SEND_RATE is a VIDEO send cap), plus RTX/NACK retransmissions, RTCP, TURN ChannelData/Send-indication framing, and IP/UDP headers. So **18 MB/min billable for video, 3.6 MB/min for audio-only**. These are arithmetic from documented rates and codec bitrates, not vendor quotes; the +20% is an estimate and is labelled as one.

## 1,000 users — calling's marginal cost: $0, but the free allowance is 70% consumed

| line | volume | cost |
|---|---|---|
| TURN relayed video | 6,300 calls × 6 min × 18 MB = **680 GB** | $0 (free tier) |
| TURN relayed audio | 4,200 calls × 6 min × 0.6 MB = **15 GB** | $0 |
| Realtime messages (calling) | ~840k/month | $0 within Pro's 5M |
| Realtime egress (calling) | 840k × ~200 B ≈ 0.2 GB | $0 |
| Edge Functions | ~90k TURN refreshes + ~60k push drains | $0 within 2M |
| Postgres — call_signals | ~2 MB live after partition drops | $0 |
| Postgres — call_events, 30-day retention | ~150 MB | $0 within Pro's 8 GB |

**Total: $0 on top of the $25 Pro the rest of the app needs.** Note the exposure: **695 GB is 70% of the shared 1,000 GB allowance**, up from the 58% the previous version claimed, and it is shared with any future SFU use.

## 10,000 users — ~$325/month

| line | volume | cost |
|---|---|---|
| TURN egress | 6,800 GB video + 150 GB audio = **6,950 GB**, minus 1,000 free | 5,950 × $0.05 = **$298** |
| Realtime messages (calling share) | 8.4M/month at $2.50/M | **~$21** |
| Realtime egress (calling) | 8.4M × ~200 B ≈ 1.7 GB | ~$0 (within 250 GB) |
| Edge Functions | ~900k/month | $0 within Pro's 2M |
| Postgres — call_events | ~1.5 GB steady | $0 within 8 GB, but 19% of headroom |

**Calling marginal: ~$325/month.** 92% is relayed video egress. Without the 1 Mbps clamp, GCC on good wifi reaches ~2.5 Mbps and this line becomes **~$750/month** for no visible difference on a phone screen.

## 100,000 users — ~$3,660/month

| line | volume | cost |
|---|---|---|
| TURN egress | 68,000 GB video + 1,500 GB audio ≈ **69.5 TB**, minus 1 TB free | 68,500 × $0.05 = **$3,425** |
| Realtime messages (calling share) | 84M/month at $2.50/M | **~$210** |
| Realtime egress (calling) | 84M × ~200 B ≈ 17 GB | ~$0 |
| Edge Functions | ~9M/month, 7M over 2M at $2/M | **~$14** |
| Postgres disk — call_events 30-day + call_signals partitions | ~15 GB, 7 GB over Pro's 8 at $0.125/GB | **~$1** |

**Calling marginal: ~$3,660/month**, on top of the ~$5,000–6,500/month research/supabase.md projects for the app overall. The previous version's $3,100 omitted `call_events` entirely and under-counted relay egress by ~20%.

Note the Realtime egress line is negligible ONLY because the Layer-B broadcast was reduced to `{call_id, seq, kind}`. Had SDP stayed in the broadcast (~8 KB × 2 SDP-bearing signals × 2 receivers per call), the line would be ~96 GB/month at 100k — still small in dollars, but it would also be a permanent copy of both partners' IPs in a replicated table.

## The cost levers, in order

1. **The relay clamp.** Worth ~$425/month at 10k and ~$4,000/month at 100k. One `getStats()` check plus `setParameters`. It is also the one thing here the server cannot enforce (see accepted_limits).
2. **Relayed video → 600 kbps**, delivered as `turn_cache.relay_max_kbps` so it changes without a release: −40% of the TURN line, $3,425 → ~$2,100 at 100k.
3. **Relay-aware modality downgrade:** on a relayed path with `qualityLimitationReason == 'bandwidth'`, offer "switch to audio". Audio is 30× cheaper per minute.
4. **200 ms candidate batching.** Cuts calling's Realtime line ~5×. Already in the design; named because dropping it silently restores the cost.
5. **Partition drops rather than DELETE** on `call_signals` and `call_events`. Costs nothing directly, but 42M rows/month removed by DELETE is autovacuum debt on the table serving the latency-critical catch-up scan — the symptom is "rings are slower in the evening" with no obvious cause.

## The cost risk that is not organic traffic

Today a 24h TURN credential sits in plaintext SharedPreferences on every device with no per-user cap, no revocation, and no server-side mint rate limit. One credential lifted off one device relays from anywhere for 24 hours. Sustained 5 Mbps both directions is ~108 GB/day = **$5.40/day per stream**, and nothing prevents 100 parallel streams: **~$540/day from a single leaked credential.** `turn_grants` + a 1 h client TTL + a per-user mint quota + revoke-at-end-of-call turns that from unbounded into a number you chose. At current scale this risk exceeds the entire organic bill by two orders of magnitude.

## Break-even

- Each couple generates ~1.4 GB/month of relayed egress on this model. The 1,000 GB free tier is exhausted at roughly **720 couples ≈ 1,440 users** — that is the first real dollar this domain costs (the previous version said ~1,700, before protocol overhead).
- Supabase Pro ($25) is required well before calling needs it; calling never justifies a tier upgrade on its own until the 10,000-connection ceiling, which it reaches at roughly **600,000 users** on its own traffic.

## Migration
Every stage ships and reverts independently. Two stages require both peers upgraded and BOTH are labelled as such with a capability gate — `profiles.client_caps`, a bitfield each client writes on foreground and each peer reads before choosing a protocol. There is no big bang, and the ordering rule below exists because the previous plan's stage ordering reconstructed the bug it was meant to remove.

**The ordering rule, stated once:** no stage may introduce a gate without the mechanism that clears it, and no stage may make the ring depend on something the previous stage did not already prove works. Concretely — the partial unique index and the reaping branch ship in ONE migration, never two; and `ring_ack` may never become a precondition for posting a notification after S1 made it unnecessary.

## S0 — Server-only hardening. No client release. Ship today.
1. `alter policy call_invites_couple … with check (couple_id = current_user_couple_id() and caller_id = (select auth.uid()))`. Today the policy is `FOR ALL USING (…)` with no WITH CHECK, so Postgres reuses USING for INSERT and any member can insert rows naming arbitrary caller/callee.
2. **Authenticate `reach-notify` — all four callers in one migration.** Grep first: `notify_reach` (fcm_push.sql:16), `notify_care` and `notify_call` (20260628_care_call_push.sql:26, :48), `notify_message` (message_push.sql:14). Add a Bearer header read inside each SECURITY DEFINER function from `app_secrets`/Vault, make the function verify it, re-enable `verify_jwt`. **Updating only `notify_call` — as the previous plan did — silently kills care reminders and message pushes, invisibly, because `net.http_post` is fire-and-forget and the function always returns 200 to avoid retry storms.** Add a Layer-1 assertion that no trigger body contains a `net.http_post` to that URL without an Authorization key. This is the highest security value per line in the whole plan: today anyone on the internet can POST `{kind:'call', record:{…}}` and ring an arbitrary device, repeatedly.
3. A crude per-caller dial rate limit on `call_invites` insert (a BEFORE INSERT trigger counting rows in a 5-minute window), so the abuse surface is closed before S2 makes pushes cheaper to send.
4. `pg_cron`: delete `call_invites` older than 1 hour (pattern already in `reach_pulses.sql:34`). Stops unbounded SDP growth.
5. Drop `call_invites` from `supabase_realtime`; `replica identity default`. It has zero subscribers and pays full-row WAL plus realtime fan-out per call for nothing.
6. Cache the Google OAuth access token in `reach-notify` module scope (Deno isolates persist across warm invocations). Today it mints a fresh RS256 JWT and exchanges it per push — two Google round trips in the critical path of a ring.

**Revert:** drop the policy change, restore the publication, redeploy the previous function. **Verify:** Layer 1, entirely.

## S1 — Ring correctness, device identity, wire call_id, diagnostics. Client + two additive server bits.
- **Mint `device_id`** into `flutter_secure_storage` on first run. Prerequisite for S2/S3/S5/S7, and it exists nowhere today.
- **`call_id` on the legacy wire**, as a purely additive envelope field `{from, kind, data, call_id?}`. Old clients ignore the extra field. New clients require `call_id` from a peer that advertises support and fall back to exact current behaviour otherwise. **This is the stage that fixes the unkeyed-hangup bug** — a hangup from a call that ended 30 seconds ago tearing down the call happening now — for any pair on the new client, and it does not regress a mixed pair. It was S6 in the previous plan, which is why that plan's dual-read window was unsafe.
- **`profiles.client_caps` bitfield** — one additive column, written by the client on foreground. Every later coordinated stage gates on it.
- **Ring from the push payload.** `reach-notify` branches on the recipient's `client_caps`: new clients get the lean `{t, cid, v, rem_ms}` payload, old clients keep today's shape. The client posts the CallStyle notification first with no network call, arms the self-cancel timer on `elapsedRealtime`, and only then does anything else.
- Answer/Decline actions, looping ringtone, repeating vibration, channel created at first FOREGROUND launch, live `canUseFullScreenIntent()` instead of the SharedPreferences mirror, `getPriority()` branch before any FGS start, `PendingIntent` bound directly to the Activity with `MODE_BACKGROUND_ACTIVITY_START_ALLOWED`, and the four cancellation owners.
- Split the call foreground service from the location service; declare `phoneCall|microphone|camera` and `FOREGROUND_SERVICE_PHONE_CALL`; implement `onTimeout`.
- **The diagnostics screen and "test your ring"** — moved here from S7 because it is the only thing in the plan that addresses the actual ceiling.

**Largest visible improvement per unit of risk; the backend change is one column and one edge-function branch. Revert:** one APK plus clearing the caps bit. **Verify:** Layer 2 (notification posts with the network stubbed to throw) plus the Layer 5 adb matrix on one phone.

## S2 — `device_tokens`, `push_outbox`, a dedicated call drain, delivery telemetry.
Outbox rows written in the same transaction as the trigger source; `pg_net` fast path (it defers until COMMIT, so a rolled-back dial sends nothing); **a dedicated `pg_cron` job at 1 s for `kind='call'` with fixed 1/2/4/8 s retries and a hard stop at `expires_at`** — the 10 s exponential-backoff drain is a chat cadence and inside a 60 s window it delivers roughly one useful retry. A call push is never sent with `ttl=0`; it is abandoned and recorded as `push_abandoned`. `UNREGISTERED`/`INVALID_ARGUMENT` → dead + delete the `device_tokens` row. `CHECK (priority <> 'high' OR kind = 'call')` and the per-device hourly high-priority budget land here. Client posts a `call_events` ack on receipt carrying `messageId`, `sentTime`, `priority`, `originalPriority`. Multi-device fan-out comes free.

Budget note: Supabase recommends no more than 8 concurrent pg_cron jobs each under 10 minutes; routing all app pushes through one outbox must respect that.

**Revert:** stop the cron job; the `pg_net` fast path still works. **Verify:** fake FCM endpoint returning 429/500/`UNREGISTERED`/timeout.

## S3 — `calls` + `call_signals` + the three triggers + the RPCs, dual-run behind a flag.
Ship the tables (both partitioned), T1/T2/T3, the RPCs, the RLS SELECT policies, the revocations, **and the partial unique index together with the three-armed reaper in the same migration**. The client calls `start_call` in addition to the legacy path and reads the log in addition to the broadcast.

**The dual-run rule, stated honestly** (the previous plan claimed "both are idempotent under the seq-cursor rule", which is false because a legacy message has no seq): **during dual-run the log is authoritative for offer, answer, hangup and end; a legacy broadcast is accepted only for `kind='ice'` and only for a `call_id` this client is currently servicing.** A legacy peer's dial creates no `calls` row, so "one live call per couple" is not yet universal — the reaper means that costs nothing, because a stale row can never block a dial.

**This is the step that makes the offer survive an offline callee. Revert:** flip the flag. **Verify:** Layer 1 in full (glare, redial, ReCall, reaping, monotonicity, idempotent ring_ack/accept, seq holes, trigger-enforced identity, realtime-revoked commit) plus Layer 2 FSM tables.

## S4 — Private per-call topic (Layer B). Gated on `client_caps`. Coordinated step #1.
Add the `realtime.messages` RLS policy and the per-call private topic with the lean `{call_id, seq, kind}` payload. A caller uses it only if the callee advertises support; otherwise the legacy public topic. One release later, remove the fallback and the public topic.

**Revert:** clear the capability bit server-side — every client falls back with no APK. **Verify:** join as a non-member and assert refusal.

## S5 — TURN hardening. Edge function + client, independent of everything above.
`turn_cache`; ICE servers returned by `start_call`/`ring_ack`/`accept_call`; two TTLs with the CHECK constraint; `Deno.resolveDns` → `urls_with_ips` + SNI hostname; timeout/retry/last-known-good; `turn_grants` + per-user mint quota + revoke at `end_call`; client expiry as a DURATION on `elapsedRealtime`; server-supplied `relay_max_kbps` and the clamp. Delete `_ensureRelay`'s 3 s budget and the "same wifi" banner.

**Revert:** the edge function is versioned and the new response is a superset. **Verify:** the symmetric-NAT harness is the acceptance gate, plus the daily live-Cloudflare contract test — this is precisely the step the two-month `iceServers`-shape bug lived in.

## S6 — Full glare/redial/ReCall/Busy machine and the batched protocol. Gated on `client_caps`. Coordinated step #2.
Per-`call_id` pre-offer buffering capped at 30; candidates after hangup for that id dropped; `end_of_candidates`; explicit `ice_restart`; 200 ms batching; `reconnecting` state; 8 s relay escalation and 20 s media deadline; caller=impolite/callee=polite for in-call renegotiation only; retire the re-send-every-candidate hack. **Labelled coordinated because a legacy peer would still emit unbatched, unkeyed traffic** — the previous plan gave S4 a capability gate and left S6 without one.

**Revert:** one APK; S3's log is unchanged. **Verify:** Layer 2 glare table + Layer 3 hostile fake channel.

## S7 — Telemetry surfacing and retention.
Partition-management cron for `call_signals` (2 days) and `call_events` (30 days). Dashboards: **per-OEM ring success rate for backgrounded devices (the headline metric)**, push→ring p50/p95 by `Build.MANUFACTURER` split by foreground/background, `originalPriority != priority` rate, relay-vs-p2p share, `end_reason` distribution. Route `CallStatsMonitor` to `call_events` instead of release-mode logcat.

## S8 — Retire the legacy path.
Drop `call_invites`, the public `call:<couple_id>` topic, the old broadcast handlers, and the legacy `reach-notify` payload branch. **Only after S7 shows ≥2 weeks of clean traffic.** The dual-run window is the only rollback that does not require an emergency release.

## Explicitly NOT in the plan
A rewrite of `call_controller.dart`. S6 refactors its inputs to (signal stream, timer ticks, PC events) so it becomes testable; the media layer stays. It contains real hard-won detail — the `identical(pc, _pc)` guard so a disposed connection cannot tear down its successor, `dispose()` rather than `close()` so `AudioSwitchManager` actually stops, `onConnectionState` as the sole authority for `connected`. The inventory rates it *medium*, not fatal, and it is right.

## Verification
## The rule
**No fix in this domain ships on the evidence of two NTP-synced phones on one wifi.** `turn-credentials/index.ts:63-74` documents the two-month outage in the codebase's own words: Cloudflare returns `iceServers` as an object, the client rejected non-Lists, `_cachedTurn` stayed empty forever, no relay candidate ever entered a peer connection — "every call between two different networks failed while two phones on one wifi worked perfectly on host candidates." Same-network testing exercises host candidates and structurally cannot observe the TURN path, the NAT path, the clock path, or the killed-app path.

Every layer below runs on one developer machine plus at most one handset.

## Layer 1 — SQL property tests (laptop, CI, no device)
Against `supabase start`, in pgTAP. This is where the architecture pays for itself.
- **Idempotent ring:** call `ring_ack` twice for the same call. Assert the second returns `ring`, not `expired`, and that `state_ord` is 20 both times. Then call `accept_call` twice from the same `device_id` — assert `accepted` both times, never `accepted_elsewhere`. *(This is the regression lock for fatal #1.)*
- **Redial vs glare:** as the same user, `start_call` against a live row you created. Assert `started` and `superseded`, in BOTH call_id orderings — an ordering-blind assertion is what catches a coin flip. Then as the partner, assert `glare_lost` for the lesser id and that the loser's return carries the surviving offer and cursor. *(fatal #2.)*
- **Reaping:** insert a state-10 row with backdated `expires_at` and a state-40 row with fresh `keepalive_at`; dial. Assert the first is reaped to `no_answer` and the dial succeeds; assert the second is NOT reaped (a naive `now() >= expires_at` reaper kills a live call at 60 s). Then backdate `keepalive_at` by 100 s and assert it IS reaped to `lost`. *(fatal #4.)*
- **Realtime cannot fail durability:** `revoke insert on realtime.messages from postgres` (or drop the current partition), then `start_call`. Assert it commits, the offer signal row exists, and N `push_outbox` rows exist. *(fatal #5.)*
- **Monotonicity is a table property:** attempt a direct `update calls set state_ord = 10` on a row at 90 with the trigger in place. Assert it raises. Call `end_call` twice with different reasons; assert first-writer wins.
- **Seq has no holes:** two concurrent `send_signal` transactions with a deliberate commit-order inversion; assert a reader polling `seq > cursor` observes both. Repeat with a `bigserial` column present to DEMONSTRATE the skip, so the test documents why the counter exists.
- **The client cannot supply anything:** call `send_signal` with a forged seq and a forged `from_user`; assert the stored row carries the server's values. Insert a `calls` row with a client-supplied `expires_at`; assert it is overwritten.
- **Party predicate on the path that actually runs:** as user C from a different couple, drive the RPC (not the table) to insert a hangup into A↔B's call. Assert it raises. Assert the same for a direct table insert (revoked). Assert `select` returns 0 rows.
- **Concurrency:** two concurrent `start_call` for one couple; assert exactly one live row and that neither transaction deadlocks under the advisory lock.
- **Rate limit:** seven dials in five minutes; assert the seventh returns `rate_limited` and writes no `push_outbox` row.
- **Outbox and priority:** assert N outbox rows exist in the same transaction snapshot as the call, one per callee device; assert `insert into push_outbox(kind:'msg', priority:'high')` violates the CHECK.
- **DDL sanity, before the migration is written:** run `create table t(a timestamptz default now(), b timestamptz generated always as (a + interval '60 seconds') stored);` and confirm it FAILS. That is why `expires_at` is a plain defaulted column.
- **Trigger coverage of `reach-notify`:** assert no `pg_proc.prosrc` in `public` contains `functions/v1/reach-notify` without an `Authorization` key.

## Layer 2 — FSM and ring tests (Dart, headless, no PeerConnection)
The controller's inputs become (signal stream, timer ticks, PC events); its outputs are (state, outbound signals). Then RingRTC's collision table is table-driven.
- **The acceptance test for the domain:** deliver a call push with EVERY network call stubbed to throw, and assert the notification is posted with the correct `rem_ms` timer. Then deliver the same push twice and assert the notification is not cancelled. *(fatal #3 and #1.)*
- Assert `unknown` (transport error) from `ring_ack` leaves the ring standing, and that only `expired`/`already_ended`/`accepted-elsewhere` cancel it.
- Timer correctness with a fake monotonic clock: advance `elapsedRealtime` to `rem_ms` and assert cancellation; jump the WALL clock ±3 minutes and assert nothing happens; move `elapsedRealtime` backwards (reboot) and assert cached TURN is treated as expired.
- Seq-gap handling (feed 1,2,4 — assert a catch-up is requested and 3 is not skipped), duplicate delivery (feed 2 twice — idempotent), null payload treated as "call ended", gap past 5 s → `end_call('signal_gap')`.
- Pre-offer candidate buffering with the 30 cap; candidates after hangup dropped; buffers for another `call_id` evicted.
- Extends the existing `mobile/test/unit/call_ring_invariants_test.dart` pattern, which already enforces "`_ring` is the only path into ringing."

## Layer 3 — Hostile fake channel (Dart VM, still no PeerConnection)
The previous plan put "both RTCPeerConnections in one Dart test process" here; `flutter_webrtc` has no Dart-VM implementation (it needs platform channels), so that would be an on-device integration test in which both peers pair over HOST candidates — structurally the same worthless evidence as two phones on one wifi. Split it: the signalling adversary lives here, against a fake channel that reorders, duplicates, delays 5 s, drops the first N candidates, and delivers the answer before some of the caller's candidates. Assert the FSM still reaches `connected` and honours `end_of_candidates`. Media and traversal move to Layer 4.

## Layer 4 — The symmetric-NAT harness. One machine. The asset that does not exist and matters most.
WSL2 or Docker on the dev box: two network namespaces each behind an `iptables` address-and-port-dependent (symmetric) NAT, `coturn` reachable from both, a STUN server outside. Endpoints are headless Chrome or `gstreamer webrtcbin` — no Flutter, because what is under test is the ICE configuration.
- Two symmetric NATs, `iceTransportPolicy: 'all'` → **assert the selected pair type is relay/relay.** This is the direct regression test for the two-month bug.
- TURN credentials absent or malformed → assert the call fails fast with a NAMED reason, never "proceeds relay-less".
- UDP blocked entirely → assert TURN/TLS on 443 is attempted, and record whether it suffices. Cloudflare does not implement RFC 6062 TCP allocations; this is how you learn whether TLS wrapping is enough before a user tells you.
- Mid-call interface flap → assert continual gathering recovers on the same ICE generation with no new offer, and that escalation to `ice_restart` fires only after 8 s.
- Credential expiry mid-call → assert the established allocation survives (it is 5-tuple bound) but a subsequent ICE restart fails without a refresh, and that the client refreshes first.
- **The relay clamp:** with a relay/relay pair, assert `getStats()` shows the video sender clamped to `relay_max_kbps` within 2 s. This is the only mechanical check on the dominant cost line.

## Layer 5 — Live vendor contract test (CI, daily)
Hit the DEPLOYED `turn-credentials` function, parse the response with the production parser, and assert it yields at least one `turn:` or `turns:` URL plus a username and credential, and that `client_ttl_seconds <= requested_ttl_seconds`. Fail the build on a shape change. **This single test is the one that would have caught the bug that motivated this entire document** — the NAT harness would not have, because a stub built from the client's own assumptions stays green forever.

## Layer 6 — Push and ring on ONE physical device
Deterministic with `adb` alone:
- `adb shell am set-standby-bucket <pkg> rare` and `restricted` — the buckets where network access is disabled and only high-priority FCM's temporary grant escapes.
- `adb shell dumpsys deviceidle force-idle` — Doze.
- `adb shell am force-stop <pkg>` — assert the ring does NOT arrive and that the app says so honestly. Force-stop is a platform contract; the test asserts the STATED behaviour.
- `adb shell am compat enable FGS_BOOT_COMPLETED_RESTRICTIONS <pkg>`.
- Revoke `USE_FULL_SCREEN_INTENT` via app-ops → assert graceful degradation to a heads-up CallStyle notification.
- **Airplane mode ON, then deliver the push after re-enabling at 45 s** → assert the ring still shows (TTL = remaining window) and `accept_call` still returns the offer. At 65 s → assert `ring_ack` cancels it and a missed-call entry appears, with no sustained ring.
- **Set the device clock 3 minutes fast, then ring** → assert the notification is posted and NOT cancelled early. Set it 3 minutes slow → assert cached TURN is still refreshed on schedule.
- Server side: a fake FCM endpoint returning 429/500/`UNREGISTERED`/timeout — assert the 1 s call drain's fixed backoff, the hard stop at `expires_at`, `push_abandoned` rather than a `ttl=0` send, and token deletion.

## Layer 7 — Field telemetry, because the first six cannot see an OEM
From `call_events`: per-call, per-device timestamps for `push_sent → push_received → ring_shown → answered → first_media`, plus `end_reason`, selected-pair type, and `Build.MANUFACTURER`/model/API. Three production truths:
1. **Per-OEM ring success rate for BACKGROUNDED devices** (`push_sent` → `ring_shown`) — the domain's headline metric.
2. **push→ring p50/p95 by manufacturer, split foreground vs background**, so a Layer B improvement cannot mask a Layer C regression.
3. **`originalPriority != priority` rate** — the direct read on whether Android is downgrading the app, the one otherwise-invisible cliff.

## The acceptance gate
A change in this domain is done when: Layer 1 green; Layer 2 green **including the network-stubbed ring test**; Layer 3 green; Layer 4 asserts a relay/relay pair between two symmetric NATs AND the bitrate clamp; Layer 5 green against the live function; the Layer 6 adb matrix documented with actual output including the clock-skew rows; and Layer 7 shows backgrounded push→ring p95 from at least one real OEM device over 48 hours. Two phones on one wifi is not on that list and never appears on it.

## Accepted limits
**1. The relay bitrate clamp is client-side and cannot be server-enforced. This is the largest residual risk in the design, and it is financial.**
In a peer-to-peer architecture the server never sees the media. `RELAYED_MAX_SEND_RATE` is applied by the sending client via `setParameters`; if a refactor drops the `getStats()` check, or `setParameters` silently fails on some device, the bill roughly triples with no error anywhere. **Cost has no error code.** What IS enforced server-side: per-call `turn_grants` so egress is attributable, a per-user mint quota, revocation at `end_call`, and `relay_max_kbps` shipped from `turn_cache` so the value can be lowered without a release. What must be added operationally: a Cloudflare billing alarm at 120% of the modelled monthly egress, and a weekly reconciliation of relayed call-minutes from `call_events` against billed GB — a divergence is the only signal the clamp has regressed. Residual: up to ~2.5× the projected TURN line (≈ +$450/month at 10k users, +$5,000/month at 100k) for up to one billing period before anyone notices.

**2. Seq-cursor reconciliation is a client algorithm. The server guarantees the log has no holes; it cannot guarantee the client reads it correctly.**
Mitigated three ways: the failure mode is a stuck call, never lost data, because the log is durable and the next foreground drains it; the gap rule is bounded by a 5 s timer that ends the call with a named reason (`signal_gap`) rather than hanging; and the whole rule is testable headless with a fake channel, so it is CI-enforceable rather than field-discovered. Residual: a client bug can produce "the call rang and then did nothing" for one attempt, recoverable by redialling.

**3. Force-stopped devices do not ring. There is no engineering answer, and this is the actual product ceiling.**
`FLAG_STOPPED` means nothing in the app runs, receivers included, until the user launches it directly; Android 15 additionally cancels all pending intents. Samsung/Oppo/Vivo/Huawei catalogue as "no known solution on dev end". All three target handsets (IN2015, OnePlus 7, Vivo) are on the worst or near-worst tier. What ships instead is honesty and measurement: the S1 diagnostics screen, per-manufacturer deep links, a "test your ring" round trip, and per-OEM ring success rate as the domain's headline metric. Residual: an unknown but almost certainly double-digit percentage of rings never arrive on these handsets, and the architecture cannot change that number — only the user's autostart settings can.

**4. Ring overshoot on a late push, bounded at roughly 2× the ring window.**
The self-cancel timer is armed at `rem_ms` from the moment of RECEIPT on a monotonic counter, because that is the only device-side timing input that survives a wrong clock and no network. FCM `ttl` is set to the same remaining window. So a push delivered at the very edge of its TTL can leave a ring standing for up to another full window — worst case ~120 s from dial. It requires simultaneously a TTL-edge delivery AND `ring_ack` failing, and the push arriving at all implies momentary connectivity, so this is narrow; the cancel push (same collapse key, which REPLACES an undelivered ring push rather than queueing behind it) narrows it further. Not closed: a device that receives the ring push and then immediately loses the network rings for up to `rem_ms` after the call is over.

**5. A CallStyle incoming-call notification is visibly a call notification, and that is in tension with the disguise.**
`visibility: SECRET` hides content on the lock screen and the FSI surface is drawn by the app under whichever cover is active, but `CATEGORY_CALL` + `CallStyle` is recognisably a calling app to anyone who looks at the notification shade, and CallStyle can forward to paired watches and car head units. Rejecting `ConnectionService` removed the permanent Settings → Calling accounts tell; it did not make the ring itself invisible. See open decision 3 for the discreet-ring alternative and its cost.

**6. Reaping an accepted call at 90 s of silence frees the couple slot but does not stop media.**
If both clients lose Supabase reachability while a direct P2P path survives, the server marks the call `lost` and releases the slot. Media keeps flowing until a client reconnects and reconciles. Consequence: a subsequent dial creates a second `calls` row while an unreconciled call is still audible. This is the safe direction (a stuck row would be worse), and it is rare, but it is a real inconsistency and it is deliberate.

**7. Layer B (private per-call broadcast) delivers no benefit on the path the design exists to fix.**
A cold-started callee must open a websocket, present a JWT and have Realtime evaluate the join policy — 1–3 s on a cold radio. Layer B improves the foregrounded case, which was never broken. It is kept because it is nearly free and it removes 1–3 s from in-call signalling, but its latency must be reported separately from the killed-app path so an improvement in one can never be read as an improvement in the other.

**8. Multi-device connect time is answer latency PLUS ICE latency.**
Signal's ICE forking shares one `IceGatherer` across parent and child PeerConnections so ICE completes with all linked devices before the human accepts. `flutter_webrtc` exposes no shared-gatherer API; getting it means forking the plugin. We use an atomic first-accept-wins compare-and-set instead and pay ~1–3 s on the answer path. Revisit only if telemetry shows real two-device usage.

**9. Telecom losses, in writing:** no true hold/swap against a cellular call, no system call log entry, degraded Bluetooth switching, no CallStyle forwarding to watches or car head units.

**10. Cloudflare TURN has two gaps that cannot be paid away:** no RFC 6062 TCP relay allocations (only TLS wrapping) and no IPv6 relay addresses. On a UDP-blocking network or an IPv6-only carrier without working 464XLAT, there may be no path at all. The NAT harness includes a UDP-blocked scenario so the coturn-on-443 decision can be made on evidence rather than on the day it breaks.

**11. The FCM priority-downgrade threshold is an unpublished number.**
Android 13+ downgrades apps whose high-priority pushes do not consistently produce notifications, assessed over 7 days, and it is invisible from the server. The design narrows exposure structurally — a dial budget in `start_call`, `CHECK (priority <> 'high' OR kind = 'call')`, a per-device hourly budget, and a ring that always produces a visible notification — but cannot guarantee the app stays above the line. The only detector is `originalPriority != priority`, instrumented from S2.

**12. The +20% protocol-overhead figure on relayed egress is an estimate, not a measurement.** It covers Opus riding alongside the video cap, RTX/NACK, RTCP, TURN framing and IP/UDP headers. The first month's Cloudflare invoice is the real calibration; the cost model should be corrected against it rather than defended.

## Open decisions
**1. Does the app lock stand between the ring and the answer?** Highest-stakes question, and a product decision. Today a cold-started callee must pass biometrics before reaching an Accept button, inside the caller's 35-second timer, and it routinely does not fit. This revision reduces the pressure considerably — the ring window is 60 s, the ring is posted before any network call, and `accept_call` returns offer + ICE servers + cursor in one round trip — but the biometric is still serial with all of it. **Recommendation: audio calls answer pre-auth onto a locked-down call surface** (only the call; no navigation to chat, gallery or Closer), with video preview and everything else behind the biometric. Rationale: the caller is already authenticated as the bound partner by the server, so the residual risk is bounded — a stranger holding a stolen phone hears the partner's voice — against a certainty on the other side. If the owner rejects this, the Answer notification action must at minimum start `accept_call` and ICE gathering BEFORE the unlock, so the biometric overlaps negotiation rather than following it.

**2. Telecom / `ConnectionService`.** **Recommendation: no**, per §6. Reconsider only if the owner will make one launcher alias a plausible calling app (a "Walkie" or "Voice" cover) and register the `PhoneAccount` under that exact label, accepting that the cover then becomes FIXED rather than switchable. There is no configuration giving both full Telecom integration and full concealment; decide once and write it down rather than rediscovering it each time someone notices the Bluetooth routing is imperfect.

**3. NEW — CallStyle ring versus a discreet ring.** `CallStyle.forIncomingCall()` buys ranking priority, a real Answer/Decline surface, and correct behaviour on Android 14+; it also makes the notification recognisably a call and can forward to paired watches and car head units. The alternative is a plain IMPORTANCE_HIGH notification styled entirely as the active cover ("News — breaking story") with two generic actions, losing the ranking boost and some FSI reliability. **Recommendation: CallStyle by default, with a per-user "discreet ring" setting that switches to the covered style**, because the disguise is the product premise and only the user knows their situation. Decide before S1 — it is the one thing in that stage that cannot be changed without another APK.

**4. Relayed video bitrate.** 1 Mbps (Signal parity) or 600 kbps (−40% of the dominant cost line). **Recommendation: 1 Mbps now, delivered as `turn_cache.relay_max_kbps`** so it can be lowered without a release when the invoice says so. The decision that must not be deferred is putting the value behind server config rather than a constant.

**5. Do calls ring after a force-stop?** No engineering answer exists. **Recommendation: state it plainly in the app**, ship "test your ring", and treat force-stopped devices as a known, MEASURED population in telemetry rather than a bug queue. The owner decides whether that sentence appears at onboarding (honest, slightly alarming) or only in diagnostics (discoverable only after the failure). Given that all three target handsets are worst-tier, the recommendation is onboarding.

**6. `KEEPALIVE_MISS` = 90 s and `CALL_CEILING` = 4 h.** These govern how long a couple's calling slot stays occupied after both processes die mid-call. Shorter is more available and more likely to reap a live call during a tunnel; longer is the reverse. **Recommendation: 90 s with a 15 s keepalive**, i.e. six missed beats, and revisit from the `end_reason='lost'` rate in telemetry. Name both in the migration so they are tunable in one place.

**7. Free versus Pro.** **Recommendation: Pro immediately.** Free fails closed at 200 concurrent connections with no overage, and research/supabase.md puts this app's real free-tier capacity at roughly 100–150 users. Calling does not drive this, but calling is what the failure gets blamed on.

**8. Per-call topic versus always-on couple topic.** **Recommendation: per-call.** It keeps concurrent Realtime connections scaling with concurrent CALLS rather than with USERS, which is the difference between fitting inside a 10,000-connection ceiling at 100k users and not. Cost is one channel join (~50–100 ms) that overlaps `getUserMedia`. Decide now — S3 and S4 both encode it.

**9. Is multi-device in scope?** **Recommendation: build `device_tokens` now** — it is cheap, it unblocks push fan-out and delivery observability, and today's single `profiles.fcm_token` column means a second sign-in silently steals the ring from the first phone — but **ship single-active-device semantics** (`accept_call` compare-and-set, losers get `accepted_elsewhere`) rather than ICE forking. Revisit forking only on evidence of real two-device usage.

**10. Retention of `call_events`.** Signalling payloads die with their call; `call_events` is the only production truth about OEM behaviour. **Recommendation: 30 days by daily partition drop** — enough for the OEM dashboards, and it caps the disk line at ~15 GB even at 100k users. The owner should confirm they want per-call, per-device timing data retained that long given the app's privacy posture; the mitigation is that `call_events` carries no content, only timestamps and device class. If the answer is no, 7 days still supports the headline metric and loses only week-over-week trend.

**11. When to drop `call_invites` and the public topic.** **Recommendation: not before S7 shows two clean weeks on the new path.** The temptation to delete the old path at S3 should be resisted — the dual-run window is the only rollback that does not require an emergency release.

**12. NEW — who owns the Cloudflare billing alarm?** The relay clamp is the one invariant this design cannot enforce, and its failure mode is silent. Somebody must own a monthly reconciliation of relayed call-minutes (from `call_events`) against billed GB. **Recommendation: make it a line in the S7 dashboard and a calendar reminder, not a hope.**
