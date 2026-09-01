# Presence and last-seen at scale: how Slack, Discord, WhatsApp and Signal implement online/offline/last-seen/typing, and how that maps onto Flutter + Supabase Realtime Presence vs a Postgres heartbeat table

## Mechanism
## 0. The one-line summary

Nobody stores presence in their durable database. In every system I could read the source of, presence is a **derived property of an open transport connection**, held in an ephemeral store (Redis / ETS / BEAM process state), with a TTL strictly longer than the heartbeat interval, and reconciled by a sweeper. "Last seen" is the only piece that is durable, and it is written **once on transition to offline**, not on every heartbeat.

---

## 1. Heartbeat interval vs TTL/expiry — the actual numbers

### Signal (legacy design, retired Nov 2024 — best-documented lease pattern)
Signal's `ClientPresenceManager` (source read at ref `c2270e5`) was a textbook Redis lease:

- `PRESENCE_EXPIRATION_SECONDS = Duration.ofMinutes(11)` — TTL on the presence key
- `PRUNE_PEERS_INTERVAL_SECONDS = Duration.ofSeconds(30)` — sweeper cadence
- On connect: `commands.sadd(connectedClientSetKey, presenceKey)` then `commands.setex(presenceKey, PRESENCE_EXPIRATION_SECONDS, managerId)`. **The value of the key is the ID of the server that owns the connection**, not a boolean.
- Renewal is a Lua script, not a plain `EXPIRE`:
```lua
-- renew_presence.lua
if redis.call("GET", presenceKey) == presenceUuid then
    redis.call("EXPIRE", presenceKey, expireSeconds)
end
```
- Clearing is compare-and-delete, not `DEL`:
```lua
-- clear_presence.lua
if redis.call("GET", presenceKey) == presenceUuid then
    redis.call("DEL", presenceKey); return true
end
return false
```
- A `presence::managers` Redis set holds every live server ID; `pruneMissingPeers()` runs every 30s, diffs that set against actual peers, and for each dead peer walks its `connectedClientSet` calling `clearPresenceScript` **with the dead peer's ID as the CAS token**.

The CAS on both renew and clear is the whole trick, and it's the part people get wrong. See Invariants.

### Signal (current design)
Signal **removed the TTL key entirely** (commit `1c167ec`, "Retire the legacy client presence system", 2024-11-05) and replaced it with `RedisMessageAvailabilityManager` on Redis 7 sharded pub/sub. Presence is now: *"Clients are considered 'present' if they have an open WebSocket connection"* — an in-process `listenersByAccountAndDeviceIdentifier` map, plus a pub/sub `ClientConnectedEvent` carrying a `serverId` to displace an older connection elsewhere in the fleet. The class javadoc is explicit that this is **best-effort, not exactly-once**: *"makes a best effort to ensure that a given client has only a single open connection across the fleet of servers, but cannot guarantee at-most-one behavior."*

There is a self-healing backstop: `GET /v1/keepalive` checks `isLocallyPresent(aci, deviceId)` and, if the server holds a socket it has no listener for, **closes the socket with code 1000** and records `closedConnectionAge`. The client's own keepalive is what evicts a zombie server-side registration.

### Discord gateway
- The **server** tells the client the heartbeat interval — `heartbeat_interval` arrives in the OP 10 `Hello` payload. Clients do not choose it. This lets Discord change the cadence fleet-wide without a client release.
- The first heartbeat must be delayed by `heartbeat_interval * jitter`, jitter ∈ [0,1), explicitly to avoid synchronized reconnect storms.
- Liveness is bidirectional: missing an OP 11 `Heartbeat ACK` means a *"failed or 'zombied' connection"* → terminate with a **non-1000 close code** and RESUME (non-1000 signals "I intend to come back", which changes server-side cleanup behaviour).
- Gateway budget: 120 events per connection per 60 seconds.

### Supabase / Phoenix (your stack's actual numbers)
Two independent timers you must not confuse:
- **Transport liveness**: supabase-js sends a `heartbeat` on the `phoenix` topic every **25,000 ms** (configurable via `heartbeatIntervalMs`); reconnect backoff is 1s, 2s, 5s, 10s. Phoenix's `websocket: [timeout: ...]` defaults to **60,000 ms** since last received data. Supabase's `endpoint.ex` sets `max_frame_size`, `active_n: 100`, `fullsweep_after`, `validate_utf8: false` — but **no `:timeout`**, so the 60s default stands. Ratio: 2 missed heartbeats before the socket dies.
- **Cluster presence liveness** (`Phoenix.Tracker`, which Supabase Presence is built on): `broadcast_period` 1500 ms, `max_silent_periods` 10 → effective heartbeat 15 s, `down_period` = 1500 × 10 × 2 = **30 s** (replica marked temporarily down), `permdown_period` = **1,200,000 ms (20 min)** (replica's presences permanently removed), `clock_sample_periods` 2, `pool_size` 1, `max_delta_sizes [100, 1000, 10_000]`.

**The design rule every one of these follows: TTL ≥ 2× heartbeat, and the sweeper period is independent of and shorter than the TTL.** Signal's legacy 11-minute TTL was deliberately far longer than any plausible heartbeat — the TTL is a crash backstop, not the detection mechanism. Detection was the 30s peer sweep. Getting this backwards (short TTL, slow sweep) produces flapping.

---

## 2. Server-authoritative time

Signal's `Envelope` proto carries **two separate timestamp fields**:
```protobuf
optional uint64 client_timestamp  = 5;
optional uint64 server_timestamp  = 10;
optional bool   ephemeral         = 12; // indicates that the message should not be persisted if the recipient is offline
```
and `MessagesManager` populates them like this:
```java
final long serverTimestamp = clock.millis();
...
.setClientTimestamp(clientTimestamp == 0 ? serverTimestamp : clientTimestamp)
.setServerTimestamp(serverTimestamp)
```
The client's claimed time is preserved as a *separate, differently-named field* and never overwrites the server's. The rename from `timestamp` to `client_timestamp` is itself the design signal: once you have two clocks, every field name must say whose clock it is.

Signal's typing message carries `System.currentTimeMillis()` from the sending device (`new SignalServiceTypingMessage(action, System.currentTimeMillis(), groupId)`) — but note the receiver **never compares that number to its own clock**. `TypingStatusRepository` ignores the embedded timestamp for expiry and instead runs a purely local 15-second timer from the moment of *receipt*. That is the pattern: a remote timestamp is metadata; freshness is always measured against a clock you control, over an interval you measured locally.

Discord's `Update Presence` has `since`: *"Unix time (in milliseconds) of when the client went idle"* — a client-supplied value that is **displayed**, never used to decide whether the session is alive. Liveness is the heartbeat ACK, full stop.

**The invariant: a device clock may appear in a payload, but must never appear on either side of a comparison that decides "is this fresh?".** Android device clocks drift, users set them manually, and timezone/DST bugs are endemic. A client that is 3 minutes fast will render itself permanently "online" or its partner permanently "5 minutes ago" depending on which side of the subtraction it lands on.

---

## 3. Being marked offline with no clean disconnect (process killed, radio dropped, Android LMK)

This is the case that matters most on Android, and there are exactly three mechanisms in use:

1. **TTL expiry** (Signal legacy). Process dies → renewal stops → key expires 11 min later. Cheap, no coordination, but slow.
2. **Supervisor/monitor death propagation** (Discord, Phoenix, Supabase). The user's session is a *process*. The socket closing kills the process; the guild/tracker is monitoring it and receives a `:DOWN`, emitting a leave immediately. This is why BEAM systems have such good presence — the runtime does liveness detection for free, at process granularity. INFERRED from BEAM semantics + Discord's documented session-process architecture; the blog describes session GenServers and guild fan-out but does not spell out the monitor.
3. **Peer-death sweep** (Signal legacy `pruneMissingPeers`, every 30 s). Handles the case where the *server* died, not the client — otherwise those clients stay "online" for the full TTL. Discord's equivalent falls out of distributed Erlang node monitoring.

The half-open TCP case (phone goes into a tunnel, no FIN ever arrives) is only caught by (1) — which is exactly why the TTL exists even in systems that have (2). Supabase gives you (2) and (3) automatically via `Phoenix.Tracker`'s `down_period`/`permdown_period`, and (1) via the 60s socket timeout.

Slack punts on the hard case and uses an **activity** definition rather than a connectivity one: *"After 10 minutes with no activity, the user is automatically marked as `away`."* Connected-but-idle is a distinct state from disconnected. Discord has the same split: `online` / `idle` / `dnd` / `invisible` / `offline`, where `invisible` is documented as *"Invisible and shown as offline"* — a server-side lie, told deliberately.

---

## 4. Fan-out cost, and how it is contained

This is where presence actually kills systems. The naive cost is O(N²) per interval: N users each publishing a state change to N-1 watchers.

Discord quantified it precisely: *"1,000 online users = 1M notifications; 100,000 users = 10 billion notifications"*, and *"the amount of work needed to handle a discord server grows quadratically with the size of the server."* Their containment stack, in order of impact:

- **Manifold** — the raw `send/2` between Erlang nodes costs **30–70 µs** due to de-scheduling; publishing one event from a large guild took **900 ms to 2.1 s**. Manifold groups destination PIDs by remote node, sends *one* message per node to a `Partitioner`, which re-hashes with `:erlang.phash2/2` across workers by core count. One cross-node message instead of thousands, while preserving linearizability of delivery order.
- **Passive sessions** — ~90% of user↔guild connections in large guilds are passive (user isn't looking at that server). Passive sessions don't get the firehose; they're "upgraded" on view. **~90% less fan-out work, ~3× capacity.**
- **Relays** — an intermediate process tier, each owning **up to 15,000 sessions**, doing permission-filtered fan-out so the single guild process isn't the bottleneck. First version replicated the whole member list into every relay → tens of millions of members in RAM across dozens of copies, **10+ second stalls** creating a relay. Fixed by having relays track only the subset they need.
- **Passive Sessions V2 (delta, not snapshot)** — `passive_update_v1` was **35.61% of all gateway traffic but only ~2% of dispatches**, because it shipped a full snapshot of channels/members/voice on any single change. V2 sends only the delta → **4.73%**, a 20% cluster-wide bandwidth cut. Combined with zstd streaming (level 6, chainlog/hashlog 16, windowlog 18; MESSAGE_CREATE 270 B → 166 B, ratio 6 → ~10, 100 µs → 45 µs per byte) the total was **~40% gateway bandwidth reduction**.

Slack's containment is **opt-in subscription**, and they changed the API contract to force it:
- Presence moved to pub/sub → *"the number of presence events received by clients was reduced by a factor of 5."*
- As of Nov 15 2017 / Jan 2018, `presence_change` is **not dispatched at all** without an explicit `presence_sub`. `rtm.start` stopped returning initial presence for each user.
- `presence_sub` is **replace-semantics**: *"All subscription requests require the entire subscription list each invocation."* Stateless server-side, no incremental leak.
- Hard guidance: *"Subscribing to all user's presence events requires specifying every user's ID. This is not recommended... 500 users is a good maximum."* `presence_query` caps at 500 IDs; `users.list` caps accurate presence at 500 users per workspace.

Slack's edge tier (Flannel) carries **4M simultaneous connections at peak, 600K client queries/sec**, with consistent hashing on team+region for cache affinity — presence rides that, it doesn't get its own infrastructure.

**Generalised: subscribe (don't broadcast) → shard the fan-out tier → coalesce/delta instead of snapshot → suppress for viewers who aren't looking.** In that order of payoff.

---

## 5. Why presence stays out of the durable database

Reasons, in the order they'll bite you:

1. **Write amplification with zero durability value.** N users × (1 / heartbeat) writes/sec forever. At 10k users on a 30s heartbeat that's 333 writes/sec of data whose value expires in 30 seconds.
2. **Postgres MVCC specifically**: every `UPDATE` writes a new tuple and marks the old one dead. A hot presence table becomes an autovacuum treadmill; the index bloats; `n_dead_tup` outruns the vacuum threshold; and on Supabase's shared free-tier compute that competes with your actual queries. (Documented Postgres MVCC behaviour; the "on free tier this competes" step is INFERRED.)
3. **WAL amplification** — every heartbeat is replicated. On Supabase, that WAL feeds the Realtime replication slot, so heartbeats become Realtime work too.
4. **It's a lease, not a fact.** Presence is only meaningful relative to a clock and a TTL. Redis `SETEX`/ETS express that natively; a Postgres row does not, so you re-implement expiry in every read path (`WHERE last_seen > now() - interval '45 seconds'`) and every one of those is a chance to get it wrong.
5. **Crash semantics.** Durable stores are durable across crashes — which is precisely the wrong behaviour. Signal's `ephemeral` flag exists to say *"do not persist this."*

WhatsApp's presence is in-memory in Erlang (Rick Reed's Erlang Factory work took a single box from ~1M to **2.8M+ connections**; ~450M MAU, **147M+ peak concurrent connections on ~550 servers / 11,000+ cores** in early 2014). The "presence never touches a database" claim for WhatsApp is widely repeated but I could not find it in a primary WhatsApp source — treat as INFERRED from the ejabberd/Mnesia architecture.

**Signal takes this furthest: it has no presence or last-seen at all.** No online indicator, no last-seen timestamp. The only leakage is the typing indicator. That is a product decision that removes an entire subsystem — worth naming explicitly when you're weighing whether your app needs last-seen.

---

## 6. Typing indicators and debounce — Signal's exact constants

Read from `Signal-Android` source (not documentation), and this is the cleanest reference implementation available:

**Sender** (`TypingStatusSender.java`):
```java
private static final long REFRESH_TYPING_TIMEOUT = TimeUnit.SECONDS.toMillis(10);
private static final long PAUSE_TYPING_TIMEOUT   = TimeUnit.SECONDS.toMillis(3);
```
- On first keystroke: send `STARTED` **immediately** (no leading debounce — latency is the whole point of the feature), then schedule a self-rescheduling refresh every **10 s** while typing continues.
- Every keystroke cancels and re-arms a **3 s** stop timer; 3 s of silence → send `STOPPED`.
- Sending a message calls `onTypingStoppedWithNotify`.

**Receiver** (`TypingStatusRepository.java`):
```java
private static final long RECIPIENT_TYPING_TIMEOUT = TimeUnit.SECONDS.toMillis(15);
```
Per-`(recipient, device, thread)` timer, re-armed on each `STARTED`. **15 s receiver expiry vs 10 s sender refresh gives exactly one missed refresh of tolerance** — that 1.5× ratio is the same TTL/heartbeat discipline as §1, applied at the UI layer.

**Transport discipline** (`TypingSendJob.java`) — this is the part most implementations miss:
```java
.setQueue("TYPING_" + threadId)   // per-thread serialisation; no reordering of start/stop
.setMaxAttempts(1)                // never retry
.setLifespan(TimeUnit.SECONDS.toMillis(5))  // expires if not sent within 5s
.addConstraint(NetworkConstraint.KEY)
.addConstraint(SealedSenderConstraint.KEY)
.setMemoryOnly(true)              // never hits disk
```
A typing indicator that arrives late is worse than one that never arrives, so it is given 5 seconds to live and exactly one attempt. Blocked/unregistered/self/inactive-group recipients are filtered before send, and the whole thing short-circuits on `isTypingIndicatorsEnabled`.

**Server side**: typing rides the `ephemeral` Envelope flag, and `MessageSender` gates push on it:
```java
if (!destinationPresent && !message.getEphemeral()) {
    pushNotificationManager.sendNewMessageNotification(destination, deviceId, message.getUrgent());
}
```
**A typing indicator never wakes a sleeping device and is never queued for later delivery.** Equivalent for you: typing must never generate an FCM push.

**Other systems**: XEP-0085 defines `active`/`composing`/`paused`/`inactive`/`gone` with suggested thresholds — `paused` after ~30 s, `inactive` after ~2 min, `gone` after ~10 min — and mandates *"a client MUST NOT send more than one standalone `<composing/>` notification in a row"* (idempotent-send debounce at the protocol level). WhatsApp Cloud API: *"The typing indicator will be dismissed once you respond, or after 25 seconds, whichever comes first."*

---

## 7. Privacy controls

- **WhatsApp — reciprocity is the design.** *"If you don't share your last seen, you can't see other contacts' last seen either."* Options are Everyone / My Contacts / My Contacts Except… / Nobody. Since Aug 2022 there is a separate "Who can see when I'm online" with only two options — **Everyone** or **Same as last seen** — deliberately not fully independent. Reciprocity is what stops the free-rider equilibrium where everyone hides and everyone still watches. It's enforced server-side, not client-side.
- **Discord** — `invisible`: *"Invisible and shown as offline."* The server reports offline to watchers while the session is live. Client-side hiding would be trivially defeated.
- **Slack** — `users.setPresence` manual override persists across connections and beats auto-away.
- **Signal** — no presence at all; typing indicators are a single opt-out toggle, default on for new installs, and the setting is checked in `TypingSendJob.onRun()` (send-side suppression, so nothing leaves the device).
- **Supabase** — you get real server-side enforcement via RLS on **private channels**. `presence_handler.ex` gates on `socket.assigns.policies.presence.read` / `.write`, evaluated against your `realtime.messages` RLS policies at join (and lazily on first `track` if presence was disabled at join). This is genuinely equivalent in strength to what the big apps do, because it's enforced in the Realtime server, not the client.

**Non-negotiable rule from all four: presence privacy is enforced at the fan-out point, never by the receiving client.** If a payload reaches a client that shouldn't see it, you've already lost.

## Invariants
- TTL > heartbeat interval, by a factor of at least 2. Phoenix.Tracker: 15s heartbeat, 30s down_period (exactly 2x, by construction: down_period = broadcast_period * max_silent_periods * 2). Supabase transport: 25s heartbeat, 60s socket timeout (2.4x). Signal typing: 10s refresh, 15s receiver expiry (1.5x). One dropped packet must never flip a user offline.
- Detection cadence and expiry TTL are separate, independently tuned knobs. Signal legacy: 30s peer-prune sweep with an 11-minute key TTL. The sweep is what makes offline detection fast; the TTL is only a crash backstop for cases the sweep cannot see. Collapsing them into one number forces you to choose between flapping and staleness.
- Presence-lease mutations are compare-and-swap on the owning server's identity, never blind writes. Signal's renew_presence.lua and clear_presence.lua both check `GET presenceKey == presenceUuid` first. Without this, a delayed disconnect handler from an old connection deletes the presence record of a newer connection that has already been established elsewhere — the classic reconnect-race that manifests as 'user randomly appears offline while actively using the app'.
- No device-supplied timestamp ever appears on either side of a freshness comparison. Signal's Envelope carries client_timestamp and server_timestamp as separate fields with names that state provenance; Signal-Android's typing receiver ignores the embedded timestamp entirely and times out from local receipt. Client clocks may be rendered, never compared.
- Presence is a derived property of a live transport connection, not an independently-writable fact. No client can assert 'I am online' as durable state; it can only hold a connection open. This makes 'offline' the default and failure-safe outcome — every failure mode (crash, netsplit, kill, radio loss) converges on offline without any component having to succeed at anything.
- Ephemeral signals are never persisted, never retried, and never wake a device. Signal's ephemeral Envelope flag drops the message if the recipient is not connected, and MessageSender explicitly skips the push notification for it; TypingSendJob is memoryOnly with maxAttempts(1) and a 5-second lifespan. A stale typing indicator is a worse product than a missing one.
- Fan-out is opt-in, not broadcast. Slack refuses to dispatch presence_change without an explicit presence_sub and caps practical subscriptions at ~500 users; Supabase defaults presence.enabled to false per channel. The default cost of adding a user to the system must be zero for everyone already in it.
- Updates carry deltas, not snapshots, once the watched set is non-trivial. Discord's passive_update_v1 was 35.61% of gateway bytes for ~2% of dispatches purely because it resent whole state on any single change.
- Privacy is enforced at the fan-out point, on the server. Discord's 'invisible' is reported as offline by the gateway; WhatsApp's reciprocity rule is server-enforced; Supabase gates presence read/write through RLS policies in the Realtime server. Filtering in the receiving client is not a privacy control.
- Identical payloads are suppressed rather than republished. Supabase's PresenceHandler returns {:error, :no_payload_change} when track() is called with the same payload it already holds — otherwise a periodic client-side refresh becomes a cluster-wide broadcast storm.

## Failure modes designed for
- Process killed with no clean close — Android low-memory killer, force-stop, crash. No FIN, no close frame. Covered by TTL expiry (Signal legacy 11 min) and by process-monitor death propagation on BEAM (immediate).
- Half-open TCP — phone enters a tunnel/lift, radio drops, kernel never learns the peer is gone. The socket looks alive on both sides indefinitely. Only heartbeat timeout catches this; this is the case that forces a TTL to exist even in systems with process monitors.
- Server death, not client death — a whole gateway node dies holding N presence leases. Signal's 30s pruneMissingPeers diffs the 'presence::managers' set against live peers and clears each dead peer's connectedClientSet with that peer's own ID as the CAS token. Without it, N users stay 'online' for the full TTL.
- Reconnect race / duplicate sessions — client reconnects to server B while server A's disconnect handler is still in flight. Solved by CAS-on-owner (Signal legacy) and by displacement events carrying a serverId (Signal current, explicitly documented as best-effort). Also why Discord distinguishes 1000 vs non-1000 close codes: non-1000 signals RESUME intent.
- Zombie server-side registration — server thinks it owns a socket it has no listener for. Signal's GET /v1/keepalive calls isLocallyPresent() and closes the socket with code 1000 if the check fails, letting the client's own keepalive perform the eviction, with a closedConnectionAge metric to observe how often it happens.
- Synchronized reconnect storm — a deploy or network blip disconnects everyone at once, and they all reconnect on the same tick. Discord mandates jittering the first heartbeat by heartbeat_interval * random(0,1). Slack's Flannel absorbs reconnect storms by serving recently-disconnected users from edge cache instead of hitting the backend.
- Quadratic fan-out — Discord's 100,000 online users = 10 billion notifications. Attacked with Manifold (one cross-node message per node instead of thousands), relays (15k sessions each), passive sessions (~90% of connections suppressed), and delta updates.
- Snapshot-instead-of-delta bandwidth waste — passive_update_v1 at 35.61% of gateway traffic for ~2% of dispatches.
- Head-of-line blocking on the presence path — Discord's guild process falling behind its message queue during peak. Mitigated by offloading member iteration to ETS-backed workers so the guild process never blocks.
- Network partition / split-brain in a clustered tracker — Phoenix.Tracker's CRDT converges without a coordinator; a silent replica is marked down at 30s but its presences are only permanently dropped at permdown_period = 20 minutes, so a brief netsplit does not mass-evict users.
- Out-of-order typing start/stop — a STOP overtaking a START leaves a permanently-stuck indicator. Signal serialises per thread with a "TYPING_<threadId>" job queue and gives each event a 5s lifespan with maxAttempts(1).
- Stale typing indicator after sender crashes mid-compose — receiver-side 15s expiry fires regardless of whether a STOP ever arrives.
- Presence privacy free-riding — everyone hides their own last-seen while still watching others'. WhatsApp's reciprocity rule makes hiding cost you the same information.
- Device clock skew and manual clock changes — a device 3 minutes fast renders itself permanently online or its partner permanently stale, depending on which side of the subtraction its clock lands on.

## Applicability to Supabase
"## What transfers directly, today, on the free tier\n\n**1. The whole timing discipline.** TTL ≥ 2× heartbeat, sweeper period independent of TTL, jittered reconnect, receiver-side expiry timers. Pure design, costs nothing.\n\n**2. Signal's typing implementation, essentially verbatim.** 10s refresh / 3s pause / 15s receiver expiry, send immediately on first keystroke, per-thread serialisation, drop rather than retry. In Dart: a `Timer` pair per conversation mirroring `TypingStatusSender`, and a receiver `Timer` mirroring `TypingStatusRepository`. **Transport must be `channel.sendBroadcastMessage()`, not Presence** — see the hard blocker below.\n\n**3. Server-authoritative time, via Postgres.** `last_seen_at timestamptz NOT NULL DEFAULT now()` written server-side, or `now()` inside an RPC. Never accept a client-supplied timestamp for last_seen. If you must round-trip a client value, store it in a differently-named column (`client_reported_at`) exactly as Signal separates `client_timestamp` from `server_timestamp`, and never compare it to `now()`.\n\n**4. RLS-gated presence on private channels.** This is the real win and it is genuinely equivalent to what the big apps do. `presence_handler.ex` evaluates `policies.presence.read` / `.write` against your `realtime.messages` RLS policies *inside the Realtime server*. Set `config: {private: true}` and write a policy that only lets a user read presence on a topic naming their own couple/pair. For a couples app you get WhatsApp-style reciprocity almost for free: make the policy require that the *viewer* has `share_last_seen = true`.\n\n**5. Never push on ephemeral signals.** Typing and presence must never trigger FCM. This is Signal's `ephemeral` flag; for you it's a rule about which Edge Functions call FCM. Cheap to get right, expensive to retrofit — an FCM-per-keystroke bug will burn your quota and your users' batteries simultaneously.\n\n**6. Opt-in fan-out.** `presence.enabled` already defaults to `false` per channel in Supabase Realtime. Subscribe to presence only on screens that render it.\n\n## The hard blocker you must design around\n\n**Supabase Presence is rate-limited to 5 `track()` calls per client per 30 seconds, on every plan including Enterprise.** That is one call per 6 seconds. Consequences:\n- Typing indicators via Presence are **impossible**. A 3-second pause debounce alone needs more than 5 calls/30s in normal typing. Use Broadcast.\n- Cursor/scroll/any continuous state via Presence: impossible. The docs say this explicitly.\n- Presence is viable only for genuine online/offline transitions, which is exactly what it's for.\n\nAlso: **`presence.enabled` defaults to `false`** in the join payload, so if you're on a recent client you must pass `config: {presence: {key: ...}}` and call `track()`; merely subscribing gives you nothing.\n\n## What needs a paid tier\n\n**200 concurrent connections on free is the binding constraint, not messages.** \"Thousands of users\" is fine; **thousands of *simultaneously open app instances* is not.** With a couples app, concurrency is maybe 5–15% of MAU on a normal day, so ~1,500–4,000 MAU is where 200 concurrent starts clipping (INFERRED — depends entirely on your usage curve; instrument it before you guess). Pro is 500 included, or 10,000 with the spend cap off at $10/1,000 connections.\n\nSecondary: 20 presence messages/sec on free is workspace-wide, not per-channel. 2M messages/month sounds generous until you multiply — see Scale notes.\n\n## What does not exist in your stack and has no equivalent\n\n**1. There is no ephemeral store.** You have Postgres and you have Realtime's in-memory CRDT. You do **not** have a Redis you can put leases in. So the Signal-legacy pattern (SETEX + CAS + peer sweep) is not directly buildable. Your options are (a) lean on Realtime Presence and accept its semantics, or (b) an `UNLOGGED` Postgres table, which avoids WAL but still incurs MVCC bloat and still doesn't replicate — and on Supabase an `UNLOGGED` table is truncated on crash recovery, which is arguably correct for presence but will surprise you.\n\n**2. There is no server-side presence sweeper you control.** Phoenix.Tracker's `down_period`/`permdown_period` are Supabase's config, not yours. If you need \"mark offline after exactly 45 seconds\", Presence won't give you that contract. A `pg_cron` job doing `UPDATE ... WHERE last_seen_at < now() - interval '45 seconds'` is the DIY equivalent, and it requires the paid tier for reasonable frequency plus it reintroduces every problem in §5.\n\n**3. You cannot observe raw connect/disconnect server-side.** Slack, Discord and Signal all hook the socket lifecycle. You can't. Your only disconnect signal is Presence `leave`, which means **Presence has to be your source of truth for online, and Postgres only stores last-seen on transition.**\n\n**4. Deno Edge Functions are stateless and have no persistent websocket.** They cannot hold presence. Don't try.\n\n**5. Flutter/Android lifecycle is your `presence_sub` equivalent.** `WidgetsBindingObserver` → on `paused`, `untrack()` and close the channel; on `resumed`, re-`track()`. Android will kill your process without warning, and the *only* thing that saves you then is Realtime's own timeout. This is precisely the case Signal's 11-minute TTL and Phoenix's `down_period` exist for. Do not add a foreground service to keep presence alive — that's the wrong trade for a private app and it will destroy battery.\n\n## Concrete recommended shape\n\n- **Online/offline**: Supabase Realtime Presence on a private per-couple channel, RLS-gated. `track()` on resume, `untrack()` on pause. That's it — a couple channel has 2 members, so fan-out is trivially 2×2.\n- **Last-seen**: written to Postgres **only on the `leave` event and on app pause**, via RPC using `now()`. That is ~2 writes per session per user, not 2 per minute. This is the single most important structural decision in the whole design.\n- **Typing**: Broadcast, with Signal's exact constants (10s/3s/15s). Never Presence. Never FCM.\n- **Privacy**: a `share_last_seen` boolean enforced in the RLS policy for presence read, giving you WhatsApp reciprocity server-side.\n\nA couples app is the best possible case for presence — the watcher set is size 1. The quadratic fan-out that dominates Discord and Slack's engineering simply does not apply to you. **Your scaling risk is entirely concurrent connection count, not presence fan-out.** Optimising fan-out here would be solving a problem you don't have."

## Scale
"## Where each approach breaks\n\n### Supabase Realtime Presence\n\n**Cost model (the thing that actually matters):** Supabase's own architecture doc states that when a user connects, *\"the state of that user is sent to all connected Realtime nodes.\"* Presence replication is cluster-wide per tenant, not per-channel. So presence cost scales with **rate of state change × cluster size**, not with your channel topology. This is invisible to you and unavoidable — it's why presence gets 20 msg/s on free while broadcast gets 100.\n\n**At 1,000 users (couples app, ~10% concurrency ≈ 100 concurrent):** Comfortable on free tier. 100 of 200 connections. Presence transitions ~2 per user-session; even at 4 sessions/day/user that's ~8,000 presence events/day ≈ 0.1/s against a 20/s cap. **Verdict: Presence wins outright.** A Postgres heartbeat table here would be pure downside — you'd add ~3 writes/sec of pointless MVCC churn to save nothing.\n\n**At 10,000 users (~1,000 concurrent):** 200-connection free cap breaks first, well before any presence limit. Needs Pro with spend cap off (10,000 connections, $10/1,000 beyond 500). Presence still fine: ~0.5–1 presence event/s against a 1,000/s Pro cap. **Verdict: Presence still wins; you're paying for connections, which you'd pay for regardless of how presence is implemented.**\n\n**At 100,000 users (~10,000 concurrent):** You are at the documented Realtime ceiling (10,000 connections, Team/Enterprise). Presence transitions ~5–10/s — still nowhere near the cap. The pressure is connection count and per-connection memory, not presence. **Verdict: Presence is still the right mechanism; the *platform* is what you'd be re-evaluating.** Note Supabase publishes Broadcast benchmarks (250k concurrent, >800k msg/s, 58ms median / 279ms p95) but **publishes no Presence benchmark at all** — that absence is itself a signal about where they'd want you.\n\n**Presence's real breaking point is not user count — it's update frequency.** 5 `track()` calls per client per 30 seconds is a hard wall on every plan. Anything that changes more than once per 6 seconds cannot use Presence at any scale.\n\n### Postgres heartbeat table\n\n**Write load:** N_concurrent / heartbeat_interval writes/sec. At 30s heartbeat: 1,000 concurrent = 33 w/s; 10,000 = 333 w/s; 100,000 = 3,333 w/s. The raw insert rate is achievable, but every one is an `UPDATE`, so every one produces a dead tuple. A 10,000-row presence table receiving 333 UPDATE/s generates ~1.2M dead tuples/hour on 10k live rows — a 120:1 churn ratio. Autovacuum will either run continuously (stealing your small instance's CPU) or fall behind (table and index bloat, degrading the reads you actually care about). Mitigations: `fillfactor=70` to enable HOT updates, `autovacuum_vacuum_scale_factor=0.01` on that table specifically, or `UNLOGGED` to at least skip WAL. None of these make it a good idea. (Postgres MVCC behaviour is documented; the specific bloat arithmetic here is INFERRED.)\n\n**The killer on Supabase specifically:** if you also want clients to *learn* about presence changes, and you use `postgres_changes`, the docs are unambiguous — *\"a single change to a table with 100 subscribed users\"* triggers 100 authorization checks, *\"throughput scales with the number of subscribers, not the write rate\"*, and it's *\"processed on a single thread to preserve their order, which means larger compute add-ons don't meaningfully increase Postgres Changes throughput.\"* With RLS the published ceiling is ~3,000–4,000 total msgs/sec, and Supabase recommends switching to Broadcast beyond ~3,000 concurrent subscribers. **A heartbeat table + postgres_changes is the single worst combination available to you**: maximum write amplification feeding the least scalable delivery path, both bounded by a single thread.\n\n**Where the heartbeat table is genuinely right:** as the **durable last-seen store, written on transition only** (~2 writes per session per user, i.e. ~0.02 w/s at 10k concurrent — four orders of magnitude below the heartbeat version), and as the cold-start read when a client opens a chat with someone not currently in its presence channel. That is the correct division of labour and it's exactly what the big apps do: ephemeral store for \"is online\", durable store for \"when last seen\".\n\n### Reference points for what containment actually costs at real scale\n- **Slack**: had to make presence subscription-only via an API-breaking change (Nov 2017), cap it at ~500 users, and stand up an entire edge cache tier (Flannel: 4M connections, 600K q/s) before presence was tractable. Pub/sub alone bought 5×.\n- **Discord**: three separate architectural rewrites — Manifold, relays at 15k sessions each, passive sessions (~90% suppression, ~3× capacity) — plus a delta-encoding fix worth 20% of total gateway bandwidth, to reach 1M online in one guild.\n- **Signal**: chose to have **no presence feature at all**, and even so needed an 11-minute Redis lease with CAS renew/clear plus a 30s peer sweep just for message-routing presence — before replacing the whole thing with sharded pub/sub in 2024.\n\nThe lesson for a couples app: **the entire body of presence-scaling engineering exists to solve fan-out, and fan-out to a watcher set of size 1 is not a problem.** Your ceiling is concurrent websocket connections, which is a billing question, not an architecture question. Spend your effort on the timing discipline (TTL ratios, server clock, transition-only last-seen writes, no-FCM-on-ephemeral) and none of it on sharding."

## Sources
- [Signal-Server: legacy ClientPresenceManager (Redis lease design), read at ref c2270e57](https://github.com/signalapp/Signal-Server/blob/c2270e57dffa045ed0df9a5aed960a472546f624/service/src/main/java/org/whispersystems/textsecuregcm/push/ClientPresenceManager.java) — PRESENCE_EXPIRATION_SECONDS = Duration.ofMinutes(11); PRUNE_PEERS_INTERVAL_SECONDS = 30; presence key set via SETEX with the owning server's managerId as the VALUE; 'presence::managers' set tracks live servers for peer-death sweeps.
- [Signal-Server: clear_presence.lua and renew_presence.lua (compare-and-swap presence ownership)](https://github.com/signalapp/Signal-Server/blob/c2270e57dffa045ed0df9a5aed960a472546f624/service/src/main/resources/lua/clear_presence.lua) — Both scripts guard on `redis.call("GET", presenceKey) == presenceUuid` before DEL/EXPIRE — a server may only clear or renew a presence lease it still owns, so a late disconnect handler cannot delete a newer connection's presence.
- [Signal-Server: RedisMessageAvailabilityManager (current presence design, replaced the TTL system Nov 2024)](https://github.com/signalapp/Signal-Server/blob/main/service/src/main/java/org/whispersystems/textsecuregcm/push/RedisMessageAvailabilityManager.java) — Presence is now defined as 'Clients are considered "present" if they have an open WebSocket connection', tracked in-process and displaced via Redis 7 sharded pub/sub; javadoc states it 'cannot guarantee at-most-one behavior' — best-effort by design.
- [Signal-Server: MessageSender — ephemeral messages never generate a push notification](https://github.com/signalapp/Signal-Server/blob/main/service/src/main/java/org/whispersystems/textsecuregcm/push/MessageSender.java) — `if (!destinationPresent && !message.getEphemeral())` gates the push; ephemeral ('online') messages like typing indicators are dropped rather than queued or pushed if the recipient isn't connected.
- [Signal-Server: TextSecure.proto Envelope — separate client and server timestamps](https://github.com/signalapp/Signal-Server/blob/main/service/src/main/proto/TextSecure.proto) — `optional uint64 client_timestamp = 5;` and `optional uint64 server_timestamp = 10;` are distinct wire fields, plus `optional bool ephemeral = 12; // indicates that the message should not be persisted if the recipient is offline`.
- [Signal-Server: MessagesManager — server stamps its own clock](https://github.com/signalapp/Signal-Server/blob/main/service/src/main/java/org/whispersystems/textsecuregcm/storage/MessagesManager.java) — `final long serverTimestamp = clock.millis();` then `.setClientTimestamp(clientTimestamp == 0 ? serverTimestamp : clientTimestamp).setServerTimestamp(serverTimestamp)` — the client's claim is preserved separately and never overwrites the authoritative value.
- [Signal-Android: TypingStatusSender — sender-side typing debounce constants](https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/components/TypingStatusSender.java) — REFRESH_TYPING_TIMEOUT = 10s (resend STARTED while typing), PAUSE_TYPING_TIMEOUT = 3s (idle keystrokes → send STOPPED); STARTED is sent immediately on first keystroke with no leading debounce.
- [Signal-Android: TypingStatusRepository — receiver-side expiry](https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/components/TypingStatusRepository.java) — RECIPIENT_TYPING_TIMEOUT = 15s, timed locally from receipt per (recipient, device, thread) — 1.5× the 10s sender refresh, and the embedded sender timestamp is never compared against the local clock.
- [Signal-Android: TypingSendJob — transport discipline for ephemeral signals](https://github.com/signalapp/Signal-Android/blob/main/app/src/main/java/org/thoughtcrime/securesms/jobs/TypingSendJob.java) — setMaxAttempts(1), setLifespan(5 seconds), setMemoryOnly(true), per-thread queue "TYPING_<threadId>", SealedSenderConstraint; a typing event that can't be sent in 5s is discarded rather than retried.
- [Slack: Presence present and future (changelog) + user presence and status docs](https://docs.slack.dev/changelog/2018-01-presence-present-and-future/) — presence_change is no longer dispatched without an explicit presence_sub; rtm.start dropped initial per-user presence; users.list caps accurate presence at 500 users per workspace; auto-away after 10 minutes of no activity.
- [Slack: presence_sub event reference](https://docs.slack.dev/reference/events/presence_sub/) — Replace-semantics subscription — 'All subscription requests require the entire subscription list each invocation'; presence_query caps at 500 user IDs; '500 users is a good maximum'.
- [Slack Engineering: Flannel, an application-level edge cache](https://slack.engineering/flannel-an-application-level-edge-cache-to-make-slack-scale/) — Moving presence to pub/sub cut presence events received by clients 'by a factor of 5'; Flannel handles 4M simultaneous connections at peak and 600K client queries/sec with consistent hashing on team+region.
- [Discord Engineering: How Discord Scaled Elixir to 5,000,000 Concurrent Users](https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users) — A single Erlang send/2 costs 30–70 µs; publishing one event from a large guild took 900 ms–2.1 s. Manifold groups PIDs by remote node and re-hashes with :erlang.phash2/2 across per-core workers, preserving delivery linearizability.
- [Discord Engineering: Maxjourney — 1M+ online users in a single server](https://discord.com/blog/maxjourney-pushing-discords-limits-with-a-million-plus-online-users-in-a-single-server) — Fan-out is quadratic — 1,000 online users = 1M notifications, 100,000 = 10 billion. ~90% of connections in large guilds are passive → ~90% less fan-out work and ~3× capacity; relays handle up to 15,000 sessions each.
- [Discord Engineering: How Discord Reduced Websocket Traffic by 40%](https://discord.com/blog/how-discord-reduced-websocket-traffic-by-40-percent) — passive_update_v1 was 35.61% of gateway traffic but only ~2% of dispatches because it sent full snapshots; delta-only v2 cut it to 4.73% (20% cluster-wide). zstd level 6 took MESSAGE_CREATE from 270 B to 166 B.
- [Discord: Gateway topic docs (heartbeat, jitter, zombie detection, rate limits)](https://docs.discord.com/developers/topics/gateway) — heartbeat_interval is server-supplied in OP 10 Hello; first heartbeat delayed by heartbeat_interval * random(0,1) to avoid reconnect storms; missing OP 11 ACK = 'zombied' connection → close with non-1000 code and resume; 120 gateway events per 60s.
- [Discord: Gateway events — Update Presence status values](https://docs.discord.com/developers/events/gateway-events) — status ∈ {online, dnd, idle, invisible, offline}; invisible is documented as 'Invisible and shown as offline' — server-side suppression. `since` is a client-supplied idle timestamp used only for display.
- [XEP-0085: Chat State Notifications](https://xmpp.org/extensions/xep-0085.html) — States active/composing/paused/inactive/gone with suggested thresholds — paused ~30s, inactive ~2 min, gone ~10 min; 'a client MUST NOT send more than one standalone <composing/> notification in a row'.
- [Meta / WhatsApp Cloud API: typing indicators](https://developers.facebook.com/documentation/business-messaging/whatsapp/typing-indicators) — 'The typing indicator will be dismissed once you respond, or after 25 seconds, whichever comes first.'
- [WhatsApp Help Center: About last seen and online (JS-rendered; content via search index)](https://faq.whatsapp.com/419827870318306/) — Reciprocity is enforced: 'if you don't share your last seen, you can't see other contacts' last seen either.' Since Aug 2022 'Who can see when I'm online' offers only Everyone or Same as last seen.
- [Phoenix.Tracker docs — the CRDT/heartbeat engine under Supabase Presence](https://hexdocs.pm/phoenix_pubsub/Phoenix.Tracker.html) — broadcast_period 1500ms, max_silent_periods 10 (→15s heartbeat), down_period = 30s, permdown_period = 1,200,000ms (20 min), clock_sample_periods 2, pool_size 1, max_delta_sizes [100,1000,10_000].
- [Supabase Realtime: Limits](https://supabase.com/docs/guides/realtime/limits) — Free: 200 concurrent connections, 100 msg/s, 100 channel joins/s, 256 KB payload. Presence-specific: 20 presence messages/s (Free), 10 presence keys per object, and 5 presence calls per client per 30 seconds on ALL plans.
- [Supabase Realtime: Presence guide](https://supabase.com/docs/guides/realtime/presence) — Explicit warning: 'Calling track() rapidly — for example on every mouse move to share cursor positions — will flood the channel and cause performance problems'; presence is for 'slow-changing state such as online/offline status'. Sync events can emit spurious join/leave.
- [Supabase Realtime: source — PresenceHandler and Presence modules](https://github.com/supabase/realtime/blob/main/lib/realtime_web/channels/realtime_channel/presence_handler.ex) — Built directly on Phoenix.Presence with a custom dispatcher; enforces per-tenant max_presence_events_per_second plus a client window (max_calls/window_ms); track() is a no-op when the payload is unchanged; RLS presence.read/presence.write policies gate private channels.
- [Supabase Realtime: join payload config schema (presence opt-in)](https://github.com/supabase/realtime/blob/main/lib/realtime_web/channels/payloads/presence.ex) — `field :enabled, FlexibleBoolean, default: false` — presence is off by default per channel; joining a channel costs nothing in presence terms until you opt in.
- [Supabase Realtime: heartbeat troubleshooting](https://supabase.com/docs/guides/troubleshooting/realtime-heartbeat-messages) — Client heartbeat default 25,000 ms (configurable via heartbeatIntervalMs); reconnect backoff 1s, 2s, 5s, 10s; heartbeat statuses sent/ok/error/timeout/disconnected.
- [Supabase Realtime: Postgres Changes scaling limits](https://supabase.com/docs/guides/realtime/postgres-changes) — 'a single change to a table with 100 subscribed users' triggers 100 authorization checks — throughput scales with subscriber count, not write rate; processed single-threaded to preserve order so compute upgrades don't help; use Broadcast beyond ~3,000 concurrent subscribers.
- [Supabase Realtime: Benchmarks](https://supabase.com/docs/guides/realtime/benchmarks) — Broadcast: 250,000 concurrent users / 500,000 channel joins / >800,000 msgs/sec at 58ms median (279ms p95). Postgres Changes with RLS tops out around 3,000–4,000 msgs/sec. No Presence-specific benchmark is published.
- [Rick Reed (WhatsApp), Erlang Factory — Scaling to Millions of Simultaneous Connections](http://www.erlang-factory.com/conference/SFBay2012/speakers/RickReed) — Target of 1M connections per server was exceeded at 2.8M+ via FreeBSD/BEAM lock-contention work; by early 2014 ~450M MAU and 147M+ peak concurrent connections on ~550 servers / 11,000+ cores, on a modified ejabberd (FunXMPP).
