# Supabase at scale — documented ceilings (Realtime connections/messages, postgres_changes vs broadcast vs presence, RLS-per-row cost, Supavisor, Edge Functions, pg_net/pg_cron, egress) and the patterns that avoid them, benchmarked against the Flutter+Supabase LDR app at E:\LDR

## Mechanism
## 1. The single most important mechanism: what `postgres_changes` actually executes

This is not "a queue". Supabase Realtime's `postgres_cdc_rls` extension runs a GenServer poller per tenant that calls `realtime.list_changes(publication, slot_name, max_changes, max_record_bytes)` **inside your own Postgres**. Source-verified defaults (`lib/extensions/postgres_cdc_rls/db_settings.ex`):

```elixir
def default do
  %{
    "poll_interval_ms" => 100,
    "poll_max_changes" => 100,
    "poll_max_record_bytes" => 1_048_576,
    "publication" => "supabase_realtime",
    "slot_name" => "supabase_realtime_replication_slot"
  }
end
```

`list_changes` calls `pg_logical_slot_get_changes(slot_name, null, max_changes, 'format-version','2', 'actions', …, 'add-tables', …)` — i.e. **wal2json decoding runs on your database CPU**, then pipes each record into `realtime.apply_rls(wal, max_record_bytes)`.

`apply_rls` is where the cost lives. Verified source (migration `20211116214523_create_realtime_apply_rls_function.ex`):

```sql
-- user subscriptions to the wal record's table
subscriptions realtime.subscription[] =
  array_agg(sub) from realtime.subscription sub where sub.entity = entity_;
...
if is_rls_enabled and array_length(subscriptions, 1) > 0 then
  perform set_config('role','authenticated',true),
          set_config('request.jwt.claim.role','authenticated',true);
  deallocate walrus_rls_stmt;                       -- per WAL record
  execute realtime.build_prepared_statement_sql('walrus_rls_stmt', entity_, columns);
end if;

for user_id, email, is_visible_to_user in (
  select subs.user_id, subs.email,
         realtime.is_visible_through_filters(columns, subs.filters)
  from unnest(subscriptions) subs
)
loop
  if is_visible_to_user then
    perform set_config('request.jwt.claim.sub', user_id::text, true),
            set_config('request.jwt.claim.email', email::text, true);
    execute 'execute walrus_rls_stmt' into user_has_access;   -- one RLS eval PER SUBSCRIBER
    ...
```

**Read the loop bound**: `where sub.entity = entity_`. It is every subscription to that *table*, project-wide — the `couple_id=eq.X` filter is evaluated *inside* the loop by `is_visible_through_filters`, it does not shrink the loop. So per row change on table T:

- 1 × `deallocate` + `prepare` of a per-entity statement,
- N × filter evaluations where N = **all** subscribers to T across the whole project,
- M × RLS prepared-statement executions where M = subscribers whose filter matched.

That is O(total subscribers to the table) CPU on your Postgres, per changed row, on a **single-threaded** poller. Supabase documents the consequence verbatim: "When you make a single change to a table with 100 subscribed users, Realtime performs 100 authorization checks — one per user" and "changes are processed on a single thread to preserve their order, which means larger compute add-ons don't meaningfully increase Postgres Changes throughput."

The published benchmark numbers confirm it does not scale with hardware:

| Compute | 500 clients, no RLS | 500 clients, with RLS |
|---|---|---|
| Micro | 64 changes/s | 30 changes/s |
| Small–Medium | 64 changes/s | 30 changes/s |
| Large–16XL | 64 changes/s | 40 changes/s |

16XL (64 dedicated cores, 256 GB) buys you **40 changes/sec** instead of 30. At 100,000 clients the same doc shows degradation to **0.1 changes/sec**. That is a ~1.5x return for a ~370x price increase — the definition of a non-scalable axis.

## 2. What Broadcast does instead

Broadcast is Phoenix PubSub (`Phoenix.PubSub.PG2`, Erlang process groups) on a globally distributed Elixir/BEAM cluster hosted on Fly. Fan-out happens in the Realtime cluster, not in Postgres. Same-page benchmarks:

- WebSocket broadcast: 32,000 concurrent users / 64,000 channel joins, **224,000 msg/s**, median 6 ms, p95 28 ms, p99 213 ms.
- Large-scale: **250,000 concurrent users / 500,000 joins, 800,000+ msg/s**, median 58 ms, p95 279 ms, p99 508 ms.
- Authenticated (private channels, RLS at join): 50,000 users / 100,000 joins, 150,000+ msg/s, median 19 ms, p95 49 ms, p99 96 ms.
- Broadcast-from-database: 80,000 users / 160,000 joins, 10,000 msg/s, median 46 ms, p95 132 ms, p99 159 ms.

Note the last row: **database-triggered broadcast tops out ~10,000 msg/s vs 224,000 msg/s for pure client broadcast** — an order of magnitude. That is the price of the WAL round-trip and it is the number to design against if you use `realtime.broadcast_changes`.

The authorization difference is the whole story. Documented: "The validation is done when the user connects. When their WebSocket connection is established and a Channel topic is joined, their permissions are calculated" and "Client access policies are cached for the duration of the connection. Your database is not queried for every Channel message." Realtime runs one `SELECT` against `realtime.messages` under the user's JWT and **rolls it back**, then caches the verdict. So:

- `postgres_changes`: RLS cost = O(subscribers) **per row change**, on your DB.
- `broadcast` private channel: RLS cost = O(1) **per channel join**, cached for connection lifetime, on Realtime's pool.

## 3. Broadcast-from-database mechanism

`realtime.broadcast_changes(topic, event, operation, table, schema, NEW, OLD)` called from an `AFTER INSERT OR UPDATE OR DELETE … FOR EACH ROW` trigger inserts one row into `realtime.messages`. Realtime holds a publication/replication slot against **only** `realtime.messages` and pushes to the topic. Key properties:

- `realtime.messages` is **daily-partitioned**; partitions older than 3 days are dropped (documented retention "at least 72 hours and at most 4 days"). Cleanup is `DROP TABLE`, not `DELETE` — no bloat, no vacuum debt.
- `realtime.send` catches exceptions and reports them via `pg_notify` rather than raising, so a Realtime-side failure **cannot roll back your business transaction**.
- Private-vs-public is enforced symmetrically: a private DB broadcast only reaches private client channels.
- Fan-out is once-per-change into the cluster, then PubSub — not once-per-subscriber in Postgres.

## 4. Presence

Phoenix Presence / Phoenix Tracker — a **delta-based CRDT**, in-memory, replicated across cluster nodes. It never touches Postgres. Verified defaults (`ENVS.md`): `PRESENCE_BROADCAST_PERIOD_IN_MS=1500` (diffs are batched and flushed every 1.5 s, not per-event), `PRESENCE_PERMDOWN_PERIOD_IN_MS=1200000` (20 min), `CLIENT_PRESENCE_MAX_CALLS=5` per `CLIENT_PRESENCE_WINDOW_MS=30000` (5 presence calls per client per 30 s), `PRESENCE_POOL_SIZE=10`.

## 5. Connections and pooling

The client library talks **HTTP (PostgREST)**, not raw Postgres, so N app users ≠ N database connections. Direct/pooled connections matter only for Edge Functions and any server process. Documented per compute tier:

| Instance | RAM | CPU | Direct conns | Pooler clients | ~$/mo |
|---|---|---|---|---|---|
| Nano (Free) | 0.5 GB | shared/burst | 60 | 200 | $0 |
| Micro | 1 GB | 2-core shared | 60 | 200 | ~$10 |
| Small | 2 GB | 2-core shared | 90 | 400 | ~$15 |
| Medium | 4 GB | 2-core shared | 120 | 600 | ~$60 |
| Large | 8 GB | 2-core ded. | 160 | 800 | ~$110 |
| XL | 16 GB | 4-core ded. | 240 | 1,000 | ~$210 |
| 4XL | 64 GB | 16-core | 480 | 3,000 | ~$960 |
| 16XL | 256 GB | 64-core | 500 | 12,000 | ~$3,730 |

Supavisor is a separate Elixir multi-tenant cluster: transaction mode on **port 6543**, session mode / direct on **5432**. Transaction mode **does not support prepared statements** — you must disable them in the driver. Supavisor's own scaling paper: 1,003,200 client connections across two 64-core nodes at 20,000 QPS, with the DB pool at 400 connections; only one node holds real DB connections and the others relay. Latency cost vs a co-located PgBouncer at 5,000 QPS: median 4 ms vs 1 ms, p99 5 ms vs 3 ms — roughly **+2 ms per query**, in exchange for not burning DB CPU/RAM.

A number almost nobody knows: Realtime's **own** pool for evaluating authorization RLS defaults to `DB_POOL_SIZE=5` (`ENVS.md`), and the dashboard exposes it as "Database connection pool size — determines the number of connections used for Realtime Authorization RLS checking". Five connections gate every private-channel join for your entire project.

## 6. Documented Realtime quotas (the actual ceilings)

| Limit | Free | Pro | Pro (no spend cap) / Team | Enterprise |
|---|---|---|---|---|
| Concurrent peak connections | 200 | 500 | 10,000 | 10,000+ |
| Messages/sec | 100 | 500 | 2,500 | 2,500+ |
| Channel joins/sec | 100 | 500 | 2,500 | 2,500+ |
| Channels per connection | 100 | 100 | 100 | 100+ |
| Presence messages/sec | 20 | 50 | 1,000 | 1,000+ |
| Presence keys per object | 10 | 10 | 10 | 10+ |
| Presence calls/client/30 s | 5 | 5 | 5 | 5 |
| Broadcast payload | 256 KB | 3,000 KB | 3,000+ KB | — |
| Postgres-changes payload | 1,024 KB | 1,024 KB | 1,024 KB | 1,024+ KB |
| Broadcast replay retention | 72 h | 72 h | 72 h | 72 h |
| Included messages/mo | 2 M | 5 M | 5 M | custom |

Self-host defaults for a new tenant (`ENVS.md`) mirror the Free tier exactly and add one limit that is *not* on the pricing page: `TENANT_MAX_BYTES_PER_SECOND=100_000` — **100 KB/s for the whole project**. Also `TENANT_MAX_CONCURRENT_USERS=200`, `TENANT_MAX_EVENTS_PER_SECOND=100`, `TENANT_MAX_JOINS_PER_SECOND=100`, `TENANT_MAX_CHANNELS_PER_CLIENT=100`, `MAX_CONNECTIONS=16384` per node, `WEBSOCKET_MAX_HEAP_SIZE=50MB`.

Error codes on breach: `too_many_channels`, `too_many_connections`, `too_many_joins`, `tenant_events` (disconnect for throughput). Sustained abuse gets the project manually suspended — `RealtimeDisabledForTenant`, at which point "connections will fail to establish and existing subscriptions will stop receiving events", and it requires a support ticket to lift.

## 7. Billing arithmetic — the multiplier everyone misses

Documented, verbatim: "Each broadcast message counts as one message sent plus one message per subscribed client that receives it. For example, if you broadcast a message and 4 clients listen to it, it counts as 5 messages—1 sent and 4 received." And: "Each database change counts as one message per client that listens to the event."

So billable messages = **events × (recipients + 1)**. Connections bill on the **peak for the billing cycle**, summed across projects, at $10 per 1,000 in whole 1,000-packages (1,001 connections = 2 packages = $20). Only successful connections count. Free tier has **no overage** — it fails closed at 200.

Realtime websocket traffic also counts as **egress**: "Data pushed to clients via Supabase Realtime for subscribed events." Free 5 GB uncached + 5 GB cached; Pro/Team 250 + 250; overage $0.09/GB uncached, $0.03/GB cached.

## 8. Edge Functions, pg_net, pg_cron

**Edge Functions** (V8 isolate per invocation on Deno Deploy): wall clock **150 s free / 400 s paid**; **CPU time 2 s per request**; memory 256 MB; request idle timeout 150 s → 504; script 20 MB CLI-bundled / 5 MB server-bundled; 100 functions free / 500 Pro / 1,000 Team; 100 secrets; log throttle 100 events per 10 s; ~5,000 req/min ceiling on recursive self-calls. Invocations: 500 k free, 2 M Pro, then $2/M. Isolates "can remain active for a period (plan-dependent)" — warm reuse exists but the duration is undocumented, and no concurrency ceiling is published. **The 2 s CPU limit, not the 150/400 s wall clock, is what kills fan-out loops** (signing 200 URLs, crypto, image work).

**pg_net**: async, fire-and-forget, requests do not start until the transaction commits. Responses land in `net._http_response`. Default timeout **2000 ms**. "Configured to reliably execute up to **200 requests per second**", higher rates introduce instability. Responses kept **6 hours** (`pg_net.ttl`). **No automatic retry is documented.** Failure visibility is entirely opt-in: you must poll `net._http_response` for `status_code >= 400`, non-null `error_msg`, or `timed_out = true`. A failed FCM push from a trigger is silent by default.

**pg_cron / Supabase Cron**: schedules from "every second to once a year". Every run is recorded in `cron.job_run_details`. Supabase recommends "**no more than 8 Jobs run concurrently**" and "each Job should run **no more than 10 minutes**". Retention/cleanup of `cron.job_run_details` and overrun behaviour are **not documented** — that table grows unbounded unless you prune it, and a failed job surfaces only if you query it.

**Auth rate limits** (relevant at scale): token refresh **1,800/hour per IP** (burst 30), verify 360/hour per IP, anonymous sign-ins 30/hour per IP, MFA challenge 15/hour per IP, built-in SMTP **2 emails/hour project-wide**, OTP 30/hour project-wide with a 60 s per-user window.

## 9. Storage / CDN

Smart CDN is **Pro and above only** — Free gets basic CDN. Cache invalidation takes up to **60 seconds** to propagate. Default TTL ~1 hour, overridable via `cacheControl` on upload. Two facts that dominate cost for a private media app: (a) private buckets check "permissions for accessing each object … on a per user level", which causes cache misses → traffic bills as **uncached at $0.09/GB**; (b) "each signed URL maintains its own independent cache entry due to unique token parameters" and "revoking or expiring a token does not purge its CDN cache entry" — so per-user signed URLs are a cache-defeating pattern *and* a soft revocation hole.

## 10. Free-tier compute floor

Nano: 0.5 GB RAM, shared burstable CPU, **250 baseline IOPS / 5 MB/s baseline** (burst 11,800 IOPS / 261 MB/s until credits exhaust), 500 MB database, 60 direct connections, 200 pooler clients. A write-heavy heartbeat design will exhaust burst credits and fall to 5 MB/s sustained.

## Invariants
- ONE WEBSOCKET PER DEVICE, MANY CHANNELS ON IT. Billing and quota are per websocket, not per channel — "one connection per browser tab and all channels share that connection", with a documented ceiling of 100 channels per connection on every plan. This makes concurrent-connection cost a function of concurrent *devices* only, and completely independent of how many features subscribe to something. Corollary invariant: exactly one SupabaseClient per process, ever.
- AUTHORIZATION IS EVALUATED AT JOIN AND CACHED FOR THE CONNECTION LIFETIME (broadcast/private channels), NEVER PER MESSAGE. Documented: "Client access policies are cached for the duration of the connection. Your database is not queried for every Channel message." This makes steady-state RLS cost O(joins), which is bounded by the joins/sec quota — versus postgres_changes where RLS cost is O(subscribers × row changes) and unbounded by anything you control.
- THE FAN-OUT SET IS BOUNDED BY THE TOPIC NAME, NOT BY A FILTER. A channel topic keyed to the tenant boundary (couple id, room id) has a recipient count fixed by the domain — 2 for a couple — so billable messages scale linearly in users regardless of user count. A filter on a shared table does NOT give you this: apply_rls loads `array_agg(sub) … where sub.entity = entity_` and evaluates every subscription's filter inside the loop, so a filtered subscription still costs CPU proportional to the total number of subscribers to that table.
- EPHEMERAL STATE NEVER ENTERS THE WAL. Typing indicators, cursors, heartbeats, screen presence and liveness have no durability requirement and no audit requirement. Anything written to a published Postgres table becomes a WAL record that is decoded by wal2json on your own database CPU and then multiplied by the subscriber count. Ephemeral state belongs in Broadcast (fire-and-forget) or Presence (CRDT, in-memory, never touches Postgres, batched at PRESENCE_BROADCAST_PERIOD_IN_MS=1500).
- DURABILITY AND NOTIFICATION ARE SEPARATE PATHS, AND THE CLIENT RECONCILES FROM THE DURABLE ONE. The Postgres row is the source of truth; the broadcast is a hint that says "go read". Under this invariant a dropped, duplicated or out-of-order broadcast is a latency bug, not a correctness bug — which is what makes it safe to run notification over a lossy, unacknowledged, at-most-once PubSub path. Realtime enforces the other half of this from the DB side: realtime.send catches its own exceptions and reports via pg_notify so a Realtime failure can never roll back the write that triggered it.
- THE HOT PATH NEVER DEPENDS ON A LIMIT YOU CANNOT SEE. Every Supabase quota that bites in production either has a report (connected clients, broadcast events, channel joins, response errors) or must be given one by you (net._http_response for pg_net, cron.job_run_details for pg_cron). Both of those tables are polled-only with no alerting, and pg_net has no documented retry — so any design that puts delivery on pg_net must own its own dead-letter query, or failures are structurally invisible.
- RLS POLICIES ARE INDEX-BACKED, ROLE-SCOPED, AND CALL auth.uid() EXACTLY ONCE. Documented measurements: indexing the policy column 171 ms → <0.1 ms; (select auth.uid()) instead of auth.uid() 179 ms → 9 ms and 178,000 ms → 12 ms; TO authenticated 170 ms → <0.1 ms; reversing the join direction 9,000 ms → 20 ms. This matters twice over — once per API query, and once per subscriber per row change if you are on postgres_changes.
- COST IS A DESIGN-TIME CHOICE, NOT A RUNTIME SURPRISE. Billable messages = events × (recipients + 1), and connection cost = peak concurrent devices. Both terms are fixed by the topology you pick before you write a line of code. A system where you cannot state those two numbers from the architecture alone has no cost model.

## Failure modes designed for
- Reconnect storms after a network flap or an auth failure. Realtime enforces joins/sec (100 free, 500 Pro, 2,500 Team) and returns too_many_joins rather than melting; the server applies CONNECT_ERROR_BACKOFF_MS=2000 and CHANNEL_ERROR_BACKOFF_MS=5000. Supabase names "rapid reconnection loops from failed authentication attempts" as a top cause of quota suspension. The client must own exponential backoff — the server's defence is refusal, not queueing.
- JWT expiring mid-connection. Because policies are cached for the connection's lifetime, a stale JWT would otherwise mean stale authorization. Realtime's answer is to disconnect the client when the JWT expires unless it pushes a fresh access_token message, which re-evaluates policies. The docs explicitly recommend a short JWT expiry window — trading reconnect churn for bounded authorization staleness.
- An abandoned replication slot pinning WAL and filling the disk. The postgres_cdc_rls poller uses a TEMPORARY logical replication slot and, when the publication has no tables, refuses to create one at all ("an unconsumed slot would retain WAL"); when tables vanish it explicitly drops the slot, and stops with {:shutdown, :drop_replication_slot_failed} if the drop fails for any reason other than :slot_not_found. It re-checks the publication OIDs every 60 s.
- A single oversized row stalling the change stream. poll_max_record_bytes defaults to 1 MiB and apply_rls checks octet_length(wal::text) up front; oversized records are emitted with 'Error 413: Payload Too Large' and empty record/old_record instead of blowing up the poller. Documented postgres-changes payload limit is 1,024 KB on every plan.
- Unbounded growth of the broadcast spool. realtime.messages is daily-partitioned and partitions older than 3 days are DROPped — physical partition drop, not row DELETE, so there is no bloat and no vacuum debt. Retention is therefore bounded at "at least 72 hours and at most 4 days", which is also why broadcast replay is capped at 72 h / 25 messages per request.
- A Realtime-side failure rolling back a user's write. realtime.send catches exceptions and reports via pg_notify to the Realtime server for logging instead of raising, so a broadcast trigger cannot abort the INSERT that fired it. This is the invariant that makes broadcast-from-database safe to attach to a business table.
- Connection exhaustion from serverless/edge callers. Supavisor exists specifically because "temporary, auto-scaling connections" from Edge Functions would exhaust the 60–500 direct Postgres connections. It multiplexes 1,000,000+ client connections onto a 400-connection DB pool at 20,000 QPS, at the cost of ~2 ms per query and no prepared statement support in transaction mode.
- Presence flooding the cluster. Presence diffs are batched and flushed on a PRESENCE_BROADCAST_PERIOD_IN_MS=1500 timer rather than per-event, clients are capped at CLIENT_PRESENCE_MAX_CALLS=5 per CLIENT_PRESENCE_WINDOW_MS=30000, and presence messages/sec is separately quota'd (20 free, 50 Pro, 1,000 Team) so presence cannot consume the broadcast budget. PRESENCE_PERMDOWN_PERIOD_IN_MS=1200000 bounds how long a partitioned node's state lingers.
- One tenant saturating a shared node. Per-tenant limits are enforced server-side (TENANT_MAX_CONCURRENT_USERS, TENANT_MAX_EVENTS_PER_SECOND, TENANT_MAX_JOINS_PER_SECOND, TENANT_MAX_CHANNELS_PER_CLIENT, TENANT_MAX_BYTES_PER_SECOND=100 KB/s) with MAX_CONNECTIONS=16384 and WEBSOCKET_MAX_HEAP_SIZE=50MB per node. The terminal defence is manual suspension: RealtimeDisabledForTenant, connections refused, existing subscriptions silenced, support ticket required.
- Fire-and-forget HTTP from a transaction. pg_net defers the request until COMMIT (so a rolled-back transaction sends nothing), applies a 2 s default timeout, and records outcome in net._http_response with an explicit timed_out flag — but caps at ~200 req/s and documents no retry. The failure mode they did NOT design away is silent loss: nothing alerts, you must poll.
- Long-running or runaway serverless work. Edge Functions cap CPU time at 2 s per request independently of the 150 s (free) / 400 s (paid) wall clock, so a busy loop is killed long before it holds a slot for minutes; idle requests 504 at 150 s; recursive self-invocation is capped around 5,000 req/min.

## Applicability to Supabase
## What the LDR app at E:\LDR already gets right

- **Channel topics are already keyed to the couple.** All 27 distinct topics are `feature:$coupleId` — `messages:$coupleId`, `call:$id`, `touch_trace:${widget.coupleId}`, `mood_lamp:$coupleId`, `game_td:$cid`. That is exactly the channel-per-tenant invariant: recipient count is 2 by construction, so billable messages scale linearly and never quadratically. Nothing to change.
- **25 `onBroadcast` call sites vs 16 `onPostgresChanges`.** The ephemeral surfaces (touch trace, mood lamp, watch-together, WebRTC signalling in `call_controller.dart`, typing/mood in `chat_screen.dart`, `together`, `screen_presence`) are already on Broadcast. This is the recommended path.
- **`ManagedSubscription` in `E:\LDR\mobile\lib\core\realtime_service.dart` awaits `removeChannel(old)` before recreating.** The code comment names the exact bug — a duplicate joined-but-dead topic after reconnect. That is the client-side half of the reconnect-storm defence, and it is the single most common cause of quota suspension per Supabase's own troubleshooting page.

## The thing that will break first, with a number

`E:\LDR\mobile\lib\core\services\presence_service.dart` implements presence as a **Postgres table with heartbeat UPSERTs**, and `public.presence` is in the `supabase_realtime` publication (confirmed in the migrations). The code's own comment: *"The partner's client re-stamps presence every ~5s while their chat is open"*, plus a 30 s foreground heartbeat, plus `_upsert` on every typing toggle, screen change, location ping, avatar change, and read receipt. Subscription is via `RealtimeService.coupleTable(channelName: 'presence:$id', table: 'presence', …)` → `onPostgresChanges` with an `eq` filter on `couple_id`.

Trace one heartbeat through the machine:

1. UPSERT on `public.presence` → WAL record.
2. Realtime's poller calls `pg_logical_slot_get_changes(...)` **on your Nano instance** — wal2json decode on 0.5 GB RAM and shared burstable CPU.
3. `apply_rls` runs `array_agg(sub) from realtime.subscription sub where sub.entity = 'public.presence'::regclass` — **every** presence subscriber in the project, not just the couple.
4. It loops over all of them evaluating `is_visible_through_filters`; the `couple_id=eq.X` filter is checked *inside* the loop.
5. For the one that matches, it `set_config('request.jwt.claim.sub', …)` and executes the prepared RLS statement.

Documented ceiling for step 2–5: **30 changes/sec with RLS at 500 clients** (40/sec even on a 16XL). At a 5 s re-stamp during chat, presence writes/sec = concurrent_chatting_users / 5.

**Break point: ~150 concurrently-chatting users.** (30 changes/s × 5 s). At 30 s heartbeats only, ~900 users. And that budget is shared with `messages`, `chat_receipts`, `body_touches`, `reach_events`, `capsules`, `intimacy_signals` — all seven tables share the same single-threaded poller. Realistically the whole app's postgres_changes path saturates somewhere around **300–800 concurrent users**, and upgrading compute buys you 30 → 40 changes/sec. That is the ceiling; there is no money you can spend on it.

The 15 s `Timer.periodic` liveness poll in `_bind()` compounds it: at 10,000 concurrent users that is 667 PostgREST `fetchPartner` reads/sec against a Nano/Micro with 250 baseline IOPS.

## What transfers directly (no new components, no paid tier)

1. **Move presence off Postgres onto Supabase Presence.** The app currently uses zero Presence (`grep` for `.track(` / `presenceState` / `onPresenceSync` returns 0 hits). Presence is a CRDT held in Realtime's memory, batched at 1.5 s, quota'd separately (20 msg/s free, 50 Pro, 1,000 Team) — and it never touches your WAL, your IOPS, or the single-threaded poller. It also deletes the 15 s polling timer, because Presence emits leave events. Constraint to respect: 10 presence keys per object, 5 presence calls per client per 30 s — a 5 s re-stamp violates that limit and must go anyway.
2. **Convert the 16 `onPostgresChanges` sites to broadcast-from-database.** Replace `RealtimeService.coupleTable` with a trigger calling `realtime.broadcast_changes('feature:' || NEW.couple_id, TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD)` and an `onBroadcast` client binding. This moves fan-out from your Postgres to the BEAM cluster (10,000 msg/s benchmarked for the DB-triggered path vs 30/s for postgres_changes-with-RLS), and moves RLS from per-row-per-subscriber to once-at-join-then-cached. Then `DROP … FROM PUBLICATION supabase_realtime` for every table — an empty publication makes the poller refuse to create a replication slot at all.
3. **One `SupabaseClient`, one websocket.** Already true via `SupabaseService.client`. Keep it: 27 topics on one socket = 1 billable connection, well under the 100-channels-per-connection cap.
4. **RLS hygiene, mechanically checkable.** Every policy on `presence`, `messages`, `chat_receipts` etc. should be `TO authenticated`, use `(select auth.uid())` not `auth.uid()`, and have an index on the `couple_id` / `user_id` column. Documented deltas: 170 ms → <0.1 ms, 179 ms → 9 ms, 171 ms → <0.1 ms. Flagged gap: **I did not read the project's RLS policies** — this needs an actual `\d+` / policy dump to verify, not assumption.
5. **Private-channel authorization.** Broadcast-from-database needs RLS on `realtime.messages` gating `topic` to the caller's couple. The obvious policy shape is `topic LIKE '%:' || couple_id_of((select auth.uid()))`, which needs a `SECURITY DEFINER` helper (documented 11,000 ms → 7 ms improvement for exactly this join-avoidance pattern). Note the observability gap: **"Private Channel Subscription RLS Execution Time" is a Pro-and-above report**, so on Free you are flying blind on join-time RLS cost.

## What needs a paid tier

- **>200 concurrent devices** — hard wall, Free has no overage, it fails closed with `too_many_connections`. Pro ($25) → 500.
- **>500 concurrent, or >500 msg/s** — Pro with the spend cap **disabled** (spend caps are ON by default), which raises the ceiling to 10,000 concurrent / 2,500 msg/s / 2,500 joins/s.
- **>100 msg/s aggregate on Free.** With 200 connections that is 0.5 msg/s per device — a couple sending typing indicators blows through it. And per `ENVS.md` the tenant default is `TENANT_MAX_BYTES_PER_SECOND=100_000`: 100 KB/s for the entire project. The `touch:$id` channel binds `photo`, `frame`, `neon` and `reaction_gif` broadcast events — if any of those carries image bytes, that ceiling is the binding constraint long before message count is.
- **Smart CDN** (Pro+). On Free, media re-fetches hit origin.
- **Broadcast-from-DB replication lag + RLS execution time reports** (Pro+). Without them you cannot tell whether the trigger path is falling behind.
- **>500 MB database / >1 GB storage** — a media-heavy couples app crosses this almost immediately.

## What does not exist yet and must be built

- **A dead-letter path for pg_net.** If FCM push is dispatched from a trigger via `pg_net`, the app has no retry and no visibility: 2 s default timeout, ~200 req/s ceiling, responses garbage-collected after 6 hours, no documented retry. You need a `pg_cron` job that scans `net._http_response` for `status_code >= 400 OR error_msg IS NOT NULL OR timed_out` and re-enqueues — plus an outbox table, because after 6 h the evidence is gone. **I did not verify whether this app uses pg_net for push** — check `E:\LDR\supabase\migrations` for `net.http_post` before acting on this.
- **Monitoring for `cron.job_run_details`.** No documented retention or cleanup; it grows forever on a 500 MB database, and failures surface only if something queries it. Respect the documented guidance: ≤8 concurrent jobs, ≤10 min each.
- **Client-side broadcast throttling.** `touch_trace_canvas.dart` and `touch_map_screen.dart` stream continuous gesture data. Nothing in the SDK rate-limits this; hitting the server limit costs you a `tenant_events` **disconnect**, not a dropped message. Coalesce to a fixed tick (30–60 ms) and drop intermediate frames client-side.
- **A reconciliation read after every reconnect.** Broadcast is at-most-once with no acks and no gap detection; the 72 h replay buffer returns at most 25 messages per request. `ManagedSubscription` already rejoins on `realtimeResumed`; it must also refetch, or a message dropped during a tunnel loses forever. This is the "durable path is the source of truth" invariant and it is the one thing that makes moving off postgres_changes safe.
- **Signed-URL strategy for private media.** Private buckets defeat the CDN ("permissions … checked on a per user level"), each signed URL is its own cache key, and revoking a token does **not** purge its cache entry. For a disguised private app that last point is a security property, not just a cost one.

## Scale
## Where each approach breaks

**postgres_changes** — breaks at **30–64 changes/sec on the whole project**, regardless of compute. Not 30/sec per table: one single-threaded poller drains one slot for the entire tenant. Cost per row change is O(all subscribers to that table) filter evaluations + O(matching subscribers) RLS executions, burned on your own Postgres CPU. Scaling compute 370x (Micro → 16XL) moves this from 30 to 40 changes/sec. At 100,000 clients the benchmark shows 0.1 changes/sec — total collapse. For this app, with `presence` re-stamped every 5 s during chat, that is **~150 concurrently-chatting users**.

**Broadcast (client → client)** — 250,000 concurrent users / 500,000 joins / 800,000+ msg/s benchmarked, median 58 ms, p99 508 ms. The practical wall is not throughput, it is your plan's msg/s quota (100 / 500 / 2,500) and `TENANT_MAX_BYTES_PER_SECOND` (100 KB/s at the self-host default). Latency degrades with payload: at 4,000 users, 1 KB → 50 KB moves median 13 ms → 27 ms and p99 85 ms → 146 ms; halving concurrency at 50 KB (2,000 users) gets 14,000 msg/s at 19 ms median.

**Broadcast-from-database** — 80,000 concurrent users / 160,000 joins but only **10,000 msg/s**, median 46 ms, p95 132 ms. One order of magnitude below client broadcast — the WAL round-trip through `realtime.messages` is the cost. Good for tens of thousands of *connections*; not for high-frequency streams. Keep gestures, typing and cursors on client broadcast; put durable-event notifications on DB broadcast.

**Presence** — quota'd at 20 / 50 / 1,000 msg/s and 5 client calls per 30 s. Cheap because it is in-memory CRDT with 1.5 s batching, but the 5-calls-per-30-s cap means presence cannot be used as a high-frequency channel. Suits online/offline/screen; does not suit "typing" at keystroke rate (use broadcast for that).

**Connections** — hard cliff at **10,000 concurrent** on Pro-no-cap/Team. Past that: Enterprise, or self-host Realtime (Elixir/Phoenix, horizontally clustered — `MAX_CONNECTIONS=16384` per node) against a managed Supabase Postgres.

**Database connections** — not the bottleneck for a mobile client, which speaks HTTP to PostgREST. It becomes one if Edge Functions open connections per invocation: Nano/Micro give 60 direct / 200 pooler clients. Use transaction mode on 6543 with prepared statements disabled. Separately, Realtime's authorization pool defaults to **5 connections** (`DB_POOL_SIZE`) — at high join rates that is what serializes, and it is tunable in the dashboard.

**Edge Functions** — the **2 s CPU limit per request** is the real ceiling, not the 150/400 s wall clock. Any fan-out loop (signing 200 URLs, hashing, image work) must be chunked or moved to a queue. No concurrency ceiling is published, so it is not a number you can design against.

**pg_net** — ~200 req/s, 2 s default timeout, 6 h response TTL, no documented retry. Fine for a couples app (2 pushes per message); not a delivery system.

**Disk** — Nano baseline 250 IOPS / 5 MB/s after burst credits exhaust. A heartbeat-write design will sit at baseline permanently.

## Monthly cost curve

**Model assumptions (INFERRED — these drive everything, change them and the numbers move):** users = individuals, 2 per couple. Peak concurrency **8% of registered users** (mobile social app rule of thumb). Billable messages = events × (recipients + 1); a couple channel with both clients subscribed bills **3** per broadcast (1 send + 2 receives). Post-refactor event budget: ~200 events/user/day (chat + typing + presence diffs + game/touch bursts), i.e. **~600 billable messages/user/day = 18,000/user/month**. Media 20 MB/user/month, private buckets → uncached egress.

### 1,000 users — **~$25–60/mo** (Pro; Free is technically survivable, but don't)
- Peak concurrent: ~80. Free's 200 fits. Pro's 500 fits with room.
- Messages: 1,000 × 18,000 = **18 M/mo**. Free's 2 M is blown 9x. Pro: 13 M over × $2.50/M = **$32.50**.
- Free's 100 msg/s also fails: 80 devices at ~0.5 events/s × 3 = 120 msg/s.
- Compute: Micro (~$10) covered by Pro's $10 compute credit. Egress: 1,000 × 20 MB = 20 GB, under Pro's 250 GB.
- **Total ≈ $25 + $33 = ~$58/mo.** Free tier is *not* viable at 1,000 users — the message quota breaks first, at roughly **110 users** (2 M ÷ 18,000).

### 10,000 users — **~$500–600/mo** (Pro, spend cap OFF)
- Peak concurrent: ~800 → exceeds Pro's capped 500. Must disable the spend cap to reach the 10,000 ceiling. Overage: 300 over, billed in whole 1,000-packages = **$10**.
- Messages: **180 M/mo** → 175 M over × $2.50 = **$437.50**. This dominates the bill.
- Peak msg/s: 800 × 1.5 ≈ 1,200/s — needs the 2,500/s tier, i.e. spend cap off. Confirms the same requirement.
- Compute: Small–Medium, ~$15–60. Egress: 200 GB media + realtime ≈ under/near 250 GB.
- **Total ≈ $500–560/mo.** With postgres_changes still in place this configuration **does not work at any price** — you would be 40x past the 30 changes/sec ceiling.

### 100,000 users — **~$5,000–6,500/mo, and you are at the platform's hard wall**
- Peak concurrent: ~8,000. Under the 10,000 cap but with no headroom — a viral day or a push-notification-induced thundering herd puts you over, and over means `too_many_connections`, not a bigger invoice. Connection overage: 7,500 over → 8 packages = **$80**.
- Messages: **1.8 B/mo** → 1,795 M over × $2.50 = **$4,487.50**. ~85% of the bill.
- Peak msg/s: 8,000 × 1.5 = 12,000/s — **~5x over the 2,500/s Team ceiling.** This is a hard stop, not an overage. Enterprise or self-hosted Realtime.
- Compute: Large–XL, $110–210. Egress: 2 TB private media, mostly uncached → (2,000 − 250) × $0.09 = **$157.50**, plus realtime egress.
- Storage: 100 k × 20 MB accumulating; at 2 TB that is (2,000 − 100) × $0.0213 = **$40/mo** and rising monthly.
- **Total ≈ $5,000–6,500/mo** — *if* Supabase grants the quota. Team ($599) does not raise the 10,000-connection or 2,500 msg/s ceiling; it is Enterprise pricing or you self-host the Realtime cluster (Elixir, `MAX_CONNECTIONS=16384`/node) against managed Postgres.

### The shape of the curve
Cost is **~85–90% Realtime messages** at every scale past 1,000 users, and it is superlinear in engagement, not in users. The two levers that actually move it, in order:

1. **Cut events, not users.** Coalescing typing indicators from per-keystroke to a 1 Hz tick, and presence from 5 s to Presence-CRDT diffs, plausibly removes 60–80% of the message count. At 10 k users that is $437 → ~$110. This is the highest-leverage change available and it is a client-side refactor.
2. **Do not subscribe the sender to its own channel** if you can render optimistically — turns 3 billable messages per broadcast into 2, a flat 33% cut.

Compute, storage and egress are rounding errors until ~50 k users. **Free tier's real capacity for this app is roughly 100–150 users** (message quota) or **~150 concurrently-chatting users** (postgres_changes ceiling), whichever you hit first — and today, with presence on a published table, it is the latter.

## Sources
- [Supabase Realtime — documented per-plan quotas (connections, msg/s, joins/s, channels, presence, payload sizes) and breach error codes](https://supabase.com/docs/guides/realtime/limits) — Free 200 concurrent / 100 msg-s / 100 joins-s / 20 presence msg-s / 256 KB broadcast payload; Pro 500 / 500 / 500 / 50 / 3,000 KB; Pro-no-spend-cap and Team 10,000 / 2,500 / 2,500 / 1,000. Channels per connection 100 on every plan. Errors: too_many_channels, too_many_connections, too_many_joins, tenant_events.
- [Supabase Realtime pricing — included allowances and overage rates](https://supabase.com/docs/guides/realtime/pricing) — Free 200 peak connections + 2 M messages/mo; Pro and Team 500 peak connections + 5 M messages/mo. Overage $2.50 per 1 M messages and $10 per 1,000 peak connections.
- [Supabase — how Realtime messages are counted for billing](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages) — "Each broadcast message counts as one message sent plus one message per subscribed client that receives it… if you broadcast a message and 4 clients listen to it, it counts as 5 messages." Database changes count one message per listening client.
- [Supabase — how Realtime peak connections are counted for billing](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-peak-connections) — Billed on "the highest number of concurrent connections for each project during the billing cycle"; only successful connections count; package-based rounding, so 1,001 connections bills 2 packages = $20.
- [Supabase Realtime benchmarks (k6, published results)](https://supabase.com/docs/guides/realtime/benchmarks) — Broadcast: 250,000 concurrent users / 500,000 joins at 800,000+ msg/s, median 58 ms, p99 508 ms. Broadcast-from-database: 80,000 users at 10,000 msg/s, median 46 ms, p99 159 ms. Postgres Changes: 64 changes/s max without RLS at 500 clients, 30 changes/s with RLS — and only 40 changes/s even on Large–16XL; 0.1 changes/s at 100,000 clients.
- [Supabase docs — Postgres Changes limitations](https://supabase.com/docs/guides/realtime/postgres-changes) — "When you make a single change to a table with 100 subscribed users, Realtime performs 100 authorization checks — one per user." Changes are "processed on a single thread to preserve their order, which means larger compute add-ons don't meaningfully increase Postgres Changes throughput." Recommends Broadcast above ~3,000 concurrent subscribers on the same change. DELETE filtering requires REPLICA IDENTITY FULL.
- [supabase/realtime source — postgres_cdc_rls default settings](https://github.com/supabase/realtime/blob/main/lib/extensions/postgres_cdc_rls/db_settings.ex) — poll_interval_ms = 100, poll_max_changes = 100, poll_max_record_bytes = 1_048_576, publication = supabase_realtime, slot_name = supabase_realtime_replication_slot.
- [supabase/realtime source — apply_rls SQL function (the per-subscriber RLS loop)](https://github.com/supabase/realtime/blob/main/lib/realtime/tenants/repo/migrations/20211116214523_create_realtime_apply_rls_function.ex) — `subscriptions := array_agg(sub) from realtime.subscription sub where sub.entity = entity_;` then `for … in unnest(subscriptions) loop … set_config('request.jwt.claim.sub', user_id) ; execute 'execute walrus_rls_stmt' into user_has_access ; end loop;` — loop is over ALL subscribers to the table; the eq filter is checked inside the loop, it does not shrink it. Oversized records return 'Error 413: Payload Too Large'.
- [supabase/realtime source — list_changes uses wal2json inside your Postgres](https://github.com/supabase/realtime/blob/main/lib/realtime/tenants/repo/migrations/20230328144023_create_list_changes_function.ex) — Calls pg_logical_slot_get_changes(slot_name, null, max_changes, 'format-version','2', 'actions', …, 'add-tables', …) — WAL decoding and RLS evaluation both execute on the tenant's own database CPU, not on Realtime's cluster.
- [supabase/realtime source — replication poller lifecycle](https://github.com/supabase/realtime/blob/main/lib/extensions/postgres_cdc_rls/replication_poller.ex) — "Polls the write-ahead log via a temporary logical replication slot, applies row level security policies for each subscriber." @idle_multiplier 5 (idle poll backs off to 500 ms), @check_oids_interval 60_000 ms; drops the slot when the publication is empty so an unconsumed slot cannot retain WAL.
- [supabase/realtime ENVS.md — tenant and server defaults](https://github.com/supabase/realtime/blob/main/ENVS.md) — DB_POOL_SIZE=5 (the pool used for Realtime Authorization RLS checks), MAX_CONNECTIONS=16384/node, WEBSOCKET_MAX_HEAP_SIZE=50MB, TENANT_MAX_CONCURRENT_USERS=200, TENANT_MAX_EVENTS_PER_SECOND=100, TENANT_MAX_JOINS_PER_SECOND=100, TENANT_MAX_CHANNELS_PER_CLIENT=100, TENANT_MAX_BYTES_PER_SECOND=100_000 (100 KB/s per project), PRESENCE_BROADCAST_PERIOD_IN_MS=1500, CLIENT_PRESENCE_MAX_CALLS=5 per CLIENT_PRESENCE_WINDOW_MS=30000, CONNECT_ERROR_BACKOFF_MS=2000, CHANNEL_ERROR_BACKOFF_MS=5000.
- [Supabase docs — Realtime Authorization (when RLS is evaluated for channels)](https://supabase.com/docs/guides/realtime/authorization) — "The validation is done when the user connects… their permissions are calculated" — Realtime runs a query against realtime.messages and rolls it back. "Client access policies are cached for the duration of the connection. Your database is not queried for every Channel message." Client is disconnected when the JWT expires unless it sends a fresh access_token.
- [Supabase docs — Broadcast and Broadcast-from-Database mechanism](https://supabase.com/docs/guides/realtime/broadcast) — realtime.broadcast_changes() fires from an AFTER INSERT/UPDATE/DELETE FOR EACH ROW trigger and inserts into realtime.messages, which is daily-partitioned with partitions dropped after 3 days (retention at least 72 h, at most 4 days). Realtime reads the WAL via a publication against realtime.messages. Private DB broadcasts only reach private client channels.
- [Supabase blog — Realtime: Broadcast from Database (2 Apr 2025)](https://supabase.com/blog/realtime-broadcast-from-database) — "These improvements let us scale subscribing to database changes to tens of thousands of connected users at once." realtime.send catches exceptions and uses pg_notify to report them, so a Realtime failure cannot fail the business transaction.
- [Supabase docs — Realtime architecture](https://supabase.com/docs/guides/realtime/architecture) — "Realtime delivers changes by polling the replication slot and appending channel subscription IDs to each wal record." Broadcast is Phoenix Channels over Phoenix.PubSub with the PG2 adapter (Erlang process groups); Presence is "an in-memory key-value store backed by a CRDT".
- [Supabase blog — Realtime Multiplayer GA (Presence implementation)](https://supabase.com/blog/supabase-realtime-multiplayer-general-availability) — Presence uses Phoenix Presence / Phoenix Tracker, "a delta-based conflict-free replicated data type (CRDT) for eventually consistent and conflict-free synced state"; the Realtime cluster runs on Fly with clients routed to the nearest node.
- [Supabase docs — subscribing to database changes (official recommendation)](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes) — Broadcast is "the recommended method for scalability and security"; Postgres Changes "does not scale as well as Broadcast". No numeric switch threshold is given on this page.
- [Supabase docs — compute and disk (connections, pooler clients, IOPS)](https://supabase.com/docs/guides/platform/compute-and-disk) — Nano/Free: 0.5 GB, shared burstable CPU, 60 direct connections, 200 pooler clients, gp3 with 250 baseline IOPS / 5 MB/s baseline (burst 11,800 IOPS / 261 MB/s), 500 MB DB. Micro 60/200 ~$10; Small 90/400 ~$15; Medium 120/600 ~$60; Large 160/800 ~$110; XL 240/1,000 ~$210; 4XL 480/3,000 ~$960; 16XL 500/12,000 ~$3,730. "Once burst capacity is exhausted, performance returns to baseline."
- [Supabase docs — connecting to Postgres / Supavisor modes](https://supabase.com/docs/guides/database/connecting-to-postgres) — Direct + shared pooler session mode on port 5432; transaction mode on 6543. "Transaction mode does not support prepared statements" — must be disabled in the client library. Pool size setting caps server-side connections Supavisor opens.
- [Supabase blog — Supavisor: Scaling Postgres to 1 Million Connections](https://supabase.com/blog/supavisor-1-million) — 1,003,200 client connections across two 64-core nodes at 20,000 QPS with a 400-connection DB pool; only one node holds direct DB connections, others relay. At 5,000 QPS Supavisor adds ~2 ms vs co-located PgBouncer (median 4 ms vs 1 ms, p99 5 ms vs 3 ms). At 20,000 QPS: median 18.4 ms, p95 46.9 ms, p99 68 ms.
- [Supabase docs — RLS performance and best practices (measured)](https://supabase.com/docs/guides/troubleshooting/rls-performance-and-best-practices-Z5Jjwv) — Index the policy column: 171 ms → <0.1 ms ("over 100x on large tables"). Wrap auth.uid() in a subselect so it is cached: 179 ms → 9 ms, and 178,000 ms → 12 ms on a complex policy. Reverse the join direction in a policy: 9,000 ms → 20 ms. Security definer function: 11,000 ms → 7 ms. Add TO authenticated: 170 ms → <0.1 ms.
- [Supabase docs — Edge Function limits](https://supabase.com/docs/guides/functions/limits) — Wall clock 150 s free / 400 s paid; CPU time 2 s per request; memory 256 MB; request idle timeout 150 s → 504; function size 20 MB CLI-bundled / 5 MB server-bundled; 100/500/1,000 functions per project by plan; 100 secrets; log throttle 100 events per 10 s; recursive self-calls cap ~5,000 req/min.
- [Supabase docs — Edge Functions architecture](https://supabase.com/docs/guides/functions/architecture) — "A new V8 isolate is spun up for each invocation"; "Even initial executions are fast (milliseconds) due to the compact ESZip format"; "Isolates can remain active for a period (plan-dependent)". No concurrency ceiling or exact cold-start figure is published.
- [Supabase docs — pg_net](https://supabase.com/docs/guides/database/extensions/pg_net) — Async; requests do not start until the transaction commits. Default timeout 2000 ms. "Configured to reliably execute up to 200 requests per second." Responses stored in net._http_response for 6 hours by default (pg_net.ttl). No automatic retry documented; failures visible only by querying status_code, error_msg, timed_out.
- [Supabase docs — Cron / pg_cron](https://supabase.com/docs/guides/cron) — Schedules "anywhere from every second to once a year". Every run recorded in cron.job_run_details. "For best performance, we recommend no more than 8 Jobs run concurrently" and "Each Job should run no more than 10 minutes." Retention/cleanup of job_run_details and overrun behaviour are not documented.
- [Supabase docs — egress usage definition](https://supabase.com/docs/guides/platform/manage-your-usage/egress) — Database, Auth, Storage, Edge Functions and Realtime all contribute; "Data pushed to clients via Supabase Realtime for subscribed events" is billed egress. Free 5 GB uncached + 5 GB cached; Pro/Team 250 + 250; overage $0.09/GB uncached, $0.03/GB cached.
- [Supabase pricing page](https://supabase.com/pricing) — Free $0 (500 MB DB, 1 GB storage, 50,000 MAU, 500 k function invocations); Pro $25 (8 GB disk then $0.125/GB, 100 GB storage then $0.0213/GB, 100,000 MAU then $0.00325/MAU, 2 M invocations then $2/M); Team $599. Pro spend caps are ON by default — with the cap on, Realtime stays at 500 connections.
- [Supabase docs — Storage Smart CDN](https://supabase.com/docs/guides/storage/cdn/smart-cdn) — "Smart CDN caching is automatically enabled for Pro Plan and above." Invalidation "can take up to 60 seconds". Default TTL ~1 hour. "Each signed URL maintains its own independent cache entry due to unique token parameters"; "revoking or expiring a token does not purge its CDN cache entry."
- [Supabase docs — Storage CDN fundamentals (private bucket cache behaviour)](https://supabase.com/docs/guides/storage/cdn/fundamentals) — Public buckets cache better because in private buckets "permissions for accessing each object is checked on a per user level", producing cache misses — i.e. private media bills as uncached egress at $0.09/GB.
- [Supabase docs — project suspended for exceeding Realtime quotas](https://supabase.com/docs/guides/troubleshooting/realtime-project-suspended-for-exceeding-quotas) — Sustained overage leads to manual suspension: error RealtimeDisabledForTenant, "connections will fail to establish and existing subscriptions will stop receiving events". Named causes include reconnect loops from failed auth and unmanaged channel accumulation. Lifting it requires a support ticket.
- [Supabase docs — Realtime reports (observability)](https://supabase.com/docs/guides/realtime/reports) — Connected Clients, Broadcast/Presence/Postgres Changes events, rate of channel joins, payload size, response errors and speed are available on all plans; but Broadcast-from-Database replication lag and read/write private-channel RLS execution time are Pro/Team/Enterprise only. No per-channel or per-tenant dimensional breakdown.
- [Supabase docs — Auth rate limits](https://supabase.com/docs/guides/auth/rate-limits) — Token refresh 1,800/hour per IP (burst 30); verify 360/hour per IP; anonymous sign-ins 30/hour per IP; MFA challenge 15/hour per IP; built-in SMTP 2 emails/hour project-wide; OTP 30/hour project-wide with a 60 s per-user window.
- [GitHub Discussion #21995 — Supabase collaborator on connection counting](https://github.com/orgs/supabase/discussions/21995) — "Typically there is one connection per browser tab and all channels share that connection" — channels multiplex onto a single websocket. Reported overages usually come from creating multiple client instances rather than reusing one. The 200 limit is simultaneous, not cumulative.
- [GitHub Discussion #27146 — Supabase on connection billing](https://github.com/orgs/supabase/discussions/27146) — "The realtime bill for the month is based on the peak connections (websockets) during the month." 10,000 peak → ~$100/mo in connection charges.
