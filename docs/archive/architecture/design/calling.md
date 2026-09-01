# 1:1 audio and video calling — signalling durability, authentication, negotiation, TURN economics, and the Android ring path for a killed app on a battery-optimising OEM ROM (Miles, Flutter + Supabase, com.miles.miles)

## Current design
## How it works today, precisely

**Signalling.** One Supabase Realtime *public* broadcast topic, `call:<couples.id>`, one event name `signal`, envelope `{from, kind: offer|answer|ice|hangup, data}` (`call_controller.dart:805-810`). No `RealtimeChannelConfig(private: true)` anywhere; no `realtime.messages` RLS policy exists in any file under `E:/LDR/supabase/*.sql` (grep confirms zero hits for `realtime.messages`). The topic is joinable by anyone holding the anon key and a couple UUID — and couple UUIDs are public, they are the first path segment of every `couple_media` URL (`inventory/realtime.md:123`).

**The wire protocol has no call identity.** I read `_onSignal` (`call_controller.dart:736-758`) and `_send` (:805). There is no `call_id` field in any message. Consequences that are not theoretical: a `hangup` from a call that ended 30 seconds ago tears down the call happening now; a late `ice` from a dead attempt is fed into the live peer connection; and RingRTC's entire pre-offer buffering / glare / ReCall machinery is *unimplementable* against this envelope because none of it can be keyed.

**Durability.** `call_invites` (`20260627_call_invites.sql`) stores the offer SDP. `startCall` fires `_insertInvite` **without await** and swallows every error in a bare `catch (_)` (:475, :103-116). RLS is `FOR ALL USING (couple_id = current_user_couple_id())` with **no WITH CHECK**, so Postgres reuses USING for INSERT — any couple member can insert a row naming arbitrary `caller_id`/`callee_id`. `answered_at` is declared and never written by anything. There is no DELETE, no TTL, no cron: every call ever placed leaves a permanent multi-KB SDP row, with `REPLICA IDENTITY FULL`, in the `supabase_realtime` publication, with **zero subscribers** (grep across `mobile/lib` confirms insert+select only). That is full-row WAL plus realtime fan-out, per call, for nothing.

**Ring.** `AFTER INSERT` trigger → `net.http_post` to a **hardcoded** `https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify` with only `Content-Type` — no Authorization (`20260628_care_call_push.sql:48-67`). The function performs no JWT or secret verification of its own, so `verify_jwt` must be off: **anyone on the internet can POST `{kind:'call', record:{...}}` and ring an arbitrary device, repeatedly**. Recipient lookup uses the service-role client, so RLS is not in the way. `android.ttl = '30s'` — FCM *discards* rather than queues. `profiles.fcm_token` is a single scalar column: one device per user by construction.

**Killed-callee path.** FCM (30s TTL) → background isolate cold-boots Firebase + local-notifications + SharedPreferences → reads a *cached mirror* of `canUseFullScreenIntent()` from `prefs['fsi_can_use']` (only the foreground can refresh it) → posts a disguised notification → user taps → app cold-starts behind the News cover → **biometric/PIN app lock** → router walks the whole onboarding funnel → AppShell mounts → post-frame drains `pendingCall` → SELECT `call_invites` → `_ring`. All of that is measured against the caller's hardcoded 35-second timer (`_startConnectTimeout`, :91-99).

**TURN.** Each device mints its own **24h** Cloudflare credential (`turn-credentials/index.ts:46`, `ttl: 86400`) and writes it to plaintext SharedPreferences. Cache validity is judged against `DateTime.now()` (12h/20h/60s windows) — the **local device clock**. `_ensureRelay` gives warm-up a hard 3s budget before `createOffer` and then proceeds relay-less, having *unconditionally cleared* the failure backoff first (:359-377). The user-facing signal when that happens is a red banner reading "calls only work when both of you are on the same wifi."

**State machine.** `idle, calling, ringing, connected, ended`. No busy, no declined, no reconnecting. Decline and hangup are the same wire message, so a caller cannot distinguish rejection from hang-up. An incoming offer while not idle is dropped silently (`if (state != CallState.idle) return`, :744) and the caller waits its full 35s with no busy signal. `onIceConnectionState` only `debugPrint`s — a mid-call ICE `disconnected` is neither surfaced nor recovered.

## Why it fails at scale — and why it already fails at n=2

1. **The ring path is dead unless the app is already unlocked and foregrounded.** The call channel only exists once `callControllerProvider` is first read, which happens in `AppShell.build`; `AppShell` only exists when `MilesApp.showRealApp == true`, which is false on every cold start and is forced false on every `paused`/`hidden`/`detached` (`main.dart:213-231`). The realtime signalling path therefore violates constraint 2 twice over: it needs the app foregrounded *and* a live socket.
2. **The offer does not survive the callee being offline.** Supabase documents that client-sent broadcasts "are not persisted—they exist only as live WebSocket transmissions." The `call_invites` row is the intended durable backstop, but it is written unawaited with errors swallowed, and it is only reachable via a notification tap — never via a socket drain.
3. **Security is a day-one abuse vector, not a scale problem.** Unauthenticated ring endpoint + unauthenticated signalling topic + no WITH CHECK on the invite table. Three independent ways for a stranger with a couple UUID to ring, inject, or terminate a call.
4. **TURN is a metered service with no cap.** A 24h credential lifted off one device relays traffic from anywhere for 24 hours. At $0.05/GB with no per-user quota, no revocation, and no server-side rate limit on minting, one leaked credential saturating 5 Mbps in both directions costs ~$5.40/day per stream, and nothing prevents 100 parallel streams.
5. **The 35-second timer versus the real wall clock.** FCM delivery + isolate cold start + human reaction + app cold start + Supabase session restore + biometric + 5-round-trip `loadProfile` + a `call_invites` SELECT does not fit in 35s on an OxygenOS device in Doze. When it does not fit: the caller broadcasts `hangup` into a channel the callee is not on, `call_invites` is not updated, and **the notification is never cancelled** — there is no `plugin.cancel(...)` anywhere in the codebase. Tapping it later re-rings the same stored offer.
6. **The recent "fix" evidence is worthless.** The comment at `turn-credentials/index.ts:63-74` names the two-month calling bug exactly: Cloudflare returns `iceServers` as an object, the client rejected non-Lists, `_cachedTurn` stayed empty forever, no relay candidate ever entered a peer connection — "every call between two different networks failed while two phones on one wifi worked perfectly on host candidates." That is the canonical proof that same-wifi testing certifies nothing.

## Target architecture
## The one mechanism

**Move call setup off the socket and onto a durable, ordered, authenticated log in Postgres. Everything else follows.** The socket becomes a latency optimisation; FCM becomes a doorbell; the log is the truth. This is Signal's three-layer stack (`research/calling.md:6-11`) with Postgres in the role of Signal's per-recipient queue.

Once signalling is a log, an entire class of bugs stops being reachable: lost offers, replayed hangups, stale rings, glare producing two live calls, and "the fix passed on wifi and failed in production" all become properties you can assert in SQL on a laptop.

---

## 1. Data model

**`calls`** — one row per call *attempt*, the serialization point.

| column | type | notes |
|---|---|---|
| `id` | uuid pk | the call_id, present in **every** signal |
| `couple_id` | uuid | |
| `caller_id`, `callee_id` | uuid | |
| `video` | bool | requested modality |
| `state_ord` | smallint | 10 dialing, 20 ringing, 30 accepted, 40 connected, 90 ended |
| `end_reason` | text | `normal, declined, busy, no_answer, media_failed, glare_lost, recall, accepted_elsewhere, declined_elsewhere, need_permission, expired` |
| `created_at` | timestamptz default now() | **server clock, always** |
| `expires_at` | timestamptz generated `created_at + interval '60 seconds'` | the one constant |
| `answered_at`, `connected_at`, `ended_at` | timestamptz | server-stamped in the RPC |
| `answered_by_device` | text | |
| `signal_seq` | bigint default 0 | the in-transaction counter |

Indexes: `unique (couple_id) where state_ord < 90` — **at most one live call per couple, by construction**. Plus `(callee_id, state_ord) where state_ord < 90`.

**`call_signals`** — the durable ordered log.

`(call_id uuid, seq bigint, from_user, from_device, to_user, kind text in ('offer','answer','ice','end_of_candidates','hangup','busy','renegotiate'), payload jsonb, created_at timestamptz default now())`, pk `(call_id, seq)`, index `(to_user, call_id, seq)`.

`seq` is assigned **inside the writing transaction** by `update calls set signal_seq = signal_seq + 1 where id = $1 returning signal_seq`. Not `bigserial`. `research/delivery.md` documents why: sequences are non-transactional, so a reader doing `seq > cursor order by seq` can observe 105 while 104 is uncommitted, advance past it, and lose it permanently with no error anywhere. With two writers per call and ~10 writes each, the row lock is unmeasurable.

**`device_tokens`** `(user_id, device_id text, token, platform, last_seen_at, created_at)` unique on `token`. Replaces `profiles.fcm_token`, which is a single scalar today.

**`push_outbox`** `(id, user_id, device_id, kind, payload jsonb, attempts int, next_attempt_at, state ∈ pending|sent|dead, fcm_message_id, last_error)`.

**`turn_grants`** `(id, user_id, device_id, cf_username, issued_at, client_expires_at, requested_expires_at, revoked_at)`.

**`call_events`** `(call_id, device_id, event text, at timestamptz default now(), meta jsonb)` — the telemetry spine: `push_sent, push_received, ring_shown, answered, first_media, ice_pair_type, ended`, with `Build.MANUFACTURER`/model/api in meta.

---

## 2. State machine and the RPCs that own it

All transitions go through `SECURITY DEFINER` RPCs. Nothing writes `calls.state_ord` directly; table-level UPDATE is revoked.

**`start_call(p_call_id uuid, p_video bool, p_offer_sdp text)`** — one transaction, resolves glare at the serialization point:
- No live call for the couple → insert `calls` (state 10) + `call_signals` offer row → `started`.
- Live call, same peer, `state_ord < 30` → compare `p_call_id` against the live id as a total order over 128 bits (bytes). Greater wins, mirroring RingRTC's `check_for_collision`. Winner: terminate the loser with `end_reason='glare_lost'`, insert. Loser: return `glare_lost` and the surviving call id, so the client attaches to the call already in flight instead of retrying.
- Live call, same peer, `state_ord >= 30` → **ReCall**: terminate the stale leg with `end_reason='recall'` and **emit no hangup signal** (the peer already ended it), then insert. This is the branch whose absence produces "I can't call you back for 30 seconds."
- Live call with a different peer (multi-device / future group) → `busy`, and write a `busy` signal to the caller.

**`ring_ack(p_call_id, p_device_id)`** — the freshness gate, and the only path that returns the offer to a callee:
`select ... where id = p_call_id and callee_id = auth.uid() and state_ord = 10 and now() < expires_at for update` → transition to 20 → return `{offer_sdp, video, seq_cursor, server_now}`. If `now() >= expires_at`, transition to 90 / `expired` and return `expired` — the client logs a missed call and **never rings**. No device clock participates.

**`accept_call(p_call_id, p_device_id)`** — atomic compare-and-set: `update calls set state_ord = 30, answered_by_device = ... where id = ... and state_ord = 20 returning *`. Zero rows means someone else already took it; the RPC writes an `accepted_elsewhere` signal to the losing devices. This replaces Signal's ICE forking with an atomic claim (see `rejected_alternatives`).

**`end_call(p_call_id, p_reason)`** — `state_ord = greatest(state_ord, 90)`, `end_reason = coalesce(end_reason, p_reason)` (first writer's reason sticks). A replayed or delayed hangup cannot resurrect or re-decide a call.

**`send_signal(p_call_id, p_kind, p_payload)`** — bumps the counter and inserts. Rejects any kind other than `ice`/`end_of_candidates`/`renegotiate` once `state_ord = 90`.

**Client-side FSM** gains the states the current one lacks: `dialing, ringing, accepting, connecting, connected, reconnecting, ended(reason)`.

---

## 3. Transport: three layers, and none of them is load-bearing alone

**Layer A — the log (truth).** Every signal is a committed row. A client's position is a per-call `seq` cursor. Catch-up is `select * from call_signals where call_id = $1 and to_user = auth.uid() and seq > $2 order by seq`.

**Layer B — private broadcast (speed).** An `AFTER INSERT` trigger on `call_signals` calls `realtime.broadcast_changes('call:' || call_id, ...)`. Topic is **per call**, **private**, created at dial and torn down at end. `realtime.messages` gets an RLS policy gating `topic` to calls the user is a party to, via a `SECURITY DEFINER` helper (`research/supabase.md:215` documents the 11,000 ms → 7 ms improvement for exactly this join-avoidance shape).

The broadcast carries the *full signal including its seq*, so the happy path costs no extra round trip. The reconciliation rule is the whole correctness story: **apply if `seq == cursor + 1`; if `seq > cursor + 1`, a gap exists — run the catch-up query and ignore the broadcast.** A dropped, duplicated or reordered broadcast is a latency bug, never a correctness bug. This is `research/supabase.md`'s "durability and notification are separate paths" invariant applied to call setup.

Authorization is evaluated once at join and cached for the connection lifetime — O(1) per join, not O(subscribers) per row change. That is why this is Broadcast-from-Database and not `postgres_changes`, which is capped at 30 changes/sec project-wide with RLS *regardless of compute* (`research/supabase.md:57-65`).

**Layer C — FCM (the doorbell).** Data-only, `priority: high`, payload `{type:'call', call_id}` and nothing else — no SDP (4 KB limit, out-of-order delivery, no guarantee), no `from_name` (today it ships the partner's real display name in cleartext to a device whose product premise is a disguised launcher). `collapse_key: "call"` — three literal keys project-wide (`call`, `msg`, `nudge`), under FCM's hard limit of 4 distinct keys per device.

**`ttl` = `floor(expires_at - now())` seconds at send time, clamped to ≥ 0.** Not the current fixed 30s (which discards a ring after a 31-second tunnel) and not Signal's 28-day default. Because the freshness gate lives in `ring_ack` and is evaluated server-side, a late push is *harmless* — so FCM should be told to be as generous as the ring window allows and no more. The push, the ring deadline, and the offer freshness window are three readings of one column.

On wake: drain the log for that `call_id`, then call `ring_ack`. Fetches are single-flight and coalescing (Signal's `SerialMonoLifoExecutor`: 1 running + 1 queued, newest wins) so N duplicate pushes collapse into ≤2 drains.

**Layer C is the tested path.** Layer B is an optimisation. If Supabase Realtime is down or throttled, calling degrades to "rings 1–3 s slower", not "calling is down."

---

## 4. Ring delivery: the push is a consequence of the committed row

`AFTER INSERT ON calls` writes N `push_outbox` rows (one per callee device) **in the same transaction**. Two drains:
- **Fast path:** the same trigger fires `pg_net.http_post` to the push function, now with `Authorization: Bearer <token>` read inside the `SECURITY DEFINER` function from `app_secrets`/Vault. `verify_jwt` is re-enabled on the function; the token never leaves the database. This closes the unauthenticated internet-reachable ring endpoint.
- **Retry path:** a `pg_cron` job every 10 s drains `state='pending' and next_attempt_at <= now()`. Retryable (429, 5xx, network, timeout) → exponential backoff. Non-retryable (`UNREGISTERED`, `INVALID_ARGUMENT`) → `dead` + delete the `device_tokens` row. `pg_net` is fire-and-forget with a 2 s default timeout, no documented retry, and responses garbage-collected after 6 h — the outbox is what makes failures survivable and visible. pg_cron is already in use in this repo (`breath_events.sql:37`, `reach_pulses.sql:34`), so this is not a new dependency.

The push function caches the Google OAuth access token in module scope (Deno isolates persist across warm invocations). Today it mints a fresh RS256 JWT and does a token exchange **per push** — two extra Google round trips in the critical path of a ring.

**Priority hygiene, enforced globally:** only pushes that terminate in a user-visible notification may be high priority. Chat pushes that `_onForeground` silently discards must stop being high-priority (`fcm_service.dart:139-146`) — Android 13+ downgrades HIGH→NORMAL for apps that do this, assessed over a 7-day window, and a downgraded message **cannot start a foreground service**. The app is currently burning the exact mechanism calls depend on, to deliver notifications it then throws away.

---

## 5. The Android ring surface for a killed app

Client-side, on receipt:
1. **Branch on `RemoteMessage.getPriority()` before anything privileged** (Signal's exact check). Downgraded → post the notification, do **not** `startForegroundService()`; that throws `ForegroundServiceStartNotAllowedException`.
2. Post a `CallStyle.forIncomingCall()` notification: `CATEGORY_CALL`, IMPORTANCE_HIGH channel created at **first foreground launch** (Android 13 drops notifications whose channel is first created in the background), `visibility: SECRET`, title/body from the active disguise, **Answer and Decline actions**, a looping ringtone and repeating vibration.
3. `setFullScreenIntent(pi, true)` gated on a **live** `canUseFullScreenIntent()` call, not the current SharedPreferences mirror. Where this app is genuinely advantaged: AOSP documents that `USE_FULL_SCREEN_INTENT` is *granted by default at install on Android 14+* and it is the **Play Store**, not the OS, that revokes it for non-calling apps. Miles is sideloaded, so the revocation never happens. Still check and degrade, because a user or an OEM ROM can revoke it manually.
4. **Cancellation has three independent owners** and the notification cannot outlive its call: a local `AlarmManager`/coroutine timer set to `expires_at`; a `call_ended` signal (broadcast or push); and the actions themselves. Today there is not one `cancel()` call in the codebase.
5. Decline is handled entirely in a `BroadcastReceiver` → RPC. Answer uses a `PendingIntent` bound **directly to the Activity** (Android 12 blocks `startActivity()` from a receiver) with `setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)` on Android 14+.
6. **A dedicated call foreground service**, separate from the location service. Today they share `com.pravera.flutter_foreground_task.service.ForegroundService`, so `start()` short-circuits when location sharing is running (the call gets no service and the notification says whatever location set), and `_teardown` unconditionally stops it (killing location sharing). Declare `FOREGROUND_SERVICE_PHONE_CALL` and `foregroundServiceType="phoneCall|microphone|camera"` — the manifest currently has `location|microphone|camera` and no phoneCall permission, and `serviceTypes` is `[microphone]` even for video calls, which Android 14+ can refuse camera access for. Implement `Service.onTimeout(startId, fgsType)` → clean hangup (Android 15). Never start it from `BOOT_COMPLETED`.
7. **The app lock must not sit between the ring and the answer.** See `open_decisions` — recommended: audio answers pre-auth onto a locked-down call surface; video preview and everything else stay behind the biometric.

**OEM survival.** No API fixes this; `research/push.md` is unambiguous that Samsung/Oppo/Vivo/Huawei are all catalogued "no known solution on dev end", and force-stop is an absolute platform wall. What ships is a diagnostics screen reading `PowerManager.isIgnoringBatteryOptimizations()`, `ActivityManager.isBackgroundRestricted()` (CDD §3.5.1 [C-1-6] — the one portable signal a CTS-passing MIUI/ColorOS/OxygenOS build must honour), `UsageStatsManager.getAppStandbyBucket()`, `areNotificationsEnabled()`, `canUseFullScreenIntent()`, and `ApplicationStartInfo.wasForceStopped()` on Android 15 — with per-`Build.MANUFACTURER` deep links, a "test your ring" button that round-trips a real push, and an honest sentence: *if you swipe this app away on this phone, calls will not ring.* All three target handsets (IN2015, OnePlus 7, Vivo) are on the worst or near-worst tier.

---

## 6. Telecom / ConnectionService versus the disguise — the explicit reconciliation

**Decision: do not register a `PhoneAccount`. Build the audio and interop pieces by hand.**

The manifest at `mobile/android/app/src/main/AndroidManifest.xml` declares `android:label="News"` on the application plus four launcher aliases — News, Calculator, Notes, Weather. The disguise is not a single fixed cover; it is **user-switchable at runtime**, and the notification builder already renders `currentNotificationStyle()` to match.

A self-managed `ConnectionService` registers a `PhoneAccount` whose label appears under **Settings → Apps → Default apps → Calling accounts**. That label is fixed at registration. It cannot track a disguise the user changes at runtime without re-registering, so the two *will* drift and the Settings entry becomes a permanent, unremovable tell. `CallStyle` additionally surfaces the app identity on the lock screen and can forward the call to paired watches and car head units. There is no configuration that gives both full Telecom integration and full concealment — the research says so, and the four-alias design makes it worse, not better.

What Telecom actually buys — hold/swap against the cellular dialer, correct routing, Bluetooth — is recoverable to roughly 80% with no disclosure:
- `AudioManager` with `MODE_IN_COMMUNICATION`, `STREAM_VOICE_CALL`, and `AudioFocusRequest(AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)`.
- A `TelephonyCallback`/`PhoneStateListener` to auto-mute-and-hold or auto-end when a GSM call arrives, and resume after.
- A `MediaSession` to capture Bluetooth headset answer/hangup button events.

What we lose and accept, in writing: no true hold/swap against a cellular call, no system call log entry, degraded Bluetooth switching, no CallStyle device-forwarding.

Two reinforcing reasons: Telecom's documented **5-second deadlines** — notification within 5 s of `addCall()`, and every remote-surface callback (`onAnswerCall`, `onSetCallActive`, …) completing within 5 s or the session may be torn down — introduce a brand-new teardown failure mode on exactly the slow, battery-restricted OEM devices this app targets. And the FSI advantage above means Telecom is not needed for the ring surface at all.

---

## 7. Negotiation, trickle ICE, and glare

- **Every signal carries `call_id`.** This is the prerequisite for everything below and it does not exist today.
- **Trickle with batching.** Candidates buffer on a 200 ms timer and go out as one `ice` row carrying an array. ~60 signals/call → ~10–14. This is a 5× reduction against both the Realtime msg/s quota and the monthly message budget, at negligible latency cost.
- **Explicit `end_of_candidates`** tagged with the ICE generation (ufrag), as RFC 8838 requires.
- **Pre-offer buffering** keyed by `call_id`, capped at 30 (Signal's constant), replayed the instant the offer's peer connection exists, cleared when a `hangup` for that `call_id` arrives, and evicted for any other `call_id`. The current code buffers into a single `_pendingRemote` list with no key and no cap.
- **Exactly-once, in-order** comes free from `(call_id, seq)` plus the cursor rule — no wire sequence numbers, no serialised-send queue needed.
- **Glare** is resolved once, in `start_call`, at a serialization point (see §2).
- **Perfect negotiation is used only for in-call renegotiation** (camera toggle, ICE restart, future screen share), with a role that is already durable: **caller = impolite, callee = polite**, read from `calls.caller_id`. No role negotiation, no id comparison at renegotiation time.
- **Retire the "re-send every gathered candidate on answer" hack** (`_applyAnswer`, :766-774). It exists because a cold-started callee missed the first trickle. With a durable log the callee simply drains from seq 0; the hack is unbounded, undeduped, and now unnecessary.

---

## 8. TURN: off the critical path, scoped, and capped

**Acquisition never blocks a dial.** The client refreshes on a background timer at 50% of client TTL, on app foreground, and on network change. `startCall` uses whatever is cached. If nothing is cached, the offer is still created and inserted immediately and the fetch runs in parallel — late credentials are applied with `setConfiguration()` plus a regather, which Cloudflare documents as the supported mid-session path. The current 3-second wall-clock budget followed by "proceed relay-less and show a banner about wifi" is deleted.

**Edge function changes** (`turn-credentials/index.ts`, currently `ttl: 86400` flat):
- **Two TTLs with the invariant asserted at load:** request 7200 s from Cloudflare, advertise 3600 s to the client, assert `client_ttl <= requested_ttl` (Signal-Server enforces this with `@AssertTrue isClientTtlShorterThanRequestedTtl()`). The client therefore always refreshes strictly before real expiry.
- **Return `urls`, `urls_with_ips` (server-resolved literals, v6 bracketed) and `hostname` for SNI** via `Deno.resolveDns`. Removes a DNS round trip on a carrier resolver from call setup and survives DNS-level blocking without weakening certificate validation.
- **Timeout + retry + last-known-good cached in Postgres**, so a Cloudflare blip is not "no calls." A non-2xx is a hard failure, not a silent empty ICE list.
- **Confirm `verify_jwt` is on.** The function header claims JWT-gating; there is no `config.toml` anywhere in the repo, so the deployed setting is unverified — check it.

**Scoping and abuse limits.** One `turn_grants` row per mint, keyed `(user_id, device_id)`. Quota enforced by counting rows in a window (recommend ≤10 mints/user/hour). Revoke on call end via Cloudflare's `POST .../credentials/$USERNAME/revoke`. Max exposure from a stolen device drops from 24 hours of unmetered relay to one client TTL, and total per-user spend becomes a number you choose rather than a number you discover on an invoice.

**Cache expiry is an absolute server-issued `client_expires_at` compared against `ServerClock.now()`** — the NTP-style offset the app already computes from presence upsert round trips (`server_clock.dart`). The current 12h/20h/60s windows against raw `DateTime.now()` mean a skewed phone either keeps dead credentials or discards good ones.

**Relayed-path bitrate cap: 1 Mbps, floor 30 kbps**, applied the moment `getStats()` reports either the local or remote selected candidate as `relay` (Signal's `RELAYED_MAX_SEND_RATE` / `MIN_SEND_RATE`). This is the single line that controls the Cloudflare bill: on good wifi, GCC will happily push 2.5 Mbps through the relay for no perceptible gain on a phone screen.

---

## 9. Timing budget — three numbers, each with an owner

| constant | value | owner | on expiry |
|---|---|---|---|
| `RING_WINDOW` | **60 s** | `calls.expires_at`, server | `ring_ack` returns `expired`; cron sweeps to `no_answer`; notification self-cancels |
| `RELAY_ESCALATION` | **8 s** after both descriptions are set | client | no selected pair → refresh TURN if near TTL, then renegotiate with `iceTransportPolicy: 'relay'` |
| `MEDIA_DEADLINE` | **20 s** after `accept_call` | client, both sides | `end_call('media_failed')` — distinct from `no_answer`, so telemetry can tell "nobody picked up" from "we could not connect" |

Calibration from the callstats corpus: 80% of sessions establish within 5 s, 67% of failures occur after 10 s of waiting. 60 s is a ring duration; the connect budget inside it is 8–20 s. The current single hardcoded 35 s covers all three cases badly.

**Mid-call recovery ladder.** `continualGatheringPolicy: 'gather_continually'` is set at construction; on `IceConnectionState.disconnected` the client enters `reconnecting` (a state that does not exist today) and lets continual gathering regather on the existing ICE generation — **no offer/answer needed**, which matters because a WiFi→LTE handover breaks the signalling path at exactly the moment you need it. Only if `disconnected` persists past 8 s does it escalate to a full `restartIce()`, and only after refreshing TURN, because a restart requires a **new allocation** and the old credential may no longer mint one. RFC 7675 consent freshness caps how long a dead path can pretend to be alive at 30 s regardless.

## Invariants
- An offer is durable before any push can exist. The `calls` row, the offer `call_signals` row and the `push_outbox` rows are written in ONE transaction by the `start_call` RPC and its AFTER INSERT trigger. There is no interleaving in which a ring was attempted for a call that is not committed, and none in which a call is committed but no delivery attempt was ever recorded. A lost, collapsed, TTL-expired or force-stop-dropped push costs latency, never the call.
- Signal ordering has no holes, by construction. `seq` is assigned by `update calls set signal_seq = signal_seq + 1 ... returning` inside the writing transaction, never by a sequence. A sequence is non-transactional: seq 105 can become visible to a reader while 104 is still uncommitted, so a client polling `seq > cursor order by seq` advances past 104 and loses it permanently with no error anywhere. The in-transaction counter makes RFC 8838's exactly-once, in-order requirement a property of the storage rather than of the wire.
- Call state cannot move backwards. `state_ord` is a monotone integer and every transition executes `state_ord = greatest(state_ord, incoming)` inside one SECURITY DEFINER RPC, with `end_reason` set by the first writer only. A replayed hangup, a duplicated push, a notification tapped an hour late, or a delayed `accept` from a device that lost the race cannot resurrect an ended call or re-decide its outcome.
- At most one live call exists per couple, enforced by a partial unique index `unique (couple_id) where state_ord < 90`. Two concurrent `start_call` transactions cannot both produce a live call regardless of how they interleave; the glare tie-break decides WHICH one survives, it is not what makes them agree. Signal must run its tie-break independently on two devices because it has no shared transactional store on the call path; we do, so agreement is structural rather than derived.
- No device clock participates in any decision about whether a phone may ring. `created_at` and `expires_at` come from the Postgres clock; freshness is a single `now() < expires_at` comparison inside the `ring_ack` RPC; the FCM TTL is computed server-side as `expires_at - now()`. The ring deadline, the offer freshness window and the push lifetime are three readings of one column, so it is impossible for an offer to be accepted as fresh yet expire before it can be answered.
- A user can only write signals attributed to themselves, into a call they are a party to. RLS on `call_signals`: `WITH CHECK (from_user = (select auth.uid()) AND exists (select 1 from calls c where c.id = call_id and (c.caller_id = (select auth.uid()) or c.callee_id = (select auth.uid()))))`, and `USING (to_user = (select auth.uid()))` for select. Note the WITH CHECK is written explicitly — the current `call_invites` policy is `FOR ALL USING (...)` with none, so Postgres reuses USING for INSERT and a member can insert rows naming arbitrary caller and callee. Call injection and teardown-by-stranger become impossible independently of who knows a couple UUID.
- Knowing a topic name grants nothing. The signalling topic is private; Realtime evaluates `realtime.messages` RLS once at join under the user's JWT and caches the verdict for the connection lifetime. This replaces today's public `call:<couple_id>` room, which is joinable by anyone holding the anon key and a couple UUID — and couple UUIDs are public, they are the first path segment of every couple_media URL.
- The signalling socket is never required for a call to ring. The FCM plus durable-log path is the primary, tested, measured path; the private broadcast is a latency optimisation. A Realtime outage, a `tenant_events` throttle or a `too_many_connections` refusal degrades calling to 'rings 1-3 seconds slower', not to 'calling is down'.
- A broadcast can be dropped, duplicated or reordered without affecting correctness, because the client applies a signal only if `seq == cursor + 1` and otherwise treats the gap as a trigger for the catch-up query. Durability and notification are separate paths and the client always reconciles from the durable one.
- A client never believes a dead TURN credential is live. Two TTLs are minted with `client_ttl <= requested_ttl` asserted where they are issued, and the client's expiry check compares an absolute server-issued `client_expires_at` against ServerClock (the offset the app already derives from presence upsert round trips) rather than the raw device clock. A skewed phone cannot manufacture a window in which it trusts an expired credential, nor discard a valid one.
- Relay exposure and relay spend are both bounded numbers rather than discovered ones. Every mint is a `turn_grants` row keyed by (user, device), quota is enforced by counting rows in a window, and grants are revoked on call end. The worst case from a credential lifted off a device is one client TTL, not the 24 hours the current `ttl: 86400` grants.
- Relayed egress is a function of minutes, not of link quality. The moment `getStats()` reports either selected candidate as `relay`, the video sender is clamped to 1 Mbps with a 30 kbps floor, regardless of what Google Congestion Control would allow. Without this clamp, good wifi triples the Cloudflare bill for no perceptible gain on a phone screen.
- Every high-priority push terminates in a user-visible notification, and nothing else in the app is permitted to send high priority. Android 13+ downgrades HIGH to NORMAL for apps that violate this over a 7-day window, and a downgraded message cannot start a foreground service. The chat push path currently sends high priority for notifications the client silently discards in `_onForeground` — it is spending the exact mechanism calls depend on.
- The client branches on `RemoteMessage.getPriority()` before any foreground-service start, so a downgraded push degrades to a plain notification instead of throwing ForegroundServiceStartNotAllowedException. Priority is a runtime property of the received message, not of what was sent.
- A ring notification cannot outlive its call. Three independent cancellation paths exist — a local timer armed at `expires_at`, the `call_ended` signal, and the accept/decline actions — and each is sufficient alone. Today there is no `cancel()` call anywhere in the codebase, and `ongoing: true` means the user cannot even swipe it away.

## Why this mirrors the top tier
## What this mirrors

**Signal / RingRTC and Signal-Server**, which `research/calling.md` documents from primary source (`call_manager.rs`, `connection.rs`, `signaling.rs`, `CloudflareTurnCredentialsManager.java`, `CloudflareTurnConfiguration.java`, `FcmSender.java`, `FcmFetchManager.kt`, `CallNotificationBuilder.java`, `ActiveCallManager.kt`). Copied essentially verbatim:

- **The three-layer stack** — durable ordered per-recipient queue, content-free push doorbell, authenticated drain on wake. Signal sends offer/answer/ICE/hangup as ordinary Signal Protocol messages through the normal message pipeline; the FCM payload is the literal string `"newMessageAlert"`. Postgres plays the queue's role.
- **One freshness constant equal to the ring deadline.** RingRTC: `MAX_MESSAGE_AGE = 60 s` and `TIME_OUT_PERIOD = 60 s`. Two constants that must agree are better expressed as one; ours is a generated column.
- **Bounded typed pre-offer buffering** — `PendingCallMessages` keyed by call_id, capped at 30, candidates after a hangup for that call_id dropped, buffers for a stale call_id evicted.
- **The full glare decision table** including the `ReCall` branch (`state >= ConnectedAndAccepted` → tear down the stale leg *without* sending a hangup and accept the new offer) and `Busy` for a different peer/device. This is the branch nobody thinks of and everybody hits.
- **Hangup reasons in the protocol**, not inferred from timing: `AcceptedOnAnotherDevice`, `DeclinedOnAnotherDevice`, `BusyOnAnotherDevice`, `NeedPermission`.
- **Two-TTL TURN credentials with the invariant enforced where they are minted**, plus pre-resolved IP literals and a separate SNI hostname, plus a circuit breaker around the vendor call.
- **`max_send_rate() = min(local, remote, relay)`** with `RELAYED_MAX_SEND_RATE = 1 Mbps`, floored at `MIN_SEND_RATE = 30 kbps`.
- **Continual gathering and regather on network change, not `restartIce()`** — because an ICE restart needs the signalling channel alive at exactly the moment the network change has broken it.
- **`getPriority()` checked before `startForegroundService()`**, and `Service.onTimeout(startId, fgsType)` implemented rather than assumed not to fire.
- **RFC 8838** exactly-once/in-order/end-of-candidates; **RFC 7675** 30 s consent expiry as the hard ceiling on a dead path; **draft-uberti-behave-turn-rest-00** on why existing allocations survive credential expiry but an ICE restart does not.

Plus **Supabase's own documented mechanics** from `research/supabase.md`: Broadcast-from-Database instead of `postgres_changes` (30 changes/sec project-wide with RLS on a single-threaded poller, 40/sec even on a 16XL — a ~1.5× return for a ~370× price increase), and private-channel authorization as O(1) per join cached for the connection.

## Where it deliberately differs, and why

**1. Glare is resolved at a serialization point, not by a symmetric client tie-break.** Signal compares `call_id` as u64 on both devices independently because it has no shared transactional store on the call path. We have Postgres. `start_call` is one transaction behind a partial unique index, so two live calls cannot exist even if both RPCs interleave. RingRTC's tie-break function survives as the *choice rule inside the RPC* — it makes the outcome deterministic and fair; it is no longer what makes the two sides agree. This is strictly stronger and strictly simpler.

**2. FCM TTL is the remaining ring window, not Signal's 28-day default with a client-side age gate.** Signal computes `received.age` on the client from server-stamped receive time. We put the gate in a server RPC (`ring_ack`), which means a late push is provably harmless — so FCM should be told to be as generous as the window allows. A fixed 30 s TTL (today) discards a ring after a 31-second tunnel; `ttl=0` ("now or never") would discard it after a 3-second elevator. Neither is right when the server already knows the deadline.

**3. No Telecom / ConnectionService, unlike Signal-Android.** Signal is a known calling app and wants the platform integration. Miles ships four launcher aliases (News/Calculator/Notes/Weather) and a runtime-switchable disguise; a `PhoneAccount` label is fixed at registration, surfaces in Settings → Calling accounts, and will drift from whichever cover the user has selected. We take `AudioManager` + `TelephonyCallback` + `MediaSession` instead and accept the loss of hold/swap, the system call log, and clean Bluetooth switching. Detailed in `target_architecture` §6.

**4. No ICE forking for multi-device.** Signal's parent/child PeerConnections share one `IceGatherer` so ICE completes with all linked devices *before* the human accepts, making perceived connect time equal to answer latency. `flutter_webrtc` exposes no shared-gatherer API; getting it means forking the plugin. We use an atomic first-accept-wins (`accept_call` compare-and-set) and accept that connect time is answer latency **plus** ICE latency. The cost is ~1–3 s on the answer path; revisit if multi-device usage becomes common.

**5. No persistent websocket fallback.** Signal-Android falls back to its own socket after three consecutive days of failed FCM registration and on devices without Play Services. Supabase's connection quotas (200 / 500 / 10,000) and the OEM battery managers on exactly the target handsets make an always-on socket both expensive and unreliable. The durable log plus catch-up-on-foreground gives the same convergence property — a client that was offline for a week converges on next open — without holding a socket for idle users.

**6. Signalling is not serialised one-message-in-flight.** RingRTC's `SignalingMessageQueue` exists to make wire order deterministic without sequence numbers. `(call_id, seq)` assigned in-transaction gives us that for free, so writes can be concurrent.

## Scale ceiling
## Model

2 users per couple, 2 calls per couple per day, mean 6 minutes, 60% video / 40% audio. Relay rate **35%** — deliberately above the callstats.io corpus figure of 22%, because cross-carrier mobile is close to the worst case in that population: carrier-grade NAT is typically address-and-port-dependent, so the STUN-learned server-reflexive candidate is bound to the 5-tuple toward the STUN server and useless to the peer, and two symmetric NATs cannot hole-punch. ~14 signal rows per call after 200 ms candidate batching.

## 1,000 users (500 couples) — comfortable

- 1,000 calls/day, 30,000/month. Signalling: ~420k rows/month, pruned hourly by `pg_cron`, so the live table stays a few thousand rows. Realtime: 14 signals × 2 billable (1 send + 1 receive) = ~28 per call ≈ 840k messages/month for calling.
- Concurrent call sockets = 1,000 calls/day × 6 min ÷ 1,440 min ≈ 4 concurrent calls ≈ 8 sockets. Trivial.
- Channel joins ≈ 0.05/s average. Against a free-tier ceiling of 100/s.
- **Nothing calling-specific breaks.** The binding constraint is the rest of the app: `research/supabase.md` puts free-tier capacity for this codebase at roughly 100–150 users (message quota) or ~150 concurrently-chatting users (the `postgres_changes` ceiling), whichever hits first. Calling rides on Pro either way.
- **Failure mode if you stay on Free:** 200 concurrent connections is a hard wall with no overage — it fails closed with `too_many_connections`. Symptom: the app stops updating and foregrounded calls stop ringing, while backgrounded users on the FCM path keep working. That inversion is a diagnosis trap and is worth writing on the wall.

## 10,000 users — works on Pro with the spend cap OFF; cost, not capacity, is the ceiling

- 10,000 calls/day, 300,000/month. Concurrent call sockets ≈ 166. Joins ≈ 0.5/s. Signalling messages ≈ 8.4M/month.
- App-wide peak concurrency ≈ 800 devices, which exceeds Pro's capped 500 — the spend cap must be disabled to reach 10,000 / 2,500 msg/s.
- **First thing to break: money, specifically relayed video egress** (see `cost`). ~$240/month, ~95% of calling's marginal bill.
- **Second: the App Standby Bucket / priority-downgrade cliff.** FCM's per-day cap on high-priority messages and the Android 13+ "downgrade apps whose high-priority pushes don't produce notifications" rule are both **unpublished numbers you cannot measure from the server**. The only signal is `originalPriority != priority` on the client. This is the scariest undocumented cliff in the design; instrument it from day one or you will discover it as "calls started arriving three minutes late on some phones."
- **Failure mode at the ceiling:** if the relay bitrate cap regresses (a refactor drops the `getStats()` check, or `setParameters` silently fails), the bill roughly triples with no alarm anywhere. Cost has no error code.

## 100,000 users — calling still fits; the tenant does not

- 100,000 calls/day, 3M/month. Concurrent call sockets ≈ 1,666 of a 10,000 hard ceiling. Joins ≈ 5/s average, maybe 20/s peak, against 2,500/s. Signalling rows 42M/month, pruned hourly, live table ~60k rows. Cloudflare credential issuance ~1/s against a documented 500/s floor.
- **Calling is not the thing that breaks.** `research/supabase.md` puts app-wide peak concurrency at ~8,000 devices and peak throughput at ~12,000 msg/s — roughly 5× past the 2,500/s Team ceiling. That is a hard stop, not an overage: Enterprise or a self-hosted Realtime cluster.
- **The failure mode at that ceiling, and the property that matters:** `tenant_events` throttling disconnects clients project-wide. Under this design that degrades calling to "rings via push, 1–3 s slower" rather than "calling is down", because Layer C never depends on the socket. **That is the single most valuable scale property here** — today the identical failure produces total calling failure, because the ring path *is* the socket.
- **The escape hatch is a Layer-B-only swap.** Because the log (A) and the push (C) are independent of the transport, moving in-call signalling to a small dedicated service — or self-hosting Realtime — changes one trigger and one client subscription. Layers A and C are untouched. No rewrite.
- **The genuinely hard calling ceiling past 100k** is Cloudflare TURN's documented gaps rather than its throughput: **no RFC 6062 TCP relay allocations** (only TLS wrapping, so a network that blocks UDP entirely may have no path at all) and **no IPv6 relay addresses issued**, which on increasingly common IPv6-only carriers puts you at the mercy of NAT64/464XLAT. Neither is a capacity problem and neither can be paid away. The mitigation is coturn on TCP/TLS 443 as a second ICE server — which is why the NAT harness in `verification` must include a UDP-blocked scenario before you ever need it.

## Cost
## Assumptions

Same model as `scale_ceiling`. Cloudflare Realtime TURN: **$0.05/GB egress, 1,000 GB free — shared between SFU and TURN, not two allowances**. Relayed audio ≈ 0.5 MB/min billable (Opus ~32 kbps, both directions). Relayed video **at the 1 Mbps cap** ≈ 15 MB/min billable. These are arithmetic from documented rates and codec bitrates, not vendor quotes.

## 1,000 users — calling's marginal cost: **$0**

| line | volume | cost |
|---|---|---|
| TURN relayed video | 6,300 calls × 6 min × 15 MB = **567 GB** | $0 (free tier) |
| TURN relayed audio | 4,200 calls × 6 min × 0.5 MB = **13 GB** | $0 |
| Realtime (calling) | ~840k messages/month | $0 within Pro's 5M |
| Edge Functions | ~90k TURN mints + ~60k push drains | $0 within 2M |
| Postgres | ~2 MB live after hourly pruning | $0 |

**Total: $0 on top of the $25 Pro the rest of the app needs.** Note the exposure: 580 GB is **58% of the shared 1,000 GB allowance**, and it is shared with any future SFU use.

## 10,000 users — **~$250/month**

| line | volume | cost |
|---|---|---|
| TURN egress | 5,670 GB video + 126 GB audio = **5,796 GB**, minus 1,000 free | 4,796 × $0.05 = **$240** |
| Realtime (calling share) | 8.4M/month; overage $2.50/M | **~$10** |
| Edge Functions | ~900k/month | $0 within Pro's 2M |
| Postgres | ~20 MB live | $0 |

**Calling marginal: ~$250/month.** 95% of it is relayed video egress. Without the 1 Mbps clamp, GCC on good wifi reaches ~2.5 Mbps and this line becomes **~$600–700/month** for no visible quality difference on a phone.

## 100,000 users — **~$3,100/month**

| line | volume | cost |
|---|---|---|
| TURN egress | 56,700 GB video + 1,260 GB audio ≈ **58 TB**, minus 1 TB free | 57,000 × $0.05 = **$2,850** |
| Realtime (calling share) | 84M/month, 79M over Pro's 5M | **~$198** |
| Edge Functions | ~9M/month, 7M over 2M at $2/M | **~$14** |
| Postgres | ~60k live rows, negligible | ~$0 |

**Calling marginal: ~$3,100/month**, on top of the ~$5,000–6,500/month `research/supabase.md` projects for the app overall.

## The cost lever, in order

1. **The 1 Mbps relay clamp.** Worth ~$400/month at 10k and ~$4,000/month at 100k. One `getStats()` check plus `setParameters`.
2. **Relayed video → 600 kbps** (server-controlled remote config, no release needed): −40% of the TURN line. $2,850 → ~$1,700 at 100k.
3. **Relay-aware modality downgrade:** on a relayed path with `qualityLimitationReason == 'bandwidth'`, offer "switch to audio". Audio is 30× cheaper per minute.
4. **Candidate batching** (200 ms): cuts calling's Realtime line ~5×. Already in the design; worth naming because dropping it silently restores the cost.

## The cost risk that is not organic traffic

Today a 24h TURN credential sits in plaintext SharedPreferences on every device with **no per-user cap, no revocation, and no server-side mint rate limit**. One credential lifted off one device relays from anywhere for 24 hours. Sustained 5 Mbps in both directions is ~108 GB/day = **$5.40/day per stream**, and nothing prevents 100 parallel streams: **~$540/day from a single leaked credential**. `turn_grants` plus a 1h client TTL plus a mint quota plus revoke-on-call-end turns that from unbounded into a number you chose. At current scale this risk exceeds the entire organic bill by two orders of magnitude.

## Break-even notes

- The 1,000 GB free TURN tier is exhausted at roughly **1,850 relayed video-call-hours/month** — about **1,700 users** on this model. That is the first real dollar this domain costs.
- Supabase Pro ($25) is required well before calling needs it; calling never justifies a tier upgrade on its own until the 10,000-connection ceiling, which it reaches at roughly **600,000 users** on its own traffic.

## Migration
Every step below ships and reverts independently. Nothing requires both peers to upgrade simultaneously except S4, which carries an explicit capability-negotiation window. There is no big bang.

## S0 — Server-only hardening. No client release. Ship today.
1. `alter policy call_invites_couple ... with check (couple_id = current_user_couple_id() and caller_id = (select auth.uid()))` — closes the "insert a row naming arbitrary caller/callee" hole created by `FOR ALL USING` with no WITH CHECK.
2. Add a Bearer header to `notify_call`'s `net.http_post`, read inside the `SECURITY DEFINER` function from `app_secrets`; make `reach-notify` verify it; re-enable `verify_jwt`. **This closes the unauthenticated internet-reachable ring endpoint.** Highest security value per line of code in the whole plan.
3. `pg_cron`: delete `call_invites` older than 1 hour (pattern already in `reach_pulses.sql:34`). Stops unbounded SDP growth.
4. Drop `call_invites` from `supabase_realtime` and set `replica identity default` — it has zero subscribers and is paying full-row WAL plus realtime fan-out per call for nothing.
5. Cache the Google OAuth access token in module scope in `reach-notify` — removes an RSA sign and a Google round trip from every ring.

**Revert:** drop the policy change, restore the publication. Risk: near zero. **Verify:** SQL tests (S0 is fully coverable by `verification` Layer 1).

## S1 — Ring notification correctness. Client-only. No schema change.
Cancellation (three owners), Answer/Decline actions, looping ringtone and repeating vibration, `CallStyle.forIncomingCall`, live `canUseFullScreenIntent()` instead of the SharedPreferences mirror, `getPriority()` branch before any FGS start, `PendingIntent` bound directly to the Activity with `MODE_BACKGROUND_ACTIVITY_START_ALLOWED`. Split the call foreground service from the location service; declare `phoneCall|microphone|camera` and `FOREGROUND_SERVICE_PHONE_CALL`; implement `onTimeout`.

**This is the largest visible improvement per unit of risk and it touches no backend.** Ship it first if the owner wants motion. **Revert:** one APK. **Verify:** adb Doze/bucket/force-stop matrix on one phone (Layer 5).

## S2 — `push_outbox` + retry + `device_tokens`. Server-side, plus a small client change for token registration.
Outbox written in the same transaction; `pg_net` fast path; `pg_cron` retry drain every 10 s; retryable vs dead classification; `UNREGISTERED` deletes the device row instead of nulling a shared column. Client registers `(device_id, token)` on every foreground and posts a `call_events` ack on push receipt carrying `messageId`, `sentTime`, `priority`, `originalPriority`.

Multi-device fan-out lands here for free. **Revert:** stop the cron job; the fast path still works. **Verify:** fake FCM endpoint returning 429/500/UNREGISTERED (Layer 5).

## S3 — `calls` + `call_signals` + the RPCs, dual-written alongside the existing path.
Ship the tables, RPCs, RLS and the `broadcast_changes` trigger. The client calls `start_call` **in addition to** the existing broadcast and `call_invites` insert, and reads the log **in addition to** the broadcast, preferring whichever arrives first (both are idempotent under the seq-cursor rule). Behind a remote flag.

**This is the step that makes the offer survive an offline callee.** **Revert:** flip the flag; the old path is still live. **Verify:** Layer 1 (glare, expiry, monotonicity, RLS) and Layer 2 (FSM table tests) both run headless.

## S4 — Private channel cutover. Requires both peers on a new client — the only coordinated step.
Add the `realtime.messages` RLS policy and the per-call private topic. Client advertises support via a `profiles.client_caps` bitfield; a caller uses the private per-call topic only if the callee advertises it, otherwise falls back to the public couple topic. One release later, remove the fallback and the public topic.

**Revert:** clear the capability bit server-side, which forces every client back to the legacy topic without an APK. **Verify:** join as a non-member and assert refusal (Layer 1).

## S5 — TURN hardening. Edge function + client, independent of everything above.
Two TTLs with the assertion, `Deno.resolveDns` → `urls_with_ips` + SNI hostname, timeout/retry/last-known-good in Postgres, `turn_grants` + per-user mint quota + revoke on call end, background refresh at 50% of client TTL, cache expiry against `ServerClock` instead of `DateTime.now()`, and the 1 Mbps relay clamp. Delete `_ensureRelay`'s 3 s budget and the "same wifi" banner.

**Revert:** the edge function is versioned; old clients accept the new response shape (it is a superset). **Verify:** the symmetric-NAT harness (Layer 4) is the acceptance gate — this is precisely the step that the two-month `iceServers`-shape bug lived in.

## S6 — Call-id-aware protocol and the full glare/ReCall/Busy machine.
Every signal carries `call_id`; per-call_id pre-offer buffering capped at 30; candidates after hangup for that id dropped; `end_of_candidates`; 200 ms candidate batching; `reconnecting` state; the 8 s relay escalation and 20 s media deadline; caller=impolite/callee=polite for in-call renegotiation only. Retire the "re-send every gathered candidate on answer" hack.

**Revert:** one APK; S3's log is unchanged. **Verify:** Layer 3 (two peer connections in one Dart process with an adversarial fake channel) plus the Layer 2 glare table.

## S7 — OEM survival + telemetry surfacing.
Diagnostics screen, per-manufacturer deep links, "test your ring" round trip, and the `call_events` dashboard: push→ring p50/p95 by `Build.MANUFACTURER`, `originalPriority != priority` rate, relay-vs-p2p share, `end_reason` distribution.

## S8 — Retire the legacy path.
Drop `call_invites`, the public `call:<couple_id>` topic, and the old broadcast handlers. Only after S7 telemetry shows ≥2 weeks of clean traffic on the new path.

## What is explicitly NOT in the plan
A rewrite of `call_controller.dart`. S6 refactors its inputs to (signal stream, timer ticks, PC events) so it becomes testable, but the media layer — `getUserMedia`, `_createPc`, renderers, audio routing, the `identical(pc, _pc)` guard — is sound peer-to-peer 1:1 code and stays. The inventory rates that module *medium*, not fatal, and it is right.

## Verification
## The rule

**No fix in this domain ships on the evidence of two NTP-synced phones on one wifi.** The record justifies the rule: `turn-credentials/index.ts:63-74` documents a two-month outage where "every call between two different networks failed while two phones on one wifi worked perfectly on host candidates." Same-network testing exercises host candidates, so it structurally cannot observe the TURN path, the NAT path, the clock-skew path, or the killed-app path. It certifies nothing.

## Layer 1 — SQL property tests (laptop, CI, no device)

Against `supabase start`, in pgTAP or plain SQL. This is where the architecture pays for itself: every correctness claim above is a database property.

- **Glare:** open two transactions, both call `start_call` with different call_ids, commit in both orders. Assert exactly one row with `state_ord < 90`; assert the loser's `end_reason = 'glare_lost'`; assert the winner is the greater id in both orderings.
- **ReCall:** call at `state_ord = 40`, then `start_call` again. Assert the old row ends with `recall` and **no hangup signal was written**.
- **Monotonicity:** call `end_call` twice with different reasons, and replay a `ring_ack` after `end_call`. Assert `state_ord` never decreases and `end_reason` is the first writer's.
- **Freshness:** insert a `calls` row with a backdated `created_at`, call `ring_ack`. Assert `expired`, assert no offer is returned. Do it once with a wildly wrong session `timezone` set to prove no client-influenced value participates.
- **Seq has no holes:** two concurrent `send_signal` transactions with a deliberate commit-order inversion; assert a reader polling `seq > cursor` observes both. (Repeat with a `bigserial` column present to *demonstrate* the skip, so the test documents why the counter exists.)
- **RLS:** as user C (a different couple), attempt `insert into call_signals` a hangup for A↔B's call; attempt `select`. Assert permission denied / 0 rows. As user A, attempt to insert with `from_user = B`. Assert denied.
- **Uniqueness:** two concurrent inserts of live calls for one couple. Assert one unique violation.
- **Outbox:** insert a call, assert N `push_outbox` rows exist in the same transaction snapshot, one per callee device.

## Layer 2 — FSM table tests (Dart, headless)

S6 refactors the controller so its inputs are (signal stream, timer ticks, peer-connection events) and its outputs are (state, outbound signals). Then RingRTC's entire collision table is a table-driven test — every row of `research/calling.md:56-64` becomes a test case. Extends the existing `mobile/test/unit/call_ring_invariants_test.dart` pattern, which already enforces "`_ring` is the only path into ringing."

Also here: seq-gap handling (feed seq 1,2,4 — assert a catch-up is requested and 3 is not skipped), duplicate delivery (feed 2 twice — assert idempotent), pre-offer candidate buffering with the 30 cap, candidates-after-hangup dropped.

## Layer 3 — Two peer connections in one Dart test process

Both `RTCPeerConnection`s in the same test, wired through a **fake signalling channel that is deliberately hostile**: reorders, duplicates, delays 5 s, drops the first N candidates, and delivers the answer before some of the caller's candidates. Assert the call still reaches `connected` and that `end_of_candidates` is honoured. libwebrtc pairs on host candidates locally — that is fine; this layer tests negotiation, not traversal.

## Layer 4 — The symmetric-NAT harness. This is the asset that does not exist and matters most.

A Linux box, WSL2, or Docker on the dev machine: two network namespaces, each behind an `iptables` address-and-port-dependent (symmetric) NAT, with `coturn` reachable from both and a STUN server outside. Endpoints are headless Chrome or `gstreamer webrtcbin` — no Flutter needed, because what is under test is the ICE configuration, not the app.

Scenarios, each an assertion:
- Two symmetric NATs, `iceTransportPolicy: 'all'` → **selected pair type is relay/relay**. *This is the direct regression test for the two-month `iceServers`-shape bug*, and it is a test that would have caught it on day one.
- TURN credentials absent or malformed → assert the call **fails fast with a named reason**, not "proceeds relay-less and shows a banner about wifi."
- UDP blocked entirely (drop all UDP) → assert TURN/TLS on 443 is attempted. Cloudflare does **not** implement RFC 6062 TCP allocations — this scenario is how you find out whether TLS wrapping actually suffices on your users' networks before they tell you.
- Mid-call interface flap (drop and restore a namespace's route) → assert continual gathering recovers on the same ICE generation without a new offer, and that the escalation to `restartIce()` only fires after 8 s.
- Credential expiry mid-call → assert the established allocation survives (it is 5-tuple bound) but a subsequent ICE restart fails without a refresh, and that the client refreshes first.

## Layer 5 — Push and ring on ONE physical device

The killed-callee path is reproducible with `adb` alone, deterministically, on a single handset:
- `adb shell am set-standby-bucket <pkg> rare` and `restricted` — reproduces the buckets where **network access is disabled** and only high-priority FCM's temporary grant escapes.
- `adb shell dumpsys deviceidle force-idle` — Doze.
- `adb shell am force-stop <pkg>` — assert the ring does **not** arrive and that the app says so honestly. Force-stop is a documented platform contract, not a bug to work around; the test asserts the *stated* behaviour.
- `adb shell am compat enable FGS_BOOT_COMPLETED_RESTRICTIONS <pkg>` — Android 15 FGS rule.
- Revoke `USE_FULL_SCREEN_INTENT` via app-ops → assert graceful degradation to a heads-up `CallStyle` notification.
- Airplane mode for 45 s during the ring window → assert the push still arrives (TTL = remaining window) and that `ring_ack` still returns the offer; then 65 s → assert `expired` and a missed-call entry, **no ring**.

Server side: a fake FCM endpoint returning 429 / 500 / `UNREGISTERED` / timeout — assert backoff, dead-lettering, and token deletion.

## Layer 6 — Field telemetry, because the first five cannot see an OEM

`call_events` gives per-device, per-call timestamps for `push_sent → push_received → ring_shown → answered → first_media`, plus `end_reason`, selected-pair type, and `Build.MANUFACTURER`/model/api. Two derived charts are the production truth:
1. **push→ring p50/p95 by manufacturer.** This is the only way to see OEM battery managers and FCM priority downgrades. Nothing on a desk shows it.
2. **`originalPriority != priority` rate.** A direct read on whether Android is downgrading the app — the one otherwise-invisible cliff.

Today the app has a `CallStatsMonitor` polling `getStats()` every 2 s and `debugPrint`ing every sample, including in release-mode logcat. It never leaves the device, so every field failure is an anecdote. Routing it to `call_events` is a small change with disproportionate value.

## The acceptance gate

A change in this domain is done when: Layer 1 green, Layer 2 green, Layer 3 green, Layer 4 asserts a relay pair between two symmetric NATs, the Layer 5 adb matrix is documented with actual output, and Layer 6 shows push→ring p95 from at least one real OEM device over 48 hours. Two phones on one wifi is not on that list and never appears on it.

## Rejected alternatives
**Supabase Realtime client-sent Broadcast as the offer transport** (the current design). Rejected: Supabase documents that messages from client libraries or the REST API "are not persisted—they exist only as live WebSocket transmissions." If the callee's socket is down when the offer is sent, the offer is simply gone. Compounding it, the call channel here only exists while `AppShell` is mounted, which requires the app foregrounded and unlocked past the disguise cover — so the transport is unavailable in the majority real-world case (partner's phone in a pocket). This is the root cause, not a contributing factor.

**`postgres_changes` on a signalling table.** Rejected: 30 changes/sec **project-wide** with RLS on a single-threaded poller, 40/sec even on a 16XL — a ~1.5× return for a ~370× price increase. `apply_rls` loads every subscription to the table across the whole project and evaluates each filter inside the loop, so the `couple_id=eq.X` filter does not shrink the work. Plus zero replay. `call_invites` is in the publication with `REPLICA IDENTITY FULL` **and zero subscribers** today — pure cost per call, removed in S0.

**Broadcast Replay as the catch-up mechanism.** Rejected: capped at **25 messages per request**, 72-hour retention, private channels only, Broadcast-from-Database only, alpha. A call emits more than 25 signals without batching. `seq > cursor` is unbounded, free, and one indexed range scan.

**`bigserial` for the signal cursor.** Rejected: `nextval` is non-transactional, so seq 105 can become visible to a reader while 104 is still uncommitted. A client doing `seq > cursor order by seq` advances past 104 and loses it permanently, with no error anywhere. For an ICE candidate that is a degraded call; for an offer or a hangup it is a hung one. The in-transaction counter costs a row lock with two writers and zero contention.

**W3C perfect negotiation (polite/impolite) for call-setup glare.** Rejected for setup: it is designed for renegotiation glare inside an *established* `RTCPeerConnection` — `negotiationneeded` firing on both sides, a track being added, an ICE restart — and it requires a stable role, which does not exist between two symmetric peers who can both dial. Signal does not use it for setup either; it uses a numeric call-id tie-break with four outcomes. **Adopted for in-call renegotiation only**, with caller=impolite/callee=polite read from the durable `calls` row.

**Signal's exact symmetric client-side glare tie-break.** Rejected as the *agreement* mechanism, kept as the *choice* mechanism. Signal must run the comparison independently on two devices because it has no shared transactional store on the call path. We have Postgres and a partial unique index, so agreement is structural and cannot diverge even under arbitrary interleaving. Keeping the client-side comparison as well would be a second source of truth — the classic way to reintroduce the bug you just removed.

**Signal's ICE forking for multi-device.** Rejected for now: it needs a shared `IceGatherer` across parent and child `PeerConnection`s, which `flutter_webrtc` does not expose — getting it means forking the plugin. The prize is real (ICE completes with all devices *before* the human accepts, so perceived connect time becomes answer latency, not answer + ICE), but at 1–2 devices per user the win is ~1–3 s. Replaced by an atomic first-accept-wins compare-and-set. Revisit if multi-device usage becomes common.

**Telecom / self-managed `ConnectionService`.** Rejected — full reasoning in `target_architecture` §6. Short version: a `PhoneAccount` label is fixed at registration and surfaces in Settings → Calling accounts, while this app's disguise is user-switchable across four launcher aliases, so the two will drift and produce a permanent tell. Telecom's two 5-second deadlines add a new teardown failure mode on exactly the slow OEM devices being targeted. And because the app is sideloaded, AOSP grants `USE_FULL_SCREEN_INTENT` by default on Android 14+ (it is the Play Store, not the OS, that revokes it for non-calling apps), so Telecom is not needed for the ring surface. `AudioManager` + `TelephonyCallback` + `MediaSession` recovers most of the value with no disclosure.

**A persistent authenticated websocket as the ring transport** (Signal-Android's FCM fallback). Rejected: Supabase caps concurrent connections at 200 / 500 / 10,000 and bills on peak, and the OEM battery managers on the target handsets (OnePlus and Xiaomi at the worst tier) will kill the process holding it. The durable log plus catch-up-on-foreground delivers the same convergence property without holding a socket for idle users.

**`ttl: 0` for the call push** ("now or never", documented best latency, never stored). Rejected in favour of `ttl = remaining ring window`. `ttl=0` discards a push for a device that is offline for three seconds in an elevator, and it buys nothing, because the freshness gate lives in a server RPC that makes a late push provably harmless. The current fixed `30s` is rejected for the mirror-image reason: it discards a ring that a 31-second tunnel would otherwise have survived, silently and with no trace.

**Keeping the always-on `call:<couple_id>` topic** (private-ified). Rejected in favour of a per-call topic: an always-on channel makes concurrent Realtime connections scale with *users*, and it is the difference between calling fitting inside a 10,000-connection ceiling at 100k users and not. It also buys nothing, since the ring must work without a socket anyway. The foreground ring hint rides the couple's existing presence/chat topic.

**WhatsApp's WASP (custom single-port relay protocol).** Rejected: it exists because "TURN… uses multiple ephemeral ports, doesn't work well with firewalls, and doesn't scale well with a distributed architecture" — a well-over-a-billion-calls-a-day problem, solved with thousands of points of presence and mid-call relay failover. Managed anycast TURN is correct here and replacing it would be pure cost.

**Discord's always-SFU model.** Rejected: relaying 100% of traffic eliminates ICE, NAT traversal failures and IP leakage, at the price of 220+ Gbps of egress. That is the right trade at 2.6M concurrent voice users and the wrong one for a two-person app where 65–78% of calls cost nothing. Revisit only if group calls arrive — at which point Jitsi's model applies (P2P at exactly 2 participants, SFU at 3+) and the P2P design does not extend.

**Self-hosted coturn instead of Cloudflare.** Rejected for now: ops cost and no anycast. Named explicitly as the escape hatch for Cloudflare's two documented gaps — no RFC 6062 TCP relay allocations, no IPv6 relay addresses — and included in the NAT harness so the decision can be made on evidence rather than on the day it breaks.

**Rewriting `call_controller.dart`.** Rejected: the inventory rates the peer-connection module *medium*, not fatal, and it is right. The media layer is sound 1:1 WebRTC, with real hard-won details in it (the `identical(pc, _pc)` guard so a disposed connection cannot tear down its successor; `dispose()` rather than `close()` so `AudioSwitchManager` actually stops; `onConnectionState` as the sole authority for `connected`). S6 refactors its *inputs* to make it testable and leaves the media path alone.

## Open decisions
**1. Does the app lock stand between the ring and the answer?** This is the highest-stakes open question and it is a product decision, not an engineering one. Today a cold-started callee must pass biometrics before reaching an Accept button, inside the caller's 35-second timer, and it routinely does not fit. **Recommendation: audio calls answer pre-auth onto a locked-down call surface** (only the call, no navigation to chat, gallery or Closer), with video preview and everything else behind the biometric. Rationale: the caller is already authenticated as the bound partner by the server, so the residual risk is bounded — a stranger holding a stolen phone hears the partner's voice — against the certainty that biometrics plus a cold start plus a 5-round-trip `loadProfile` does not fit a ring window. If the owner rejects this, the ring window must be raised well above 60 s and the "answer" affordance must at minimum be a notification action that starts negotiation *before* the unlock, so the biometric overlaps ICE rather than following it.

**2. Telecom / `ConnectionService`.** Recommendation: **no**, per §6. Reconsider only if the owner will make one launcher alias a plausible calling app (e.g. a "Walkie" or "Voice" cover) and register the `PhoneAccount` under that exact label, accepting that the cover then becomes fixed rather than switchable. There is no configuration that gives both full Telecom integration and full concealment — that is a documented product tension, and it should be decided once and written down rather than rediscovered each time someone notices the Bluetooth routing is imperfect.

**3. Relayed video bitrate.** 1 Mbps (Signal parity) or 600 kbps (−40% of the dominant cost line). **Recommendation: 1 Mbps now, delivered via server-controlled remote config** so it can be lowered without an APK when the invoice says so. The decision that must not be deferred is putting the value behind config rather than a constant.

**4. Do calls ring after a force-stop?** There is no engineering answer — FCM drops the message and the platform contract is explicit that nothing may start the app until the user taps the launcher icon. **Recommendation: state it plainly in the app**, ship the "test your ring" button, and treat force-stopped devices as a known, *measured* population in telemetry rather than as a bug queue. The owner should decide whether that sentence appears at onboarding (honest, slightly alarming) or only in a diagnostics screen (discoverable only after the failure).

**5. Free versus Pro.** **Recommendation: Pro immediately.** Free fails closed at 200 concurrent connections with no overage, and `research/supabase.md` puts this app's real free-tier capacity at roughly 100–150 users. Calling does not drive this, but calling is what the failure will be blamed on, because the visible symptom of `too_many_connections` is that foregrounded phones stop ringing.

**6. Per-call topic versus always-on couple topic.** **Recommendation: per-call.** It is what keeps concurrent Realtime connections scaling with *concurrent calls* rather than with *users*, which is the difference between fitting inside the 10,000-connection ceiling at 100k users and not. The cost is one channel join (~50–100 ms) that overlaps `getUserMedia` anyway. Decide now, because S3 and S4 both encode it.

**7. Is multi-device in scope?** **Recommendation: build `device_tokens` now** — it is cheap, it unblocks push fan-out and delivery observability, and the current single `profiles.fcm_token` column means a second sign-in silently steals the ring from the first phone — but **ship single-active-device semantics** (`accept_call` compare-and-set, losers get `accepted_elsewhere`) rather than ICE forking. Revisit forking only if telemetry shows real two-device usage.

**8. Retention of `call_signals` and `call_events`.** Signalling rows have no value past the 60 s freshness window; **recommend a 1-hour `pg_cron` prune** (matching `reach_pulses.sql`). `call_events` is the opposite — it is the only production truth about OEM behaviour and should be kept for at least 90 days, which is well within budget at any scale here. The owner should confirm they want per-call, per-device timing data retained for that long given the app's privacy posture; the mitigation is that `call_events` carries no content, only timestamps and device class.

**9. When to drop `call_invites` and the public topic.** **Recommendation: not before S7 telemetry shows two clean weeks on the new path.** The temptation to delete the old path at S3 should be resisted — the dual-write window is the only rollback that does not require an emergency release.
