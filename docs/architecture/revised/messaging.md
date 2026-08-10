# messaging (revised)

## What changed vs v1
## FATAL 1 — "Process-scoped singleton with a re-entrancy guard" does not exist across Flutter isolates

**Closed, but not by the attacker's route.** The attacker's repair (background isolate becomes a doorbell only; if you ever want a background drain, use a SQLite lease on a monotonic clock) fixes the *symptom*. I close the *class* instead: **concurrent sync workers are made safe, so no mutual exclusion is needed for correctness at all.**

Two changes make concurrency harmless:
1. **Row storage is idempotent.** Received rows are inserted keyed on `(couple_id, cseq)` with insert-or-ignore. Two workers writing the same page converge; neither can corrupt the other.
2. **The cursor is not a read-modify-write.** It is a server-minted opaque *coverage token* plus its decoded `covered_through`, advanced by a single conditional update guarded by `WHERE covered_through < :new` inside the same local transaction as the rows. This is monotone and commutative. There is no "read applied, add n, write applied" sequence anywhere, so there is no lost update to lose.

Replay the attacker's exact scenario: both isolates hold token(100). Background is served 101–103 and commits {rows 101–103, token 103}. Foreground is served 101–250 and commits {rows 101–250, token 250}. In either commit order the final state is rows 101–250 and token 250 — the lower token update is rejected by its own WHERE clause, and the rows were already idempotent. The attacker's failure ("cursor at 103 with rows 104–250 stored, undetectable") is not reachable, because the cursor is never derived from an in-memory integer.

**Why it cannot regress:** the guard is gone, so it cannot be reintroduced wrongly. The only way back to the bug is to replace the conditional monotone update with an increment — which is a schema-visible change (`covered_through` would have to stop being the token's decoded value), and the ack RPC would reject the resulting token because tokens are HMAC'd server-side and cannot be computed by the client.

**Additionally**, on the platform facts (`push.md` L201: background handler gets "several seconds"; L119/L205: network access is *disabled* in the Rare and Restricted standby buckets; FlutterFire: >30 s and the process may be killed): the background isolate is budgeted to **one page with a hard deadline**, and its unconditional first action is to post the disguised notification and write a `sync_due` marker row. If the page does not complete, nothing is lost — the marker survives. **The outbox drainer never runs in the background isolate** (no reason to; server dedup would make it safe, but sending is not what a doorbell is for). Two connections to one SQLite file in WAL mode with a busy timeout; a `SQLITE_BUSY` is a no-op because the marker persists.

## FATAL 2 — `clear_conversation_everyone()` hard-deletes every row, destroying contiguity forever

**Closed by construction, two independent mechanisms, either sufficient.**

The root error in the original was that contiguity was defined **over rows present**. The receive step "assert the rows are exactly applied+1..applied+n; if not, full resync" is deleted from this design — it was the bug, and the attacker is right that it turns a hard delete into an infinite resync loop pinned to that couple.

1. **Coverage is server-declared over the issued range, never inferred from rows.** Every `sync_messages` response declares the half-open interval of *issued* cseq it covers, and the client merges **the interval**, not the cseqs of the rows it got back. A cseq that was issued and whose row has since been deleted is simply not in the page; the interval still closes. The client has no code path that computes coverage from rows, so no deletion by any mechanism — today's `clear_conversation_everyone`, tomorrow's retention job, a manual `DELETE` in the SQL editor — can produce a gap.
2. **Clear-for-everyone consumes a cseq.** It takes the same `chat_streams` row lock, allocates one cseq, writes a `clear` control row carrying `clear_through_cseq`, and then hard-deletes the message rows at or below it. This gives the partner the live "your view was blanked" signal that `chat.deletion` currently lacks, and it moves that signal off the forgeable public `mood_burst` topic (see open decision 6 in the original, now closed).

Replay the attacker's exact scenario: A clears 8,000 rows; `chat_streams.last_seq` advances to 8001 (the clear row). B, holding token(8000), syncs: server returns the clear control row and declares coverage `(8000, 8001]`. B blanks, gets token(8001). A fresh install bootstraps at the account's own `delivered_cseq` or at the head, is served whatever rows exist inside a declared interval, and closes it. **No assert, no loop, no exit-less state.**

**Why it cannot regress:** the client cannot re-derive coverage from rows because the response *contains* the interval and the row set separately, and the token — the only thing that can advance a watermark — is minted by the server against the interval, not the rows.

## FATAL 3 — The phantom-seen bug is relocated, not eliminated

The attacker is correct and the original's claim was false: `ack_read_cseq(max_observed)` was perfectly expressible, and the only guard was a debug-build assertion, i.e. correct-by-convention in a codebase where the identical convention already failed (`chat_screen.dart:344` `_messages.fold(0, (a,m) => m.seq > a ? m.seq : a)` feeding `ackDelivered(_maxSeq)` then `_ackRead()` — both verified on disk).

**Closed by making the watermark unrepresentable as a client-chosen integer.**

There is no `ack_delivered(bigint)` and no `ack_read(bigint)` in this design. There is one RPC, `ack_receipts(token, read_up_to)`, and:

- `token` is an **opaque server-minted HMAC** over `(key_version, couple_id, user_id, covered_through)`. The client cannot compute one. A tampered, foreign-couple, or foreign-user token is rejected.
- A token for `covered_through = N` is obtainable **only** by presenting a token for some `M ≤ N` and being served every row that exists in `(M, N]` in that same response. The read API is *chained*: `sync_messages(token)` returns rows starting from the token's own position and mints the next token for the position it actually reached. **There is no call that mints a token for a position without serving the complete interval up to it.** A client sitting at token(104) that receives a hint for cseq 106 cannot skip — it has no token for 106 and cannot make one.
- `delivered_cseq := greatest(existing, token.covered_through)`. No client integer participates.
- `read_up_to` is the one client integer left, and the server clamps it: `read := greatest(existing, least(read_up_to, token.covered_through))`. Because `covered_through` certifies a *completely served* interval, **there is no hole inside the range a read ack can address.** A client can under-report (harmless); it cannot report read across a gap, because the gap would place `covered_through` below it.
- The RPC also sets `delivered := greatest(delivered, read)`, preserving read⇒delivered⇒sent.

**Residual, stated plainly** (see accepted_limits): the token certifies what the *server sent*, not what the *client stored*. A client bug that drops a row out of a served page could still commit the token. This is narrowed to one code site and closed **fail-closed in release builds**: `sync_messages` returns `rows_in_range` (the server's own count of existing rows inside the declared interval) and the local transaction refuses to commit the token unless the count of stored rows in that interval matches. Refuse-and-log, not crash. That check is a client-local guard, not a server property — I say so rather than claim otherwise.

**Why it cannot regress:** removing the token would require deleting the HMAC verification from the server RPC, which is one function body under review, not a client refactor. The bug class has moved from "any integer any client passes" (unbounded, invisible) to "rows dropped inside one server-served page by one client function" (bounded, locally detectable, fail-closed).

---

## Serious flaws

**#3 — no failure exit from CATCHING_UP; no timeouts anywhere.** Closed. Every network call carries an explicit deadline (send 15 s, sync page 15 s, upload 120 s, ack 10 s) — `supabase_flutter`'s PostgREST calls have no default timeout, so a half-open socket otherwise hangs for the OS timeout. `CATCHING_UP → STALLED(backoff) → CATCHING_UP` is a first-class transition, and STALLED is surfaced in the chat header. Structurally, the wedge class is gone anyway: concurrent syncs are now safe, so the coalescing flag is advisory and self-clearing on deadline — **there is no guard whose failure can permanently reject a trigger.**

**#4 — newly-paired couple has no `chat_streams` row; both NULL exit conditions wedge.** Closed server-side, by construction, not by remembering to edit four call sites. There are **four** places that insert into `couples` (`schema.sql:320`, `pairing_invites.sql:38`, `newuser_fixes.sql:64`, `hardening_2026_08.sql:111`), so a per-call-site fix would rot. An `AFTER INSERT ON couples` trigger creates the stream row; `send_message` and the clear RPC upsert defensively before locking; and `sync_messages`/`sync_bootstrap` read `coalesce(last_seq, 0)` through a left join so **NULL is not representable in the response**. A zero-message couple is a named CI test.

**#5 — `outbox.next_attempt_at` is a device wall clock, contradicting the design's own clock invariant.** Closed by deleting the timestamp. Persisted outbox state is `attempts` only. Scheduling is in-memory against a monotonic `Stopwatch` from process start. Every row is **immediately due after a process restart**, and `attempts` still throttles the first post-restart attempt (`min(30 s, 1 s · 2^attempts)` with full jitter). The drainer's predicate contains no timestamp on either side, literally. A NITZ time jump, a timezone crossing, or a MIUI clock correction cannot park the outbox.

**#6 — reinstall pins delivered/read at the pre-reinstall value until a full backfill closes.** Closed by splitting the watermark base from the history base **and by putting the split on the server**. `sync_bootstrap()` reads the account's own existing `delivered_cseq` (server-side, survives the reinstall) and:
- if `stream_last_seq − delivered_cseq ≤ 2,000`, it mints a token at `delivered_cseq` and the ordinary chained sync runs forward. **No skip, no lie, fully paginated.**
- otherwise (Telegram `differenceTooLong`), the server sets `install_floor = stream_last_seq − page_size`, **itself advances `delivered_cseq` to `install_floor` and logs the decision**, and mints a token at `install_floor`. The skip is a recorded server decision, not a client claim.

Everything below `install_floor` is fetched by `fetch_history(before_cseq, limit)`, which **mints no token** — so backfill is structurally incapable of touching a watermark, and the sender's ticks track the live conversation from the first sync. Notification posting is gated on `cseq > install_floor` AND `cseq > session_start_watermark`, and capped at 5 per sync with a collapsed summary above that, so the thousands-of-notifications storm cannot occur.

**#7 — cost model ~2× optimistic; 100k ceiling wrong.** Accepted and corrected. The ceiling is restated as **50,000 users**. Billing is recomputed with the documented rule (`events × (recipients + 1)`) applied to *every* broadcast event. Additionally, the topology is changed: **two private per-recipient topics per couple** (`chat:<couple_id>:<recipient_uid>`) instead of one shared couple topic, so each broadcast has exactly one subscriber and bills **2, not 3** — a flat 33 % cut that `research/supabase.md` L285 names explicitly. Delivered and read are coalesced into one `ack_receipts` RPC and **one** broadcast event. DB disk, provisioned IOPS, `push_pending` sizing, and prune jobs for `net._http_response` and `cron.job_run_details` are added to the cost model.

**#8 — pg_net's ~200 req/s bound evaluated at daily mean, not evening peak.** Closed. The cron drain has a **hard budget of 300 rows per 5 s tick (60 req/s)** with carry-forward ordered by enqueue tick, so pg_net is never presented with a burst regardless of backlog size. Volume is modelled at peak, not mean. Above ~10k users the sender becomes **one Edge Function invocation per tick carrying a batch**, holding the cached bearer and issuing FCM calls with its own concurrency limit. The benign-degradation story is corrected: at the ceiling Realtime and push degrade *together*, so the honest fallback is foreground catch-up — minutes to hours, not ~100 ms.

**#9 — no collapse key, no TTL, suppression races the recipient.** Closed with the numbers stated. One collapse key per couple, `m:<couple_id>`; the device's 4-key budget is allocated `m:` / `c:` (call) / `r:` (reach+care), leaving one spare. TTL 24 h (data-only; a `notification` payload is never used — it would ignore `collapse_key`, render FCM's own text, and break the disguise). The 20-burst / 1-per-3-min collapsible throttle is accepted and its worst case stated. Suppression is de-raced two ways: a **one-tick grace** (a row is eligible on its second tick, giving a connected recipient 5 s to ack), and a re-check immediately before send. Priority is `high` only when `chat_receipts.last_ack_tick < current_tick − 3` — a **server-side tick counter**, no device clock — so a foregrounded recipient on the Home tab stops generating notification-less high-priority pushes, which is the documented trigger for `priorityLowered` and would otherwise degrade the call path's ring.

**#10 — stage 2 was a chat-client rewrite with a non-clean rollback.** Closed by splitting it into four independently shippable releases in the order the attacker proposed, and by verifying the rollback claim rather than asserting it: `_maxSeq` is computed **in memory** from `_messages` (`chat_screen.dart:343-344`), so the old build persists no cursor state. Rolling back the token-cursor client returns to the pre-existing bug and creates no new one. The one genuine rollback hazard is the local Drift file; policy is stated (open decision 10).

**#11 — partitioning contradiction; the irreversible step scheduled last.** Closed. Partitioning moves into **stage 1** and the contradicting sentence in the old stage 5 is deleted. This is cheap *now* — the production dataset is one couple — and the plan states the threshold past which it stops being cheap and needs a sized window.

**#12 — stage 1's backfill races live inserts and can mint permanently invisible NULL-cseq rows.** Closed by eliminating the window instead of narrowing it: the partition creation, the cseq backfill, the `chat_streams` seeding and the table swap happen in **one transaction holding ACCESS EXCLUSIVE on `messages`**. There is no interval in which a live insert can land without a cseq. This is only available while the table is small — the plan says so, sizes it, and gives the trigger-first-with-offset fallback for the large-table case (safe here because contiguity is over the *issued* range, so a one-time offset is harmless by construction). `cseq IS NOT NULL` becomes a table constraint at the end of stage 1 and a canary predicate.

**#13 — stage 3 increased `chat_receipts` write volume while it was still on the 30-changes/s postgres_changes poller.** Closed by reordering: the transport swap for `chat_receipts` and `messages` (stage 4) is a **hard prerequisite** of the receipts work (stage 6), stated as an ordering constraint, not a suggestion. Delivered and read are coalesced into one RPC and one broadcast, halving the event count regardless.

**#14 (minor) — orphaned media when a send is discarded.** Closed. The uploaded remote path is recorded on the outbox row; discarding a `BLOCKED` row deletes the storage object in the same operation. Uploads go to a path derived from `client_msg_id`, so a server-side sweeper can also find objects with no referencing row.

**#15 — three verification holes mapping onto the three fatal findings.** Closed. (a) There is no integer to pass to the ack, so "test that the right integer is passed" is replaced by type-level impossibility plus server-side HMAC rejection tests. (b) The `CATCHING_UP → STALLED` test is written first and must fail until the transition exists. (c) The two-isolate race is tested **in CI without a device**: two Dart isolates against one SQLite file with arbitrary interleaving, asserting rows-union and token-max. The one-device check remains only for platform plumbing (Doze wake, disguised notification), which is not a protocol test.

## Target architecture
## Messaging — target architecture (revised, self-contained)

### The two mechanisms

Everything below follows from two server-side facts.

**Mechanism A — a per-couple, contiguous, commit-ordered log, assigned under a row lock held to COMMIT.**
A narrow table `chat_streams(couple_id primary key → couples, last_seq bigint not null default 0)`, **not** in the realtime publication. Every operation that appends to a couple's stream begins by taking an exclusive row lock on that couple's row and holds it until COMMIT. Therefore, for a given couple, **cseq order is commit order**: a reader that observes cseq N is guaranteed every cseq ≤ N is already visible. This is exactly the property a Postgres sequence cannot give — `nextval` is non-transactional, and `receipts_v2.sql:30-31` uses **one global sequence for the whole project**, so 105 can and does become visible before 104 commits. Synapse builds in-flight-token tracking to emulate this; here the lock *is* the serialization, at the cost of one row lock on a table with one writer per couple.

**Mechanism B — the read cursor is a server-minted, chained coverage token, not a client integer.**
A client cannot name its own position. It presents the token it holds; the server serves everything from that position forward and mints the next token for the position it actually reached. Watermarks are advanced *from the token*, never from a number the client chose. This is what makes the phantom-seen bug unrepresentable rather than merely discouraged.

### Data model (shapes, not DDL)

**`messages`** — hash-partitioned on `couple_id`, 32 partitions.
`id` (uuid, pk) · `couple_id` · `sender_id` · `client_msg_id` (uuid, minted by the sender before its first network attempt) · `cseq` (bigint, not null, per-couple, dense from 1 over *issued* values) · `kind` (`text` | `image` | `video` | `voice` | `clear`) · `body` · `media_path` · `reply_to_client_id` · `created_at` (**display only — never compared, never ordered on, never an inequality operand**) · the existing `deleted_for_sender` / `deleted_for_everyone` / `deleted_by` columns.
Uniqueness: `(couple_id, cseq)`; `(couple_id, sender_id, client_msg_id)` where `client_msg_id` is not null. Index: `(couple_id, cseq)` — the only hot read path, and it prunes perfectly on the partition key.

**`chat_streams`** — as above. One row per couple, created by an `AFTER INSERT ON couples` trigger so all four existing couple-creation sites are covered by construction.

**`chat_receipts`** — `(couple_id, user_id)` pk · `delivered_cseq` · `read_cseq` · `last_ack_tick` (bigint, the server's own push-tick counter at the last ack — used for push priority, contains no device clock).

**`push_pending`** — `(couple_id, recipient_id)` pk · `max_cseq` · `first_tick` · `attempts`. **Keyed by recipient, not by message**, upserted with `greatest()`. Its size is bounded by the number of couples with an undelivered watermark, so it needs no retention policy and cannot grow with message volume. This is a deliberate change from a per-message outbox.

**`push_ticks`** — a single counter row advanced by the cron job. The only "time" anywhere in the push path.

**Client-local (Drift/SQLite), owned by no screen:**
- `messages` mirror, keyed `(couple_id, cseq)` for received rows and by `client_msg_id` for not-yet-committed sends.
- `chat_cursor(couple_id pk, token blob, covered_through bigint, install_floor bigint, held_ranges)` — `held_ranges` is a small interval set over issued cseq, maintained by merge on insert, used for display gap-marking and for the fail-closed count check. **The variable `max(received_seq)` does not exist anywhere in the client.**
- `outbox(client_msg_id pk, couple_id, kind, body, media_local_path, media_remote_path, state, attempts, reply_to_client_id)` — **no timestamp column of any kind.**
- `sync_due(couple_id pk)` — the marker the FCM background isolate writes.

`messages.seq` and `messages_seq_seq` survive migration untouched and are dropped only in the last stage.

### Server operations (all SECURITY DEFINER, all resolving the couple from `(select auth.uid())`)

**`send_message(client_msg_id, kind, body, media_path, reply_to_client_id) → (id, cseq, created_at, deduped)`** — one transaction:
1. upsert the `chat_streams` row (no-op in the normal case), then lock it FOR UPDATE — **the lock comes first, before anything else**;
2. look up `(couple_id, sender_id, client_msg_id)`; if found, return the original `{id, cseq, deduped: true}` and commit **without bumping the counter**;
3. otherwise bump `last_seq`, insert the message with that cseq, upsert `push_pending` for the partner with `max_cseq = greatest(...)`;
4. return `{id, cseq, deduped: false}`.

Because the lock precedes the dedup check, a concurrent duplicate cannot burn a counter value. Holes in the *issued* range are impossible, not unlikely. This is Matrix's txnId rule — a retransmission returns the original response — and Telegram's `random_id`.

**`clear_conversation_everyone()`** — takes the same lock, allocates one cseq for a `kind='clear'` control row carrying `clear_through_cseq`, then hard-deletes the message rows at or below it. Privacy is preserved (content genuinely leaves the database); the log stays meaningful; and the partner gets a live, authenticated signal instead of a forgeable public broadcast.

**`sync_bootstrap() → (rows, covered_from, covered_through, rows_in_range, stream_last_seq, token, install_floor)`** — the only call that mints a token without presenting one. It reads the account's own `delivered_cseq`:
- if `stream_last_seq − delivered_cseq ≤ 2,000`: mints a token at `delivered_cseq` with an empty page. Ordinary chained sync then runs forward, paginated. No skip.
- otherwise: sets `install_floor = stream_last_seq − page_size`, **advances `delivered_cseq` to `install_floor` itself and logs the decision**, returns the newest page and mints a token at `stream_last_seq`.

**`sync_messages(token, limit) → (rows, covered_from, covered_through, rows_in_range, stream_last_seq, next_token)`** — verifies the token's HMAC and its `(couple_id, user_id)` binding; returns rows with `couple_id = C AND cseq > token.covered_through ORDER BY cseq LIMIT n`; declares `covered_from = token.covered_through`, `covered_through = ` the highest cseq it actually scanned to (the page's last row, or `stream_last_seq` if the page is short); returns `rows_in_range` (the count of rows that exist in that interval) and mints `next_token`. `has_more` is `stream_last_seq > covered_through` — a **server fact**, never `count == limit` guesswork.

**`fetch_history(before_cseq, limit) → rows`** — descending, display-only. **Mints no token.** This is the structural reason backfill cannot move a watermark.

**`ack_receipts(token, read_up_to) → (delivered_cseq, read_cseq)`** — verifies the token, then:
`delivered := greatest(delivered, token.covered_through)`;
`read := greatest(read, least(read_up_to, token.covered_through))`;
`delivered := greatest(delivered, read)`;
`last_ack_tick := current_tick`;
then emits **one** broadcast to the partner's private topic with `{delivered_cseq, read_cseq}`.

**Coverage token format:** `(key_version, couple_id, user_id, covered_through)` plus an HMAC over those fields using a server-held key (pgcrypto, key in a table readable only by these SECURITY DEFINER functions). Stateless — no storage, no pruning, O(1) to mint and verify. Not single-use: a client that crashes and re-presents an old token simply gets re-served, which is safe and idempotent. No expiry: the values it carries are monotone and `greatest()` handles ordering.

### Transport, in three strictly ranked layers

1. **Truth** — the `messages` table, read only through `sync_bootstrap` / `sync_messages` / `fetch_history`. The only thing that may be believed, and the only thing that can mint a token.
2. **Hint** — private Broadcast-from-Database on **two per-recipient topics per couple**, `chat:<couple_id>:<recipient_uid>`, fired by an AFTER INSERT trigger. Payload is `{cseq}` only — never the row. RLS on `realtime.messages` gates SELECT to `topic = 'chat:' || <caller's couple> || ':' || auth.uid()` via a SECURITY DEFINER helper (the documented 11,000 ms → 7 ms join-avoidance pattern), and gates client INSERT (typing) to the *partner's* topic only. Because the topic has exactly one subscriber, a broadcast bills 2 rather than 3. Because it is DB-generated on a private channel it cannot be forged, unlike today's client-sent `msg` on the public `mood_burst:<coupleId>` topic. `realtime.send` catches its own exceptions via `pg_notify`, so a Realtime failure can never roll back a send.
3. **Wake-up** — FCM data-only push, collapse key `m:<couple_id>`, TTL 24 h, payload `{type: 'message', couple_id}`. Never a body, never a sender name, never a `notification` block.

**No layer above (1) may advance any cursor or watermark.** Layers 2 and 3 can only *trigger a read of* layer 1. A dropped, duplicated, reordered, delayed or forged frame is therefore a latency event and never a correctness event.

The public `mood_burst:<coupleId>` topic — which today carries message bodies with no membership or sender check, and accepts a forged `cleared` that blanks the partner's chat — is retired onto these private topics. Typing rides the same private topic as client broadcast, throttled to ≤ 1 per 2 s and only on transitions; it is never a DB write.

### Client: the outbox

A Drift table owned by no screen, drained by a **main-isolate-only** drainer. It wakes on app start, connectivity regained, foreground, enqueue, and a monotonic timer while any row is due. Never "while ChatScreen is mounted" — today `app_shell.dart:240` renders the chat body in a bare `Expanded`, not an `IndexedStack`, so switching tabs disposes the screen and takes catch-up, receipts and the pending send list with it.

Backoff is `min(30 s, 1 s · 2^attempts)` with full jitter, measured on a `Stopwatch` from process start. `attempts` is the only persisted scheduling state; every row is immediately due after a restart. There is no timestamp in the drainer's predicate.

Correctness across concurrent drainers is not the drainer's problem: `unique(couple_id, sender_id, client_msg_id)` makes a duplicate send a server-side no-op that returns the original row.

### Client: the cursor

Per couple: the opaque `token`, its decoded `covered_through`, an `install_floor`, and a `held_ranges` interval set. The apply rule is:

- A page arrives with `(rows, covered_from, covered_through, rows_in_range)`.
- **One local transaction**: insert-or-ignore each row keyed `(couple_id, cseq)`; merge the interval `(covered_from, covered_through]` into `held_ranges`; verify the count of stored rows inside that interval equals `rows_in_range` — **if it does not, abort the transaction and log; the token is not committed and no watermark can advance**; otherwise update the cursor with `WHERE covered_through < :new`.
- A hint frame carrying a cseq above `covered_through` triggers a sync. It is never applied and never staged as truth. There is no staging buffer, because there is nothing a hint can contribute.

`held_ranges` exists for display (rendering a "loading older messages" affordance) and for the count check. It is not the watermark; the token is.

### Push, rebuilt

The message trigger writes a `push_pending` upsert — a plain statement, no HTTP in the write path, which also shortens the stream-lock hold. Today's path does an RSA sign plus a Google OAuth exchange plus an FCM POST **per message**, three sequential outbound hops inside the write path, with no token cache and no suppression.

A `pg_cron` job every 5 s:
1. advances `push_ticks`;
2. selects at most **300** rows where `max_cseq > (recipient's delivered_cseq)` and `first_tick ≤ current_tick − 1` (the one-tick grace that de-races a connected recipient's ack), oldest first, carrying the rest forward;
3. re-checks suppression immediately before sending;
4. sets priority `high` only when `last_ack_tick < current_tick − 3`, otherwise `normal`;
5. sends via `pg_net` below ~10k users (300 rows / 5 s = 60 req/s, comfortably under pg_net's documented ~200 req/s), or via **one Edge Function invocation per tick carrying the batch** above it;
6. uses an OAuth bearer cached in a table with its expiry, refreshed by roughly one edge invocation per 50 minutes.

Failure is visible: rows persist with attempt counts, and "pending past N ticks" is a one-line dead-letter query. `pg_net` documents no retry and garbage-collects `net._http_response` after 6 hours, so this must be owned or it does not exist. Prune jobs for `net._http_response` and `cron.job_run_details` ship with it.

**Disguise:** the payload is data-only and carries no sender name, no body, and no message id. The background isolate posts through the existing `currentNotificationStyle()` path so the notification wears the active disguise (the launcher is an activity-alias named "News"; a care reminder once leaked as a "News update" and that regression must not return). A `notification` payload is never used — it would render FCM's own text, bypass the disguise, and be ignored by `collapse_key` anyway.

### Sequence: send

1. Client mints `client_msg_id`.
2. **One local transaction**: insert the local message row (`cseq` null) plus the outbox row (`QUEUED`). Commit.
3. Only then does the UI render the bubble. This ordering is what makes "on screen but never sent" impossible — today `chat_screen.dart:125-129` swallows the insert failure with a bare `catch (_)`, leaving a bubble that looks sent forever and is gone on restart.
4. Drainer: if media, upload, write `media_remote_path` back to the outbox row, commit locally. A retry after this point does not re-upload.
5. Drainer calls `send_message` with a 15 s deadline.
6. Server: upsert stream row → lock → dedup → bump → insert → `push_pending` upsert → commit.
7. On **any** successful return including `deduped: true`: one local transaction writes the server id and cseq into the message row and deletes the outbox row.
8. Commit fires the hint to the partner's topic. The sender ignores its own cseq; a later sync re-serves its own row and insert-or-ignore absorbs it.
9. The cron drains `push_pending` on the next tick.

### Sequence: receive

1. Any trigger (app start, foreground, connectivity, socket open, hint frame, `sync_due` marker, 60 s timer, `onDeletedMessages`) invokes the couple's sync worker.
2. Read the token. If absent → `sync_bootstrap`.
3. `sync_messages(token, 200)` with a 15 s deadline.
4. Apply the page per the cursor rule above (idempotent rows, interval merge, count check, monotone token update) in one local transaction.
5. If `stream_last_seq > covered_through` → go to 3.
6. Caught up: call `ack_receipts(token, read_up_to)` once, debounced to ≤ 1/s per couple. `read_up_to` is the newest cseq actually on screen while the chat is visible and pinned to the bottom; otherwise it is the previous read value.
7. Post local notifications for anything with `cseq > install_floor` and `cseq > session_start_watermark`, capped at 5 with a collapsed summary above that.

**Local commit strictly precedes the ack, always** — the client-side mirror of Signal's rule that only a 2xx authorises removal from the queue.

### State machines

**Outbox (per message, client-local, persisted):**

| From | To | Trigger |
|---|---|---|
| — | QUEUED | user sends; outbox row + local message row committed atomically |
| QUEUED | UPLOADING | drainer picks it up and the kind has a local file |
| UPLOADING | QUEUED | upload error or deadline → `attempts++`, monotonic backoff |
| UPLOADING | INFLIGHT | upload succeeded, remote path persisted |
| QUEUED | INFLIGHT | drainer picks up a text message |
| INFLIGHT | COMMITTED | `send_message` returned, including `deduped: true` |
| INFLIGHT | QUEUED | timeout / socket error / 5xx / 429 → backoff. `client_msg_id` unchanged, so the retry is byte-identical |
| INFLIGHT | BLOCKED | deterministic 4xx (RLS denial, unpaired, rejected payload) |
| BLOCKED | QUEUED | user taps retry |
| BLOCKED | discarded | user dismisses → **the uploaded storage object is deleted in the same operation** |

No transition changes `client_msg_id`. No network error is ever terminal. Retry is forever.

**Sync worker (per couple, client):**

| From | To | Trigger |
|---|---|---|
| IDLE | BOOTSTRAPPING | no token |
| BOOTSTRAPPING | CATCHING_UP | token minted |
| BOOTSTRAPPING | STALLED | error or deadline |
| CAUGHT_UP | CATCHING_UP | app start / foreground / connectivity / socket open / hint frame / `sync_due` / 60 s timer / `onDeletedMessages` |
| CATCHING_UP | CATCHING_UP | `stream_last_seq > covered_through` → next page |
| CATCHING_UP | CAUGHT_UP | `stream_last_seq == covered_through` → **then and only then** call `ack_receipts` |
| CATCHING_UP | **STALLED(backoff)** | **network error, deadline, or a failed count check** |
| STALLED | CATCHING_UP | backoff elapsed (monotonic) or any trigger |
| any | BACKFILLING | user scrolls below `install_floor` — runs `fetch_history`, mints no token, cannot touch a watermark |

STALLED is surfaced in the chat header. Display order and the watermark are decoupled: the UI shows anything it holds; the watermark is strictly the certified coverage.

**Tick (per message, sender's screen) — not stored; a pure function of three integers.** For message cseq `S` and the partner's `(D, R)`:
`S is null` → PENDING · `S > D` → SENT · `D ≥ S > R` → DELIVERED · `R ≥ S` → SEEN.
Transitions occur only when D or R change, which happens only when the recipient's device acks. No timer, no timeout, no client-side latch, no per-message row. SENT → SEEN directly is legal and correct — Meta documents exactly this ("the delivered webhook is not sent because it's implied"). Today the double-grey tick is unreachable by any code path: `ackDelivered` has one caller (`chat_screen.dart:379`) and the very next line calls `_ackRead()` with the same value, and `ack_read` advances both columns.

### The two-day-offline guarantee, as a chain of custody

1. The outbox row commits to SQLite before the UI acknowledges the user → survives app kill.
2. The drainer retries forever with monotonic backoff; every retry is idempotent on `client_msg_id`.
3. Once `send_message` returns, the row is in Postgres with a cseq. **Postgres retention is unbounded** — no TTL, unlike Signal's 7 days or WhatsApp's 30. The message cannot expire.
4. The recipient's token is persisted and behind. Any of eight triggers resumes the chain from exactly where it stopped.
5. Catch-up is paginated until `stream_last_seq`. Because cseq is contiguous over the issued range and commit-ordered, and because the token can only advance over completely-served intervals, the missing set is returned exactly, in order, with no possibility of a skip.

None of this requires both users online, the same network, a foregrounded app, a correct device clock, or a reliable socket. The honest limit: if the recipient never opens the app again, nothing arrives, and in the Rare/Restricted standby buckets a woken process has no network at all. FCM is an accelerator, not the guarantee.

### Where this deliberately differs from the top tier

**No per-recipient server queue** (Signal's model). For 1:1 it doubles rows, needs a TTL sweeper, and *introduces* a loss class ("aged out") that unbounded Postgres retention removes for free.

**No `pts_count`.** Every stream-mutating operation — send, and now clear — advances the counter by exactly 1. This deletes the phantom-gap class that gotd needs `Manager.HandleAffected` for. **Load-bearing:** any future operation that mutates the stream must consume exactly one cseq, or `pts_count` arithmetic has to come back. This is the single change that would silently break the design, and it is a line in the canary.

**`delivered` exists.** Matrix has no delivery receipt; Telegram has none for cloud chats. The product needs it and the recipient device can write it honestly.

**Per-user, not per-device, watermarks.** Supabase Auth gives a user, not a device, and `profiles.fcm_token` is a single column, so multi-device is already broken elsewhere. With `greatest()`, a lagging second device can only fail to advance a watermark, never regress one.

**No retry receipt.** WhatsApp's `retry` means "delivered but decryption failed." There is no E2EE here, so there is nothing to fail. **Budgeted:** if `research/e2ee.md`'s work lands, this must be added, or you get permanent "Waiting for this message" holes that no transport reliability fixes.

**Privacy divergence.** *Careless Whisper* (arXiv 2411.11194) shows delivery-receipt RTT leaks screen-on/off and foreground state, and that WhatsApp and Signal both emit receipts for references to messages that never existed. For an app with a deliberately disguised launcher this matters: the token clamp structurally refuses to acknowledge a cseq the server never served, receipts reach only the bound partner via RLS, and the 1 s ack debounce coarsens the timing signal.

### Rejected alternatives

**Keep the global sequence, add Synapse-style in-flight token tracking.** Postgres is the only server; there is no long-lived writer process to hold that state. You would need an in-flight-id table, a publisher advancing a token, and a sweeper for crashed writers — three moving parts and a new failure mode (a crashed writer pins the published token forever, stalling every reader) to replicate what one row lock gives free. Strictly more machinery, strictly worse failure mode.

**Timestamp cursor.** This is what the app had before `receipts_v2.sql`, whose own header documents the two-month invisible outage it caused. `now()` is *transaction start* time and identical for every statement in a transaction, so two overlapping transactions commit in the opposite order to their `created_at`. Rejected. (Note the current initial load still does `.order('created_at', descending).limit(300)` — this ordering has not actually been removed from the app.)

**Broadcast Replay as catch-up.** Private channels only, **max 25 messages per request**, 72-hour retention, public alpha. A user offline overnight blows past 25 immediately and the retention bound reintroduces permanent loss. Acceptable later as a latency optimisation, never as truth.

**Exactly-once delivery.** XEP-0198 states it outright: resending unacknowledged stanzas may duplicate and "there is no way to prevent such a result." All four studied systems chose at-least-once plus idempotent apply.

**Per-message receipt rows.** O(messages × participants), non-idempotent under replay, turns a tick render into a join.

**`SERIALIZABLE` on send instead of an explicit row lock.** Correct, but it converts contention into serialization failures that PostgREST surfaces as opaque 500s indistinguishable from real errors, so the retry logic would have to guess.

**`pg_advisory_xact_lock(couple_id)` instead of a counter row.** Identical serialization, no extra table — but the counter row also yields `stream_last_seq`, which is what makes gap detection server-declared and the read watermark clampable. Same cost, strictly less capability.

**Keeping `postgres_changes` on `messages` and just fixing the cursor.** `apply_rls` loads every subscription to the table project-wide and evaluates the filter *inside* the loop, so the filter does not shrink the loop: 30 changes/s with RLS at 500 clients, 40/s even on a 16XL. Not an axis that scales at any price.

**A cross-isolate SQLite lease as the fix for the background-isolate race.** Correct, but it requires a process-shared monotonic clock (an `elapsedRealtime` platform call from an isolate that cannot host a platform listener), and it makes correctness depend on a lease being taken rather than on the data being safe. Making the writes idempotent and the cursor monotone is strictly stronger and removes the need for the lease entirely.

**Carrying the row in the hint payload.** Saves one round-trip, but the row cannot advance the cursor without a token, so the client must call `sync_messages` anyway. Carrying the row would create two render paths and a divergence risk for no structural gain. Rejected as the default; available later as a pure latency optimisation that changes no invariant.

## Invariants
- ORDERING (SERVER-ENFORCED). Every cseq is assigned only while holding an exclusive row lock on that couple's chat_streams row, taken before the dedup check and held to COMMIT. Therefore commit order equals cseq order per couple, and a reader observing cseq N is guaranteed every issued cseq below N is already visible. This is the property messages.seq cannot have: receipts_v2.sql:30-31 uses ONE GLOBAL non-transactional sequence, so 105 can become visible before 104 commits. The lock IS the serialization; no in-flight token tracking is needed.
- ISSUED-RANGE CONTIGUITY, NOT ROW CONTIGUITY (SERVER-ENFORCED + BY CONSTRUCTION). Contiguity is a property of the ISSUED cseq range (chat_streams.last_seq), never of the rows physically present. The counter is bumped only after the dedup check passes under the lock, and unique(couple_id, cseq) makes a duplicate impossible. Rows may leave the table at any time — clear_conversation_everyone() hard-DELETEs every row for a couple today (clear_chat_everyone.sql L22-23) — and this cannot create a gap, because no component anywhere derives coverage from rows.
- COVERAGE IS SERVER-DECLARED (SERVER-ENFORCED). Every sync response declares the half-open interval of issued cseq it covers, plus the count of rows that exist inside it. The client merges the INTERVAL, not the cseqs of the rows. has_more is stream_last_seq > covered_through — a server fact, never 'count == limit' guesswork. There is no client code path that infers whether it missed something.
- THE CURSOR IS NOT A CLIENT INTEGER (SERVER-ENFORCED). The read position is an opaque HMAC token over (key_version, couple_id, user_id, covered_through), minted only by the server. A token for position N is obtainable ONLY by presenting a token for some M <= N and being served every existing row in (M, N] in that same response. No API mints a token for a position without serving the complete interval up to it. A client holding token(104) that sees a hint for 106 cannot skip: it has no token for 106 and cannot compute one. This is the direct replacement for chat_screen.dart:344's `_messages.fold(0, (a,m) => m.seq > a ? m.seq : a)`.
- WATERMARK SOUNDNESS (SERVER-ENFORCED). delivered_cseq := greatest(existing, token.covered_through) — no client integer participates. read_cseq := greatest(existing, least(read_up_to, token.covered_through)) — the only client integer is clamped to a server-certified completely-served interval, inside which no hole can exist by the previous invariant. ack_read(max_observed) is not expressible: there is no bigint parameter that names a position. A late, replayed or reordered ack is a no-op.
- CURSOR ADVANCE IS MONOTONE AND COMMUTATIVE (BY CONSTRUCTION). Received rows are inserted idempotently keyed (couple_id, cseq); the cursor is advanced by a single conditional update guarded by 'covered_through < :new', both in one local SQLite transaction. There is no read-modify-write anywhere, so two concurrent sync workers — including the FCM background isolate, which has separate globals and cannot see any in-memory guard (verified at reach_notifications.dart:227-295) — converge to rows-union and token-max in any interleaving. Concurrency safety does not depend on a lease, a flag, or a singleton.
- FAIL-CLOSED LOCAL COVERAGE CHECK (CLIENT-LOCAL, RELEASE BUILDS, FAIL-CLOSED — NOT A SERVER PROPERTY). The local transaction refuses to commit the token unless the count of stored rows inside the declared interval equals the server's rows_in_range. A page the client failed to store cannot advance any watermark. Stated as a client guard because the server cannot verify what a client stored — nothing can.
- ATOMICITY OF THE CURSOR (CLIENT-LOCAL, BY CONSTRUCTION). The token, the interval merge, and the rows it covers are written in one local SQLite transaction. A crash between them is impossible, so the client can never hold a token for data it did not store.
- IDENTITY (SERVER-ENFORCED). client_msg_id is minted before the first network attempt and committed to local SQLite before the UI acknowledges the user. Every retry is byte-identical, and unique(couple_id, sender_id, client_msg_id) makes a retry a server-side no-op returning the ORIGINAL row. A timeout is therefore never ambiguous, and the retry path needs no logic the first-attempt path lacks. Concurrent outbox drainers in different isolates are safe for the same reason.
- ACK ORDERING (CLIENT-LOCAL). The local commit strictly precedes the ack. The client acks only what is durably in its own storage, never what merely arrived on a wire. (Signal's mirror image: only a 2xx on the message PUT triggers acknowledgeMessage.)
- TRANSPORT SUBORDINATION (BY CONSTRUCTION). Only sync_bootstrap and sync_messages mint tokens, and only a token can move a watermark. Broadcast hints and FCM pushes carry no token and can therefore only TRIGGER a read. fetch_history mints no token, so history backfill is structurally incapable of touching a watermark. A dropped, duplicated, reordered, delayed or forged frame is a latency event and never a correctness event — which is what makes it safe to run notification over Supabase Realtime, a transport with documented zero delivery guarantees.
- NO STATE MACHINE HAS AN EXIT-LESS STATE (BY CONSTRUCTION). Every network call carries an explicit deadline (supabase_flutter's PostgREST calls have no default timeout, so a half-open socket otherwise hangs for the OS timeout). CATCHING_UP has an explicit failure transition to STALLED(backoff) and back. No guard exists whose failure can permanently reject a trigger, because concurrent syncs are safe and the coalescing flag self-clears on deadline. sync responses return coalesce(last_seq, 0), so a NULL comparison cannot wedge a newly-paired couple, and an AFTER INSERT ON couples trigger creates the stream row across all four couple-creation sites.
- CLOCKS ARE PAYLOAD, NEVER CONTROL (BY CONSTRUCTION). created_at is rendered and never compared. The outbox persists 'attempts' and no timestamp; retry scheduling is in-memory against a monotonic Stopwatch from process start, so every row is immediately due after a restart and a NITZ jump or timezone crossing cannot park the queue. Push priority and the suppression grace are computed from a server-side tick counter, not a device clock. There is no inequality anywhere in the delivery path with a device timestamp on either side. Postgres now() is transaction-start time and is not monotonic across overlapping transactions, so it is not used for ordering either.
- OWNERSHIP (SERVER-ENFORCED VIA RLS). 'sent' is a server fact (a row exists with a cseq). 'delivered' is written only from the recipient's own token. 'read' is written only on actual widget visibility and only by the recipient. A token is bound to (couple_id, user_id) by its HMAC, so a sender cannot write the peer's watermark even by replaying a captured token. No server ever infers 'read'.
- STATE LATTICE WITH SKIPPING (SERVER-ENFORCED). read implies delivered implies sent, enforced inside the single ack_receipts RPC. The sender's tick is a pure function of (message cseq, partner delivered_cseq, partner read_cseq) with no stored per-message state, no timers, no latch. SENT to SEEN directly is legal — Meta documents that when a message is delivered and read at once 'the delivered webhook is not sent because it's implied.'
- NO SCREEN OWNS DELIVERY (CLIENT-LOCAL). The outbox drainer and the sync worker are driven by app start, foreground, connectivity, hint frames, FCM markers and a monotonic timer — never by a widget lifecycle. Today app_shell.dart:240 renders the chat body in a bare Expanded rather than an IndexedStack, so a tab switch disposes ChatScreen and takes catch-up, receipts and the pending send list with it.
- PUSH CARRIES A DOORBELL, NEVER A MESSAGE (BY CONSTRUCTION). FCM payloads are data-only and contain {type, couple_id} — no body, no sender name, no message id, no cseq the client acts on. Coalescing forty messages into one push loses nothing, because the recipient's response to any push is identical: run the sync worker from its own token. A 'notification' payload is never used — it would ignore collapse_key, render FCM's own text, and break the deliberately disguised launcher.
- EXACTLY ONE CSEQ PER STREAM-MUTATING OPERATION (SERVER-ENFORCED, LOAD-BEARING). send_message and clear_conversation_everyone each advance chat_streams.last_seq by exactly 1. This is what makes pts_count arithmetic unnecessary. Any future operation that mutates the stream must consume exactly one cseq or the arithmetic has to come back; adding one WITHOUT a cseq is the single change that breaks this design silently, and it is a line in the production canary.

## Scale ceiling
**Supported ceiling: 50,000 users (25,000 couples). 100,000 is NOT supported on Supabase Realtime.** The original document claimed 100k "at the wall"; the attack showed the billing arithmetic was ~2x optimistic and that correcting it pushes 100k past the wall, not to it. That correction is accepted.

**Assumptions, stated so they can be attacked.** 2 users per couple. 40 user-messages per user per day (high — this is an LDR couples app). Peak concurrency 8% of registered users. **Evening concentration factor 0.5** — half of daily volume lands in a 3-hour window in the dominant timezone cluster. Billable Realtime = `events × (recipients + 1)`, and because the topology is **two private per-recipient topics per couple**, each broadcast has exactly one subscriber and bills **2**, not 3.

**Events per user-message:** 1 message hint + ~0.5 amortised coalesced receipt + ~0.5 amortised typing = ~2 events → ~4 billable. Pessimistic (no amortisation, 3 full events) → **6 billable**. All figures below use 6.

**1,000 users (500 couples) — comfortable.** Peak concurrent 80. 40k messages/day, ~0.5 writes/s average. The stream lock spreads across 500 independent rows: zero contention. Realtime 7.2M msg/mo. **The Free tier dies first, at ~280 users** (2M ÷ 6 ÷ 40 ÷ 30). Free's 500 MB database is the other early wall — ~800k rows at ~600 B including indexes, about 20 days of accumulation. Both are billing events, not failures.

**10,000 users (5k couples) — works; cost is the constraint.** Peak concurrent 800, which exceeds Pro's spend-capped 500, so the cap must come off. 400k messages/day, ~5 writes/s average, ~50/s at peak; a Small/Medium instance is untroubled. Peak Realtime: 10,000 × 40 × 0.5 ÷ (3 × 3600) = 18.5 user-msg/s × 6 = **111 msg/s** against Pro-no-cap's 2,500. 146M message rows/year. This is also the crossover where push moves off `pg_net` onto a per-tick batched Edge Function invocation.

**50,000 users (25k couples) — the supported ceiling.** Peak concurrent 4,000 against 10,000 on Pro-no-cap/Team — 40% utilisation, real headroom for a reconnect stampede. Peak Realtime 92.6 user-msg/s × 6 = **556 msg/s** against 2,500. 730M message rows/year → roughly 440 GB of database disk, which is now a real line item. `pg_net` at the capped 60 req/s drain: 25,000 couples × 40 msgs concentrated into the evening produces far more than 60 push-eligible recipients per 5 s tick, so the drain runs continuously with a growing backlog and push latency degrades gracefully to tens of seconds — which is why the Edge Function batch path is mandatory above 10k, not optional.

**100,000 users — not supported, and the reason is the honest one.** Peak concurrent **8,000 against a 10,000 ceiling: 80% utilisation with no headroom for a synchronised reconnect** (a Supabase restart, or a commute ending). Peak Realtime at the stated assumptions is ~1,112 msg/s against 2,500 — under, but the margin is inside the error bar of the two assumptions I cannot verify: raise the evening concentration factor from 0.5 to 0.8 and it is 1,780; revert to a shared couple topic (fan-out 3 instead of 2) and it is 2,670, over the hard ceiling. Crossing it returns `too_many_connections` / `tenant_events` — connections refused and existing subscriptions silenced, not a larger bill — and sustained overage gets the project manually suspended (`RealtimeDisabledForTenant`), which needs a support ticket to lift. **I will not claim a ceiling that depends on an assumption I cannot measure. The number is 50,000.**

**The failure mode at the ceiling, honestly.** The original claimed benign degradation: "Realtime refuses connections → falls back to FCM wake + foreground catch-up, messages still arrive, latency goes from ~100 ms to minutes." That is half true and the attack is right to call it out. **At the ceiling both legs degrade together** — the same evening peak that saturates Realtime saturates the push drain — so the real fallback is *foreground catch-up*, which is hours, not minutes, for a user who does not open the app. What remains true and is the actual payoff: **nothing is lost.** The token chain resumes exactly where it stopped, Postgres retention is unbounded, and every message is still there on next open. Contrast with today, where `postgres_changes` *is* a delivery path and a refused connection is a permanently lost message with no error anywhere.

**Today's design, for comparison, reaches none of these numbers.** `postgres_changes` with RLS tops out at **30 changes/sec project-wide** at 500 clients and 40/sec even on a 16XL — the poller is single-threaded and `apply_rls` loops over every subscriber to the table, project-wide, per row change, with the filter evaluated *inside* the loop. `research/supabase.md` puts the current app's whole `postgres_changes` path at **300–800 concurrent users**, and no amount of money raises it.

**The escape hatch past 50k, and why it is cheap.** Only the hint layer is replaced — self-hosted Realtime, or SSE/long-poll from an edge function, or FCM-only with a shorter foreground poll. **None of these touches the data model, the token chain, the outbox, the watermarks, or the state machines**, because the hint layer is architecturally isolated by the transport-subordination invariant. That isolation is the migration insurance and is worth more than any throughput number here.

**The non-Supabase ceiling** is the per-couple row lock, which becomes a real limit around hundreds of writes/second *into one conversation* — irrelevant for a 2-person app, and if it ever mattered the fix is Telegram's: shard the counter further.

## Cost
All figures monthly. Pro is $25 base and includes 5M Realtime messages, 500 peak connections, 250 GB egress, 100 GB storage, **8 GB disk**, and a $10 compute credit. Overages: $2.50/M messages, $10 per 1,000 peak connections (whole packages), $0.09/GB uncached egress, $0.0213/GB storage, **$0.125/GB disk**. Realtime billing uses `events × (recipients + 1)`; with per-recipient private topics that is **2 per broadcast**, and the budget below is **6 billable per user-message** (the pessimistic 3-event case), i.e. 40 × 6 × 30 = **7,200 billable/user/month**.

**1,000 users**

| Line | Basis | Cost |
|---|---|---|
| Pro base | required — Free dies at ~280 users on the message quota | $25.00 |
| Realtime messages | 7.2M, 2.2M over | $5.50 |
| Peak connections | 80, under 500 | $0 |
| Compute | Micro, covered by the $10 credit | $0 |
| Database disk | ~9 GB/yr, ~1 GB over the included 8 | ~$0.13 |
| Storage (media) | ~20 GB/mo accumulating, mostly within included 100 GB | ~$0.50 |
| Egress | 20 GB, under 250 | $0 |
| Edge functions | ~870 invocations (one OAuth mint per ~50 min) | $0 |
| **Total** | | **~$31** |

**10,000 users**

| Line | Basis | Cost |
|---|---|---|
| Pro base, spend cap OFF | 800 peak > capped 500 | $25.00 |
| Realtime messages | 72M, 67M over | $167.50 |
| Peak connections | 800 → 1 package over | $10.00 |
| Compute | Small–Medium, net of credit | ~$45 |
| Database disk | ~90 GB/yr message rows + indexes, 82 GB over | ~$10 |
| Provisioned IOPS | above gp3 baseline for a write-heavy evening peak | ~$20 |
| Storage (media) | ~2.4 TB accumulating over year 1 | ~$49 |
| Egress | 200 GB, under 250 | $0 |
| Edge functions | per-tick batched push sender, ~518k invocations | ~$0 |
| **Total** | | **~$327** |

**50,000 users — the stated ceiling**

| Line | Basis | Cost |
|---|---|---|
| Pro base, spend cap OFF | | $25.00 |
| Realtime messages | 360M, 355M over | $887.50 |
| Peak connections | 4,000 → 4 packages over | $40.00 |
| Compute | Large–XL | ~$150 |
| Database disk | ~440 GB/yr | ~$54 |
| Provisioned IOPS + working set | XL does not hold 440 GB in RAM; the catch-up range scan is the hot path | ~$60 |
| Storage (media) | ~12 TB accumulating | ~$255 |
| Egress | ~1 TB, mostly uncached private media | ~$67 |
| **Total** | | **~$1,540** |

**Three lines the original model omitted entirely, now included above and called out:**
- **Database disk.** 1.46B rows/year at 100k users is ~900 GB, ~$110/mo and growing, plus the fact that no Large/XL instance holds that working set in RAM. This grows forever because retention is deliberately unbounded.
- **`push_pending` retention.** There is none needed, and that is a design decision, not an oversight: the table is keyed `(couple_id, recipient_id)` and upserted with `greatest()`, so its row count is bounded by the number of couples with an outstanding watermark — it does **not** grow with message volume. The original's per-message `push_outbox` did, and had no policy.
- **Supabase system tables with no documented cleanup.** `net._http_response` (6-hour default TTL, but only if `pg_net.ttl` is actually set) and `cron.job_run_details` (no documented retention). Both get explicit prune jobs shipped alongside the push rebuild, or they become the surprise disk line.

**What the design saves versus today, in money.** `research/supabase.md` models the current app at ~18,000 billable Realtime messages/user/month. This design is 7,200. The reductions are structural, not from serving fewer users: delete the client-sent `msg` broadcast (the message no longer travels twice), move to **per-recipient topics** (3 billable per broadcast → 2, a flat 33% cut), **coalesce delivered and read into one ack RPC and one broadcast**, delete the 5 s `presence.chat_last_read` timer and the duplicate typing DB write, and debounce receipt acks to 1/s. Realtime bill: **1k $32.50 → $5.50; 10k $437.50 → $167.50; 50k $2,187 → $887.**

**Push, separately.** Today: one `pg_net` call + one edge invocation + an RSA signature + a Google OAuth exchange + 2 Supabase queries + an FCM POST **per message** — three sequential network hops inside the write path, with the 2 s Edge CPU limit sitting in it. At 10k users that is 12M edge invocations/month plus 12M Google token-endpoint calls. After: a bearer cached in a table refreshed roughly once per 50 minutes, and either `pg_net` at a capped 60 req/s or one batched Edge invocation per 5 s tick. Edge cost goes to ~$0 and the message write path stops making network calls at all — which also measurably shortens the `chat_streams` lock hold.

**Where the cost curve bends.** Below ~25k users, Realtime messages are ~75-85% of the bill and the only lever that matters is events-per-message. Above that, **media storage and database disk together overtake it** ($255 + $54 vs $887 at 50k, and both grow monthly with nothing pruning them) — which makes a **media lifecycle policy the next cost project, not a delivery one.** Flagged from `inventory/chat.md`: `couple_media` is a public bucket with no TTL whose first path segment is the couple_id, flung GIFs are uploaded and never referenced by any row so nothing *can* delete them, and `chat-bg` orphans every previous upload permanently. This design adds one fix to that surface (deleting the object when a BLOCKED outbox row is discarded) and does not pretend to solve the rest.

**The cost of the correctness machinery itself is approximately zero**: one bigint column, two unique indexes, one narrow counter table with one row per couple, one recipient-keyed push table, one HMAC per sync response, and one indexed range query per reconnect. The expensive parts of the systems this borrows from — per-device queues, TTL sweepers, multi-writer stream-position tracking, per-channel pts sharding, retry receipts, session repair — are all things a 1:1 non-E2EE app on Postgres genuinely does not need.

## Migration
Eleven stages. Each ships alone, each has a stated rollback, none requires the other end of the wire to have shipped first. **Two ordering rules are hard prerequisites, not suggestions, and both exist because violating them recreates a bug this plan removes.**

**Stage 0 — server only, zero behaviour change: the canary and the stream table.**
- Create `chat_streams` and an `AFTER INSERT ON couples` trigger that populates it; backfill a row for every existing couple. This alone closes the "new couple has no stream row" wedge across all four couple-creation sites (`schema.sql:320`, `pairing_invites.sql:38`, `newuser_fixes.sql:64`, `hardening_2026_08.sql:111`) by construction rather than by editing four call sites.
- Canary job: record, per couple, the maximum `seq` observed at each poll, and flag any subsequent row appearing *below* a previously observed maximum. Against the current **global** sequence this fires — that is the skip, caught in production, with no phones.
- Prune jobs for `net._http_response` and `cron.job_run_details`.
- **Ship this first**, because it converts an architectural argument into a number on a dashboard.
- Rollback: drop the trigger and the job.

**Stage 1 — server only: partition and cseq, in ONE transaction.**
`BEGIN` → `LOCK messages IN ACCESS EXCLUSIVE` → create the hash-partitioned replacement (32 partitions on `couple_id`) carrying `cseq` and `client_msg_id` → `INSERT SELECT` with `row_number() over (partition by couple_id order by seq, id)` → set each couple's `chat_streams.last_seq` to its max → rename/swap → `COMMIT`.
- **There is no window in which a live insert can land without a cseq.** This is the closure for the migration hazard that would otherwise create rows invisible to every future catch-up (`cseq > n` is NULL for NULL cseq, forever). The original plan's ordering — trigger-then-backfill or backfill-then-trigger — has a hole in both directions; a single locked transaction has none.
- **This is only cheap while the table is small.** It is cheap *now*: production is one couple. The threshold is roughly 5M rows / ~30 s of lock. Past that, the fallback is: install a BEFORE INSERT trigger first with `chat_streams.last_seq` seeded to `count(*) + margin` so live inserts allocate above the backfill range, backfill below it, and **accept the one-time offset** — which is harmless here because contiguity is defined over the *issued* range, not from 1.
- Add the BEFORE INSERT trigger that assigns `cseq` under the same lock for any insert not arriving through the RPC, so the old fleet's direct PostgREST inserts stay contiguous during rollout.
- Add `send_message`, `sync_bootstrap`, `sync_messages`, `fetch_history`, `ack_receipts`, the HMAC key table, and the rewritten `clear_conversation_everyone` (cseq-consuming tombstone).
- `cseq NOT NULL`; `unique(couple_id, cseq)`; `unique(couple_id, sender_id, client_msg_id) where client_msg_id is not null`.
- `seq` and `messages_seq_seq` untouched. Old clients behave exactly as before — still broken, no worse.
- **Verification in production, without phones:** the stage-0 canary against `cseq` (extended with a `cseq IS NOT NULL` predicate) must be permanently empty while the same canary against `seq` keeps firing. That is an A/B proof of the core claim on live traffic.
- Rollback: the swap is the one genuinely awkward step. Keep the pre-swap table under a rename for one release rather than dropping it.
- **This is where partitioning happens.** The original scheduled it last while its own open decisions said "now"; that contradiction is deleted. It is the only step that gets materially harder with data volume, and deferring it converts an afternoon into a maintenance window.

**Stage 2 — client only, additive: the outbox for TEXT.**
Drift outbox plus a main-isolate drainer, routing text only. Calls `send_message` with a `client_msg_id`, **falling back to the direct insert if the RPC is absent**, so this build works against a pre-stage-1 server. Read path completely untouched. This closes `chat.send.text` — the highest-risk item in the inventory and the only send path with no failure state at all (`chat_screen.dart:125-129` swallows the insert failure with a bare `catch (_)`).
Rollback: clean. The old build reads nothing from Drift.

**Stage 3 — client only, additive: listen to the private broadcast, stop trusting the public one.**
Subscribe to `chat:<couple_id>:<uid>` *in addition to* the existing `postgres_changes` subscription; treat every frame from either as a hint that triggers a fetch. **Stop rendering `msg` frames from the public `mood_burst` topic** — that closes the forgery hole on the receiving side one release ahead of the server work. Keep listening to `mood_burst` for typing/mood only.
Rollback: clean; `postgres_changes` is still published.

**Stage 4 — server only: the transport swap.**
AFTER INSERT triggers emitting to the two per-recipient private topics; RLS on `realtime.messages` gating `topic` via a SECURITY DEFINER helper; then `ALTER PUBLICATION ... DROP TABLE` for both `messages` and `chat_receipts`.
Rollback: re-add both to the publication; stage-3 clients still listen to `postgres_changes`.
**HARD PREREQUISITE OF STAGE 6.** Stage 6 raises `chat_receipts` write volume from one ack per 5 s per open chat to one debounced ack per burst per direction. Shipping that while `chat_receipts` is still on the `postgres_changes` poller — 30 changes/s **project-wide** with RLS, shared with presence, `messages`, `reach_events` and the Closer tables, and unimprovable by compute — makes receipts arrive minutes late, and the visible symptom is "the new delivered tick is broken," which is exactly the conclusion that gets a redesign reverted.

**Stage 5 — client only: the coverage-token cursor.**
Replace `_maxSeq` with the token, `fetchSince(_maxSeq)` with `sync_bootstrap` / `sync_messages(token)` / `fetch_history`, and move the sync worker out of `ChatScreen` into a lifecycle-driven worker. Deadlines on every call; `STALLED` state; the fail-closed row-count check in release builds. FCM background handler reduced to: post the disguised notification, write the `sync_due` marker, optionally attempt one bounded page.
**Rollback is genuinely clean, and this was checked rather than assumed:** `_maxSeq` is computed *in memory* from `_messages` (`chat_screen.dart:343-344`), so the old build persists no cursor state. Rolling back returns to the pre-existing bug and creates no new one. The real rollback hazard is the Drift file itself — see open decision 10.

**Stage 6 — client + server: `delivered` becomes reachable.**
The coalesced `ack_receipts(token, read_up_to)` RPC and one receipt broadcast. Delete the 5 s `_readTimer` and its `setChatLastRead` companion; read is written on visibility change only. Sender renders from the new columns, falling back to `delivered_seq`/`read_seq` while the partner is on an older build — both are `greatest()`-monotone, so the mixed-fleet period cannot regress a tick. **Requires stages 1, 4 and 5.**

**Stage 7 — client only: media onto the outbox.**
Replaces `ChatSendQueue`'s in-memory list. Fixes the video duplicate-bubble bug for free, because the id now comes back from the server keyed on `client_msg_id` instead of being guessed twice (today `ChatSendQueue._enqueue` passes `id=null` and Postgres assigns a different uuid, so the sender gets two bubbles, one dead). Adds storage-object deletion on BLOCKED discard.

**Stage 8 — client + server: retire the public topic.**
Stop *sending* the client `msg` broadcast. Move typing, mood/GIF bursts and `cleared` onto the private per-recipient topics. `clear_conversation_everyone` starts consuming a cseq, giving the partner an authenticated blank signal instead of a forgeable public one.

**Stage 9 — server only: push rebuilt.**
`push_pending` upsert in the trigger instead of `net.http_post`; the 5 s `pg_cron` drain with a 300-row budget and carry-forward; one-tick suppression grace; tick-based priority rule; collapse key `m:<couple_id>`; 24 h TTL; cached bearer; dead-letter query. **Independently shippable and revertible with no client change at all**, because the client's response to a push is already "run the sync worker" — identical whether the push carries a message id or nothing.

**Stage 10 — server only: cleanup.**
Drop `messages.seq` and `messages_seq_seq` once no client reads them. Delete `presence.chat_last_read` if open decision 7 is taken.

**Ordering constraints, stated as rules:**
- 0 → 1 in order.
- 2 may ship before or after 1 (the fallback handles both).
- 3 must precede 4. 4 must precede 6. 5 must follow 1 and precede 6.
- 10 must follow 5 on every client in the fleet.
- **If the project stops after stage 5, the two worst bugs — silent send loss and permanent catch-up loss — are already gone.**
- **No stage re-enables a path a prior stage disabled.** The specific trap avoided: dropping `messages.seq` before every client uses tokens would leave a rolled-back client with no cursor at all, which is worse than the bug it started with. That is why stage 10 is last and gated on fleet composition, not on calendar.

## Verification
The reason every previous fix passed and then failed is precise and worth naming: **two NTP-synced phones on one wifi can produce none of the five conditions this system must survive** — reordering, commit-order inversion, packet loss, clock skew, and two isolates racing one SQLite file. That setup can only ever confirm the happy path. Every check below *constructs* those conditions deterministically. **None requires two phones on two networks; items 1–11 require no device at all.**

**1. The ordering invariant is a plain SQL test.** Two concurrent psql sessions (or one pgTAP script with dblink) both call `send_message` for the same couple. Assert: the transaction that commits second holds the higher cseq; a third session polling never observes a hole in the issued range; the counter is **not** bumped when the dedup branch is taken. Runs in CI in under a second. **This test can be written today against the current schema, where it fails** — that failure is the cheapest possible evidence the redesign is warranted, and it costs an afternoon.

**2. Token forgery and clamping, server-side.** Assert `ack_receipts` rejects: a token with a broken HMAC; a valid token minted for the *partner's* user_id; a valid token for a different couple; a token from an older `key_version` after rotation. Assert `read_up_to` above `token.covered_through` is clamped, not accepted. Assert `delivered` and `read` never decrease under any input.

**3. The chain property, as a test of the API surface itself.** Enumerate every function that returns a token and assert each one served the complete interval from the presented position to the minted position. Assert `fetch_history` returns no token under any argument. This is the test that would catch someone adding a convenience RPC that mints a token from a bare integer — the single change that would reopen the phantom-seen bug.

**4. Type-level impossibility, then a lint.** The client ack function accepts a `CoverageToken` value, not a bigint; there is no overload that takes an integer. A static check asserts `ack_receipts` is never called with a literal or with anything other than a token read from the cursor store. The original's equivalent test ("assert the right integer is passed") is deleted because there is no integer.

**5. The apply function is pure, so property-test it.** `apply(cursor, page) -> (cursor', action)` — zero I/O, zero clock, zero network. Generate the issued range `{1..N}`, then subject the *pages* to arbitrary permutation, duplication, truncation, and arbitrary deletion of rows *within* declared intervals (simulating `clear_conversation_everyone`). Assert after every run: `covered_through'` equals the top of the server-declared coverage actually applied; no cseq applied twice; `covered_through'` never decreases; a page whose rows were deliberately dropped by the harness **does not** commit its token (the fail-closed count check). Under the current `_maxSeq` fold the third and fourth assertions fail on the first generated case.

**6. Two isolates, one SQLite file, in CI — no device.** Spawn two Dart isolates against one Drift file and one fake server. Interleave: isolate A served 101–103, isolate B served 101–250, arbitrary commit order, arbitrary `SQLITE_BUSY` injection, arbitrary mid-transaction kill of A. Assert the final state is rows-union and token-max in every interleaving, and that no interleaving produces a cursor above the rows it covers. **This is the test the original's single-isolate harness structurally could not run**, and it closes the fatal finding rather than describing it.

**7. Deterministic in-process fault injection.** A fake transport that drops, duplicates, reorders, delays and times out any frame; a fake monotonic clock; the *real* sync worker and *real* outbox drainer against a real SQLite store. Each historical and predicted failure is a named regression test:
- "socket dies mid-catch-up, page 2 of 4" → asserts `CATCHING_UP → STALLED → CATCHING_UP` and full recovery. **Write this one first; it must fail until the transition exists.**
- "half-open socket: request neither returns nor errors" → asserts the deadline fires and the worker is not wedged.
- "`clear_conversation_everyone` runs between two sync pages" → asserts the interval closes, no resync loop, no assert.
- "fresh install with 30,000 unread" → asserts `install_floor` is set, the server advanced `delivered` over the skipped range, the watermark tracks the live conversation immediately, and **at most 5 notifications are posted**.
- "fresh install with 400 unread" → asserts the *no-skip* branch is taken and every message is paginated in.
- "send times out but the server committed" → asserts exactly one row and that the client adopts the server's cseq.
- "device clock jumps back 3 minutes mid-backoff" → asserts the outbox drains on schedule (there is no timestamp to corrupt).
- "process restart with 5 queued messages" → asserts all are immediately due.
- "zero-message couple, first app open" → asserts no NULL comparison, no wedge, `CAUGHT_UP` reached.
- "hint frame for a cseq above the token" → asserts it triggers a fetch and is never applied.
- "forged frame on the public topic" → asserts nothing renders and no cursor moves.
- "two days offline, 900 messages, five pages."

**8. One-process, two-identity end-to-end.** Two Supabase sessions (two JWTs) in a single Dart test process against a local `supabase start` Postgres. Covers the RPC contract, RLS, the dedup index, token binding, watermark monotonicity, "sender cannot write the peer's watermark," and "read cannot exceed coverage" — **zero devices**.

**9. Load and lock verification without users.** `pgbench` with a custom script driving `send_message` across N synthetic couples. Measures the `chat_streams` lock hold time — the number that decides whether the row lock is ever a ceiling — and proves issued-range contiguity under real concurrency. Also the place to confirm that removing `net.http_post` from the trigger in stage 9 measurably shortens the hold.

**10. Push drain under a synthetic backlog.** Seed `push_pending` with 50,000 rows and assert the cron tick never issues more than the 300-row budget, that carry-forward is ordered by `first_tick` with no starvation, that a recipient whose `delivered_cseq` advances mid-backlog is dropped from the drain, and that priority is `normal` for a recipient with a recent `last_ack_tick`. All server-side, no FCM, no device.

**11. Production canary as a continuous assertion, kept forever.** Per couple: contiguity of the *issued* range, `cseq IS NOT NULL`, `chat_streams` row exists for every couple, token-mint failures counter, `ack_receipts` rejection counter (a nonzero rate means a client is passing a bad token — the early-warning signal for a bad rollout), fail-closed count-check failures reported by clients, and `push_pending` rows past N ticks. One indexed aggregate per run. **This is the check that survives future refactors by people who have not read this document**, and it is the only place the "exactly one cseq per stream-mutating operation" invariant is observable in production.

**What still needs a device, and what it is actually for.** Exactly three things, all on **one** phone: that Android's Doze and process-freeze wake the FCM background isolate and that it can post a notification and write the marker within its "several seconds"; that the notification renders under the active disguise (a care reminder once leaked as a "News update" — that regression must not return); and that two isolates contending on one Drift file on real hardware behave as item 6 predicts. The first two are plumbing checks. The third is a correctness check, and it needs one phone, not two — it is the only device test in this plan that is not a plumbing check.

**Flagged gap, stated plainly:** none of items 1–11 exist today. The current automated test surface for this domain is **zero**, so every number in this document about the new design is a design claim and not a measurement. The first deliverable is item 1 written against the *current* schema, where it will fail.

## Accepted limits
**1. The server cannot verify what a client stored — nothing can.** The coverage token certifies what the server *sent*, not what the client *committed*. A client bug that drops a row out of a served page could still commit the token and advance a watermark. This is reduced from the original's unbounded "any integer any client passes" to "rows dropped inside one server-served page by one client function," and it is closed fail-closed in release builds by comparing stored-row count against the server's `rows_in_range`. **Residual risk:** that check is a client-local guard, not a server property. A refactor can delete it, and the production canary cannot see the result — it only sees server-side contiguity. Mitigation is that the lie is now bounded by a single page (≤200 messages) rather than by the entire history, and that the check has a named test (verification item 5). This is the one place where the design is not correct-by-construction, and the original document claimed it was.

**2. `delivered` is best-effort while the app is not foregrounded.** `push.md` documents that network access is **disabled** in the Rare and Restricted standby buckets (Restricted entry after 8 days of no interaction on Android 13+), and that the FCM background handler gets "several seconds" with process kill past ~30 s. So the background isolate's single bounded sync page will routinely fail, and `delivered_cseq` will lag until the recipient next foregrounds. The double-grey tick is therefore honest but slow for a partner who has not opened the app in over a week. No design fixes this; it is an OS policy.

**3. Collapsible push throttling caps wake latency at ~3 minutes for the heaviest users.** With one collapse key per couple, FCM throttles to "a burst of 20 per app per device, refilling 1 every 3 minutes." A recipient whose phone is in Doze through an active evening gets the first 20 wakes promptly and then one wake per 3 minutes. This is accepted deliberately: the alternative (non-collapsible) hits the 100-pending-per-instance cliff, at which point FCM discards **all** stored messages and sends the `onDeletedMessages` tickle. A bounded 3-minute latency beats an unbounded discard. The collapse-key budget is 3 of the device's 4 slots (`m:`, `c:`, `r:`); a fourth logical push stream cannot be added without evicting one unpredictably.

**4. A `differenceTooLong` bootstrap marks a range delivered that this device never downloaded.** When a reinstalled client is more than 2,000 messages behind, the server sets `install_floor` and **itself** advances `delivered_cseq` to it. The sender's ticks go double-grey over messages this device holds only as fetchable history. This is a recorded, logged server decision rather than a client claim, and it matches Meta's documented "delivered to at least one of the user's devices" semantics — but it is a real, deliberate imprecision, not an accident.

**5. 100,000 users is not supported, and the reason is an assumption I cannot measure.** The stated ceiling is 50,000. At 100k, peak concurrent connections are 8,000 against a hard 10,000 with no headroom for a synchronised reconnect, and whether peak Realtime message rate clears the 2,500/s ceiling depends on the evening-concentration factor (0.5 assumed) and the broadcast fan-out (2 assumed, per-recipient topics). Move either one and it goes over. The cost model carries roughly ±2× uncertainty on its dominant line for the same reason.

**6. At the ceiling, degradation is not benign in the way the original claimed.** The same evening peak that saturates Realtime saturates the push drain, so both notification legs fail together and the real fallback is "next time the user opens the app" — hours, not minutes. What survives intact is that **nothing is lost**: the token chain resumes exactly where it stopped and retention is unbounded. The original's "latency goes from ~100 ms to minutes" was optimistic.

**7. Media lifecycle is not solved.** This design deletes the storage object when a BLOCKED outbox row is discarded, and nothing else. `couple_media` remains a **public** bucket with permanent unauthenticated URLs whose first path segment is the `couple_id` (as `hardening_2026_08.sql` L25 itself admits — which is also how the current public broadcast topic became guessable). Flung GIFs are uploaded and referenced by no row, so nothing can ever delete them, and `chat-bg` orphans every previous upload. At 50k users media is the second-largest line on the bill and growing monthly. This is a separate project and conflating it with delivery is how the delivery work gets delayed.

**8. No E2EE, therefore no retry-receipt class.** WhatsApp's `retry` means "delivered to the device but decryption failed" — transport succeeded, semantics failed. There is nothing here to fail. **If `research/e2ee.md`'s work lands, a retry receipt must be added in the same change**, or you get permanent "Waiting for this message" holes that no amount of transport reliability fixes.

**9. Multi-device is not supported and this design does not add it.** `profiles.fcm_token` is a single column, so signing in on a second device silently steals push from the first. Watermarks are per-user. With `greatest()`, a lagging second device can only fail to advance a watermark, never regress one, so per-user is *safe* today — but if multi-device ships, per-device tokens, per-device watermarks and a `max()` aggregate must land as one change or the ticks flap.

**10. There is a window where a cleared message is briefly visible.** If a partner clears while the other is mid-page, rows already rendered locally stay on screen until the `clear` control row is applied on the next page. Bounded by one sync round-trip, not by anything unbounded, but it is not zero.

**11. The hint layer costs a round-trip per message.** Carrying `{cseq}` only instead of the row means every message adds a `sync_messages` call (~50–150 ms) before it renders on the recipient. This is a deliberate trade for having exactly one render path and a hint layer that is provably incapable of being mistaken for truth. Carrying the row remains available as a pure latency optimisation that changes no invariant.

**12. Rolling back the coverage-token client loses queued outbox rows if the Drift file is unreadable.** The local database holds no authoritative data *except* the outbox. The stated policy on an unrecoverable Drift open is drop-and-rebootstrap with a user-visible warning — which means a message queued but not yet sent can be lost by a schema-migration crash. The alternative (refuse to start) is worse.

## Open decisions
**1. Does the broadcast hint carry the row, or only the cseq?**
**Recommend `{cseq}` only** — this reverses the original document's recommendation, and the reason is the token chain. Because a hint can never mint a token, a client that receives the row still has to call `sync_messages` before anything can advance, so carrying the row saves no round-trip on the *correctness* path — it only lets the UI paint sooner, at the cost of a second render path that can disagree with the durable one. Cost of the recommendation: ~50–150 ms added latency per message. Reversible at any time; it changes no invariant. Decide before stage 4.

**2. Per-recipient topics or one shared couple topic?**
**Recommend per-recipient** (`chat:<couple_id>:<recipient_uid>`, two per couple). A broadcast then has exactly one subscriber and bills 2 instead of 3 — a flat 33% cut on the dominant cost line — and the RLS policy becomes a string comparison against `auth.uid()` rather than a membership test. Cost: two channel joins per couple instead of one, against a joins/sec quota that a synchronised reconnect stampede already stresses. Decide before stage 4; it is baked into the trigger and the RLS policy.

**3. What is the `differenceTooLong` threshold, and may the server advance `delivered` over the skipped range?**
**Recommend 2,000 messages, and yes — with a log line.** Below the threshold the reinstalled client paginates the whole unread range and no watermark is imprecise. Above it, the server sets `install_floor` and advances `delivered_cseq` to it *itself*, so the skip is a recorded server decision rather than a client claim. This needs a product call because the alternative (never skip) means a partner with 30,000 unread shows one grey tick for days. Also decide whether the UI shows anything at the floor boundary — "older messages" is honest, silence is simpler.

**4. Does `clear_conversation_everyone` keep hard-deleting?**
**Recommend yes.** Content genuinely leaving the database is the point for this app, and the coverage-is-server-declared invariant makes hard deletion safe by construction. Sub-decision: is the `clear` control row itself deletable by a subsequent clear? **Recommend no** — keep the last one, so a fresh install always learns the view was blanked. It is one row per clear.

**5. Partition count, and is stage 1's locked swap acceptable?**
**Recommend 32 HASH partitions on `couple_id`, executed in stage 1 in a single locked transaction.** The catch-up query is `couple_id = X AND cseq > N`, which prunes perfectly on `couple_id` and not at all on time. It is cheap right now — production is one couple — and this is the only step in the plan that gets materially harder with data volume. Owner call because it is the one stage whose rollback is a rename rather than a revert.

**6. Read watermark granularity.**
**Recommend the clamped `read_up_to`** (client names a cseq, server clamps to `token.covered_through`) rather than token-boundary-only. Boundary-only would be marginally stronger — zero client integers anywhere — but it makes read granularity page-sized, which reads as a bug to the user. The clamp already removes the failure that matters, because there is no hole inside a certified interval.

**7. Delete `presence.chat_last_read` entirely?**
**Recommend yes.** It is a second, clock-based read watermark duplicating `chat_receipts.read_cseq`, and it costs 12 writes/minute per open chat on the hottest row in the system — a row with `REPLICA IDENTITY FULL` in the realtime publication, so each write also fans a full-row WAL record (including GPS columns) to the partner. Anything reading it should read the receipt instead. Owner call because `presence` has consumers outside this domain.

**8. Do edits and deletes join the cseq stream?**
**Recommend yes, in a stage of their own, and with the rule that every stream-mutating operation consumes exactly one cseq.** Today deletes are UPDATEs (`deleted_for_everyone`) and the partner sees nothing live, because `messages` is only subscribed for INSERT and DELETE. The dangerous version is someone adding a stream-mutating operation *without* a cseq, which breaks the invariant silently — that is why it is a line in the canary and a comment in the migration. If any future operation ever advances the counter by more than 1, `pts_count` arithmetic has to come back, and that should be a deliberate decision rather than a discovery.

**9. Push sender: `pg_net` or a batched Edge Function, and where is the crossover?**
**Recommend `pg_net` with a 300-row/tick budget below 10,000 users, and one batched Edge Function invocation per tick above it.** `pg_net` is documented at ~200 req/s reliable with a 2 s timeout and **no retry**; the budget keeps it at 60 req/s so it is never presented with an evening burst. Above 10k the backlog grows faster than the budget drains it and a single invocation holding the cached bearer with its own concurrency control is the right shape. Decide at stage 9; the switch requires no client change.

**10. Drift-open-failure policy.**
**Recommend drop-and-rebootstrap with a user-visible warning.** The local database holds no authoritative data except the outbox, so discarding it costs a bootstrap and, in the worst case, a message that was queued but never sent. The alternative — refuse to start — turns a schema-migration bug into a brick. Sub-decision worth taking: attempt to read the outbox table alone before dropping, and surface "some queued messages may not have been sent" rather than silently losing them. This is the single largest rollback risk in stage 5 and it deserves an explicit owner decision rather than a default.
