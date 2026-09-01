> **Partly superseded by [`../CONTRACT.md`](../CONTRACT.md).** This document was written
> before the cross-domain reconciliation. Where it disagrees with the contract, the
> contract wins. Specifically superseded here:
>
> - **R1** — position allocation — one row, two dense counters; chat stays out of couple_stream
> - **R2** — presence retirement — public.presence is replaced, never indexed
> - **CLIENT-F2** — chat mutation tombstones and the staged revoke/guard ordering
>
> Reasoning: `../RECONCILIATION.md`. Corrections that verification forced:
> `../RECONCILIATION-REPAIRS.md`.

# client (revised)

## What changed vs v1
**FATAL 1 — "the cursor is `messages.seq`" (a global `nextval`, out-of-order visibility). CLOSED, by deleting client-side positions entirely.**
Mechanism: the client no longer holds, computes, compares or transmits any position it derived itself. It holds one **opaque cursor per stream, minted only by the server**, and it advances that cursor only by applying a page whose covered interval the server declared. This is `revised/messaging.md`'s coverage token (`(key_version, couple_id, user_id, covered_through)` + HMAC, obtainable only by presenting a token for some M ≤ N and being served the complete interval `(M, N]`) and `revised/transport.md`'s `couple_stream.pos` allocated under a `couple_cursor` row lock held to COMMIT. Both are the same client-side contract — *the server declares coverage; the client merges intervals* — so one generic engine serves both. The concrete deletions: `chat_screen.dart:343-344`'s `_maxSeq` fold over the in-memory list, `ChatRepository.fetchSince(couple, _maxSeq)` at line 372, and `ackDelivered(_maxSeq)` at line 379 all become unrepresentable, because the engine's public API has **no method that accepts a bigint position from feature code**. `messages.seq` is never again read by the client for any purpose.

**FATAL 2 — "`messages` is append-only". CLOSED, by making deletion a forward event plus a bounded digest for everything else.**
Three mechanisms, in order of strength. (a) Every mutating operation **consumes a position**: `revised/transport.md` §D gives per-row deletes `op='delete'` and the bulk purge exactly one `op='purge'` (per-row trigger suppressed by a transaction-local flag), and `revised/messaging.md` makes `clear_conversation_everyone()` allocate a `kind='clear'` control row carrying `clear_through_cseq` **before** it hard-deletes. So a partner clearing their chat is learned as a row the reader's cursor must pass *forward* over, not as an absence it must infer. `delete_for_everyone` and `hide_message` likewise become position-consuming updates. (b) The client's apply rule states the general form: **a local row may be deleted only by an applied stream op; absence of a row from a range read is evidence of nothing and the client never diffs.** A missing entity behind a position is normal and the cursor advances anyway (transport.md's "a stream position survives its entity"). (c) For anything that removes rows *outside* the stream — a data-domain retention reaper, a manual SQL delete, a restore-from-backup — no forward event exists, so I add a **coverage digest**: a cheap zero-parameter RPC returning `(rows_present, min_pos, max_pos)` over the client's covered range; mismatch against the local count is a `resync_required` for that stream. Run once per cold start and at most once per 24 h, never on a doorbell. This is PowerSync's checksum answer at the cheapest granularity that still catches whole-row loss. What it does **not** catch is a substituted or corrupted body at an unchanged count — stated in accepted_limits.

**FATAL 3 — "LWW cursor on `(updated_at, id)` from a BEFORE trigger". CLOSED, by deleting the LWW-collection class.**
`now()` is transaction-start time, so a `(updated_at, id)` keyset skips rows exactly as `nextval` does. The repair is not a safety window; it is that **no durable collection is synced by a timestamp anywhere in this design**. Collections split into four classes (§A): STREAM (positions/tokens only), SNAPSHOT (zero-parameter server-computed reads that carry no history and no cursor — `revised/presence.md`'s `presence_bootstrap()` returning `last_seen_age_seconds`, an *age*, is the canonical case), SESSION (ephemeral broadcast, never persisted), and LOCAL-ONLY. Every one of the eight collections the v1 design put behind an LWW cursor lands in STREAM or SNAPSHOT. There is no third option and no client code path that orders on, compares, or issues an inequality against any timestamp — `created_at` is display-only, which is also forced by the fact that `messages.created_at` is client-settable today (no table-level INSERT revoke exists anywhere in `E:/LDR/supabase`).

**FATAL 4 — "bootstrap does not terminate". CLOSED, by making both the entry and the exit server-declared.**
Bootstrap is a distinct phase, not a catch-up with a large gap. `sync_bootstrap()` (messaging.md) decides server-side: within 2,000 of head → mint a token at the existing watermark and run ordinary forward pagination; otherwise set `install_floor = stream_last_seq − page_size`, advance the watermark to the floor, log the decision, return the **newest** page and mint a token at `stream_last_seq`. Older history is `fetch_history(before_cseq, limit)`, descending, on scroll, **minting no token** — so backfill structurally cannot move a watermark or trigger a wipe. "Too far behind" is a server response (`resync_required` when the presented cursor precedes `floor_pos`), never a client page count; the 20-page cap survives only as a UI yield point with no side effect. And a resync **never deletes local rows as its first action**: it fetches the replacement page, then in one transaction installs the new floor and token and marks rows below the floor `unverified`. There is no state in which the app has deleted history and not yet acquired its replacement.

**Also closed (rated serious by the attack, and mine to own):**
- *Device clock in the outbox.* The outbox has **no timestamp column of any kind** (messaging.md's rule, adopted verbatim). `attempts` is the only persisted scheduling state; backoff is measured on a `Stopwatch` from process start; every row is immediately due after a restart; **there is no lifespan and no `failed_permanent` by expiry**. An RTC that resets to the ROM build date changes nothing, because nothing compares a clock.
- *`on conflict (id) do nothing returning *` returns zero rows.* Deleted. Sends go through `send_message(...)` which returns `{id, cseq, deduped}` on every attempt including the duplicate. There is no raw client insert on any streamed table.
- *One `chat:<couple>` queue in a one-conversation app.* Two lanes, `chat:text` and `chat:media`. A stuck 30 MB upload can no longer hold three texts for hours. The cost — a photo that finally lands gets a later `cseq` than texts composed after it — is stated as a deliberate trade in accepted_limits, not hidden.
- *Doorbell request-amplification.* transport.md removes the forgery (`cs:` has a SELECT policy and deliberately no INSERT policy). Client-side defence in depth: a doorbell may only set a dirty bit; a token bucket independent of arrival rate permits at most one catch-up per stream per interval.
- *"No place for calls, games, heartbeat, touch."* The SESSION class exists, is named, has its own error rule ("the interaction did not happen"), and has an explicit lint allowlist. It may never write an entity row.
- *Step 5 as a flag-day refactor claimed parallelisable.* The lint ships as a **ratchet**: a seeded per-directory allowlist of every current offender, one entry deleted per PR, red on any *new* offender from day one.
- *No kill switch, no store channel.* `app_runtime_config` (presence.md's table, extended with `client_flags jsonb` and `min_client_build`, read over plain HTTP so it works with a dead socket) is a prerequisite of the first client stage, not an open decision. And because this app is sideloaded behind a disguised launcher with no update channel, telemetry moves **early** in the migration, not last.

## Target architecture
# Client architecture — revised

## The one mechanism

**A local SQLite database is the application; the network is a replication detail; and every position in it was minted by the server.** One generic sync engine fills it, one generic outbox drains it, every screen reads a bounded local stream and writes by enqueueing, and **no screen issues a network request**. The v1 design had this right. What it got wrong was believing the client could name its own place in the data. It cannot — not with `nextval`, not with `now()`, not by counting pages. The revision removes every client-minted position and every client-side inference about what it might have missed.

Three sentences carry the whole thing:

1. **The client never says where it is.** It presents an opaque token; the server serves forward from it and mints the next one.
2. **The client never infers what is gone.** Deletion is a position it must pass forward over; absence is evidence of nothing.
3. **The client never compares a clock.** Not for ordering, not for freshness, not for retry, not for expiry.

---

## 0. External prerequisites — named, because this design is stacked on them

These are not assumptions. Each is owned by another domain and each has a check that says whether it has landed.

| Prerequisite | Owner | Check |
|---|---|---|
| `supabase/migrations/` + `config.toml` exist; `supabase db reset` reproduces the app; a staging project exists; every migration has a written revert | **data** | `ls supabase/migrations` is non-empty — it does not exist today, verified; `supabase db reset` on a clean container followed by the client's golden-fixture suite |
| `couple_cursor` / `chat_streams` counter + position triggers live in production | transport, messaging | `select` on the counter table returns a row per couple; a CI assertion that every streamed table has an append trigger and a `NOT NULL` position column |
| `cs:` is private with no client INSERT policy | transport | a test client joins `cs:<other couple>` and is refused; a member attempts a broadcast on `cs:` and is refused |
| `send_message`, `sync_bootstrap`, `sync_messages`, `fetch_history`, `ack_receipts` exist and return the declared shapes | messaging | contract test against staging |
| `presence_bootstrap()` returns an **age**, never a timestamp | presence | contract test asserts no ISO-8601 string in the response |
| `app_runtime_config` exists with `client_flags jsonb`, `min_client_build` | presence (table), client (columns) | read over plain HTTP with the socket disconnected |
| Table-level INSERT/UPDATE grants are narrowed so `created_at` is not client-settable | data | a client attempting to insert a future `created_at` is rejected |

**The honest consequence of the first row:** until the data domain ships `supabase/migrations`, `config.toml` and a staging project, the client stages below can be built and unit-tested but **cannot be verified against a real schema anywhere but production**. Stages C0–C2 are safe under that constraint because they change no server behaviour. Stage C3 onward is not. This is stated as a gate, not a hope.

---

## A. Four data classes. This replaces "log collections and LWW collections"

The v1 split was the source of two of the four fatal flaws: it classified a mutable table as an append-only log, and it invented a timestamp cursor for everything else. The replacement is exhaustive and each class has exactly one sync mechanism.

### 1. STREAM — durable, couple-scoped, ordered, must survive both users offline
`messages`, reaches, capsules, care nudges, love reasons, cycle events, call signals, the Closer set, deletes and purges.

- Position is server-allocated: `couple_stream.pos` under the `couple_cursor` row lock (transport.md §C), or `messages.cseq` under the `chat_streams` row lock (messaging.md). In both cases **position order is commit order per couple**, because the lock is held to COMMIT.
- Read exclusively through server RPCs that **declare the interval they covered**: `(rows, covered_from, covered_through, rows_in_range, stream_last_pos, next_token)`.
- Cursor is opaque to the client. `has_more` is `stream_last_pos > covered_through` — a server fact, never `count == limit`.
- Deletions are positions (`op='delete' | 'purge'`, or a `kind='clear'` control row carrying `clear_through_cseq`).

### 2. SNAPSHOT — durable state with no history worth replaying
Partner last-seen, partner privacy prefs, coarse location label, own profile, couple settings, runtime config, funnel state.

- **No cursor. No local history. No timestamp anywhere.** A zero-parameter `SECURITY DEFINER` RPC computes the entire answer server-side and returns it. `presence_bootstrap()` returning `last_seen_age_seconds` (an *age*, computed on the server) is the pattern for all of them.
- The client caches the **response**, opaquely, with a monotonic `Stopwatch` reading taken at receipt. Rendering is `age + elapsed_monotonic`. A device six hours wrong renders byte-identical output.
- Refreshed on: app start, resume (debounced 400 ms), socket reconnect, and an explicit user pull. Never on a timer. Single-flighted per key; Full Jitter retry `random(0, min(10s, 250ms · 2^attempt))`; then quiet.
- Empty state is explicit and is never a spinner and never a false claim: no cache and no network renders `unknown` ("last seen: unavailable"), never "Offline".

*This class is what makes fatal flaw 3 structurally impossible: none of these collections has a cursor to be wrong.*

### 3. SESSION — ephemeral, live-connection-scoped, never persisted
Typing, room/zone, live coordinates, gesture streams, heartbeat/PPG, watch-together sync, game state, presence membership, in-call SDP/ICE *hints*.

- Lives on `cl:{couple}` / `rt:{couple}:{session}` (transport.md) and presence.md's `:live`. Latest-wins coalescing, byte-budgeted, self-expiring on a monotonic receiver timer.
- **May never write an entity row, may never enter the outbox, may never advance a cursor.** Its failure mode is named: *the interaction did not happen.* That is an acceptable outcome for a typing dot and an unacceptable one for a message, which is exactly why the classes are separate.
- Call *signalling* is not in this class: it is durable and ordered, so it is STREAM (`stream='call'`, transport.md §I). What is SESSION is the ring hint that shortcuts latency.
- The class carries an explicit lint allowlist. Without it an engineer implementing calls has no legal path and either breaks the doctrine or leaves calls broken — the v1 doctrine's real defect.

### 4. LOCAL-ONLY — never leaves the device
Draft text, scroll anchors, the outbox, frame statistics before they are shipped, the funnel state cache, `pending_entry_intent`, the error ring.

---

## B. Local schema (drift over SQLite)

**Sync meta**
- `stream_cursor(stream_key PK, scope_id, token BLOB, covered_through, floor, generation, bootstrapped, last_ok_monotonic_ms)` — `token` is the server's opaque cursor. There is **no** `cursor_a/cursor_b` integer pair and no timestamp.
- `held_ranges(stream_key, lo, hi)` — a small interval set over *issued* positions, merged on apply. Used for display gap-marking and the fail-closed count check. It is not the watermark; the token is.
- `snapshot_cache(key PK, payload_json, received_monotonic_ms, received_wall_ms)` — `received_wall_ms` is written but is read by exactly one call site (cold-start coarse bucketing, per presence.md §5) which the clock-hostility CI test whitelists by name. Every other read uses the monotonic field.

**Outbox**
- `outbox(op_id PK /* client uuid v4, minted before the first network attempt */, kind, lane, scope_id, payload_json, attempts, state, last_error_class)` — **no `created_at`, no `next_attempt_at`, no `expires_at`.** `state ∈ {QUEUED, UPLOADING, INFLIGHT, COMMITTED, BLOCKED}`.
- `outbox_blob(op_id PK, local_path, byte_len, sha256)` — the baked JPEG is *moved* into `<appSupport>/outbox/<op_id>.<ext>` in the same transaction as the outbox row, out of the OS temp dir the cleaner reaps. This is the durable replacement for `ChatSendQueue._pending`, a plain `List<PendingSend>` in a singleton (verified, `chat_send_queue.dart`) that loses the user's photo and its temp file on any background kill.

**Entities** mirror server streams. Chat rows are keyed `(couple_id, cseq)` for committed rows and by `client_msg_id` for not-yet-committed sends. Every row carries `sync_state ∈ {pending, committed, blocked, unverified}`. **Status is a column on the row the UI is already bound to**, not an entry in a parallel in-memory list — Signal's `markAsSentFailed(messageId)` shape.

**Local-only**
- `pending_patch(entity_table, entity_id, field, value_json, op_id)` — unacknowledged field edits.
- `frame_stats(route, phase, bucket, p50, p95, p99, jank_frames, severe_frames, total_frames)`.
- `ui_error_log` — bounded 500-row ring.
- `funnel_state(has_session, profile_complete, paired, role_set, last_verified_generation, last_failure_class)` — every field **three-valued** (`yes | no | unknown`).
- `pending_entry_intent(route_enum, arg_json)`.

Encryption at rest: see open decisions. It is decided **before** the local DB ships, because retrofitting it is a forced full re-bootstrap for every installed device.

---

## C. The sync engine

One service, parameterised by a **stream descriptor** per stream: `(stream_key, bootstrap_rpc, page_rpc, backfill_rpc, digest_rpc, apply_fn, page_size)`. Registering a new collection is a descriptor and an apply function. There is no per-screen sync code anywhere.

### The apply rule — one transaction, fail-closed

A page arrives as `(rows, covered_from, covered_through, rows_in_range, stream_last_pos, next_token)`. In **one** local transaction:

1. insert-or-ignore each row on its natural key;
2. apply each row's `op` (`insert` / `update` / `delete` / `purge` / `clear`);
3. merge the half-open interval `(covered_from, covered_through]` into `held_ranges`;
4. **verify the count of stored rows inside that interval equals `rows_in_range`; if it does not, abort the whole transaction, log, and enter STALLED** — the token is not committed and no watermark can move;
5. update the cursor with `WHERE covered_through < :new`.

Properties this buys, each of them structural:
- **The cursor advance and the rows it describes commit together.** A crash between fetch and apply replays the range; it can never skip it.
- **Advance is monotone and commutative.** Two concurrent workers — including the FCM background isolate, which has separate globals and cannot see any in-memory guard — converge to rows-union and token-max in any interleaving. No lease, no singleton, no flag.
- **The UI never observes a partial round.** Consistency boundaries are a property of the storage engine, not of screen code.
- **A page the client failed to store cannot advance anything.** Fail-closed, in release builds.

### Bootstrap (fatal flaw 4)

A separate phase, entered only when there is no token:

1. `sync_bootstrap()` — the server decides. Within 2,000 of head: mint at the existing watermark, empty page, ordinary forward pagination follows. Beyond it: `install_floor = stream_last_pos − page_size`, watermark advanced to the floor and the decision logged server-side, **newest page** returned, token minted at `stream_last_pos`.
2. Older history is `fetch_history(before_pos, limit)`, descending, on scroll. **It mints no token.** That is the structural reason backfill cannot move a watermark and cannot trigger a wipe.
3. A page cap exists only to yield to the UI between pages. It has no side effect. **"Too far behind" is `resync_required` from the server** (presented cursor precedes `floor_pos`), never a page count.
4. A resync never deletes first: fetch the replacement, then in one transaction install the new floor and token and mark rows below the floor `unverified`. Progress is visible and paged; there is no full-screen spinner, because local data is already on screen.

### Catch-up triggers, coalescing, and the doorbell

Triggers: app start, foreground, connectivity gain, socket open, doorbell frame, FCM `sync_due` marker, the resume probe reply, `onDeletedMessages`, and a 60 s monotonic timer while STALLED.

- **A doorbell may only set a dirty bit.** It never schedules work directly, never carries a row, never contributes a position. transport.md removes the forgery (`cs:` has no client INSERT policy); this is the client half, and it holds even if that policy is later misconfigured.
- **Single-flight per stream**, plus a token bucket independent of arrival rate: at most one catch-up per stream per interval regardless of how many doorbells land. Five triggers inside 200 ms of leaving a tunnel produce one fetch.
- **Full Jitter backoff** `random(0, min(30_000, 1000 · 2^attempts))`, measured on a `Stopwatch`. **Reset on a successful response, never on a connectivity event** — `connectivity_plus`' own README says a connection type does not guarantee internet access, and resetting on connectivity means every device leaving one tunnel converges on attempt 0 in the same second.
- Connectivity state decides only **when** the drainer wakes. It is never a precondition for issuing a request; the authority on reachability is a request that returned or timed out.

### Caught-up, and the reconciliation digest

Caught-up is decidable with no clock, no ack and no extra round trip: `covered_through == stream_last_pos`. The UI shows a syncing affordance only while behind.

The digest closes the residue of fatal flaw 2 — row loss that produces no forward event. `stream_digest()` returns `(rows_present, min_pos, max_pos)` over the client's covered range. Run **once per cold start and at most once per 24 h**, never on a doorbell. Disagreement is `resync_required` for that stream. It catches whole-row loss; it does not catch a substituted body (accepted_limits).

---

## D. Deletion — the rules that make a vanishing row safe

1. **A local row is deleted only by an applied stream op.** There is no code path from "I did not see it in a page" to a local delete. The engine has no diff function.
2. **A missing entity behind a position is normal.** A range read that left-joins to entity tables and gets nulls is not an error; the cursor advances.
3. **`clear` is a forward event.** `clear_conversation_everyone()` allocates a control position carrying `clear_through_cseq` before it hard-deletes. The reader applies: delete local rows at or below that position, raise the local floor to it so backfill never re-fetches them, and render the empty state. The partner learns the deletion; it is not silently invisible forever.
4. **The bulk purge costs exactly one position**, not 50,000 — the per-row trigger is suppressed for that statement by a transaction-local flag.
5. **Positions never rewind.** A purge is a forward event like any other.
6. **A local media blob is deleted when its owning op reaches a terminal state**, in the same transaction — so a dismissed BLOCKED send deletes both the outbox row and the uploaded object, and orphaned files are not a category.

---

## E. The outbox — every durable mutation, one table, no clocks

Repositories no longer call PostgREST; they enqueue. Feature code has no other way to mutate shared state.

| kind | lane | coalesce | notes |
|---|---|---|---|
| `msg.send.text` | `chat:text` | append | |
| `msg.send.media` | `chat:media` | append | separate lane so a stuck upload blocks nothing else |
| `msg.delete` / `msg.clear` | `chat:text` | append | position-consuming server ops |
| `receipt.ack` | `receipt` | **replace-with-greatest** | server clamps to the token; a late or replayed ack is a no-op |
| `profile.field` | `profile:<field>` | replace | |
| `presence.anchor` | `presence` | replace | zero-parameter RPC; server enforces cadence in its predicate |
| `location.label` | `location` | replace | on label change, not every 15 s |
| `telemetry` | `telemetry` | append, batched, **bounded ring, drop-oldest** | the one lane where loss is acceptable and is stated as such |

**State machine** (messaging.md's, adopted): `QUEUED → UPLOADING → INFLIGHT → COMMITTED`; any network error, timeout, 5xx or 429 returns to `QUEUED` with `attempts++`; a deterministic 4xx (RLS denial, unpaired, rejected payload) goes to `BLOCKED`, which is a **row state the user can see and retry**, never a toast and never a silence. `op_id` never changes, so every retry is byte-identical and the server dedups on `(couple_id, sender_id, client_msg_id)`.

**No lifespan. No expiry. Retry is forever.** This is not laxness — it is the only way to be correct on a phone whose RTC resets to the ROM build date. `attempts` is the only persisted scheduling state; every row is immediately due after a restart; backoff runs on a `Stopwatch` from process start. There is no timestamp in the drainer's predicate, so there is no state in which a message typed one second ago is marked permanently failed because the clock says 2023.

**Drained on the main isolate only.** The FCM background isolate may write a `sync_due` marker and post a notification; it may not drain and it may not apply. Correctness does not depend on that rule holding (the apply is idempotent and the cursor monotone), but the rule removes the contention.

**What coalescing alone deletes, with no feature code touched:** the unconditional 5 s `setChatLastRead` (verified at `chat_screen.dart:327, 453, 492, 497, 536`) becomes one ack per actual watermark movement; typing leaves Postgres entirely (SESSION class); the 15 s location loop reads its mode from the local DB and writes only on label change; presence becomes ~6 anchor writes per 30-minute session against ~540 today.

---

## F. Optimistic UI and reconciliation

**Send** (messaging.md's sequence, and the ordering is the point):
1. mint `client_msg_id`;
2. **one local transaction**: message row (`cseq` null, `sync_state='pending'`) + outbox row (`QUEUED`);
3. **only then** render the bubble.

That ordering is what makes "on screen but never sent" unrepresentable. Today `chat_screen.dart:125-129` renders the bubble, broadcasts it to the partner's screen, and then swallows the insert failure in a bare `catch (_)` with the comment *"it's already on screen; the DB retry isn't worth blocking"* — three independently reachable states, one of which is a message both people have seen that exists in no database.

4. drainer uploads media if any, writes `media_remote_path` back, commits — a retry past this point does not re-upload;
5. drainer calls `send_message` with a 15 s deadline;
6. on **any** success including `deduped: true`, one transaction writes the server id and position into the row and deletes the outbox row.

**Receive.** The server echo arrives through catch-up, never through a broadcast payload, and upserts on the same key. The sender ignores its own echo. This kills the confirmed video-duplicate bug (`ChatSendQueue._enqueue` passes `id: null` for video, so Postgres mints a different uuid and the sender gets two bubbles, one dead) by making a client id mandatory for every kind.

**Field updates.** The read model returns `pending_patch` over the base row; incoming server values for patched fields are discarded while the patch is unacked — Figma's rule, because the unacked local value is the best prediction of the eventually-consistent value. No toggle flickers back.

**Ticks** are a pure function of three integers, not stored: for message position `S` and the partner's `(delivered D, read R)` — `S null` → PENDING, `S > D` → SENT, `D ≥ S > R` → DELIVERED, `R ≥ S` → SEEN. No timer, no latch, no per-message row.

---

## G. Error doctrine — four classes, enforced by a ratchet

**176 `catch (_)` sites in `lib/`, 68 of them completely empty** (verified this session). You do not fix that by auditing it.

1. **ABSORB-AND-RECORD.** Cosmetic enrichment with a correct empty state: geocode label, RSS cover, GIPHY search, map tiles. Written to `ui_error_log`; the UI renders the *degraded* state explicitly ("location unavailable"), never the stale-but-plausible one. Never `catch (_) {}`.
2. **QUEUE-AND-PERSIST.** Everything that mutates shared state. Never surfaced at failure time; surfaced as a **row state**. Screens cannot catch these because screens do not issue them.
3. **HALT-AND-SHOW.** Exactly four cases, all requiring the user to change something: auth invalid; RLS denial on a user-initiated op; schema/contract mismatch (today `reply_to_id`, `voice_path` and `video_path` have no migration at all, so replies, voice and video fail silently on any fresh environment); upload quota or size rejection.
4. **EXPIRE-SILENTLY.** SESSION class only. Failure means *the interaction did not happen*. Never retried, never persisted, never surfaced — but **counted**, so "typing never shows up" is a number rather than a rumour.

**Enforcement is a ratchet, not a flag day.** A `Result<T>` at the boundaries the engine owns (not every repository signature in the app), plus custom lints banning bare `catch (_)` outside `lib/core/errors/` and `_c.from(...)` outside `lib/data/remote/`. Both ship on day one **as errors, with a seeded per-directory allowlist containing every current offender**. Any *new* offender is red immediately. One allowlist entry is deleted per collection-migration PR, so the cleanup inherits that work's natural sequencing instead of colliding with it in a rebase.

---

## H. Navigation and onboarding — no dead ends

Today `router.dart` computes `needsCouple = session.couple == null` and force-redirects to `/couple`. `null` means *both* "not paired" and "we could not find out" — so a single transient failure of the `couples` SELECT inside `loadProfile`'s fan-out funnels a fully paired user into onboarding. `session.loading → return null` means "stay wherever you are", so a wedged load is a wedged screen. Each escape hatch was retrofitted after it stranded someone: `/couple` has sign-out in the corner, `/role-setup` reveals it only *after a save fails*, `/welcome` has none.

Four rules:

1. **The funnel reads local `funnel_state`, never a live query, and every field is three-valued.** A failed fetch writes nothing. `unknown` **never redirects**. Absence of fresh data is structurally incapable of being read as absence of a couple.
2. **Funnel state is written by one authoritative response.** `session_bootstrap()` — a single `SECURITY DEFINER` RPC returning `{profile_complete, paired, role_set, client_flags, min_client_build}` — replaces the five-round-trip fan-out. One response, one transaction, one generation number. Partial knowledge is not writable.
3. **Every funnel state renders three exits: forward, sign-out, back.** Made structural, not conventional: the funnel is an enum, the route table is a total function from that enum to a `FunnelScaffold` whose constructor *requires* an exits record, and a new state without a case does not compile. A widget test enumerates the enum and asserts a sign-out affordance is findable in every state — exhaustive over the type, so a new state cannot be added without one.
4. **Unreachable-backend is its own screen, not a spinner.** When `funnel_state` is `unknown` and there is prior state, render the last-known route with a non-blocking banner. When there is no prior state at all (fresh install, no network), render `Blocked(reason, retry, sign out)`. `loading → return null` is deleted.

Plus: the unvalidated `?redirect=` passthrough to `context.go` is removed — deep-link intent is a **persisted enum** in `pending_entry_intent`, not a string, so a route that does not exist in the enum is unrepresentable. Persisting it in SQLite is also what fixes recovery cold-start, which today is a `ValueNotifier` consumed on first read and therefore lost when the disguise cover unmounts the tree.

---

## I. Pagination

**No remote read without an explicit page size.** The repository wrapper requires a `Page` argument, so an unbounded select does not compile. Today: **52 `.select(` call sites and 9 `.limit(` call sites** (verified) — 43 unbounded reads, several re-running in full on every realtime event.

- Chat is `ListView.builder(reverse: true)` over a **keyset local query** (`cseq < anchor limit 60`). Scroll-back reads locally first and only enqueues `fetch_history(before_cseq)` when the local store lacks the range. Infinite history for less network than today's ceiling.
- Today's initial load is `.order('created_at', descending).limit(300)` (verified at `chat_repository.dart:209-210`) — both the 300-row ceiling *and* a `created_at` ordering on a column the client can set. Both die here.
- **No column over ~4 KB is selected by a list query.** Blobs are a separate by-id fetch with their own local cache table.
- `Expanded(child: bodies[bodyIndex])` at `app_shell.dart:240` becomes an `IndexedStack`, so a tab switch stops disposing ChatScreen, tearing down three channels and refetching 300 rows.

---

## J. Image decode, decryption and caching

Reconciled with `revised/crypto.md`, which changes the answer materially: **object bytes are XChaCha20-Poly1305 under a per-object DEK, so there is no server-side transform and no derivative endpoint.** The v1 plan's "upload a ≤512 px thumb alongside the original, server-side" is withdrawn.

1. **Thumbnails are first-class client-generated objects** (crypto.md): a 256 px long-edge thumbnail is produced at write time with its own DEK, its own object and its own ledger row. Lists fetch thumbnails; only the viewer fetches originals. This is still the largest egress lever in the app; it now costs double object count, which crypto.md prices.
2. **Poly1305 forbids range requests and progressive decode** — the whole object must land and authenticate before any byte is trusted. So the memory peak is `ciphertext + plaintext + decoded RGBA`, and on the IN2015 that is the binding constraint, not the bill. Decrypt runs on a **long-lived** isolate (spawn + copy per call costs more than the work), never on the UI isolate, and the viewer holds exactly one original decoded at a time.
3. **Three decode tiers chosen by the widget's box in device pixels, never by the source.** Decode and cache cost are functions of decoded pixels: a 4000×3000 JPEG is ~48 MB of RGBA regardless of the 220 dp box it is drawn in.
4. Every remote image goes through one `NetImage` choke point; `Image.network` is lint-banned outside `lib/core/widgets/` (**9 raw `Image.network(` sites today**, verified, and `media_viewer.dart` uses it on full-resolution originals); `cacheWidth` is required on `Image.file`.
5. **A URL is never a capability.** Local rows store an opaque object id; the choke point resolves id → bytes under RLS. This is the client half of crypto.md's rule and it is why the `couple_media` bucket's permanent unauthenticated URLs keyed by a guessable couple UUID stop being a client-side leak — the client stops storing and passing URLs at all. Making the bucket private is the data domain's to ship.
6. `ImageCache.maximumSizeBytes` → **48 MB** on devices reporting < 4 GB RAM. The default is 1000 images / 100 MB, a plausible OOM on exactly the IN2015 / Vivo / OnePlus 7 test set. `clear()` does not evict *live* images; `clearLiveImages()` on media-route disposal is the only correct eviction point.
7. Bubbles must not trigger `saveLayer` — `borderRadius` on the decoration, not `ClipRRect(Clip.antiAliasWithSaveLayer)`; alpha baked into the colour, not `Opacity`.

---

## K. Smoothness budget

p95, **profile mode, physical OnePlus 7, cold image cache, network stack stubbed to throw**. Platform floor is ~16 ms/frame at 60 Hz (~8 ms UI + ~8 ms raster); < 8 ms total at 120 Hz.

| Interaction | Budget | Measured as |
|---|---|---|
| Keystroke → glyph | 16 ms | `FrameTiming.totalSpan` p95 during a scripted 40-keystroke burst |
| Tap Send → bubble visible | **≤ 50 ms, network-independent** | `TimelineTask` span, tap to first frame containing the bubble |
| Open Chat → first paint of last screenful | ≤ 120 ms | route-push to first non-placeholder frame |
| Tab switch | ≤ 100 ms, **zero channel churn** | span + an assertion of zero `.channel(` calls during the transition |
| Scroll 5,000-message chat | ≥ 58 fps, **zero frames > 32 ms** | `TimelineSummary` over a scripted fling |
| Shutter → bubble | ≤ 250 ms (already achieved; must not regress) | span |
| Cold start → interactive Home | ≤ 900 ms **on local data** | first frame after `runApp` that accepts input |
| Any user-initiated network action | **0 ms of UI blocking** | assertion: no `await` of a network call on the build path |
| Catch-up after 8 h offline | ≤ 3 s to caught-up on a 3G latency profile | simulator, not a device |
| Bootstrap after reinstall, 6,000 messages | **first screenful ≤ 1.5 s; never a loop** | simulator; asserts exactly one `sync_bootstrap` call |

The non-negotiable: **p95 of "action → visible result" is independent of network RTT for every action with a local representation.** It is the only budget that survives a tunnel, and it is the one the current architecture cannot meet at any percentile.

---

## L. Measurement plan

There are **zero** `addTimingsCallback` / `FrameTiming` references in `lib/` today (verified). Nothing measures anything, which is why "it feels smoother" has been the evidence.

- `SchedulerBinding.instance.addTimingsCallback` (supports multiple listeners, unlike `PlatformDispatcher.onReportTimings`) buckets `totalSpan` / `buildDuration` / `rasterDuration` / `vsyncOverhead` per route and phase into `frame_stats`: p50/p95/p99, jank ratio (> 16 ms), severe ratio (> 32 ms). One row per route per bucket, shipped through the `telemetry` outbox lane — bounded ring, drop-oldest, loss acceptable and stated. Profile and release only; debug numbers are documented as non-comparable.
- Every budgeted interaction and **every sync phase** (drain, fetch, apply, decrypt, decode) gets a `dart:developer` `TimelineTask` span, so sync work appears on the same timeline as the frames it janks.
- Lab: `flutter run --profile` on a physical device. Rebuild Stats finds `setState` scoped too high — `chat_screen.dart` is **2,118 lines with 32 `setState` calls** (verified), so any state change rebuilds the whole screen. Track Layouts for intrinsic passes (two layout passes, polling all cells). `checkerboardOffscreenLayers` for `saveLayer`. Raster Stats for per-layer cost. **22 non-lazy `ListView(` against 6 `ListView.builder`** (verified) is the first list to fix.
- **CI frame gate**: `flutter drive` on **one** physical device, offline, scrolling a seeded 5,000-message local DB, asserting `TimelineSummary` build and raster percentiles against the table above. Numbers committed and diffed per PR.
- **Field telemetry lands at stage C4, not last.** This app is sideloaded behind a disguised launcher with no store channel; a bad stage cannot be pulled back. Knowing the failure rate is worth more here than anywhere else, and it is the only thing that will ever see a captive portal, a Doze window or an OEM background kill.

---

## M. Isolates and the single-writer question

The FCM background isolate has separate globals and cannot see any in-memory guard. The v1 design's answer was a lock. The answer here is stronger: **make the writes safe rather than making the writers exclusive.** The apply is idempotent on the natural key, the cursor advance is a single guarded conditional update, and the outbox dedups server-side on `client_msg_id`. Two writers in any interleaving converge to rows-union and token-max. A lease would additionally require a process-shared monotonic clock from an isolate that cannot host a platform listener, and would make correctness depend on the lease being taken rather than on the data being safe.

The operational rule remains: **the background isolate posts the notification and writes a `sync_due` marker; the main isolate applies.** That is for SQLite contention, not for correctness — so if the rule is violated by a future contributor, the result is a busy-timeout retry, not silent loss.

Heavy work off the UI isolate, on **long-lived** isolates (spawn plus argument copy per call exceeds the work for anything repeated): object decrypt, thumbnail encode, and any Closer/Vault crypto.

## Invariants
- NO POSITION IS EVER MINTED, COMPUTED, MAXIMISED OR COMPARED BY THE CLIENT. The read position is an opaque server-minted token (messaging.md's HMAC over (key_version, couple_id, user_id, covered_through)) or a server-allocated couple_stream.pos. A token for position N is obtainable ONLY by presenting a token for some M <= N and being served every existing row in (M, N] in that same response. ENFORCED SERVER-SIDE: no RPC mints a token for a position without serving the complete interval up to it, and no RPC accepts a bigint position naming a read location. ENFORCED BY CONSTRUCTION CLIENT-SIDE: the sync engine's public API has no method taking a bigint position, and chat_screen.dart:343-344's `_maxSeq` fold, fetchSince(couple, _maxSeq) at :372 and ackDelivered(_maxSeq) at :379 have no replacement expression.
- POSITION ORDER IS COMMIT ORDER, AND ALLOCATION IS UNBYPASSABLE. Every position is allocated while holding an exclusive row lock on that couple's counter row, taken before any other work and held to COMMIT, so a reader observing position N is guaranteed every issued position below N is already visible. ENFORCED SERVER-SIDE by Postgres row locking plus a CI assertion that every streamed table has an append trigger and a NOT NULL position column. This is precisely the property messages.seq cannot have: receipts_v2.sql:31 is one GLOBAL nextval for the whole project, non-transactional, so 105 becomes visible before 104 commits.
- COVERAGE IS SERVER-DECLARED; THE CLIENT NEVER INFERS WHAT IT MISSED. Every sync response declares the half-open interval of issued positions it covered and the count of rows existing inside it. The client merges the INTERVAL, not the positions of the rows it received. `has_more` is `stream_last_pos > covered_through`, a server fact, never `count == limit`. ENFORCED SERVER-SIDE: the interval and the count are computed in the same query that returns the rows.
- THE CURSOR ADVANCE AND THE ROWS IT DESCRIBES COMMIT IN ONE LOCAL TRANSACTION, FAIL-CLOSED. The transaction refuses to commit the token unless the count of stored rows inside the declared interval equals the server's rows_in_range. A crash between fetch and apply replays the range and can never skip it; a page the client failed to store cannot advance any watermark. ENFORCED BY CONSTRUCTION: there is no API surface permitting cursor-then-apply, so the classic data-loss bug is not reintroducible by a future contributor. (The count check is stated as a client guard, because the server cannot verify what a client stored.)
- A LOCAL ROW IS DELETED ONLY BY AN APPLIED STREAM OP; ABSENCE IS EVIDENCE OF NOTHING. Every removal or mutation consumes a position: per-row deletes append op='delete', the bulk purge appends exactly one op='purge' with the per-row trigger suppressed by a transaction-local flag, and clear_conversation_everyone() allocates a kind='clear' control row carrying clear_through_cseq BEFORE it hard-deletes. ENFORCED SERVER-SIDE by trigger and RPC shape. ENFORCED BY CONSTRUCTION CLIENT-SIDE: the engine has no diff function and no code path from 'not present in this page' to a local delete. A stream position survives its entity; a range read that joins to a missing entity advances anyway.
- BOOTSTRAP AND BAILOUT ARE SERVER-DECLARED, NEVER CLIENT-COUNTED. sync_bootstrap() decides newest-first versus forward-from-watermark and sets install_floor; 'too far behind' is a server resync_required when the presented cursor precedes floor_pos. ENFORCED SERVER-SIDE. A page cap exists only as a UI yield point and has no side effect, so no client page count can trigger a wipe. Backfill runs through fetch_history(before_pos, limit), which MINTS NO TOKEN and is therefore structurally incapable of moving a watermark.
- A RESYNC NEVER DELETES BEFORE IT HAS THE REPLACEMENT. Recovery fetches the replacement page first, then in ONE transaction installs the new floor and token and marks rows below the floor `unverified`. There is no reachable state in which the app has destroyed local history and not yet acquired what replaces it. ENFORCED BY CONSTRUCTION: the transaction boundary.
- NO DURABLE COLLECTION IS SYNCED BY A TIMESTAMP, AND NO CLOCK ENTERS ANY CONTROL DECISION. Postgres now() is transaction-start time, identical for every statement in a transaction and not monotonic across overlapping transactions, so a (updated_at, id) keyset skips rows exactly as nextval does. There is no LWW-with-timestamp-cursor class in this design. created_at is display-only and is never ordered on, compared, or used as an inequality operand — which is also forced by the fact that messages.created_at is client-settable today. Freshness is a server-computed AGE rendered against a monotonic Stopwatch; ordering is position; expiry is a server predicate. ENFORCED BY CONSTRUCTION plus a CI clock-hostility test that fails the build on any DateTime.now() comparison outside one whitelisted call site (presence.md's coarse cold-start cache bucket).
- THE OUTBOX HAS NO TIMESTAMP COLUMN OF ANY KIND, AND NO OP EXPIRES. `attempts` is the only persisted scheduling state; backoff is measured on a Stopwatch from process start; every row is immediately due after restart; there is no lifespan and no expiry transition. ENFORCED BY CONSTRUCTION: the schema has no such column, so `now > expires_at -> failed_permanent` is not expressible. A phone whose RTC resets to the ROM build date behaves identically to a correct one.
- THE ENTITY ROW AND ITS OUTBOX ROW ARE WRITTEN IN ONE LOCAL TRANSACTION, AND THE UI RENDERS ONLY AFTER IT COMMITS. There is no observable state in which the user sees a message nothing is responsible for sending, nor one queued that the UI does not show. ENFORCED BY CONSTRUCTION: the transaction boundary precedes the render. This replaces chat_screen.dart:101-130, where render, partner broadcast and DB insert are three independently reachable states and the insert failure is swallowed by a bare catch (_).
- EVERY MUTATION CARRIES A CLIENT UUID MINTED BEFORE THE FIRST NETWORK ATTEMPT, AND EVERY SERVER WRITE RETURNS THE AUTHORITATIVE ROW ON EVERY ATTEMPT INCLUDING A DUPLICATE. send_message returns {id, cseq, deduped} whether it inserted or matched; `on conflict do nothing returning *` — which returns zero rows and makes an ambiguous timeout unrepresentable — appears nowhere. ENFORCED SERVER-SIDE by unique(couple_id, sender_id, client_msg_id) and the RPC contract. A retry after a lost response cannot create a twin and cannot be mistaken for a failure.
- ORDERING IS PRESERVED WHERE IT IS OBSERVABLE, AND HEAD-OF-LINE BLOCKING IS SCOPED BY LANE. chat:text and chat:media are separate serial lanes drained in parallel; a stuck 30 MB upload cannot delay a subsequent text. ENFORCED BY CONSTRUCTION: the lane is a column on the outbox row assigned by the kind, not chosen by the caller.
- NOTHING ARRIVING OVER A CHANNEL IS EVER STORED, AND A DOORBELL MAY ONLY SET A DIRTY BIT. Realtime and FCM payloads are contentless signals ({stream, pos, entity_id} / {t, cid, w, rid}); the sole writer of entity rows is a response to a request this client issued with its own JWT. A dropped, duplicated, reordered, replayed, absurd or FORGED frame costs at most one redundant query. ENFORCED SERVER-SIDE by transport.md's cs: topic having a SELECT policy and deliberately no INSERT policy; ENFORCED BY CONSTRUCTION CLIENT-SIDE because a token bucket independent of arrival rate caps catch-ups per stream per interval, so the property survives even if that policy is later misconfigured.
- A TERMINAL FAILURE IS A PERSISTED ROW STATE, NOT AN EXCEPTION, A TOAST OR AN IN-MEMORY FLAG. The three states {pending, committed, blocked} are exhaustive and stored on the row the UI is already bound to, so a failure survives process death and is rendered by the query the user was already looking at. ENFORCED BY CONSTRUCTION: sync_state is a column, and lints ban bare catch (_) outside lib/core/errors/ and _c.from(...) outside lib/data/remote/, shipped as errors on day one with a seeded allowlist that only ever shrinks.
- NO SCREEN MAY ISSUE A NETWORK REQUEST. Screens read local streams and enqueue ops. Therefore no screen can own a spinner whose end condition is a network response, and 'works offline' is not a per-screen feature — it is the only thing that compiles. ENFORCED BY CONSTRUCTION via the _c.from lint plus a golden-fixture suite that renders every screen with the network stack stubbed to throw on every call.
- EVERY REMOTE READ IS BOUNDED BY AN EXPLICIT PAGE SIZE AT THE REPOSITORY BOUNDARY. An unbounded select does not compile, because the wrapper requires a Page argument. Response size is independent of account age. ENFORCED BY CONSTRUCTION: the type signature. 43 of the 52 current .select( sites are unbounded.
- EVERY IMAGE DECODE IS BOUNDED BY THE WIDGET'S BOX IN DEVICE PIXELS, NEVER BY THE SOURCE'S DIMENSIONS, AND A URL IS NEVER A CAPABILITY. Lists fetch client-generated 256px thumbnail objects; originals are decoded one at a time in the viewer only; decrypt runs on a long-lived isolate. Local rows store opaque object ids, never URLs, and one choke point resolves id to bytes under RLS. ENFORCED BY CONSTRUCTION: Image.network is lint-banned outside lib/core/widgets/ and the upload/download choke point is CI-grep-asserted to be the only caller of storage.from(...).
- EVERY FUNNEL STATE RENDERS AT LEAST ONE EXIT THAT DOES NOT DEPEND ON A SUCCESSFUL BACKEND CALL, AND ABSENCE OF DATA NEVER REDIRECTS. Funnel facts are three-valued (yes/no/unknown), written only by one authoritative session_bootstrap() response, never by a failed fetch; `unknown` never redirects and `loading -> stay put` is deleted in favour of an explicit Blocked screen. ENFORCED BY CONSTRUCTION: the funnel is an enum, the route table is a total function from it to a FunnelScaffold whose constructor requires an exits record, so a state without an exit does not compile — plus a widget test exhaustive over the enum. Deep-link intent is a persisted enum, not a string, so the unvalidated ?redirect= passthrough is unrepresentable.
- TWO WRITERS ARE SAFE WITHOUT A LEASE. Received rows insert idempotently on the natural key, the cursor advances by one guarded conditional update, and sends dedup server-side on client_msg_id — so the FCM background isolate and the UI isolate converge to rows-union and token-max in any interleaving. ENFORCED BY CONSTRUCTION: there is no read-modify-write anywhere in the apply path. The main-isolate-only drain rule exists for SQLite contention, not correctness, so violating it costs a busy-timeout retry rather than silent loss.
- CONNECTIVITY DECIDES ONLY WHEN THE DRAINER WAKES, AND BACKOFF RESETS ONLY ON A SUCCESSFUL RESPONSE. Connectivity is never a precondition for issuing a request — the authority on reachability is a request that returned or timed out, per connectivity_plus' own README. Resetting backoff on a connectivity event would put every device leaving one tunnel on attempt 0 in the same second. ENFORCED BY CONSTRUCTION: the reset is written in the response handler and nowhere else.

## Scale ceiling
**1,000 users (~100-150 concurrent). The client is unstressed and the change is subtractive.** Read load collapses: 300 rows per tab switch becomes zero (`IndexedStack` plus local reads), the 15 s presence poll becomes one `presence_bootstrap()` per resume, the unconditional 5 s `setChatLastRead` becomes one ack per actual watermark movement. Local DB is a few MB. No client-side ceiling. The binding constraint is server-side and is documented by the transport and presence domains — presence heartbeats alone consume the Free tier's entire 2M monthly realtime allowance at about 11 users today.

**10,000 users (~800-1,500 concurrent). Client architecture holds; two things bend.**
- *Correlated resume.* Every commute ends at 08:40; every device wakes, wants a catch-up and a channel re-subscribe. Supabase's channel-join ceiling is 100/s Free, 500/s Pro, and it **refuses** (`too_many_joins`) rather than queues. Mitigations are in the design — Full Jitter on the drain timer, server-supplied `join_budget_ms` stagger, one coalesced catch-up per stream — and their absence is the specific regression to test for. *Failure mode if the jitter is wrong:* "realtime silently stopped working at 08:40", which is exactly the bug class this design exists to delete, self-inflicted.
- *Bootstrap concurrency.* Reinstalls and new pairings now do a bounded newest-first page instead of an unbounded forward walk, so the per-event cost is one page rather than minutes. This is the change that turns bootstrap from a load-shaped problem into a constant.

Local DB ~30 MB. **The connection cap should be stated plainly rather than as a line item:** Pro-without-spend-cap is a hard **10,000 concurrent connections**. That is a wall, not a bill. What this design contributes is that hitting it is a **latency** ceiling and not a correctness one — transport.md's invariant that the socket has no authority means every position is reachable over plain HTTP via `sync_head` plus a range read, and FCM drives the same path. A user who cannot get a socket still gets every message, late.

**100,000 users (~8,000 concurrent). Two real client ceilings, both media.**
- *Egress and memory, together.* crypto.md makes every object ciphertext under a per-object DEK, which removes server-side transforms entirely — there is no derivative endpoint to lean on. The lever is the client-generated 256 px thumbnail as a first-class object, which cuts list-scroll bytes by roughly an order of magnitude and **doubles object count**. Poly1305 also forbids range requests and progressive decode, so the whole object must land and authenticate before a byte is trusted: peak memory is ciphertext + plaintext + decoded RGBA. *Failure mode:* on the IN2015 the viewer OOMs on large originals before the bill notices. The mitigation is one original decoded at a time plus the 48 MB `ImageCache` cap, and it needs measuring on that device specifically, not asserted.
- *Local storage.* The client breaks when per-user local data exceeds what a mid-range phone can index — order 10^6 rows or a few GB. The answer is time-windowed local retention (90 days hot, older served by `fetch_history` on demand), which is a bounded change to the pagination layer because backfill already mints no token and already has its own path. Not a redesign.

**Where the client genuinely breaks first, honestly: neither of the above.** It breaks at the point where a single SQLite writer plus decrypt plus decode cannot keep the apply path off the frame budget on the slowest device in the test set — a *device* ceiling reached at user count 2. Everything above is server-side or years away. **The client's near-term job is to stop manufacturing server load**, and that is where its value is, not in its own headroom.

## Cost
**Direct new service cost: $0.** drift + `sqlite3_flutter_libs`, `connectivity_plus` and `cached_network_image` (already a direct dependency at ^3.4.1) are free packages. APK grows ~1.5 MB from bundled SQLite, +~2 MB if SQLCipher is adopted. PowerSync is rejected below and is the only paid alternative.

**Savings — restated honestly, because the v1 numbers contradicted themselves.**

The v1 design claimed "realistic post-change volume is under 2,000 messages/user/month" while simultaneously recommending that Heartbeat and Watch-Together be kept. Those cannot both be true. Arithmetic, using presence.md's `self: false` (so a broadcast bills 1 send + 1 receiver = 2):

- **Heartbeat/PPG: 70-90 broadcasts per user per *minute*.** At 80/min × 2 billable × 10 minutes of use per day = **48,000 billable messages per user per month** from one feature.
- **Watch-Together: 24/min**, same shape, ~14,400/user/month at 10 min/day.
- **All of chat**, at 50 messages/day, is 1 hint to 1 recipient = 2 billable × 50 × 30 = **3,000/user/month.**

So heartbeat at ten minutes a day is roughly **sixteen times the entire chat volume**. The correct statement is therefore: *the client design removes the presence, typing and read-ack amplification — transport.md's ~180× reduction on the largest line — and it does not touch heartbeat or watch-together at all.* Those two are a product decision with a price tag, and pretending otherwise is how a cost model becomes fiction.

**Post-change, excluding the two ephemeral features:**
- *1,000 users.* Phase-1 baseline ≈ $58/mo (Pro $25 + ~$33 realtime overage). Removing presence-as-payload, typing-as-DB-write, the unconditional 5 s read-ack, the 15 s presence poll and the 15 s location SELECT lands at ≈ **$25-35/mo**. Saving ≈ $25-30/mo. **With heartbeat left as-is and used ten minutes a day by half the base, add roughly $60/mo** and the saving is erased. That is the number the product call is about.
- *10,000 users.* ≈ **$60-110/mo** against ~$150-200 unreduced. Saving ≈ $90/mo, and more valuable than the money: it delays the moment the 500-connection Pro cap forces a plan decision.
- *100,000 users.* Media dominates. Phase-1 estimates ~2 TB mostly-uncached egress at $0.09/GB over the 250 GB Pro allowance = **$157.50/mo**, plus storage accrual. Client-generated thumbnails cut list-scroll egress by roughly an order of magnitude — conservatively **$80-110/mo removed** — but crypto.md's encryption doubles object *count* and adds ~12% PADMÉ padding, which partly offsets it. Net: call it **$60-90/mo removed**, not $110, and say so.

**Engineering cost — the real number.** research/mobile.md's ~600-line estimate is for a chat-only engine. This one is generic across ~15 collections and includes four data classes, the error doctrine, the funnel machine, pagination, the image pipeline and telemetry:
- sync engine + outbox + drainer + apply, generic: **1,400-1,800 lines, 3-4 weeks** including the deterministic test harness
- lint + `Result<T>` at the engine boundaries, shipped as a seeded ratchet: **4 days**, then one allowlist entry per subsequent PR (not a parallel 3-day task — the v1 plan's estimate was wrong by an order of magnitude and collided with the steps rewriting the same 30 files)
- navigation/onboarding machine + `session_bootstrap()`: **5 days**
- measurement harness + CI frame gate: **1 week**
- per-collection migrations: **1-2 weeks**, repeating template, the safest work to hand off
- image/decrypt pipeline reconciled with crypto.md: **1 week**

**Total: 8-10 weeks of one engineer**, staged so something ships every week. That is two to four weeks more than the v1 estimate, and the difference is honest: the ratchet, the funnel machine and the crypto-reconciled media path were all under-costed.

**Cost of doing nothing, in money.** All of the above forgone, plus the uncapped line: a permanent background rate of silently-lost messages on flaky networks with **zero telemetry** — 176 `catch (_)` sites, 68 of them empty, and no `FrameTiming` anywhere; a support queue generated by a funnel that converts every backend blip into a permanent dead end; and a first launch whose cost grows with account age. The first two do not improve with scale and the third gets linearly worse.

## Migration
Ten stages. Each independently shippable and individually revertible. The local DB is introduced dark and adopted one collection at a time; there is no big-bang, because the highest-risk part is a new persistence layer in a 91-module app.

**Stage D0 — external, owned by the data domain, blocking from C3 onward.**
`supabase/migrations/` + `config.toml` (neither exists today, verified), a staging project, and a written revert for every migration. Also: the DDL that is missing entirely — `care_nudges`, `cycle_settings`, `cycle_events`, `love_reasons`, the three undeclared buckets, and `reply_to_id` / `voice_path` / `video_path`, which have no migration at all, so replies, voice and video fail silently on any fresh environment. Also: the CI assertion that catches `hardening_2026_08.sql:35-46` — a column list computed from `information_schema` at apply time and frozen by `pg_dump`, so the next `ADD COLUMN` yields a column `authenticated` cannot UPDATE (this has already produced one production dead end with `gender`/`gender_set`). The client cannot ship this and must not pretend to. **Gate:** `supabase db reset` on a clean container reproduces the app, and the client golden-fixture suite runs green against it.

**Stage C0 — the kill switch and the version floor. Server-only SQL, zero client risk. Ship first.**
`app_runtime_config` (presence.md's table) gains `client_flags jsonb` and `min_client_build int`, read over plain HTTP at boot and on resume, absent = safe path. Every later client stage is gated on a flag. This is the cheapest insurance in the plan and it was an open decision in v1 — which is not good enough for a sideloaded app with a disguised launcher and no update channel, where "revert" otherwise means rebuilding an APK and getting it onto each device by hand.

**Stage C1 — server-side positions and idempotent writes. Server-only, invisible to clients.**
The per-couple counter under a row lock (`chat_streams` / `couple_cursor`), position triggers on every streamed table, `send_message` / `sync_bootstrap` / `sync_messages` / `fetch_history` / `ack_receipts` / `session_bootstrap` / `stream_digest`, `clear_conversation_everyone()` rewritten to allocate a `clear` control position before deleting, per-row deletes appending `op='delete'`, and the bulk purge suppressing the per-row trigger. `cs:` made private with no client INSERT policy. **This stage closes fatal flaws 1, 2 and 4 server-side before any client change exists that could depend on them.** Existing clients keep using `seq` and are unaffected. **Gate for every later stage: this must be live in production, not merely in a migration file.**

**Stage C2 — local DB exists, nothing depends on it.**
Add drift; define `outbox`, `stream_cursor`, `held_ranges`, entity mirrors and the meta tables. Ship a **shadow writer**: existing paths keep working, the local DB is populated in parallel and compared, discrepancies logged. Zero user-visible change. De-risks the schema, the codegen and the migration machinery. The at-rest-encryption decision is made *before* this stage, because retrofitting SQLCipher is a forced full re-bootstrap for every installed device.

**Stage C3 — chat SEND moves to the outbox. First user-visible win.**
Delete `chat_screen.dart:125-129`'s `try { await sendText } catch (_) {}` and the pre-insert `sendBroadcastMessage`. All four kinds enqueue through one path with a mandatory client id, killing the `id: null` video-duplicate bug. The RAM-only `ChatSendQueue` is replaced and its pending file moved into the durable outbox directory. Two lanes from the start (`chat:text`, `chat:media`), so this stage does not introduce the head-of-line regression it exists to fix. Reads still come from the network. **A failed send becomes a failed row with Retry rather than a ghost.** Behind a C0 flag.

**Stage C4 — telemetry. Deliberately early, not last.**
`addTimingsCallback` collector, `frame_stats`, the telemetry outbox lane, outbox failure-rate reporting, and the CI frame gate. It runs before the read path changes so that C5's effect is *measured* rather than asserted, and because with no store channel the blast radius of a bad stage is bounded by manual reinstall — which makes knowing the failure rate worth more here than in any app with an update button. The v1 plan put this last; that was wrong for this distribution model.

**Stage C5 — chat READS move to the local DB.**
ChatScreen binds to a drift stream. `ChatRepository.fetch()`'s `.order('created_at', descending).limit(300)` (`chat_repository.dart:209-210`) and the refetch-per-tab-switch are deleted; `Expanded(child: bodies[bodyIndex])` at `app_shell.dart:240` becomes `IndexedStack`. Catch-up feeds the local DB through `sync_messages`; the doorbell becomes a dirty bit. Keyset pagination and infinite scroll-back via `fetch_history` arrive here. **This stage is refused unless C1 is live in production** — shipping it against the unconverted `nextval` cursor is precisely how three self-healing bugs become permanent ones, because the 300-row refetch is currently the only thing masking them.

**Stage C6 — error doctrine as a ratchet.**
`Result<T>` at the engine boundaries only. Lints banning bare `catch (_)` outside `lib/core/errors/` and `_c.from(...)` outside `lib/data/remote/`, shipped **as errors on day one with a seeded per-directory allowlist containing every current offender**, so any new offender is red immediately. One allowlist entry deleted per Stage C8 PR. This is explicitly **not** parallelisable with C3/C5/C8 as a whole-codebase refactor; the ratchet is what makes it sequenceable at all.

**Stage C7 — navigation and onboarding machine.**
`session_bootstrap()`, three-valued local `funnel_state`, `FunnelScaffold` with required exits, the `Blocked` screen, deletion of `loading -> return null` and of the `?redirect=` passthrough, `pending_entry_intent` as a persisted enum. Genuinely independent of C5 and C8 — it touches `router.dart` and the four funnel screens and nothing else — so this one really can run in parallel.

**Stage C8 — remaining collections, one PR each.**
Presence (adopting presence.md's `presence_session` / `presence_bootstrap()` as SNAPSHOT class), profiles, receipts, reasons, care, capsules, cycle, call signals (STREAM per transport.md §I). Each PR registers a stream or snapshot descriptor and deletes that screen's ad-hoc fetch/subscribe, one `postgres_changes` subscription and one full-table refetch, and one C6 allowlist entry. **This stage adopts presence.md's retirement of the `presence` table and therefore does NOT add the `presence(couple_id, updated_at desc)` index that `design/data.md` still plans** — that index destroys HOT on the most-written table in the app and its bloat outruns autovacuum. The data domain owns the migration and must drop that plan; the client domain states here that it will never issue a query needing it.

**Stage C9 — image and decrypt pipeline.**
`NetImage` choke point, three decode tiers, 48 MB `ImageCache` cap on <4 GB devices, client-generated 256 px thumbnail objects per crypto.md, decrypt on a long-lived isolate, one original decoded at a time, opaque object ids instead of URLs in local rows.

**Ordering rationale, and the bugs each stage must not recreate.** D0 and C0-C1 are pure server prerequisites with no client risk, and C1 exists specifically so that C5 cannot ship the cursor bug. C3 stops the bleeding before C5 optimises. C4 precedes C5 so the effect is measurable and so a bad stage is detectable on devices nobody can reach. C6 is a ratchet, not a flag day, so it cannot recreate the merge-conflict failure the v1 plan's step 5 would have. C7 is genuinely orthogonal. C8 is a repeating template and is the safest work to hand off. C9 is last because its value is only legible once C4 can measure it — and because it is the only stage whose correctness depends on another domain's crypto work landing first.

## Verification
**The premise this replaces:** "we tested it on two NTP-synced phones on one wifi" tests exactly the configuration in which every clock-dependent and socket-dependent bug is invisible. That is why every previous fix passed and then failed in the field. Six layers, **none requiring a second device or a second network**, and every layer runs on a laptop except layers 5 and 6, which need one phone.

**Layer 1 — the sync engine is a pure function of (local state, transport responses, timer ticks), so it unit-tests in plain `dart test`.** No Flutter, no device, no network. A fake transport replays scripted response sequences. Named, required cases:
- duplicate delivery of the same page; pages delivered out of order;
- a page applied and the process killed before the cursor write → assert **replay**, never skip;
- an ambiguous timeout followed by a retry → assert **one** row *and a non-empty response on the retry* (this is the case that `on conflict do nothing returning *` fails, and it must be asserted explicitly, not folded into "assert one row");
- a page whose `rows_in_range` disagrees with what was stored → assert the whole transaction aborts, the token does not commit, and the engine enters STALLED;
- a 500 mid-page; a malformed row in a page → skip-and-continue;
- a cursor preceding `floor_pos` → assert the engine takes the **server's** `resync_required`, and assert that **no page count anywhere can produce the same outcome**;
- a bootstrap against a 6,000-message couple → assert exactly **one** `sync_bootstrap` call, a first screenful from the newest page, and **zero** re-bootstraps. This is fatal flaw 4's regression test and it fires on the developer's own chat, which is already well past 4,000 messages;
- a `clear` control row → assert local rows at or below `clear_through_cseq` are deleted and the floor is raised;
- an `op='delete'` for an entity the client never held → assert it is a no-op that still advances;
- a token expiring mid-catch-up → assert `setAuth` and resume, not a wedged channel (`supabase_client.dart:375-394` silently swallows `FormatException: InvalidJWTToken` exactly in the cold-start window).

**Layer 2 — property/model tests over the outbox and the cursor.** Generate random interleavings of `{enqueue, drain-success, drain-timeout, drain-4xx, process-kill, connectivity-flap, app-upgrade, background-isolate-apply, clock-jump}` and assert: no op lost; no op applied twice; no failed op invisible; no lane reordered; no cursor moving backwards; **no local row deleted without an applied op**; and **a stuck media op never delays a subsequent text op** (a named case, because the v1 invariant list would have let that ship as correct).

**The clock-jump generator is ±10 years and ±1 simulated boot, not ±1 hour.** ±1 h is the magnitude that does *not* find the real bug — a cheap Android losing power and resetting its RTC to the ROM build date. The design's own claim is that this is the one thing two phones can never test, so the generator has to actually generate it. With no timestamp column in the outbox this suite should be trivially green; if it ever goes red, a clock has been reintroduced.

**Layer 3 — a deterministic two-engine simulator, in one process.** Two engine instances against one in-memory fake server with injectable latency, loss, partition, reorder and duplication. Strictly stronger than two phones: one side can be held dark for a simulated week in 200 ms and reruns are byte-identical. Golden assertions:
- A sends 500 messages while B is partitioned; after reconnect B's rows are byte-identical to A's and both cursors agree.
- A calls `clear_conversation_everyone()` while B is partitioned for a week; after reconnect **B's local history is empty**. This is fatal flaw 2's regression test — it is the one the v1 design fails, and it fails silently and forever.
- Two overlapping writes commit in inverted order; assert both are delivered. Fatal flaw 3's regression test.
- The server drops a row outside the stream; assert the **digest** detects it on the next cold start and produces a resync.
- A forged doorbell storm at 4 Hz across every stream; assert the catch-up count is bounded by the token bucket, not by the doorbell rate.

**Layer 4 — local-DB golden fixtures with a hard-fail network stub.** Seed a SQLite file with 5,000 messages, 200 media rows, one BLOCKED op, one `pending_patch` and one range below the floor. Every screen must render it in the lab, at budget, **with the network stack stubbed to throw on every call**. *If any screen renders differently with the network hard-failed, that screen has a network dependency it should not have.* One mechanical test catching the whole class — the 43 unbounded selects, any surviving on-open fetch, and any spinner whose end condition is a response.

Two additions in the same layer:
- **The funnel test is exhaustive over the enum**: for every funnel state, assert a sign-out affordance is findable and that no state redirects when its inputs are `unknown`. Adding a state without an exit fails CI rather than stranding a user.
- **The clock-hostility test** greps for `DateTime.now()` in comparisons and fails on anything outside the one whitelisted call site.

**Layer 5 — the CI frame gate.** `flutter drive` on **one** physical device, offline, scrolling the seeded 5,000-message DB, asserting `TimelineSummary` build and raster percentiles against the smoothness budget. Numbers committed and diffed per PR, so "it feels smoother" is never the evidence. Plus a decode-memory assertion on the IN2015: open the viewer on a full-resolution encrypted original and assert peak RSS stays under the device's headroom — the one budget crypto.md's whole-object-must-land constraint puts at genuine risk.

**Layer 6 — contract tests against staging.** Every server RPC this design depends on, asserted for shape: `sync_bootstrap` never returns a page larger than its declared size; `fetch_history` returns no token field at all; `presence_bootstrap` returns no ISO-8601 string; `send_message` returns a non-empty row on a duplicate. Runs in CI against the staging project from D0. **Until D0 lands, layers 1-3 run and layers 4-6 have nothing real to run against, and every backend change is still validated only in production.** That is the honest status, not a caveat.

**What none of this verifies, stated plainly:** real radio behaviour (captive portals, dying cell handoffs, carrier NAT timeouts), Doze and FCM delivery latency, and OEM background-kill aggressiveness on the Chinese ROMs in the test set. Those are only observable in the field — which is what the C4 telemetry exists for, and why it moved earlier in the plan. The claim is that these become **observable rather than silent**, not that they become testable on a desk.

## Accepted limits
**1. Row loss outside the stream is detectable only by count, not by content.** The coverage digest returns `(rows_present, min_pos, max_pos)` and catches whole rows vanishing without a forward event — a retention reaper, a manual delete, a partial restore. It does **not** catch a substituted, truncated or corrupted body at an unchanged count. WhatsApp's homomorphic LtHash16 would; we have one trusted server and two-person tenants, so we take PowerSync's cheaper answer. **Residual risk: a server-side bug that mutates a row's content without allocating a position is invisible to the client forever.** Closing it costs a per-range content hash on every page, priced at roughly one extra column and a hash computation per row on both sides. Deferred, not solved.

**2. The reconciliation digest has a 24-hour blind window.** It runs once per cold start and at most once per day, because running it per doorbell reintroduces the amplification the design just removed. A row lost outside the stream at 09:00 is invisible until the next cold start. Tightening this trades directly against battery and request volume; the current setting is a judgement, not a proof.

**3. A photo that finally uploads lands after texts composed later.** Splitting `chat:text` from `chat:media` is what stops a 30 MB video holding three texts hostage for hours — but position is assigned at the moment `send_message` returns, so the photo gets a later position than texts sent while it was stuck. The pending bubble renders in composition order and **moves** when it commits. The alternative is head-of-line blocking, which is strictly worse and is the status quo's actual behaviour for media. Stated because a user will notice it and it will look like a bug.

**4. Two SQLite writers are correct but not contention-free.** Idempotent apply plus a monotone cursor makes the FCM background isolate and the UI isolate converge in any interleaving, with no lease. But WAL-mode SQLite still serialises writers, so a background apply during a foreground drain costs a `busy_timeout` retry and, at worst, a frame. The main-isolate-only drain rule is the mitigation. **Residual risk: on a device where the background isolate is doing heavy work during an active chat, apply latency is unbounded by anything except the busy timeout.** No measurement of this exists yet; C4 is what produces one.

**5. The local database holds chat plaintext.** messaging.md is explicit that there is no E2EE for chat, and crypto.md encrypts object bytes and Closer content but not the message mirror. So a SQLite file containing every message sits on a device whose app-lock is an **unsalted SHA-256 of a 4-digit PIN in SharedPreferences** — 10,000 candidates, breakable instantly from any backup or rooted read. SQLCipher with the key in `flutter_secure_storage` raises the bar to "needs the keystore", which on a rooted device or a compromised OEM keystore is not a wall. **Residual risk: physical device compromise reads the conversation regardless.** For an app whose entire premise is concealment this is the single largest unclosed item in the client domain, and it is not closable client-side alone.

**6. The frame budget is asserted on the OnePlus 7 and only measured there.** The IN2015 and the Vivo are in the test set but the CI gate runs one device. Numbers on the other two are field telemetry, not gates. And the media-viewer memory budget under crypto.md's whole-object-must-land constraint may simply not be met on the IN2015 for large originals; the fallback is a hard size ceiling on what the viewer will decode, with an explicit "too large to preview on this device" state. That state is a real product regression and is named rather than hidden.

**7. Revert has no delivery channel.** This is a sideloaded app behind a deliberately disguised launcher with no store presence. `app_runtime_config.client_flags` makes a bad stage a config change *for behaviour the flag gates*, but a crash on boot, a corrupt migration or a bad drift schema is not flag-recoverable — it is a manual reinstall on each device. That is why C0 ships first and C4 (telemetry) ships fifth rather than last. **Residual risk: a bug outside the flag's reach is live until every device is manually updated, and the design cannot fix that; it can only shorten the time to noticing.**

**8. Field conditions remain unverifiable on a desk.** Captive portals, dying cell handoffs, carrier NAT timeouts, Doze wake latency, and OEM background-kill aggressiveness on the Chinese ROMs in the test set. The design's claim is that these become *observable* through telemetry, not that they become testable. Nothing in six verification layers touches a real radio.

**9. Presence's `unknown` state is a deliberate honesty cost.** presence.md's three-valued render means the app now says "last seen 4 minutes ago" with no dot in situations where it previously said "online". Some of those were true. The design accepts showing less rather than claiming more, and users will read it as the feature getting worse.

**10. The rows-in-range check is a client guard, not a server property.** The server cannot verify what a client stored — nothing can. A client that silently fails to persist and also miscounts advances its cursor wrongly. Fail-closed in release builds narrows this to "the local DB lied about its own contents", which is the storage engine failing, but it is stated rather than claimed as server-enforced.

## Open decisions
**1. drift versus raw sqflite. Recommend drift. Decide before C2.** Compile-time-checked queries, first-class `Stream` support — the entire read path depends on it — and transactional migrations. `sqflite` is already present transitively but offers no streams and no migration story, so both would be hand-rolled. Cost: `build_runner` in the toolchain and slower incremental builds.

**2. Local encryption at rest — the highest-stakes item, and it must be decided BEFORE C2.** Retrofitting SQLCipher after the local DB ships is a forced full re-bootstrap for every installed device. *Recommend `sqlcipher_flutter_libs` with the key in `flutter_secure_storage`,* accepting ~2 MB of APK and a small read overhead, and designing the key-loss path (key loss = resync, which the existing recovery mechanism already handles). See accepted_limits 5 for what this does and does not buy. **Owner must decide, not the client design** — it is a product risk judgement about physical-device compromise.

**3. One per-couple counter, or one per stream family? This is a genuine unresolved contradiction between two already-revised siblings.** `revised/transport.md` specifies `couple_cursor.next_pos` with one dense position space per couple covering chat, reach, capsule, call and closer. `revised/messaging.md` specifies `chat_streams.last_seq` with `cseq` scoped to chat, and `revised/push.md` refers to a third name, `couple_seq`. **The client is indifferent to which wins** — it holds a descriptor and a cursor per stream either way, and the generic apply rule is identical. What differs is the number of RPC round trips per catch-up (one range read versus N) and whether a single hot counter row serialises a photo upload against a call signal. **Recommend one counter per couple (transport.md's), because the tenant has two writers at human speed and the serialisation is free; and recommend that the message-specific `cseq` be defined as that same position rather than a second counter.** This needs one owner to arbitrate before C1, and it cannot be arbitrated inside the client domain.

**4. Do Heartbeat/PPG and Watch-Together survive? A product call with a price tag, and it should be made before the 10k-user plan decision, not during it.** Heartbeat is 70-90 broadcasts per user per *minute*; at ten minutes a day that is ~48,000 billable messages per user per month, roughly sixteen times all of chat. Watch-Together adds ~14,400. *Recommend: keep both, hard-rate-limit heartbeat to ≤4 messages/second client-side through transport.md's byte-budgeted send path, and designate heartbeat the first feature cut if the realtime bill bites.* The client design is indifferent — both are SESSION class — but the cost model is not, and the v1 design's headline saving was arithmetically incompatible with keeping them.

**5. How much history to keep locally. Recommend "all of it" for v1** — text plus object ids is tiny, ~30 MB per 100k messages — **with a committed trigger** to add 90-day windowing when p95 local DB size exceeds ~200 MB, measured by C4 telemetry. Deciding this later is cheap; deciding it wrong now is not. Note the change is bounded because backfill already mints no token and already has its own RPC.

**6. Where the coverage digest lives.** It can be a per-stream RPC owned by each domain (messaging exposes `chat_digest`, transport exposes `stream_digest`) or one generic RPC over `couple_stream`. *Recommend the generic one*, contingent on decision 3 landing on a single counter. If decision 3 goes the other way, each domain owes a digest and the client owes a descriptor field.

**7. `app_runtime_config` is per-couple in presence.md. Client staged rollout wants per-device.** A couple-level flag cannot ship C5 to 10% of devices, and `min_client_build` is a floor rather than a target. *Recommend adding a device-scoped overlay table keyed by `(user_id, device_id)` that shadows the couple row, resolved server-side in `session_bootstrap()` so the client sees one merged answer.* Small, but it is the difference between a staged rollout and a coin flip, and this app has no store channel to undo a coin flip.

**8. Whether `messages.created_at` gets a table-level INSERT revoke, and when.** The data domain owns it. The client design makes itself immune by never ordering on or comparing `created_at` — but retention elsewhere keys off it, and a future-dated `created_at` makes a row immortal. **The client domain's position: do not defer this on the grounds that the client no longer depends on it.** Client independence removes one consumer, not the hole.
