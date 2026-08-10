# Client architecture — offline-first data layer, outbox, error doctrine, navigation state machine, pagination, image policy, and the felt-responsiveness budget (Flutter client, E:/LDR/mobile)

## Current design
**There is no local database.** Verified: `pubspec.yaml` lists no drift/isar/hive/objectbox/sembast; `sqflite` appears only transitively (pubspec.lock:1704). Durable client state is `shared_preferences` + `flutter_secure_storage`. The network *is* the model.

**The read path is "fetch on screen open".** `ChatRepository.fetch()` does `.select().order('created_at', desc).limit(300)` on mount (chat_repository.dart:204-220 — verified 300, not 500). There is no pagination, so history older than 300 messages is unreachable in the UI. `app_shell.dart:240` renders `Expanded(child: bodies[bodyIndex])` rather than an `IndexedStack`, so switching tabs **disposes** ChatScreen: three realtime channels are torn down and 300 rows are refetched on every return to Chat. Across the app: **52 `.select(` call sites, 9 `.limit(` call sites** (verified by grep) — 43 unbounded reads, several re-run in full on every realtime event (reasons, care, cycle).

**The write path shows success it has not achieved.** chat_screen.dart:101-130, verified still present on this branch:
```dart
_onIncoming(Message(id: id, ...));                       // bubble on screen
_moodChannel?.sendBroadcastMessage(event:'msg', ...);    // partner's screen
try { await ChatRepository.sendText(...); }
catch (_) { /* it's already on screen; the DB retry isn't worth blocking */ }
```
When the insert fails, the partner has *seen* the message, the sender *sees* the message, and it exists in no database. Both lose it on next launch, with no error at any point. `ChatSendQueue` retries media but is a RAM-only `List<PendingSend>` singleton (chat_send_queue.dart:51) — a background kill mid-upload loses the photo and its temp file with no record. Text and voice bypass the queue entirely.

**Failure is swallowed as a matter of style, not accident.** Verified: **176 `catch (_)` sites in `lib/`, 68 of them completely empty (`catch (_) {}`)**. The presence path alone has 4. `care_screen.dart:93` swallows a failed insert so the nudge silently does nothing.

**The router turns any transient backend failure into a permanent dead end.** router.dart:66-118 (read directly): `needsCouple = session.couple == null` → force `/couple`. A transient failure of the `couples` SELECT inside `loadProfile`'s 5-round-trip fan-out leaves `couple=null`, so a fully paired user is funnelled to onboarding. Each stage's escape hatch was retrofitted after it stranded someone: `/couple` has sign-out in the corner, `/role-setup` reveals sign-out only *after a save fails*, `/welcome` has none at all. `session.loading → return null` means "stay wherever you are", so a wedged load is a wedged screen. `/signin?redirect=` is passed to `context.go` with no allow-list.

**Steady-state cost is polling dressed as realtime.** `PartnerPresenceNotifier` throws away the realtime payload and issues a fresh REST SELECT behind an 800 ms debounce, plus an unconditional 15 s poll. Home runs a 15 s loop = 4 presence SELECTs + 4 UPSERTs + 4 reverse-geocodes per user-minute (rest.md). An open chat writes `ack_read` + `setChatLastRead` every 5 s unconditionally. Heartbeat (PPG) emits 70-90 broadcast messages per user per **minute**. Typing writes a replicated Postgres row *and* broadcasts, for one boolean.

**Nothing measures anything.** Verified: **zero** `addTimingsCallback` / `FrameTiming` references in `lib/`. `chat_screen.dart` is 2,118 lines with 32 `setState` calls, so any state change rebuilds the entire screen. 22 non-lazy `ListView(` vs 6 `ListView.builder`. 9 raw `Image.network(` sites but only 3 `cacheWidth` uses — and `NetImage` (cached_network_image ^3.4.1, which already computes `memCacheWidth = width * devicePixelRatio`) is imported by `chat_screen.dart` and then *not used* for the chat background; `media_viewer.dart` uses raw `Image.network` on full-resolution originals.

**Why it fails at scale:** every one of these is a per-user multiplier. Read load grows with navigation frequency, not usage. Write load grows with keystrokes and timers, not messages. The silent-loss rate grows with network quality, which gets worse as the user base leaves the developer's wifi. And the dead-end funnel converts every backend blip into a support ticket, which is the only cost line with no cap.

## Target architecture
## The one mechanism

**A local SQLite database is the application. The network is a replication detail.** One generic sync engine fills it; one generic outbox drains it. Every screen reads a bounded local stream and writes by enqueueing. No screen may issue a network request. This single shape removes: silent send loss, ghost messages, forged broadcasts, full-table refetch, the 300-row ceiling, tab-switch churn, and the "spinner forever" class — not as five fixes but as one.

## A. Local schema (drift over SQLite; SQLCipher — see open decisions)

**Meta tables**
- `sync_cursor(collection PK, scope_id, cursor_a, cursor_b, generation, bootstrapped_at, last_ok_at, consecutive_failures)` — `cursor_a/b` is opaque: a bigint `seq` for log collections, `(updated_at, id)` for LWW collections.
- `outbox(op_id PK /*client uuid v4*/, kind, queue_key, scope_id, payload_json, created_at, attempt, next_attempt_at, expires_at, status, last_error_code, last_error_at)`; `status ∈ {queued, inflight, done, failed_permanent}`.
- `outbox_blob(op_id PK, local_path, byte_len, sha256)` — the baked JPEG is **moved** into `<appSupport>/outbox/<op_id>.ext` in the same transaction as the outbox row, out of the OS temp dir the cleaner reaps.
- `pending_patch(entity_table, entity_id, field, value_json, op_id, created_at)` — unacknowledged field-level edits.
- `frame_stats(route, phase, hour_bucket, p50, p95, p99, jank_frames, severe_frames, total_frames)`.
- `ui_error_log(id, ts, class, code, detail, op_id?)` — bounded 500-row ring.
- `onboarding_state(has_session, profile_complete, couple_id, role_set, last_verified_at, last_failure_code)`.

**Entity tables** mirror server collections and every one carries `sync_state ∈ {confirmed, pending, failed}` and `op_id`. Status is a column on the row, not an entry in a parallel in-memory list. This is Signal's `onFailure() → markAsSentFailed(messageId)` shape: a terminal failure is a state transition in the DB the UI is already bound to.

## B. Sync engine — one service, two collection classes

**Log collections** (messages; anything append-only). Cursor = server-assigned `seq`. Catch-up: `where couple_id=$1 and seq > $2 order by seq limit 200`, loop until a short page. `seq` must come from an in-transaction per-conversation counter (`update couples set last_seq = last_seq+1 returning`), **not** a Postgres sequence — `nextval` is non-transactional and row 105 can become visible before 104 commits, so a `seq > cursor` reader advances past 104 and loses it permanently (delivery.md; Synapse's published-position rule exists for exactly this).

**LWW collections** (profiles, presence, receipts, reasons, care, capsules, cycle, settings). Requires per-row `updated_at timestamptz` maintained by a BEFORE trigger on the **server** clock, a `deleted_at` tombstone, and an index on `(couple_id, updated_at, id)`. Catch-up: `where couple_id=$1 and (updated_at,id) > ($2,$3) order by updated_at,id limit 200`. Tombstones are mandatory — without them a cursor cannot express a delete and rows resurrect on reinstall.

**A sync round is a checkpoint.** The engine applies a page's rows **and** the cursor advance in ONE drift transaction. The UI never observes a partial round. (PowerSync's checkpoint-boundary rule.)

**Generation / bailout.** Each collection has a `generation`. If the server rejects the cursor as too old, or a coverage probe disagrees, the engine increments `generation`, deletes that collection's local rows, and re-bootstraps. Bounded, and it is a first-class *state*, not an error. (Telegram `differenceTooLong`; PowerSync checksum-mismatch → drop bucket and re-sync.)

**Transport is a doorbell that carries no data.** Realtime broadcast payload is `{collection, scope_id}` and nothing more; FCM data payload is the same, one collapse key per couple per collection (FCM allows max 4 active collapse keys per token, and discards past 100 pending — both become irrelevant when the payload is contentless). On receipt the engine schedules a catch-up. **A peer-writable channel is never a source of rows.** This is what structurally kills the forged-`msg` injection (any client knowing a `couple_id` can today post a fake message that sits at `seq=0` forever) and the ghost-message case, without any validation code.

**Coalescing.** `Map<String, Future<void>>` keyed `collection:scope:cursor`, behind a ~250 ms debounce. `onResume` + connectivity change + socket `onOpen` + FCM arrive within ~200 ms of leaving a tunnel and today produce three or four identical queries; they produce one.

**Backoff.** AWS Full Jitter: `sleep = random(0, min(30_000, 500 * 2^attempt))`. Reset on a **successful response**, never on a connectivity event. Jittered `subscribe()` too — Supabase's channel-join ceiling (100/s Free, 500/s Pro) is what a synchronised commute-end saturates.

## C. Outbox — every mutation, one table, declarative policy

Repositories no longer call PostgREST; they enqueue. Each `kind` declares its policy statically, in Signal's `Job.Parameters` shape:

| kind | queue_key | lifespan | attempts | coalesce |
|---|---|---|---|---|
| `msg.send` | `chat:<couple>` | 24 h | unlimited | append |
| `receipt.read` | `read:<couple>` | 10 m | unlimited | replace-with-greatest |
| `presence.location` | `loc:<uid>` | 30 s | 1 | replace |
| `presence.typing` | `typing:<couple>` | 2 s | 1 | replace |
| `profile.field` | `profile:<uid>:<field>` | 1 h | unlimited | replace |
| `telemetry` | `telemetry` | 7 d | unlimited | append (batched) |

`requires_network` gates the attempt so airplane mode burns no attempts and no radio (Signal's `NetworkConstraint`). `on_permanent_failure` names the row-state transition to apply.

Coalescing alone removes the app's worst write amplification with no feature code changed: the 5 s unconditional `ack_read` becomes "enqueue on visibility change, drop unless the watermark increased" (zero no-op writes by construction); typing's start/stop pair becomes at most one write that self-drops if it can't land in 2 s; the 15 s location loop reads its mode from the *local* DB (−1 round-trip) and drops the write if the position moved less than the accuracy radius.

**Outbox state machine:** `queued —(due & network)→ inflight —2xx→ done` / `—timeout|5xx→ queued(attempt+1, next_attempt_at=jitter)` / `—4xx-permanent | now>expires_at→ failed_permanent` + declared row transition. Draining is serialised per `queue_key`, parallel across keys.

## D. Optimistic UI and reconciliation

- **Inserts**: local row written `sync_state='pending'` with the client uuid. The server echo arrives through the *catch-up* (never through a broadcast payload) and upserts on the same PK → `confirmed`. Same id whichever arrives first, so no twin. This also kills the confirmed video-duplicate bug (`ChatSendQueue._enqueue` passes `id=null` for video and `sendVideo` inserts without one, so Postgres mints a different uuid and the sender gets two bubbles, one dead) — the outbox makes the client id mandatory for every kind, so it cannot be reintroduced.
- **Field updates**: the read model returns `pending_patch` value over the base row. Incoming server values for patched fields are **discarded** while the patch is unacked — Figma's rule verbatim ("the unacked local value is our best prediction of the eventually-consistent value"). No toggle can flicker back.
- **Failure**: `failed_permanent` + row state. The bubble renders failed with Retry; Retry re-arms the same `op_id` with `attempt=0` and a fresh lifespan. Safe because the server insert is idempotent.

## E. Error-handling doctrine — three classes, enforced by a lint

1. **Absorb-and-record.** Cosmetic enrichment with a correct empty state: geocode label, RSS cover feed, GIPHY search, map tiles. Written to `ui_error_log`; the UI renders the *degraded* state explicitly ("location unavailable"), never the stale-but-plausible one. Never `catch (_) {}`.
2. **Retry-and-persist.** Everything that mutates shared state. Never surfaced at failure time; surfaced as a row state after the lifespan expires. Screens *cannot* catch these because screens do not issue them.
3. **Halt-and-show.** Exactly four cases, all requiring the user to change something: auth expired/invalid; RLS denial on a user-initiated op; schema/contract mismatch (today `reply_to_id`/`voice_path`/`video_path` have no migration, so replies, voice and video silently fail to insert on any fresh environment); upload quota/size rejection.

Enforcement is mechanical: a `Result<T>` at the repository boundary plus a custom lint banning bare `catch (_)` outside `lib/core/errors/` and banning `_c.from(...)` outside `lib/data/remote/`. You do not audit 176 catch blocks by hand — you make the shape uncompilable.

## F. Navigation / onboarding state machine — three rules, no dead ends

1. **The funnel reads local `onboarding_state`, never a live query.** A failed fetch writes nothing, so absence-of-fresh-data is never read as absence-of-couple. This alone removes the "transient `couples` SELECT failure funnels a paired user to /couple" trap.
2. **Every state renders three exits, always: forward, sign-out, back.** Owned by one `OnboardingScaffold`, so a screen cannot forget it and no exit is conditional on a prior failure.
3. **Unreachable-backend is its own screen.** When `last_verified_at` is stale and the last N syncs failed, the machine renders `Blocked(reason, retry-in Ns, sign out)` instead of holding the user on a spinner. `loading → return null` (stay put) is deleted.

Plus: remove the unvalidated `?redirect=` passthrough; and persist deep-link entry intent (`pending_entry_intent`) in SQLite so a confirmation/recovery link that cold-starts the app behind the disguise cover still lands on the right route after the gate — today it is a `ValueNotifier` consumed on first read, which is why recovery cold-start is lost.

## G. Pagination

**No remote select without an explicit page size** — the repository wrapper requires a `Page` argument, so unbounded selects do not compile (43 exist today). Chat is `ListView.builder(reverse:true)` over a **keyset** local query (`seq < anchor limit 60`); scroll-back pages locally first and only enqueues a `backfill(before_seq)` sync op when the local store lacks the range — infinite history for less network than today's 300-row ceiling. Catch-up pages at 200 with a hard per-round cap (20 pages) before declaring "too far behind" and re-bootstrapping. **No column over ~4 KB is selected by a list query**; blobs are a separate by-id fetch with their own local cache table.

## H. Image decode / caching policy

1. Every remote image goes through `NetImage`; lint-ban `Image.network` outside `lib/core/widgets/`, require `cacheWidth` on `Image.file`. Decode and cache cost are functions of *decoded pixels*: a 4000×3000 JPEG is ~48 MB RGBA regardless of the 220 dp box.
2. **Three decode tiers chosen by the widget's box, never the source**: thumb (≤2× box in device px), view (≤ screen px), original (save/export only, never decoded to a texture).
3. `ImageCache.maximumSizeBytes` → **48 MB** on devices reporting <4 GB RAM (default is 1000 images / 100 MB — an OOM risk on exactly the IN2015/Vivo/OnePlus 7 test set). `clear()` does not evict *live* images; `clearLiveImages()` on media-route disposal is the only correct eviction point.
4. **Server-side derivatives**: upload a ≤512 px thumb alongside the ≤1920 px original. Bubbles fetch the thumb. This is the largest egress lever in the app.
5. Bubbles must not trigger `saveLayer` — `borderRadius` on the decoration, not `ClipRRect(Clip.antiAliasWithSaveLayer)`; alpha baked into the colour, not `Opacity`.

## I. Smoothness budget (p95, profile mode, OnePlus 7, cold cache)

Platform floor: ~16 ms/frame at 60 Hz (~8 ms UI + ~8 ms raster); <8 ms total at 120 Hz.

| Interaction | Budget |
|---|---|
| Keystroke → glyph | 16 ms |
| Tap Send → bubble visible | **≤50 ms, network-independent** |
| Open Chat → first paint of last screenful | ≤120 ms |
| Tab switch | ≤100 ms, **zero** channel churn (IndexedStack + sync scopes) |
| Scroll 5,000-message chat | ≥58 fps, zero frames >32 ms |
| Shutter → bubble | ≤250 ms (already achieved; must not regress) |
| Cold start → interactive Home | ≤900 ms on local data |
| Any user-initiated network action | **0 ms of UI blocking** |
| Catch-up after 8 h offline | ≤3 s to consistent, on a 3G profile |

The non-negotiable: **p95 of "action → visible result" must be independent of network RTT for every action with a local representation.** It is the only budget that survives a tunnel.

## J. Measurement plan

- `SchedulerBinding.instance.addTimingsCallback` (supports multiple listeners, unlike `PlatformDispatcher.onReportTimings`) bucketing `totalSpan`/`buildDuration`/`rasterDuration`/`vsyncOverhead` per route+phase into `frame_stats`; p50/p95/p99 + jank ratio (>16 ms) + severe ratio (>32 ms); one row per route per hour shipped **through the outbox** (kind `telemetry`) so it inherits the same reliability machinery. Profile/release only — debug numbers are documented as non-comparable.
- Every budgeted interaction gets a `dart:developer` `TimelineTask` span; so does every sync phase (drain, fetch, apply), so sync work appears on the same timeline as the frames it janks.
- Lab: `flutter run --profile` on a physical device. Rebuild Stats to find `setState` scoped too high (2,118 lines / 32 `setState`), Track Layouts for intrinsic passes, `checkerboardOffscreenLayers` for `saveLayer`, Raster Stats for per-layer cost.
- **CI gate**: `flutter drive` scrolls a seeded 5,000-message local DB and asserts `TimelineSummary` build/raster percentiles. One device, offline, no partner. Numbers committed and diffed per PR — this is what makes the budget a fact rather than an opinion.

## Invariants
- The entity row and its outbox row are written in ONE SQLite transaction. There is no observable state in which the UI shows a message nothing is responsible for sending, nor one queued that the UI does not show. (Today all three states — shown, broadcast, unsaved — are independently reachable at chat_screen.dart:125-129.)
- Every mutation carries a client-minted uuid created BEFORE the first network attempt, and every server write is `on conflict (id) do nothing returning *`. A retry after an ambiguous timeout cannot create a second row, and the server echo upserts onto the same primary key rather than inserting a twin — which is why the confirmed video-duplicate bug (id=null in ChatSendQueue._enqueue) becomes unrepresentable rather than patched.
- The cursor advance and the rows it describes commit in the SAME transaction. A crash between fetch and apply replays the page; it can never skip it. There is no API surface that permits cursor-then-apply, so a future contributor cannot reintroduce the classic data-loss bug.
- No page is visible to the UI until its transaction commits, so the UI cannot observe a partial catch-up. Consistency boundaries are a property of the storage engine, not of screen code.
- Nothing arriving over a peer-writable channel is ever stored. Realtime and FCM payloads are {collection, scope_id} doorbells; the sole writer of entity rows is a response to a request this client issued with its own JWT. Forged content is therefore not a validation problem — it is unrepresentable.
- A terminal failure is a persisted row state, not an exception, a toast, or an in-memory flag. It survives process death and is rendered by the same query the user was already looking at. The three states {pending, confirmed, failed} are exhaustive and stored, so silent loss has no state to occupy.
- Every outbox kind declares lifespan and max_attempts independently, enforced by the drainer rather than the caller. An op that can never succeed still terminates, and termination is a state transition, not a silence.
- Serialisation is per queue_key; parallelism is global. One undeliverable photo blocks exactly its own conversation. Head-of-line blocking is scoped by construction, not avoided by care.
- For any field with an unacknowledged local patch, the read model returns the LOCAL value and discards the incoming server value. The UI cannot flicker back to a stale value between write and ack, for any field, without any per-screen code.
- Connectivity state only ever decides WHEN the drainer wakes; it is never a precondition for issuing a request. The authority on reachability is a request that returned or timed out — per connectivity_plus' own README, connection type 'does not guarantee that there is an Internet access'.
- Backoff resets on a successful RESPONSE, never on a connectivity event, so N devices leaving the same tunnel do not all re-converge on attempt 0 in the same second.
- No device clock participates in any ordering, gating, or freshness decision. Order is the server-assigned seq; freshness is a server-stamped updated_at read through ServerClock; expiry is evaluated server-side. A wrong device clock can make a label wrong; it cannot make delivery wrong. (Today it can: ReachEvent.isActive compares a server expires_at against local DateTime.now(), and breath sync compares two device clocks.)
- No screen may issue a network request; screens read local streams and enqueue ops. Therefore no screen can own a spinner whose end condition is a network response, and 'works offline' is not a per-screen feature — it is the only thing that compiles.
- Every remote read is bounded by an explicit page size at the repository boundary; an unbounded select does not compile. Response size is independent of account age.
- Every image decode is bounded by the WIDGET's box in device pixels, never the source's dimensions, so memory cost is a function of what is on screen rather than what was once uploaded.
- Every route renders at least one exit that does not depend on a successful backend call. A backend failure can change what the user sees; it cannot change how many ways out exist.

## Why this mirrors the top tier
**Mirrors Signal-Android's job manager for the outbox.** `IndividualSendJob` is constructed with `Job.Parameters` that carry the entire reliability policy declaratively: `queue = recipient.id.toQueueKey(hasMedia)` (per-recipient serial queue), `constraints = [NetworkConstraint]`, `lifespan = TimeUnit.DAYS.toMillis(1)`, `maxAttempts = UNLIMITED`, and `onFailure() → SignalDatabase.messages.markAsSentFailed(messageId)`. `Job.java`'s defaults are deliberately hostile (`maxAttempts=1`, `lifespan=IMMORTAL`) so nothing retries by accident. Our kind-table is that table. Source: https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/jobs/IndividualSendJob.kt

**Mirrors Telegram/TDLib and Matrix for cursor discipline.** Apply-then-advance, arithmetic gap detection, and a documented give-up path (`differenceTooLong` / `channelDifferenceTooLong`). Matrix states the cursor-ack invariant normatively (MSC4186): "The server cannot assume that a client has received a response until it receives a new request with the `pos` token set to the `pos` it returned", with expiry as an explicit protocol event (HTTP 400 `M_UNKNOWN_POS`) rather than an error. Sources: https://core.telegram.org/api/updates, https://github.com/matrix-org/matrix-spec-proposals/blob/erikj/sss/proposals/4186-simplified-sliding-sync.md

**Mirrors Figma for the optimistic overlay.** Per-property last-writer-wins with the server defining total order, and the anti-flicker rule: the client "discards incoming server changes that conflict with its own unacknowledged property changes", because the unacked local value "is our best prediction of what the eventually-consistent value will be". Source: https://www.figma.com/blog/how-figmas-multiplayer-technology-works/

**Mirrors PowerSync for checkpoint-boundary visibility and per-collection re-bootstrap**, and Linear for serialise-transactions-to-durable-storage-before-dispatch (Linear writes to an IndexedDB `__transactions` table before sending, so a crash mid-flight replays on next launch). Sources: https://docs.powersync.com/architecture/powersync-protocol, https://github.com/wzhudev/reverse-linear-sync-engine

**Where it deliberately differs:**

1. **No per-recipient server queue.** Signal has one (Redis sorted set + `INCR` counter, 7-day DynamoDB TTL). We use `messages` + per-participant cursor — fan-out-on-read, the Telegram/Matrix model — because for a 2-person tenant it is one row per message instead of 2-4, needs no TTL sweeper, and Postgres retention is unbounded so "the message aged out" is not a failure class we have. Cost: no server-sent `PUT /api/v1/queue/empty` marker; the client's short page is the equivalent, which is weaker (the client infers "caught up" rather than being told).
2. **No homomorphic integrity hash.** WhatsApp's LtHash16 lets an offline-for-a-month client prove a server-built snapshot dropped nothing. We have one trusted server and 2-person tenants, so we take PowerSync's cheaper answer — re-bootstrap the collection on disagreement — and **accept the residual risk that a server-side bug could silently drop a row without the client being able to prove it**. Stated, not hidden.
3. **No CRDT/OT.** Same reasoning Figma published, applied to a far less concurrent product: chat is an append-only per-author log with a server-assigned `seq`; the hard CRDT problem (convergent concurrent edits to a shared mutable structure) never arises, Dart bindings are immature, and metadata grows with edit history rather than document size.
4. **No `pts_count`-style batched update arithmetic.** Our doorbell carries no data, so there is nothing to validate arithmetically; the cursor query is the only path and is self-validating. Simpler, at the cost of one RTT per notification that Telegram avoids by trusting its payload — a trade we take deliberately because our channel is peer-writable and Telegram's is not.
5. **Backoff is AWS Full Jitter, not Signal's ±25% proportional jitter.** AWS's simulation (100 contending clients, 10 ms-mean network) shows Full and Equal Jitter each cut total calls by more than half versus un-jittered, with Full Jitter doing the least work. Signal's proportional jitter is weaker; ours is the same three lines and strictly better under *correlated* recovery — a train carriage or a Supabase restart — which is precisely this app's load spike. Source: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/

## Scale ceiling
**1,000 users (~100-150 concurrent).** The client design is unstressed. Read load collapses: 300-row-per-tab-switch becomes zero (local), the 15 s presence poll becomes one catch-up per resume, the 5 s read-ack becomes one write per actual watermark movement. Local DB is a few MB. **No client-side ceiling.** The binding constraint is server-side and already documented (Realtime message quota; the phase-1 costing shows the Free tier's 2M/month breaks at ~110 users at today's ~18,000 messages/user/month — the coalescing design pushes that out roughly 9×).

**10,000 users (~800-1,500 concurrent).** Client architecture still holds. The first thing that bends is **catch-up amplification under correlated resume**: every commute ends at 08:40, every device wakes, every device wants a catch-up and a channel re-subscribe. Supabase's channel-join ceiling is 100/s (Free) / 500/s (Pro). *Failure mode if the jitter is wrong:* join throttling, experienced by users as "realtime silently stopped working at 08:40" — exactly the bug class this design exists to delete, self-inflicted. Mitigations are already in the design (Full Jitter on the drain timer, jittered `subscribe()`, one coalesced catch-up per collection) and their absence is the specific thing to regression-test. Local DB ~30 MB.

**100,000 users (~8,000 concurrent).** Two real client ceilings appear:
- **Media egress**, not compute. Without server-side thumbs, every bubble pulls the ≤1920 px original. Private-bucket objects miss the CDN (permissions checked per user per object) so they bill as *uncached* at $0.09/GB. *Failure mode:* the egress line becomes the largest bill in the project and scrolling a photo-heavy chat on cellular becomes visibly slow. This is why the derivative pipeline is in the design rather than deferred.
- **Cold bootstrap.** A reinstall fetching a couple's full history through 200-row pages is minutes of paging. *Failure mode:* first launch after reinstall looks broken and users abandon. Fix before it bites: a server-side snapshot endpoint (one compressed payload of the last N + a cursor), which is WhatsApp's Snapshot/Patch-Queue shape.

**Where the client design actually breaks.** Not at any of the above. It breaks when per-user local data exceeds what a mid-range phone can index — order 10^6 rows / a few GB. At that point the answer is time-windowed local retention (90 days hot, older paged from the server on demand), which is a bounded change to the pagination layer, not a redesign. **Honest statement: the client ceiling is a storage ceiling and it is years away; every near-term ceiling is server-side.** The client's job is to stop *manufacturing* server load, which is the actual near-term win.

**One ceiling I will not pretend is solved:** the sync engine has a single writer per device. If the app ever runs a background isolate that also writes (e.g. an FCM handler applying a catch-up while the UI isolate drains the outbox), two writers share one cursor — Signal enforces one consumer per queue with close code 4409 precisely because Matrix documents what happens when you don't (the process that advances first deletes state the other never saw). Our answer must be an explicit single-writer lock on the drift database with the background isolate only *scheduling* work, never applying it. Getting that wrong reintroduces silent loss at any scale.

## Cost
**Direct new service cost: $0.** drift + sqlite3_flutter_libs, connectivity_plus, cached_network_image (already a direct dep at ^3.4.1) are free packages. APK grows ~1.5 MB from bundled SQLite; +~2 MB if SQLCipher is adopted. No PowerSync — that is the paid alternative and it is rejected below.

**Savings, against the phase-1 costing in research/supabase.md:**

*1,000 users.* Phase-1 baseline ≈ **$58/mo** (Pro $25 + ~$33 realtime message overage at ~18,000 messages/user/month). The doorbell + coalescing design removes: presence-as-payload (every presence change currently costs a WAL record, a websocket frame, *and* a PostgREST refetch per subscriber), typing-as-DB-write, the unconditional 5 s read-ack, the 15 s presence poll, and the 15 s location SELECT. Realistic post-change volume is under 2,000 messages/user/month. Result ≈ **$25-35/mo** (Pro + ~$0 overage). **Saving ≈ $25-30/mo**, and it puts the 2M/month Free quota back within reach for the first ~1,000 users if that ever mattered.

*10,000 users.* Phase-1 baseline: Pro with the spend cap disabled, ~800 peak connections → $10 connection overage (billed in whole 1,000-packages), compute Small-Medium $15-60, plus realtime messages at $2.50/M. With a ~9× message reduction the message line goes from dominant to noise. Result ≈ **$60-110/mo** versus ~$150-200 unreduced. **Saving ≈ $90/mo**, and — more valuable than the money — it delays the moment the 500-connection Pro cap forces a plan decision.

*100,000 users.* The dominant line is media: phase-1 estimates **2 TB mostly-uncached egress = $157.50/mo** (at $0.09/GB over the 250 GB Pro allowance) plus $40/mo and rising in storage accrual. Thumbnail tiering is the client-side lever: a ≤512 px thumb is ~40 KB against a ~350 KB original, so list-scroll egress drops roughly 8×. Conservatively **$80-110/mo removed**, growing with usage. Compute (Large-XL, $110-210) is unaffected by client design; connection charges (~$100/mo at 10k peak) are unaffected.

**Engineering cost — the real number.** research/mobile.md estimates ~600 lines for a chat-only drift+outbox+cursor+drainer. That undercounts this design, which is generic across ~15 collections and includes the error doctrine, the funnel, pagination and telemetry. Realistic: **1,200-1,800 lines of engine + ~3-4 weeks including the test harness**, plus ~3 days for the lint + `Result<T>` migration, ~4 days for the navigation machine, ~1 week for the measurement harness and CI gate, ~1 week for the per-collection migrations. **6-8 weeks of one engineer**, staged so something ships every week.

**Cost of doing nothing, in money.** All of the above savings forgone, plus the uncapped line: a permanent background rate of silently-lost messages on flaky networks with zero telemetry (`chat.send.text` is rated `risk: high` for exactly this), a support queue generated by a funnel that turns every backend blip into a dead end, and a first-launch experience that gets slower with account age. None of these improve with scale; the last two get linearly worse.

## Migration
Nine steps. Every one independently shippable and individually revertible. **No big-bang** — the local DB is introduced dark and adopted one screen at a time.

**Step 0 — reproducible schema (server only, zero client work).** Create `supabase/migrations/` + `config.toml`; add the missing DDL for `care_nudges`, `cycle_settings`, `cycle_events`, `love_reasons` and the three undeclared buckets (`couple_media`, `couple_intimate`, `chat-bg`); add `reply_to_id`, `voice_path`, `video_path` as real migrations. `supabase db reset` must reproduce the app. inventory/rest.md rates schema management `risk: fatal` and says explicitly that every other scaling fix is gated on it — **without this, nothing below can be verified anywhere but production.** ~2 days.

**Step 1 — idempotent server writes.** `on conflict (id) do nothing returning *` (or a `client_op_id` unique index) on every insert path; `greatest()` on every watermark; add `updated_at` trigger + `deleted_at` tombstone + `(couple_id, updated_at, id)` index to the LWW tables. Changes no client behaviour. Precondition for an aggressive outbox — without it, a retry after an ambiguous timeout is a 23505. ~1 day.

**Step 2 — local DB exists, nothing depends on it.** Add drift; define `outbox`, `sync_cursor`, `messages`, and the meta tables. Ship a **shadow writer**: existing paths keep working, the local DB is populated in parallel and compared. Zero user-visible change; de-risks the schema, the codegen and the migration machinery. ~1 week.

**Step 3 — chat SEND moves to the outbox.** Delete the `try { await sendText } catch (_) {}` at chat_screen.dart:125-129. All four kinds (text/image/video/voice) enqueue through one path; the `id=null` video-duplicate bug dies with it; the RAM-only `ChatSendQueue` is replaced and its pending file is moved into the durable outbox directory. Reads still come from the network. **First user-visible win: a failed send is a failed row with Retry, not a ghost.** Behind a kill-switch. ~1 week.

**Step 4 — chat READS move to the local DB.** ChatScreen binds to a drift stream; `fetch()`'s 300-rows-on-open and the refetch-per-tab-switch are deleted; catch-up feeds the local DB; realtime becomes a doorbell for chat only. Swap `Expanded(child: bodies[i])` for `IndexedStack`. Keyset pagination and infinite scroll-back arrive here. ~1 week.

**Step 5 — error doctrine + lint.** Introduce `Result<T>`, the three classes, `ui_error_log`, the diagnostics screen, and the lint banning bare `catch (_)` outside `lib/core/errors/` and `_c.from(...)` outside `lib/data/remote/`. Migrate the 68 empty catches by class — the lint enumerates what's left, so this is mechanical rather than an audit. ~3 days. *Independent of steps 3-4; can run in parallel.*

**Step 6 — navigation state machine.** Local `onboarding_state`, `OnboardingScaffold` with three always-present exits, the `Blocked` screen, removal of the `?redirect=` passthrough, durable `pending_entry_intent` for deep-link cold start. ~4 days. *Independent; can run in parallel.*

**Step 7 — remaining collections, one PR each.** presence, profiles, receipts, reasons, care, capsules, cycle. Each PR is: register the collection (client) + delete that screen's ad-hoc fetch/subscribe. Each removes one `postgres_changes` subscription and one full-table refetch. This is where the presence write amplification and Home's 4-SELECT/4-UPSERT/4-geocode loop die. ~1-2 weeks total.

**Step 8 — image policy + telemetry.** `NetImage` everywhere, three decode tiers, `ImageCache` cap, server-side thumb derivatives, `addTimingsCallback` collector shipping via the outbox, and the CI frame-percentile gate. **Last, deliberately** — its value is only legible once you can measure it.

**Ordering rationale:** 0 and 1 are pure server prerequisites with no client risk. 3 stops the bleeding (silent data loss) *before* 4 optimises. 5 and 6 are orthogonal and parallelisable. 7 is a repeating template, so it is the safest work to hand off. 8 closes the loop by making the budget enforceable.

**A design requiring a big-bang here would be a failed design** — the shadow-writer step exists specifically so that the highest-risk part (a new persistence layer in a 91-module app) ships with zero blast radius.

## Verification
The premise: "we tested it on two NTP-synced phones on one wifi" tests exactly the configuration in which every clock-dependent and socket-dependent bug is invisible. That is why every previous fix passed and then failed. Five layers, **none requiring a second device or a second network.**

**1. The sync engine is a pure function of (local state, transport responses, timer ticks) — so it unit-tests in plain `dart test`.** No Flutter, no device, no network. A fake transport replays scripted response sequences. Required cases, each a named test: duplicate delivery of the same page; pages out of order; a page applied then the process killed before the cursor write (assert **replay**, not skip); an ambiguous timeout followed by a retry (assert **one** row); a 500 mid-page; a malformed row in a page (assert skip-and-continue, matching the existing `Message.fromJson` behaviour); a cursor older than retention (assert re-bootstrap, not unbounded backfill); a token expiring mid-catch-up (assert `setAuth` + resume, not a wedged channel — the documented supabase-flutter sharp edge).

**2. Property/model tests over the outbox.** Generate random interleavings of `{enqueue, drain-success, drain-timeout, drain-4xx, process-kill, connectivity-flap, clock-jump ±1h, app-upgrade}` and assert the invariants: no op lost; no op applied twice; no failed op invisible; no `queue_key` reordered; no op outliving its lifespan; no cursor moving backwards. **A ±1 h clock jump is a generated input here — it is the single thing two NTP-synced phones can never test, and it is the root of the reach/breath/pairing-expiry bugs.**

**3. A deterministic two-engine simulator, in one process.** Two engine instances against one in-memory fake server with injectable latency, loss, partition, reorder and duplication. This replaces "two phones" and is **strictly stronger**: you can hold one side dark for a simulated week in 200 ms, and reruns are byte-identical. Golden assertion: engine A sends 500 messages while B is partitioned; after reconnect, B's local rows for the collection must be byte-identical to A's, and both cursors must agree.

**4. Local-DB golden fixtures + a hard-fail network stub.** Seed a SQLite file with 5,000 messages, 200 media rows, one `failed` op and one `pending_patch`. Every screen must render it in the lab, at budget, **with the network stack stubbed to throw on every call**. *If any screen renders differently with the network hard-failed, that screen has a network dependency it should not have.* One mechanical test catching the whole class — including the 43 unbounded selects and any surviving on-open fetch.

**5. The CI frame gate** (from the measurement plan): `flutter drive` scrolls the seeded 5,000-message DB on one physical device, offline, and asserts `TimelineSummary` build/raster percentiles against the smoothness budget. Numbers committed and diffed per PR, so "it feels smoother" is never the evidence.

**Prerequisite, not optional:** step 0 of the migration. Until `supabase db reset` reproduces the schema, layers 1-3 can run but layers 4-5 have nothing real to run against and every backend change is still validated only in production.

**What this does NOT verify, stated plainly:** real radio behaviour (captive portals, dying cell handoffs, carrier NAT timeouts), Doze/FCM delivery latency, and OEM background-kill aggressiveness on Chinese ROMs. Those are only observable in the field — which is exactly what the `FrameTiming` + outbox telemetry pipeline is for. The design's claim is that these become *observable* rather than silent, not that they become testable on a desk.

## Rejected alternatives
**PowerSync.** Documented, first-class Flutter SDK, documented Supabase integration; gives sync buckets, checkpoints, per-bucket checksums, an upload queue and LSN-backed write confirmation off the shelf, and scales to "tens of thousands of concurrent clients per service instance". *Rejected:* a second paid service and a second deployment, plus sync rules must be expressed for every table. For a 2-person tenant with ~15 collections the DIY engine is genuinely simpler and stays inside the existing bill. **Reconsider if** the goal becomes *every* module offline-first including vault and capsule media — at that point the rule-authoring cost is amortised and the checksum machinery earns its keep.

**CRDTs / Automerge.** *Rejected* on Figma's published reasoning applied to a far less concurrent product: with an authoritative server "we can simplify our system by removing this extra overhead". Chat is an append-only per-author log with a server-assigned `seq` — the hard CRDT problem never arises. Metadata grows with edit history rather than document size, and Dart bindings are immature. Every mutable surface here (couple settings, chat theme, shared lists) is a per-property LWW case.

**"Keep the network as the source of truth, just add retries."** This is what the codebase already does — `ChatSendQueue` retries media, text has a bare catch, the queue is RAM-only. *It has already failed in production.* Retry without durability loses the op on process death; retry without idempotency cannot be aggressive (23505 on every ambiguous timeout); retry without a persisted row-state cannot surface failure. The three are one mechanism, not three patches — which is the brief's own criterion.

**Broadcast payloads as the fast path (status quo).** *Rejected.* It is the direct cause of the "message on both screens, in no database" failure, and it lets any client that knows a `couple_id` inject a permanent fake bubble at `seq=0` (chat.transport, verified in inventory/chat.md). Latency is not the argument for it: the local write already delivers the sender's 50 ms budget, and the receiver's path is one RTT either way. A contentless doorbell on an authorised private channel costs the same and removes an entire bug class *and* an entire security class.

**`postgres_changes` with better filters / a bigger compute add-on.** *Rejected on the documented numbers:* `realtime.apply_rls` loops over **every** subscription to that table project-wide (`where sub.entity = entity_`), the `couple_id=eq.X` filter is evaluated *inside* the loop and does not shrink it, and the poller is single-threaded. 3,000 clients → 5 changes/sec for the whole project; a 16XL buys 40/sec instead of 30 — a ~1.5× return for a ~370× price increase. No client-side change rescues this.

**Riverpod `FutureProvider` + `keepAlive` as "the cache".** *Rejected.* A per-process memory cache with no durability, no failure state, no cursor and no cross-screen consistency. It resembles the local-first answer closely enough to be dangerous, and would have to be torn out to build the real one.

**Rewriting `chat_screen.dart` first** (2,118 lines, 32 `setState` calls). Tempting and *rejected as an early step*: splitting widgets without changing the data layer produces a prettier version of the same architecture, and burns the political capital for the change that matters. It falls out of step 4 almost for free once the screen reads a drift stream instead of owning a `List<Message>`.

**`shared_preferences` for the cursor as a "stopgap"** (suggested in research/mobile.md's applicability notes). *Rejected* — it makes the cursor writable outside the transaction that applies the page, which destroys the single invariant the whole design rests on. If drift is not ready, the correct stopgap is *no cursor persistence at all* (refetch a bounded window), not a cursor that can advance past unapplied data.

## Open decisions
**1. drift vs raw sqflite.** *Recommend drift.* Compile-time-checked queries, first-class `Stream` support (the entire read path depends on it), and transactional migrations. sqflite is already present transitively but offers no streams and no migration story, which would mean hand-rolling both. Cost: `build_runner` in the toolchain and slower incremental builds. **Decide before step 2.**

**2. Local encryption at rest — the highest-stakes item.** The app's entire premise is concealment, yet the local DB would hold every message, every location and every intimate item in plaintext on a device whose app-lock is an **unsalted SHA-256 of a 4-digit PIN in SharedPreferences** (10,000 candidates, breakable instantly from any backup or rooted read — inventory/auth.md). *Recommend SQLCipher via `sqlcipher_flutter_libs`, key in `flutter_secure_storage`.* Cost: ~2 MB APK, a measurable but small read overhead, and a key-loss path that must be designed (key loss = full re-bootstrap, which the generation mechanism already handles). **Must be decided BEFORE step 2** — retrofitting it is a forced full local re-bootstrap for every installed user.

**3. How much history to keep locally.** *Recommend "all of it" for v1* — text plus URLs is tiny (100k messages ≈ 30 MB) — with a committed trigger to add 90-day windowing when p95 local DB size exceeds ~200 MB, measured by the telemetry from step 8. Deciding this later is cheap; deciding it wrong now is not.

**4. Do the ephemeral broadcast features survive?** Heartbeat/PPG is 70-90 broadcast messages per user per **minute** for zero durable value — by a wide margin the largest realtime line item in the app, and Supabase bills broadcast messages. Watch-Together adds 24/user/min. *Recommend: keep both, hard-rate-limit heartbeat to ≤4 msgs/sec client-side, and designate it the first feature cut if the realtime bill bites.* This is a **product call, not a technical one** — the owner has to make it, and should make it before the 10k-user plan decision rather than during it.

**5. Does presence stay in Postgres at all?** *Recommend moving the ephemeral facts (online, typing, current screen) to Realtime Presence/broadcast and keeping only the durable ones (last_seen, shared location) in the table.* That is properly the presence domain's decision; note that **the client design is indifferent** — both are collections behind the same doorbell — so this can be decided independently and later without reopening anything here.

**6. Kill-switch mechanism for the migration.** Steps 3, 4 and 7 each want a remote flag so a bad ship is a config change rather than a store release. There is no remote config today. *Recommend the cheapest possible version: a `client_flags jsonb` column on `couples` read at boot and on resume, defaulting to the safe path when absent.* Building anything more is scope creep; shipping without any of it means a bad step 4 requires a Play release cycle to undo, on an app that isn't on the Play Store.

**7. Single-writer enforcement across isolates.** If the FCM background handler ever applies a catch-up while the UI isolate drains the outbox, two writers share one cursor — the exact failure Signal prevents with close code 4409. *Recommend a hard rule now: the background isolate may only enqueue a wake request; it may never open the drift database for writing.* Cheap to decide today, expensive to discover in the field, and it is the one way this design can silently reintroduce the loss it was built to eliminate.
