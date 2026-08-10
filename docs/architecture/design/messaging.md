# Message delivery and the sent / delivered / seen state machine (Miles, Flutter + Supabase, com.miles.miles)

## Current design
## What exists today, precisely

**Identity.** `messages.id uuid primary key default gen_random_uuid()`. The text path mints a client-side uuid v4 and threads it through (`chat_screen.dart:_sendTextFast` L101-130). The video path does NOT — `ChatSendQueue._enqueue` passes `id=null` and `ChatRepository.sendVideo` inserts without an id, so Postgres assigns a different uuid and the sender gets two bubbles, one of them dead (inventory/chat.md, chat.send.media, CONFIRMED BUG). There is no `client_msg_id`, no unique constraint on it, and no `ON CONFLICT` anywhere — so the server has no idempotency key at all.

**Ordering.** Verified in `E:/LDR/supabase/receipts_v2.sql` L30-31:
```
create sequence if not exists public.messages_seq_seq owned by public.messages.seq;
alter table public.messages alter column seq set default nextval('public.messages_seq_seq');
```
A single **global** Postgres sequence, shared by every couple in the project.

**Cursor.** Verified in `E:/LDR/mobile/lib/features/chat/chat_repository.dart` L183-200 and `chat_screen.dart` L343-344:
```
fetchSince: .gt('seq', afterSeq).order('seq', ascending: true).limit(500)
_maxSeq:    _messages.fold<int>(0, (a, m) => m.seq > a ? m.seq : a)
```
This is the exact pattern research/delivery.md names as fatal, in both halves at once: a non-transactional sequence, read by `WHERE seq > cursor`, with the cursor set to the **maximum** observed value.

**Transports.** Three, simultaneously, none authoritative: (1) client-sent Broadcast on the **public** topic `mood_burst:<coupleId>` carrying message bodies with no membership check and no sender check — a forged `msg` renders at `seq=0` forever and never gets a DB echo; (2) `postgres_changes` on `messages`, live-only, `REPLICA IDENTITY FULL`, RLS re-evaluated per subscriber per row; (3) an AFTER INSERT trigger firing `net.http_post` per row into an edge function that RSA-signs a fresh service-account JWT and does an OAuth exchange **on every single message** before it reaches FCM (3 outbound HTTPS hops per message, no token cache, no suppression when the recipient's chat is already open).

**Send durability.** `_sendTextFast` L125-129: `try { await ChatRepository.sendText(...) } catch (_) { /* it's already on screen */ }`. There is no outbox, no retry, no persistence, no failure state for the most common message type. An insert that fails leaves a bubble that looks sent forever and is gone on restart. Media has an in-memory `List<PendingSend>` that does not survive process death.

**Receipts.** `chat_receipts(couple_id, user_id, delivered_seq, read_seq)`, PK `(couple_id, user_id)`, advanced only through `greatest()` SECURITY DEFINER RPCs. The monotonicity is genuinely right. Everything around it is not: `ackDelivered` has exactly one caller (`chat_screen.dart` L379, inside `_catchUp`) and the very next line calls `_ackRead()` with the same value, and `ack_read` advances both columns. **The double-grey tick is unreachable by any code path.** A `Timer.periodic(5s)` re-acks read and re-upserts `presence.chat_last_read` unconditionally for as long as the chat is open.

## Why it fails, in order of severity

**1. The cursor loses messages permanently, and the loss is silent.** `nextval` is non-transactional. Two overlapping inserts take 105 and 106; if 106 commits first, a reader polling `WHERE seq > cursor` observes 106, advances to 106, and 105 becomes unreachable to every subsequent catch-up. This is Synapse's documented hazard verbatim — "monotonic, but they may skip or jump over IDs because facts complete out of order" — and the app has both halves of it. The sequence being **global** rather than per-couple makes the window denser at scale, not sparser: at 5,000 couples every couple's stream is interleaved with everyone else's, so any commit-order inversion anywhere in the project can straddle a couple's cursor.

**2. `_maxSeq` is a maximum, not a prefix — so a hole is never repaired and is actively reported as read.** No code path ever re-reads below `_maxSeq`. Worse, `_ackRead()` passes `_maxSeq` to `ack_read`, so the recipient tells the server it has read up to 106 while never having received 105, and the sender's `_statusFor` (L653-663) renders 105 as **seen**. The system's most-trusted signal is structurally capable of lying. The only repair is a cold app restart, whose 300-row `fetch()` re-reads everything — which is exactly why this bug is intermittent, unreproducible, and survives every fix.

**3. `delivered` does not exist.** One caller, immediately overwritten by `read`. A partner sitting on the Home tab with the app open, or one who received the FCM push, gives the sender no signal at all. The tick jumps single-grey → blue.

**4. Nothing survives the screen.** Catch-up, receipt acks, and the send queue are all owned by `ChatScreen`, which `app_shell.dart` renders in a bare `Column` rather than an `IndexedStack` — switching tabs **disposes** it, tearing down all three channels and dropping the pending list.

**5. The fast path is a forgery channel.** `couple_id` is not secret; it is the first path segment of every never-expiring public `couple_media` URL, as `hardening_2026_08.sql` L25 itself admits. Anyone holding one can join `mood_burst:<coupleId>` and inject messages attributed to either partner.

**6. Every previous fix was validated in a setup that cannot exhibit any of this.** Two NTP-synced phones on one wifi produce no reordering, no commit-order inversion, no packet loss, and no clock skew. It is the four-way blind spot.

## Target architecture
## The one mechanism

**A per-couple, contiguous, commit-ordered log, assigned under a row lock held to commit.** Everything else is a consequence.

```sql
chat_streams (
  couple_id uuid primary key references couples(id) on delete cascade,
  last_seq  bigint not null default 0
)   -- narrow, NOT in the realtime publication
```

Assignment happens only inside `send_message`, which takes `SELECT last_seq FROM chat_streams WHERE couple_id = C FOR UPDATE` **before** doing anything else and holds it until COMMIT. Any concurrent send for the same couple blocks there. Therefore, for a given couple, **cseq order is commit order**: a reader that observes cseq N is guaranteed every cseq < N is already visible. That is the property a Postgres sequence does not have and that Synapse builds in-flight-token tracking to emulate. Here the lock *is* the serialization, so it costs one row lock on a table with one writer per couple.

This single change removes, by construction: the skip hazard, the need for gap *repair* (only gap *detection* remains, for the socket layer), the hot-global-counter, and the whole class of "cursor advanced past an uncommitted write."

## Data model

```sql
messages (
  id                   uuid primary key default gen_random_uuid(),
  couple_id            uuid not null,
  sender_id            uuid not null,
  client_msg_id        uuid not null,        -- Telegram random_id / Matrix txnId
  cseq                 bigint not null,      -- per-couple, contiguous, gapless
  kind, body, media_path, reply_to_client_id,
  created_at           timestamptz default now(),   -- DISPLAY ONLY, never compared
  ...
);
unique (couple_id, sender_id, client_msg_id);   -- idempotency
unique (couple_id, cseq);                       -- makes a hole a constraint violation, not a mystery
index  (couple_id, cseq);                       -- the only hot read path

chat_receipts (
  couple_id, user_id,
  delivered_cseq bigint not null default 0,
  read_cseq      bigint not null default 0,
  primary key (couple_id, user_id)
);

push_outbox (id, couple_id, recipient_id, cseq, state, attempts, next_attempt_at);
```

`messages.seq` and `messages_seq_seq` stay untouched during migration and are dropped at the end. HASH-partition `messages` on `couple_id` (32 partitions) — the catch-up query `couple_id = X AND cseq > N` prunes perfectly; a time-based partition would not.

## Server operations (three RPCs, all SECURITY DEFINER)

**`send_message(client_msg_id, kind, body, media_path, reply_to_client_id) -> (id, cseq, created_at, deduped)`**, one transaction:
1. resolve couple from `(select auth.uid())`
2. `SELECT last_seq FROM chat_streams WHERE couple_id = C FOR UPDATE`  ← the lock, first
3. lookup `(couple_id, sender_id, client_msg_id)`; if found, return `{id, cseq, deduped: true}` and commit **without bumping the counter**
4. else `UPDATE chat_streams SET last_seq = last_seq + 1 RETURNING last_seq` → INSERT message → INSERT push_outbox
5. return `{id, cseq, deduped: false}`

Because the lock is taken before the dedup check, a concurrent duplicate cannot burn a counter value. Holes are impossible, not unlikely.

**`sync_messages(after_cseq bigint, limit int) -> (rows, stream_last_seq)`** — `WHERE couple_id = C AND cseq > after_cseq ORDER BY cseq LIMIT n`, plus the stream head. `has_more` is **server-declared** (`stream_last_seq > max(returned cseq)`), never inferred from `count == limit`. This is Matrix's `timeline.limited` / Telegram's `differenceSlice`.

**`ack_delivered_cseq(n)` / `ack_read_cseq(n)`** — `greatest(existing, least(incoming, stream.last_seq))`. The `greatest` makes a replayed or reordered ack a no-op; the `least` makes it impossible for a client to claim it read into the future. `ack_read` advances both columns (read implies delivered).

## Client: the outbox

A Drift/SQLite table, owned by no screen:
```
outbox(client_msg_id pk, couple_id, kind, body, media_local_path, media_remote_path,
       state, attempts, next_attempt_at, reply_to_client_id)
```
A single drainer per process (re-entrancy-guarded — Signal enforces one-consumer-per-queue server-side with close code 4409; there is no server queue here, so the client owns it). Wakes on: app start, connectivity regained, foreground, FCM wake, enqueue, and a timer while any row is due. **Never** "while ChatScreen is mounted."

## Client: the cursor

Per couple, persisted in SQLite: **`applied_cseq` = the length of the contiguous prefix**, plus a staging buffer of rows ahead of it. Telegram's pts arithmetic, simplified because every message advances by exactly 1 (no `pts_count` — see the deliberate-difference note in `why_top_tier`).

- `incoming == applied + 1` → apply, `applied++`, then drain the staging buffer forward
- `incoming <= applied` → already applied, drop (this is the idempotency rule)
- `incoming > applied + 1` → **gap**: stage it, run catch-up

`applied_cseq` and the message rows it covers are written in **one local transaction**. The variable `max(received_seq)` does not exist anywhere in the new client — which is what makes the phantom-seen bug unable to reappear.

## Transport, in three strictly ranked layers

1. **Truth** — the `messages` table read via `sync_messages`. The only thing that may be believed.
2. **Hint** — private Broadcast-from-database on `chat:<couple_id>`, fired by an AFTER INSERT trigger calling `realtime.broadcast_changes`, carrying the row. Because it is DB-generated on a private channel gated by RLS on `realtime.messages`, it cannot be forged — unlike today's client-sent broadcast on a public topic, which is deleted. `realtime.send` catches its own exceptions via `pg_notify`, so a Realtime failure can never roll back a send.
3. **Wake-up** — FCM data push carrying `{couple_id, max_cseq}` only, never a body. Mirrors Signal's "schedule a push 1 minute after a disconnect that left the queue non-empty."

**No layer above (1) may advance any cursor or watermark.** Layers 2 and 3 can only *trigger a read of* layer 1. A dropped, duplicated, reordered, or forged frame is therefore a latency event, never a correctness event.

## Push, rebuilt

The trigger writes a `push_outbox` row — a plain insert, no HTTP in the write path (which also shortens the stream-lock hold). A `pg_cron` job every 5s drains it: **coalesces by recipient** (one push carrying the max cseq — a watermark, not a message), **suppresses** any recipient whose `delivered_cseq >= max cseq`, and uses an OAuth bearer cached in a table with its expiry, refreshed by one edge invocation per ~50 minutes. A 40-message burst collapses from 120 outbound HTTPS calls to 1. Failure is visible: rows persist with attempt counts, and "undelivered for > N minutes" is a one-line dead-letter query — pg_net documents no retry, so this must be owned.

## Sequence: send

1. Client mints `client_msg_id = uuidv4()`.
2. **One local transaction**: insert local message row (`cseq = null`) + outbox row (`QUEUED`). Commit.
3. UI renders the bubble — only after step 2 commits. This ordering is what makes "on screen but never sent" impossible.
4. Drainer: if media, upload, write `media_remote_path` back to the outbox row, commit locally (a retry after this point does not re-upload).
5. Drainer calls `send_message`.
6. Server: lock → dedup check → bump → insert → push_outbox → commit.
7. Client, on **any** successful return including `deduped: true`: one local transaction — write server id + cseq into the message row, delete the outbox row. Commit.
8. Commit fires the broadcast; the recipient applies under the prefix rule; the sender ignores its own cseq (already applied).
9. pg_cron drains push_outbox on the next tick.

## Sequence: receive

1. Any trigger invokes the couple's sync worker (singleton, guarded).
2. Read `applied_cseq` from SQLite.
3. `sync_messages(applied_cseq, 200)` → `{rows, stream_last_seq}`.
4. **Assert** the rows are exactly `applied+1 .. applied+n` with no holes. If not, the server invariant is broken: log loudly, full resync.
5. One local transaction: insert rows + set `applied_cseq = applied + n`. Commit.
6. If `stream_last_seq > applied_cseq` → goto 3.
7. Caught up: `ack_delivered_cseq(applied_cseq)`. If the chat is visible and pinned to the newest message: `ack_read_cseq(applied_cseq)`. Both debounced to ≤1/s per couple — they are idempotent watermarks, so coalescing loses nothing.
8. Post local notifications for anything that arrived while backgrounded.

**Local commit precedes ack, always** — the client-side mirror of Signal's ack-then-delete ordering.

## The state machines

**Outbox (per message, client-local, persisted):**

| From | To | Trigger |
|---|---|---|
| — | QUEUED | user sends; outbox row + local message row committed atomically |
| QUEUED | UPLOADING | drainer picks it up, kind has a local file |
| UPLOADING | QUEUED | upload error → `attempts++`, `next_attempt_at = now + backoff(attempts)` |
| UPLOADING | INFLIGHT | upload succeeded, remote path persisted |
| QUEUED | INFLIGHT | drainer picks up a text message |
| INFLIGHT | COMMITTED | `send_message` returned — including `deduped: true` |
| INFLIGHT | QUEUED | timeout / socket error / 5xx / 429 → backoff. `client_msg_id` unchanged, so the retry is byte-identical |
| INFLIGHT | BLOCKED | deterministic 4xx (RLS denial, unpaired, rejected payload) |
| BLOCKED | QUEUED | user taps retry |

There is no transition that changes `client_msg_id` and no automatic terminal failure for a network error. Retry is forever.

**Tick (per message, sender's screen) — not stored; a pure function of three integers.** For message cseq `S`, partner's `(D, R)`:

- `S is null` → PENDING (clock)
- `S > D` → SENT (one tick)
- `D >= S > R` → DELIVERED (two grey)
- `R >= S` → SEEN (two blue)

Transitions occur only when D or R change, which happens only when the recipient's device writes them. No timer, no timeout, no client-side latch, no per-message row. **SENT → SEEN directly is legal and correct** — Meta documents exactly this: when a message is delivered and read simultaneously "the delivered webhook is not sent because it's implied."

**Sync worker (per couple, client):**

| From | To | Trigger |
|---|---|---|
| CAUGHT_UP | CATCHING_UP | app start / foreground / connectivity / socket open / FCM wake / 60s timer |
| CAUGHT_UP | GAPPED→CATCHING_UP | live frame with `cseq > applied + 1`; frame is staged |
| CATCHING_UP | CATCHING_UP | `stream_last_seq > applied_cseq` → next page |
| CATCHING_UP | CAUGHT_UP | `stream_last_seq == applied_cseq` → **then and only then** write the watermarks |
| CATCHING_UP | BACKFILLING | cold start with `stream_last_seq - applied_cseq > 2000` → render the newest page for display, leave `applied_cseq` where it is, backfill downward in background |
| BACKFILLING | CATCHING_UP | a backfill page closes part of the prefix |

BACKFILLING is Telegram's `differenceTooLong` and Matrix's `M_UNKNOWN_POS` — a first-class protocol state, not an error. Note the deliberate split: **display order and the watermark are decoupled.** The UI shows anything it has; the watermark is strictly the prefix, so during backfill the sender's ticks lag — and that is honest, because those messages genuinely have not been received.

## The two-day-offline guarantee, as a chain of custody

1. The outbox row commits to SQLite before the UI acknowledges the user → survives app kill.
2. The drainer retries `send_message` forever with backoff; every retry is idempotent on `client_msg_id`.
3. Once it returns, the row is in Postgres with a cseq. **Postgres retention is unbounded** — no TTL, unlike Signal's 7 days or WhatsApp's 30. The message cannot expire.
4. The recipient's `applied_cseq` is persisted and behind. App start, foreground, connectivity, socket open, FCM wake, or the 60s timer all trigger catch-up. For a phone off for two days, the trigger is "app start" or "the first FCM wake after it returns."
5. The catch-up is paginated until `stream_last_seq` is reached. Because cseq is contiguous and commit-ordered, it returns exactly the missing set, in order, with no possibility of a skip.

None of this requires both users online, the same network, a foregrounded app, a correct device clock (no timestamp is compared anywhere — `created_at` is display-only), or a reliable socket. The honest limit: if the recipient never opens the app again, nothing arrives. No system solves that; FCM is an accelerator, not the guarantee.

## Invariants
- ORDERING: cseq is assigned only while holding an exclusive row lock on chat_streams for that couple, taken before the dedup check and held to COMMIT. Therefore commit order equals cseq order per couple, and a reader observing cseq N is guaranteed every cseq < N is already visible. This is what a Postgres sequence cannot give — nextval is non-transactional, so 105 can become visible before 104 commits (Synapse: current positions 'are monotonic, but they may skip or jump over IDs because facts complete out of order'). The lock IS the serialization; no in-flight token tracking is needed.
- CONTIGUITY: cseq for a couple is dense from 1 with no gaps, enforced by unique(couple_id, cseq) plus the fact that the counter is bumped only after the dedup check passes under the lock. A hole is therefore a constraint violation or a detectable production anomaly, never a silent state. A concurrent duplicate send cannot burn a counter value.
- IDENTITY: client_msg_id is minted before the first network attempt and committed to local SQLite before the UI acknowledges the user. Every retry is byte-identical, and unique(couple_id, sender_id, client_msg_id) makes it a server-side no-op that returns the ORIGINAL row. A timeout is therefore never ambiguous, and the retry path needs no logic that the first-attempt path does not have.
- CURSOR: applied_cseq is the LENGTH OF THE CONTIGUOUS PREFIX, never the maximum observed value. It advances only through applied+1. The variable max(received_seq) does not exist in the new client. Therefore a skipped message is detected at the very next apply attempt, and the catch-up query — which starts at the prefix, not the max — necessarily re-reads it. This is the direct replacement for chat_screen.dart:344 `_messages.fold<int>(0, (a, m) => m.seq > a ? m.seq : a)`.
- ATOMICITY OF THE CURSOR: applied_cseq and the message rows it covers are written in a single local SQLite transaction. A crash between them is impossible, so the client can never believe it has applied something it did not store.
- WATERMARK SOUNDNESS: delivered_cseq and read_cseq are only ever written from applied_cseq, which by the previous invariant covers a complete prefix. Combined with server-side `greatest(existing, least(incoming, stream.last_seq))`, a late/replayed/reordered ack cannot move a watermark backwards, and no client can claim to have read into the future. The current code's `ack_read(_maxSeq)` — which reports a hole as read and makes the sender render a never-received message as SEEN — has no expressible equivalent.
- ACK ORDERING: the local commit strictly precedes the ack. The client acks only what is durably in its own storage, never what merely arrived on a wire. (Signal's mirror image: only a 2xx on PUT /api/v1/message triggers acknowledgeMessage() and removal from the queue.)
- TRANSPORT SUBORDINATION: only the messages table may advance a cursor or a watermark. Broadcast and FCM may only TRIGGER a read of it. Consequently a dropped, duplicated, reordered, delayed, or forged frame is a latency event and never a correctness event — which is what makes it safe to run notification over Supabase Realtime, a transport with documented zero delivery guarantees.
- GAPS ARE SERVER-DECLARED: sync_messages returns stream_last_seq alongside the rows, so has_more is a server fact, not `count == limit` guesswork. The client never infers whether it missed something. 'Too far behind' (BACKFILLING) is a first-class state with a defined exit, not an error path.
- STATE LATTICE WITH SKIPPING: read implies delivered implies sent, enforced by ack_read advancing both columns. The sender's tick is a pure function of (message cseq, partner delivered_cseq, partner read_cseq) with no stored per-message state, no timers, and no latch. SENT → SEEN directly is legal — Meta documents that when a message is delivered and read at once, 'the delivered webhook is not sent because it's implied that the message was delivered since it was read.'
- OWNERSHIP: sent is a server fact (the row exists with a cseq). delivered is written ONLY by the recipient device, and only after the row is committed to its local storage as part of the contiguous prefix — not when Realtime emitted it, not when FCM arrived. read is written ONLY on actual widget visibility. RLS makes it structurally impossible for a sender to write the peer's watermark. No server ever infers 'read'.
- NO SCREEN OWNS DELIVERY: the outbox drainer and the sync worker are process-scoped singletons with re-entrancy guards, not children of ChatScreen. They run on app start, foreground, connectivity change, and FCM wake. Delivery correctness has no dependency on which tab is selected — today, tab-switching disposes ChatScreen and takes catch-up, receipts, and the pending send list with it.
- CLOCKS ARE PAYLOAD, NEVER CONTROL: created_at is rendered and never compared. No device clock enters any ordering, cursor, watermark, or expiry decision. There is no inequality anywhere in the delivery path with a timestamp on either side.
- PUSH CARRIES A WATERMARK, NEVER A MESSAGE: FCM payloads contain {couple_id, max_cseq} only. Coalescing forty messages into one push loses nothing, because the recipient's response to any push is identical — run the sync worker from its own prefix. Push is a wake-up, not a delivery channel.

## Why this mirrors the top tier
Mirrors, with sources from `research/delivery.md`:

**Telegram's `pts`** — [core.telegram.org/api/updates] — for both the ordering integer and the gap arithmetic. The apply rule is Telegram's `local_pts + pts_count == pts` → apply; `>` → already applied, drop; `<` → gap, buffer and call `getDifference`. The per-couple counter is Telegram's channel sharding taken to its logical end: Telegram gives every channel its own `pts` and its own `getChannelDifference` precisely because one account-wide counter cannot absorb a large channel's write rate. **`client_msg_id` is Telegram's `random_id`**, "a unique 64-bit client message ID required to prevent message resending," which the client also uses "to associate the previously transmitted message with the one delivered to the server."

**Synapse's stream discipline** — [matrix-org.github.io/synapse/.../streams.html] — for *why* the lock exists. Synapse publishes "the largest stream ID where all transactions added by W with equal or smaller ID have completed," because positions "are monotonic, but they may skip or jump over IDs because facts complete out of order." The app currently has the failure this prevents, verbatim, in `receipts_v2.sql` L30-31 plus `chat_repository.dart` L188.

**Matrix's txnId rule** — [spec.matrix.org] — "The homeserver should identify a request as a retransmission if the transaction ID is the same as a previous request," and a retransmission returns **the original response** (same event_id). That is exactly `send_message` returning `{id, cseq, deduped: true}`.

**Matrix's cursor-ack invariant** — MSC4186 — "the server MUST ensure that any per-connection state it tracks correctly handles receiving multiple requests with the latest pos token," and MSC2285's normative "both receipts can only move forwards." The `greatest()` RPCs are that as a database constraint.

**Signal's ack ordering** — [Signal-Server WebSocketConnection.java] — 2xx is the ack and is the only thing authorising deletion; and "on disconnect with a non-empty queue, schedule a push notification 1 minute later." Push-as-wake-up, and local-commit-before-ack, both come from here.

**WhatsApp / Meta's public state machine** — [Cloud API status webhook reference] — the read⇒delivered⇒sent lattice with skippable intermediates, batched read receipts as watermarks with a `<list>` of ids, and "delivered to at least one of the user's devices."

## Where this deliberately differs

**No per-recipient queue.** Signal keeps a real per-(account, device) Redis/DynamoDB queue with a 7-day TTL. Rejected: for 1:1 it costs 2× the rows, needs a TTL sweeper, and *introduces* a loss class ("the message aged out") that Postgres retention removes for free. `research/delivery.md` reaches the same conclusion: "`messages` + per-participant cursor *is* fan-out-on-read, the Telegram/Matrix model, which is cheaper than Signal's per-device queue and needs no TTL sweeper."

**No `pts_count`.** Every message advances the counter by exactly 1, because there are no grouped updates and no self-initiated RPCs that mutate the stream. This deletes the entire class of phantom gaps that gotd needs `Manager.HandleAffected` for — Telegram's documented trap where `messages.readHistory` returns `affectedMessages{pts, pts_count}` and a client that fails to apply it manufactures a gap and triggers a pointless full `getDifference`. **Load-bearing caveat**: if deletions or edits ever join the stream, they must get their own cseq and `pts_count` arithmetic must come back. Adding a stream-mutating operation without a cseq is the one change that silently breaks this design.

**Unbounded retention.** Signal 7 days, WhatsApp 30. Postgres keeps everything, so BACKFILLING is a display concern only, never data loss — a strictly better position than any of the four systems studied.

**`delivered` exists.** Matrix has no delivery receipt at all (a deliberate omission and, per the research, its biggest weakness for 1:1 UX); Telegram has none for cloud chats. Miles keeps it because the product needs it and the recipient device can write it honestly.

**Per-user, not per-device, watermarks.** The Telegram/Matrix model, where multi-device consistency is free because state is server-side per-user. Signal and WhatsApp issue per-device receipts and must aggregate with an explicit rule; here `greatest()` gives Meta's "at least one device" semantics for free and a lagging second device can never regress the tick.

**No retry-receipt channel.** WhatsApp's `retry` type means "delivered to the device, but decrypting the message failed" — transport succeeded, semantics failed. Miles has no E2EE, so there is nothing to fail. **Budgeted explicitly**: if `research/e2ee.md`'s work lands, this must be added, or you get permanent "Waiting for this message" holes that no amount of transport reliability fixes.

**One privacy divergence.** *Careless Whisper* (arXiv 2411.11194) shows delivery-receipt RTT leaks screen-on/off and foreground/background state (WhatsApp ~350ms foreground vs >1s screen-off), and that both WhatsApp and Signal emit receipts for references to messages that never existed. For an app with a deliberately disguised launcher this matters: the `least(incoming, stream.last_seq)` clamp already refuses to acknowledge a nonexistent cseq, receipts only ever reach the bound partner via RLS, and the 1s ack debounce coarsens the timing signal.

## Scale ceiling
Assumptions, stated so they can be attacked: 2 users per couple; 40 user-messages per user per day (high, this is an LDR couples app); peak concurrency 8% of registered users; billable Realtime messages = events × (recipients + 1) = 3 for a couple topic with both subscribed; ~6 billable per user-message post-design (1 message broadcast + debounced receipt + debounced typing).

**1,000 users (500 couples) — comfortable, no ceiling in sight.**
Peak concurrent 80 (Free's 200 fits, Pro's 500 is roomy). 40k messages/day, ~0.5 writes/s average. The stream lock is per couple across 500 independent rows: zero contention. Realtime 7.2M msg/mo — **this is what breaks first, and it breaks the Free tier at ~280 users** (2M ÷ 6 ÷ 40 ÷ 30). Free's 500 MB database is the other early wall: ~800k message rows at ~600 B including indexes, i.e. ~20 days of accumulation at this rate. Both are billing events, not failures.

**10,000 users (5k couples) — works, cost is the constraint.**
Peak concurrent 800, which **exceeds Pro's spend-capped 500** — the cap must be disabled to reach the 10,000 ceiling. 400k messages/day, ~5 writes/s average and maybe 50/s at peak; a Small/Medium instance is untroubled. Peak Realtime ~240 msg/s against Pro-no-cap's 2,500. 146M message rows/year: **`messages` needs HASH partitioning on `couple_id` before this point** — do it at the first migration that touches the table, because retrofitting a partition key on a live 100M-row table is the one migration in this document that is not cheap.
Failure mode if you overshoot: none in delivery. You get an invoice, not a break.

**100,000 users (50k couples) — the platform wall, and it is a hard one.**
Peak concurrent 8,000 against a 10,000 ceiling on Pro-no-cap/Team: **no headroom.** Peak ~2,400 Realtime msg/s against the 2,500/s Team ceiling: **at the wall.** Crossing either returns `too_many_connections` / `tenant_events` — connections refused and existing subscriptions silenced, not a larger bill. Sustained overage gets the project manually suspended (`RealtimeDisabledForTenant`), which requires a support ticket to lift. 4M messages/day, 1.46B rows/year — partitioning is mandatory, and the DB itself is now the second-largest line item after media.

**The failure mode at the ceiling is the point, and it is benign by construction.**
When Realtime refuses connections or silently drops frames, this architecture degrades to: catch-up query on foreground + FCM wake. **Messages still arrive. Ticks still update. Nothing is lost.** Latency goes from ~100 ms to "next foreground or next push" — minutes, not never. That is invariant 8 paying for itself. Contrast with today, where `postgres_changes` *is* a delivery path and a refused connection is a permanently lost message with no error anywhere.

Today's design, for comparison, does not reach any of these numbers. `postgres_changes` with RLS tops out at **30 changes/sec project-wide** at 500 clients, and 40/sec even on a 16XL — the poller is single-threaded and `apply_rls` loops over every subscriber to the table, project-wide, per row change. `research/supabase.md` puts the current app's whole postgres_changes path at **300–800 concurrent users**, and there is no amount of money that raises it.

**The escape hatch, and why it is cheap.** Past 100k, the hint layer is replaced — self-hosted Realtime (`MAX_CONNECTIONS=16384`/node), or SSE/long-poll from an edge function, or FCM-only with a longer foreground poll. **None of these touches the data model, the outbox, the cursor, the watermarks, or the state machine**, because the hint layer is architecturally isolated by invariant 8. That isolation is the migration insurance and is worth more than any of the throughput numbers.

**The honest non-Supabase ceiling**: the per-couple row lock. It becomes a real limit around hundreds of writes/second *into one conversation* — irrelevant for a 2-person app, and if it ever mattered the fix is Telegram's: shard the counter further.

## Cost
All figures monthly. Pro is $25 base, includes 5M Realtime messages, 500 peak connections, 250 GB egress, 100 GB storage, 8 GB disk, and a $10 compute credit. Overages: $2.50/M messages, $10 per 1,000 peak connections (whole packages), $0.09/GB uncached egress, $0.0213/GB storage.

**1,000 users**
| Line | Basis | Cost |
|---|---|---|
| Pro base | required — Free dies at ~280 users on the message quota | $25.00 |
| Realtime messages | 7.2M, 2.2M over | $5.50 |
| Peak connections | 80, under 500 | $0 |
| Compute | Micro, covered by the $10 credit | $0 |
| DB + media storage | ~9 GB DB/yr + 20 GB/mo media, mostly within included | ~$0.50 |
| Egress | 20 GB, under 250 | $0 |
| Edge functions | ~870 invocations (one OAuth mint per 50 min) | $0 |
| **Total** | | **~$31** |

**10,000 users**
| Line | Basis | Cost |
|---|---|---|
| Pro base, spend cap OFF | 800 peak > capped 500 | $25.00 |
| Realtime messages | 72M, 67M over | $167.50 |
| Peak connections | 800, 300 over → 1 package | $10.00 |
| Compute | Small–Medium, net of credit | ~$45 |
| Storage | ~2.4 TB media accumulating over yr 1 | ~$49 |
| Egress | 200 GB, under 250 | $0 |
| **Total** | | **~$297** |

**100,000 users**
| Line | Basis | Cost |
|---|---|---|
| Pro base | | $25.00 |
| Realtime messages | 720M, 715M over | $1,787.50 |
| Peak connections | 8,000, 7,500 over → 8 packages | $80.00 |
| Compute | Large–XL | ~$150 |
| Storage | ~24 TB media accumulating | ~$510 |
| Egress | 2 TB, mostly uncached private media | ~$157.50 |
| **Total** | | **~$2,710 — if the quota is granted, which on Team it is not.** |

**What the design saves versus today, in money.** `research/supabase.md` models the current app at ~18,000 billable Realtime messages/user/month. This design is ~7,200 (40 messages × 6 × 30). The reductions are all structural: delete the client-sent `msg` broadcast (the message no longer travels twice), delete the 5s `presence.chat_last_read` timer and the duplicate typing DB write, debounce receipt acks to 1/s. Realtime bill: **1k $32.50 → $5.50; 10k $437.50 → $167.50; 100k $4,487 → $1,787.** Roughly a 60% cut, entirely from removing redundant transports rather than from serving fewer users.

**Push, separately.** Today: one `pg_net` call + one edge invocation + an RSA signature + a Google OAuth exchange + 2 Supabase queries + an FCM POST **per message**. At 10k users that is 12M edge invocations/month (≈$20 plus 12M Google token-endpoint calls, and the 2s Edge CPU limit sitting in the write path). After: **one edge invocation per ~50 minutes** for the cached bearer, and pg_cron+pg_net doing the sends at ~1.7 req/s against pg_net's ~200 req/s ceiling. Edge cost goes to **$0** and, more importantly, the message write path stops making three network hops.

**Where the cost curve bends.** Below ~50k users, Realtime messages are ~85% of the bill and the only lever that matters is events-per-message. Above ~50k, **media storage overtakes it** ($510 vs $1,787 at 100k and growing monthly with nothing pruning it) — which makes a media lifecycle policy the next cost project, not a delivery one. Flagged from `inventory/chat.md`: `couple_media` is a public bucket with no TTL, flung GIFs are uploaded and never referenced by any row so nothing can ever delete them, and `chat-bg` orphans every previous upload permanently.

**The cost of the correctness machinery itself is approximately zero**: one bigint column, two unique indexes, one narrow counter table with one row per couple, one small outbox table, and one indexed range query per reconnect. The expensive parts of the systems this borrows from — per-device queues, TTL sweepers, multi-writer stream-position tracking, per-channel pts sharding, retry receipts, session repair — are all things a 1:1 non-E2EE app on Postgres genuinely does not need.

## Migration
Six stages. Each ships alone, each is revertible, none requires the other end of the wire to have shipped. There is no big bang.

**Stage 0 — server only, zero behaviour change, zero risk: the canary.**
Add a contiguity check as a view plus a `pg_cron` job:
```sql
select couple_id, count(*), min(seq), max(seq)
from messages group by couple_id
having count(*) <> max(seq) - min(seq) + 1;
```
Against the current global `seq` this is always non-empty (couples interleave) — so run the sharper form: log, per couple, the maximum observed `seq` at each poll and flag any subsequent row appearing *below* a previously-observed maximum. That is the skip, caught in production, with no phones. Also create `chat_streams` and backfill `last_seq = count(*)` per couple.
**Ship this first**, because it converts an architectural argument into a number on a dashboard.

**Stage 1 — server only, old client entirely unaffected: the contiguous sequence.**
- Add `messages.cseq bigint`, `messages.client_msg_id uuid`.
- Backfill: `cseq = row_number() over (partition by couple_id order by seq, id)`; set `chat_streams.last_seq` to each couple's max.
- Add `send_message`, `sync_messages`, `ack_delivered_cseq`, `ack_read_cseq`.
- **The trick that makes this shippable without a client release**: add a BEFORE INSERT trigger on `messages` that, for any insert not arriving through the RPC (i.e. the old client's direct PostgREST insert), takes the same `chat_streams` lock and assigns `cseq` the same way. Both paths serialize on the same row, so contiguity holds across a mixed fleet from day one.
- Add `unique (couple_id, cseq)` and `unique (couple_id, sender_id, client_msg_id) where client_msg_id is not null`.
- `seq` and `messages_seq_seq` are untouched. Old clients behave exactly as before — still broken, but no worse.
- **Verification, in production, without phones**: the stage-0 canary run against `cseq` must be permanently empty while the same canary against `seq` keeps firing. That is an A/B proof of the core claim on live traffic.

**Stage 2 — client only: the outbox and the prefix cursor.**
- Drift outbox + process-scoped drainer. Route **text first** — that alone closes `chat.send.text`, the highest-risk item in the inventory and the only send path with no failure state at all. Then media, replacing `ChatSendQueue`'s in-memory list. This also fixes the video duplicate-bubble bug for free, because the id now comes back from the server keyed on `client_msg_id` instead of being guessed twice.
- Replace `_maxSeq` with `applied_cseq`; replace `fetchSince(_maxSeq)` with paginated `sync_messages(applied_cseq)`.
- Client calls `send_message` with a `client_msg_id`, **falling back to the direct insert if the RPC is absent** — so this build works against a pre-stage-1 server during rollout.
- **Delete the client-sent `msg` broadcast.** Keep *listening* to `mood_burst` for one release so a mixed fleet keeps the fast path, but treat it strictly as a hint that triggers catch-up and never as a message. That closes the forgery hole on the receiving side immediately, one release ahead of the server work.
- Verified entirely by the pure-function property tests and the local-Postgres integration test (see `verification`). No device required.

**Stage 3 — server + client: `delivered` becomes reachable.**
- Add `delivered_cseq`/`read_cseq` columns and the clamped RPCs.
- **Move the sync worker out of `ChatScreen`** into a couple-scoped process singleton driven by app start, foreground, connectivity, and FCM wake. This is the change that makes the double-grey tick exist at all: today `ackDelivered` has one caller, inside `_catchUp`, immediately overwritten by `_ackRead`.
- Delete the 5s `_readTimer` and its `setChatLastRead` companion; `read` is written on visibility change only.
- Sender renders from the new columns, falling back to `delivered_seq`/`read_seq` while the partner is on an older build. Both are `greatest()`-monotone, so the mixed-fleet period cannot regress a tick.

**Stage 4 — server only: push becomes a coalesced watermark.**
- Trigger writes `push_outbox` instead of calling `net.http_post`. `pg_cron` drains every 5s, coalescing per recipient, suppressing where `delivered_cseq >= max cseq`, using a bearer cached in a table with its expiry.
- Independently shippable *and* independently revertible, because the client's response to a push is already "run the sync worker" — identical whether the push carries one message id or a watermark. No client change is needed for this stage at all.
- Add the dead-letter query (`push_outbox` rows undelivered past N minutes). pg_net documents no retry and garbage-collects `net._http_response` after 6 hours, so failure visibility must be owned here or it does not exist.

**Stage 5 — server only: transport hygiene and cleanup.**
- Replace `postgres_changes` on `messages` and `chat_receipts` with private Broadcast-from-database on `chat:<couple_id>`; add RLS on `realtime.messages` gating `topic` to the caller's couple via a SECURITY DEFINER helper. Then `ALTER PUBLICATION ... DROP TABLE` for both.
- Drop `messages.seq` and `messages_seq_seq` once no client reads them.
- HASH-partition `messages` on `couple_id`. **Do not defer this past 10k users** — it is the only step here that gets materially harder with data volume.

**Ordering constraint worth stating**: stages 0→1 must be in order; 2 can ship before or after 1 (the fallback handles both); 3 requires 1; 4 and 5 are independent of everything after 1. If the project stops after stage 2, the two worst bugs — silent send loss and permanent catch-up loss — are already gone.

## Verification
The reason every previous fix passed and then failed in production is precise and worth naming: **two NTP-synced phones on one wifi can produce none of the four conditions this system must survive** — reordering, commit-order inversion, packet loss, and clock skew. That setup can only ever confirm the happy path. Every check below *constructs* those conditions deterministically instead of hoping to encounter them.

**1. The ordering invariant is a plain SQL test.** Two concurrent psql sessions (or one `pgtap` script with dblink) both call `send_message` for the same couple. Assert: the transaction that commits second holds the higher `cseq`; a third session polling `where cseq > 0` never observes a hole; and the counter is not bumped when the dedup branch is taken. Runs in CI in under a second. **This is the test that would have caught the current `nextval` bug** — and it can be written today, against the current schema, where it fails.

**2. The apply state machine is a pure function, so property-test it.**
`apply(applied_cseq, staged_set, incoming) -> (applied_cseq', staged', action)` — zero I/O, zero clock, zero network. Generate the multiset `{1..N}`, then subject it to arbitrary permutation, arbitrary duplication, and arbitrary drops, and assert after every run:
- `applied_cseq'` equals exactly the length of the contiguous prefix of what was actually delivered
- no cseq is ever applied twice
- `applied_cseq'` never decreases
- for any dropped element k, `applied_cseq' < k`

A few hundred generated cases per CI run covers reordering, duplication and loss — the three things two phones on one wifi never produce. Under the current `_maxSeq` fold, the fourth assertion fails on the first generated case with a drop.

**3. A deterministic in-process fault-injection harness.** A fake transport that can drop, duplicate, reorder and delay any frame; a fake clock; the *real* sync worker and *real* outbox drainer against a real SQLite store. Each historical failure becomes a named regression test:
- "socket dies mid-catch-up, page 2 of 4"
- "FCM wake with the app process killed"
- "send times out but the server committed" (assert: exactly one row, and the client adopts the server's cseq)
- "partner acks a watermark with a hole below it" (assert: unreachable — the value cannot be produced)
- "two days offline, 900 messages, four pages"
- "duplicate broadcast of an already-applied cseq"
- "broadcast arrives before the row is visible to a follow-up read" (assert: staged, then applied on the next page)

**4. Production canary as a continuous assertion.** The stage-0 contiguity job, kept forever. If the log is contiguous by construction, it is always empty; if it is ever non-empty, the core invariant broke in production and you know within a minute, with the couple id. One indexed aggregate per run. This is the check that survives future refactors by people who have not read this document.

**5. Client-side watermark assertion in debug builds.** Before writing `delivered_cseq = X`, assert local storage contains every cseq in `[1..X]` — one `count(*)` query. Cheap enough to leave on in internal builds, and it makes the phantom-seen bug impossible to ship rather than merely unlikely.

**6. One-process, two-identity end-to-end test.** Two Supabase sessions (two JWTs) inside a single Dart test process, driving the real repository against a local `supabase start` Postgres. Covers the RPC contract, RLS, the dedup index, and watermark monotonicity — including "sender cannot write the recipient's watermark" and "ack_read cannot exceed stream.last_seq" — with **zero devices**.

**7. Load and lock verification without users.** `pgbench` with a custom script driving `send_message` across N synthetic couples. Measures the stream-lock hold time (the number that decides whether the row lock is ever a ceiling) and proves contiguity under real concurrency. Also the place to verify that removing `net.http_post` from the trigger in stage 4 measurably shortens the hold.

**What still needs a device, and what it is actually for.** Exactly two things: that Android's Doze/process-freeze wakes the FCM background isolate and that the isolate can run the sync worker; and that the local notification renders under the disguise. Both are single-device checks — put the app in the background, send from the second identity in the test harness on a laptop, observe. Neither is a correctness test of the delivery protocol, because by then the protocol has already been proven in CI.

**Flagged gap, stated plainly**: none of the tests in items 1–7 exist today. The current test surface for this domain is zero, so every number in this document about the *new* design is a design claim and not a measurement. The first deliverable of stage 0 should be item 1 written against the *current* schema, where it will fail — that failure is the cheapest possible evidence that the redesign is warranted, and it costs an afternoon.

## Rejected alternatives
**Keep the global sequence, add Synapse-style in-flight token tracking.** Synapse tracks in-flight ids per writer and publishes a position only past fully-committed ids. In an architecture where Postgres *is* the only server, there is no long-lived writer process to hold that state — you would need a table of in-flight ids written and deleted per insert, a publisher advancing a token, and a sweeper for crashed writers that abandoned an id. Three moving parts and a new failure mode (a crashed writer pins the published token forever, stalling every reader) to replicate what one row lock gives for free. **Rejected: strictly more machinery, strictly worse failure mode.**

**Timestamp cursor (`created_at > last_seen`).** This is what the app had before `receipts_v2.sql`, and that file's own header documents the two-month invisible outage it caused. Beyond the clock problem: Postgres `now()` is *transaction start* time, so two overlapping transactions can commit in the opposite order to their `created_at` — the identical skip hazard, with a device clock added. **Rejected.** Note that the current initial load still does `.order('created_at', descending).limit(300)`, so this ordering has not actually been removed from the app.

**Per-recipient server-side queue (Signal's model).** One row per (recipient, message) plus a TTL sweeper and a drain protocol. For 1:1 it doubles the row count, adds a component, and *introduces* a loss class — "the message aged out" — that Postgres retention eliminates for free. `research/delivery.md` reaches this conclusion independently. **Rejected: cost with negative benefit.**

**Broadcast Replay as the catch-up mechanism.** Private channels only, Broadcast-from-Database only, **max 25 messages per request**, 72-hour retention, public alpha. A user offline overnight in an active conversation blows past 25 immediately, and the retention bound reintroduces permanent loss. The `cseq > cursor` query has none of these limits and costs one indexed range scan. **Rejected as a correctness mechanism**; acceptable later as a latency optimisation, never as truth.

**Exactly-once delivery.** XEP-0198 states it outright: "Because unacknowledged stanzas might have been received by the other party, resending them might result in duplicates; there is no way to prevent such a result in this protocol." All four studied systems chose at-least-once plus idempotent apply. **Rejected as unachievable**, and pursuing it is how you end up with five patches instead of one mechanism.

**Per-message receipt rows.** `O(messages × participants)` rows, non-idempotent under replay, order-sensitive, and it turns a tick render into a join. Every studied system uses watermarks. **Rejected.**

**`SERIALIZABLE` isolation on send instead of an explicit row lock.** Correct, but it converts contention into serialization failures that the client must detect and retry, and PostgREST surfaces them as opaque 500s indistinguishable from a real error — so the retry logic would have to guess. The explicit `FOR UPDATE` makes the ordering property visible in the function body and directly assertable in a two-session test. **Rejected on legibility and testability**, not on correctness.

**`pg_advisory_xact_lock(couple_id)` instead of a counter row.** Identical serialization, no extra table. But the counter row also yields `stream_last_seq` for free, and that value is what makes gap detection *server-declared* rather than client-inferred and what makes the read watermark clampable against a lying client. **Rejected: same cost, strictly less capability.**

**Keeping `postgres_changes` on `messages` and just fixing the cursor.** Tempting because it is the smallest diff. But `apply_rls` loads every subscription to the table project-wide and evaluates the `couple_id=eq.X` filter *inside* the loop — the filter does not shrink the loop. That is 30 changes/sec with RLS at 500 clients, and 40/sec on a 16XL: a 1.5× return for a 370× price increase. **Rejected: it is not an axis that scales at any price**, and leaving it in means the delivery path still has a hard ceiling below 1,000 users.

**Per-device watermarks now.** Signal and WhatsApp issue per-device receipts and aggregate with an explicit rule. Miles has no device identity (Supabase Auth gives a user, not a device) and `profiles.fcm_token` is a single column, so multi-device is already broken elsewhere. With `greatest()`, a lagging second device can only fail to advance a watermark, never regress one — so per-user is safe today and matches Telegram/Matrix, where multi-device consistency is free. **Deferred, not rejected**: if multi-device ships, per-device tokens *and* per-device watermarks *and* the `max()` aggregate must land in one change, or you get flapping ticks.

## Open decisions
**1. Does the broadcast hint carry the row, or only the cseq?**
Carrying the row saves one round-trip per message; carrying `{cseq}` only makes the hint layer trivially small and provably incapable of being mistaken for truth. **Recommend: carry the row**, generated by `realtime.broadcast_changes` on a private channel. Because it is DB-generated it cannot be forged (unlike today's client-sent broadcast), and the prefix rule already makes a dropped/duplicated/reordered frame harmless. Cost moves from message count to egress, which is cheap at every scale modelled. Decide before stage 5.

**2. Per-user or per-device watermarks?**
**Recommend per-user** — the Telegram/Matrix model, where multi-device consistency is free and `greatest()` gives Meta's documented "delivered to at least one of the user's devices" semantics without an aggregate. Revisit only if multi-device ships, and then do per-device tokens, per-device watermarks, and the `max()` aggregate as one change.

**3. What is the BACKFILLING threshold, and what does the UI show?**
**Recommend 2,000 messages (10 pages).** Below it, backfill silently on open. Above it, render the newest page immediately and backfill in background with the watermark honestly lagging. This needs a product call: during backfill the *sender* sees ticks that have not caught up. That is true rather than wrong, but it will look like a bug to whoever reports it, so it needs a decision and probably a subtle UI affordance.

**4. Partitioning key for `messages`.**
**Recommend HASH on `couple_id`, 32 partitions**, decided now and applied at the first migration that touches the table. The catch-up query is `couple_id = X AND cseq > N`, which prunes perfectly on `couple_id` and not at all on time. This is the one migration in the plan that gets materially harder with data volume — deferring it past 10k users converts an afternoon into a maintenance window.

**5. Delete `presence.chat_last_read` entirely?**
**Recommend yes.** It is a second, clock-based read watermark duplicating `chat_receipts.read_cseq`, and it costs 12 writes/minute per open chat on the hottest row in the system — a row with `REPLICA IDENTITY FULL` in the realtime publication, so each write also fans a full-row WAL record (including GPS columns) to the partner. Anything reading it should read the receipt instead. Owner call because `presence` has other consumers outside this domain.

**6. What happens to the existing `mood_burst` public topic?**
Stage 2 stops sending messages on it and downgrades receiving to a hint. But it still carries typing, `cleared`, and mood/GIF bursts, and it is still public and still accepts a forged `cleared` that blanks the partner's chat view. **Recommend: move the whole topic to a private channel in the same release as stage 5**, and treat that as a security fix with its own timeline rather than a delivery concern. Flagged here because it is the one hole this design does not close on its own.

**7. Does `delete` join the cseq stream?**
Today deletes are UPDATEs (`deleted_for_everyone`) and the partner sees nothing live, because `messages` is only subscribed for INSERT and DELETE. If deletes and edits become stream events they need their own cseq — at which point `pts_count` arithmetic must return, because one RPC will advance the counter by more than one. **Recommend: yes, give them a cseq, and do it deliberately in a stage of its own.** The dangerous version is someone adding a stream-mutating operation *without* a cseq, which breaks the contiguity invariant silently. Worth a comment in the migration and a line in the canary.

**8. Retention policy.**
Unbounded retention is a feature (it deletes the "aged out" loss class that Signal and WhatsApp both accept). But it means `messages` grows forever, and at 100k users media storage becomes the largest line on the bill with nothing pruning it — plus `couple_media` is public with permanent URLs, flung GIFs are never referenced by any row so nothing *can* delete them, and `chat-bg` orphans every previous upload. **Recommend: keep unbounded retention for message rows, and open a separate media-lifecycle project.** They are different problems and conflating them is how the delivery work gets delayed.
