# WebRTC 1:1 calling that reliably connects strangers on different mobile carriers — signalling durability, trickle ICE + glare, TURN economics and credential lifecycle, ICE recovery on network change, connect-timeout budgets, and Android incoming-call delivery (Signal/RingRTC, WhatsApp, Discord, Jitsi, libwebrtc, AOSP)

## Mechanism
## 1. Signalling transport: nobody puts call setup on a bare websocket

**The universal shape is a three-layer stack, not one channel.** DOCUMENTED across Signal, WhatsApp and Discord:

- **Layer A — durable, ordered, per-recipient message queue on the server.** Signal sends offer/answer/ICE/hangup as ordinary Signal Protocol messages through the normal message pipeline, so they inherit the store-and-forward queue used for text. RingRTC's `signaling.rs` defines exactly five message types: `Offer`, `Answer`, `Ice`, `Hangup`, `Busy` (`src/rust/src/core/signaling.rs`). WhatsApp does the same: call control rides the same Noise-encrypted websocket used for messaging, as `<call>` stanzas with children `<offer>`, `<preaccept>`, `<accept>`, `<reject>`, `<terminate>`, `<transport>`, `<relaylatency>`.
- **Layer B — a content-free push doorbell.** Signal-Server's `FcmSender` sends a data message whose entire payload is a key string (`"newMessageAlert"`) — no SDP, no caller identity, no call payload. Priority is chosen by one boolean: `.setPriority(pushNotification.urgent() ? AndroidConfig.Priority.HIGH : NORMAL)`, TTL defaults to `Duration.ofDays(28)`.
- **Layer C — the client's own authenticated socket, drained on wake.** Signal-Android's `FcmFetchManager.retrieveMessages()` calls `WebSocketDrainer.blockUntilDrainedAndProcessed(WEBSOCKET_DRAIN_TIMEOUT, ...)` where `WEBSOCKET_DRAIN_TIMEOUT` is **5 minutes** normally, **2 minutes** when the network access is censored. If the drain fails it falls back to `FcmJobService.schedule()` (JobScheduler, API 26+) or the internal JobManager.

**This is the answer to "callee socket is down when the offer is sent."** The offer is never lost — it is *durably enqueued server-side*. The push is only a wake-up. When the callee reconnects it drains the queue in order and gets the offer. What kills the call is not loss, it's **staleness**, and Signal handles that with an explicit freshness gate rather than pretending:

```rust
pub const MAX_MESSAGE_AGE: Duration = Duration::from_secs(60);

pub fn validate_offer(received: &signaling::ReceivedOffer)
    -> std::result::Result<(), OfferValidationError> {
    if received.age > MAX_MESSAGE_AGE {
        return Err(OfferValidationError::Expired);
    }
    Ok(())
}
```
(`ringrtc/src/rust/src/core/call_manager.rs`, lines 64 and 334–341.) An offer older than 60 s is rejected as `Expired` and rendered as a missed call — it never rings. The same 60 s gate applies to group-ring intentions (`RingUpdate::ExpiredRequest`). INFERRED: `received.age` is computed by the platform layer from the server-stamped receive time, which is why it survives clock skew between the two handsets.

**Ordering and one-message-in-flight.** RingRTC does not fire signalling messages concurrently. `SignalingMessageQueue` holds a `VecDeque<SignalingMessageItem<T>>` plus a `messages_in_flight: bool`; the comment says it exists "to control the timing of sending Signaling messages… so messages are sent with the same cadence that they can actually be sent." A new incoming call calls `self.reset_messages_in_flight()`. This makes the wire order deterministic, which is what RFC 8838 §4 *requires* of any trickle-ICE using protocol: the channel must deliver "each trickled candidate… exactly once and in the same order it was conveyed."

**Early-arrival buffering is explicit, bounded, and typed.** RingRTC has `enum PendingCallMessages { None, IceCandidates{..}, Hangup{..} }` — "Management of 1:1 call messages that arrive before the offer for a particular call." ICE candidates for a not-yet-known call are stashed keyed by `call_id`, capped at 30 (`if received.len() >= 30 { received.remove(0); }`), and replayed the moment the offer lands. Candidates arriving after a stored `Hangup` for the same `call_id` are dropped on the floor ("Ice candidates arriving after a hangup are never needed"). Pending messages for a *different* call_id are discarded with a warning. This is the concrete implementation of RFC 8838's rule that a receiver with no local candidates yet for a component simply *stores* the remote candidate.

**Discord is the counter-example and it is instructive.** Discord runs two websockets — the main Gateway and a per-voice-server Voice websocket — and on native clients **deletes ICE, DTLS, SRTP and most of SDP**. They exchange "about 1000 bytes" of raw parameters (server address, port, encryption method/keys, codec, stream ID) instead of an SDP round trip, encrypt with Salsa20 instead of DTLS-SRTP, and hole-punch with periodic pings. They can do this only because every client talks to a server-side SFU, so there is no peer-to-peer NAT problem to solve. Scale: 2.6M concurrent voice users, 850+ voice servers in 13 regions / 30+ data centres, 220+ Gbps egress, 120+ Mpps.

## 2. Offer/answer + trickle ICE lifecycle

RFC 8838 (Trickle ICE, standards track). Candidates go out incrementally as they are gathered so connectivity checks run *in parallel with* gathering. Requirements the using protocol must meet: exactly-once delivery, preserved order, correlation to a specific ICE session by ufrag/pwd, and an explicit **end-of-candidates** indication tagged with that generation — after which the agent "MUST NOT trickle any new candidates" for that session. *Half trickle* (initiator sends a complete generation up front) exists only for interop with non-trickle peers; *full trickle* is the normal mode.

**Signal's ICE forking is the notable product-level extension.** The caller builds one "parent" `PeerConnection` used purely as an ICE gatherer, sends one offer to *all* of the callee's linked devices, and for each answer creates a "child" `PeerConnection` that **shares the parent's IceGatherer** — so N devices are negotiated against without allocating N sets of UDP ports. Critically: "ICE negotiation between *all* of the devices occurs before the recipient accepts the call," so whichever device picks up is already media-ready. That moves ICE off the critical path entirely — the perceived connect time becomes the answer latency, not the ICE latency.

## 3. Perfect negotiation vs. what a real 1:1 call app actually ships

The W3C perfect-negotiation pattern (`polite`/`impolite`, `makingOffer`, `ignoreOffer`, `isSettingRemoteAnswerPending`, `setLocalDescription({type:"rollback"})`) is the right tool for **renegotiation glare inside an established session** — adding a track, an ICE restart, a `negotiationneeded` firing on both sides at once. The spec ties it to `RTCOfferOptions.iceRestart`, which forces "ICE credentials that are different from the current credentials," and recommends restarting when `iceConnectionState` hits `failed`.

**Signal does not use perfect negotiation for call-establishment glare. It uses a numeric call-id tie-break with four distinct outcomes** — because the collision it cares about is "two humans dialled each other," not "two renegotiations raced." From `check_for_collision()`:

```rust
let glare_tiebreaker = || match active_call.call_id().as_u64()
                                 .cmp(&incoming_call_id.as_u64()) {
    Ordering::Greater => ReceivedOfferCollision::GlareWinner,   // keep active call
    Ordering::Less    => ReceivedOfferCollision::GlareLoser,    // drop mine, take theirs
    Ordering::Equal   => ReceivedOfferCollision::GlareDoubleLoser, // drop both
};
```

The full decision table (`ringrtc/src/rust/src/core/call_manager.rs` ~1433–1485, 2061–2118):

| Situation | Collision | Active call action | Incoming call action |
|---|---|---|---|
| No active call | `None` | don't terminate | **Start** |
| Active call, *different* peer | `Busy` | don't terminate | RejectAsBusy → send `Busy` |
| Same peer+device, not yet accepted, my call_id **>** theirs | `GlareWinner` | don't terminate | **Ignore** |
| Same peer+device, not yet accepted, my call_id **<** theirs | `GlareLoser` | TerminateAndSendHangup(`RemoteGlare`) | **Start** |
| call_ids equal (shouldn't happen) | `GlareDoubleLoser` | TerminateAndSendHangup | RejectAsBusy |
| Same peer, same device, but state ≥ `ConnectedAndAccepted` | `ReCall` | Terminate **without** hangup (`RemoteReCall`) | **Start** |
| Same peer, *different* device | `Busy` | don't terminate | RejectAsBusy |

The `ReCall` branch is the one nobody thinks of and everybody hits: the peer hung up and redialled faster than your hangup could be processed, or their ICE failed before yours did. Treating that as `Busy` produces the classic "I can't call you back for 30 seconds" bug. Signal explicitly tears down the stale leg *without* sending a hangup (the peer already ended it) and accepts the new offer.

Note the asymmetry with perfect negotiation: the tie-break is on `call_id` (a random u64 minted per call attempt), not on a static polite/impolite role. That's correct here because there is no stable role between two symmetric peers — either can dial.

## 4. TURN necessity and cost

**Published relay fractions (DOCUMENTED):** callstats.io, 12 months Jan-2015→Feb-2016, billions of minutes, 100+ customers:
- **22 % of sessions required a TURN relay**
- **9 % of conferences required TCP transport** (UDP fully blocked)
- **12 % overall session failure rate**, of which **85 % were NAT/firewall traversal failures**
- ~20 % of sessions dropped after setup; 25 % showed participant churn/rejoin

Jitsi's own handbook states the P2P path exists specifically to avoid burning JVB resources and that TURN is the fallback when direct connection is impossible; community/vendor figures around 40 % for Jitsi deployments are *not* from a Jitsi engineering publication and should be treated as unverified.

For your case specifically — **two strangers on different mobile carriers is close to the worst case in that 22 %.** Mobile carriers overwhelmingly deploy carrier-grade NAT, which is typically address-and-port-dependent (symmetric): the server-reflexive candidate learned from STUN is bound to the 5-tuple toward the STUN server and is useless to the peer. Two symmetric NATs cannot hole-punch. INFERRED but well-founded: for cross-carrier mobile-to-mobile you should budget relay rates materially above 22 %, and design so that TURN is *never* the thing you're missing.

**WhatsApp threw TURN away rather than scale it.** They wrote WASP (WhatsApp STUN Protocol) because "TURN is a somewhat complex protocol that uses multiple ephemeral ports, doesn't work well with firewalls, and doesn't scale well with a distributed architecture." WASP uses **one port for all communication** and "relies much more on the user device to make decisions and keep track of the connection state, which works well for relay server failover." Relays run on "thousands of points-of-presence," selection uses "sophisticated targeting algorithms [applied] to historical latency data" and can change *mid-call* when a user switches WiFi→cellular. Critical call state (group size, device addresses) is checkpointed to state servers immediately; ephemeral state (bandwidth estimates, active speaker) is checkpointed rarely. Scale: "well over a billion calls a day," hundreds of thousands of containers.

**Cost (Cloudflare TURN, which is what Signal itself uses):** $0.05/GB egress from the Cloudflare edge to the TURN client, with a **1,000 GB free tier shared between SFU and TURN** (not two independent allowances). Anycast-homed to the nearest data centre; when both peers are on Cloudflare TURN the traffic rides Cloudflare's backbone. Documented limits: **no TCP relaying** (RFC 6062 not implemented, `REQUESTED-TRANSPORT` ignored — TURN/TLS is available as a wrapper, but there is no TCP *allocation*); **no IPv6 relay addresses** issued (`REQUESTED-ADDRESS-FAMILY` rejected) although client→server works over v4 and v6; packet loss expected above **50–100 Mbps or 5–10 kpps per client**; credential issuance starts at **500/sec**.

## 5. TURN credential lifecycle — Signal's implementation is the reference

Signal-Server's `CloudflareTurnCredentialsManager` (`service/src/main/java/.../auth/CloudflareTurnCredentialsManager.java`) does four things worth copying verbatim:

1. **Two separate TTLs, with a validated invariant.** `requestedCredentialTtl` is what the server asks Cloudflare for; `clientCredentialTtl` is what the server tells the client it may cache. The config record enforces `clientCredentialTtl <= requestedCredentialTtl` via `@AssertTrue isClientTtlShorterThanRequestedTtl()`. The client therefore always refreshes strictly *before* the credential actually dies — there is no window where a client believes a dead credential is live.
2. **DNS is resolved server-side and shipped as literal IPs.** `dnsNameResolver.resolveAll(turnHostname)` → each address is formatted into `urlsWithIps` patterns (v6 bracketed), and the plain `hostname` is also returned "for use as an SNI when connecting to pre-resolved hosts." The returned `TurnToken` is `(username, password, ttlSeconds, urls, urlsWithIps, hostname)`. This removes a DNS round-trip from call setup *and* survives DNS-based blocking, while keeping TLS certificate validation correct via SNI.
3. **The credential fetch is behind a circuit breaker and a retry policy** (`FaultTolerantHttpClient.newBuilder("cloudflare-turn").withCircuitBreaker(...).withRetry(...).withNumClients(n)`), and a non-201 response throws. TURN credential vending is treated as a dependency that will fail, not as a library call.
4. **A dynamic-config override path** (`experimentEnrollmentManager.isEnrolled(accountUuid, "turnBeta")`) so TURN URLs/hostname can be swapped per-user without shipping a client build.

The underlying scheme is `draft-uberti-behave-turn-rest-00`: `username = <unix-expiry-timestamp>:<userid>`, `password = base64(hmac(secret, username))`, response carries `ttl` with **86400 s (one day) recommended**. Crucially: expiry "does not affect existing TURN allocations, as they are tied to a specific 5-tuple, but requests to allocate new TURN ports will fail after the expiry time." So a long call does *not* die when the credential expires — but an **ICE restart mid-call will fail** unless the client re-fetches. Cloudflare's max TTL is **48 hours**, and it exposes an explicit revoke endpoint (`POST .../credentials/$USERNAME/revoke` → 204).

Jitsi does the same shape over XMPP: ephemeral REST-style credentials distributed via **XEP-0215** using `mod_external_services`; the handbook explicitly warns that static `turnserver.conf` credentials are "not recommended for production" because "other people can use your bandwidth freely." Jitsi also documents the corporate-network escape hatch: TURN on **TCP/TLS 443**, multiplexed with the web front end by nginx on SNI, with a dedicated DNS record. Defaults are UDP 3478 and TCP/TLS 5349.

## 6. ICE restart on network change — Signal deliberately does *not* do a full ICE restart

RingRTC's `Connection` handles network change with **continual gathering plus regather**, not with `restartIce()`:

- `ConnectionEvent::IceNetworkRouteChanged(NetworkRoute)` and `inject_ice_network_route_changed()` are driven from the WebRTC callback thread; `handle_ice_network_route_changed()` feeds the FSM, `Call::notify_network_route_changed()` surfaces it to the UI.
- `Connection::regather_on_all_networks()` → `Rust_regatherOnAllNetworks()` — a fresh gathering pass on the *same* ICE session (same ufrag/pwd), so no new offer/answer round trip is needed.
- `ConnectionEvent::IceDisconnected` and `inject_ice_failed()` exist separately, fed from `IceConnectionState::Disconnected` / `::Failed`.

INFERRED (strongly): keeping one ICE generation and trickling new candidates into it is preferable on mobile because a real ICE restart requires an offer/answer exchange, which requires the *signalling* path to be alive — and the moment you most need to recover (WiFi→LTE handover) is exactly the moment your signalling socket is also broken. Continual gathering needs only the media path.

The libwebrtc defaults that govern this are worth knowing exactly (`p2p/base/p2p_constants.h`, current main):

| Constant | Value | Meaning |
|---|---|---|
| `kMinCheckReceivingInterval` | 50 ms | min check interval |
| `kReceivingTimeout` | 2,500 ms (50 × 50 ms) | transport declared not-receiving |
| `kWeakPingInterval` | 48 ms | check pace when selected pair is weak |
| `kStrongPingInterval` | 480 ms | check pace when writable **and** receiving |
| `kStrongAndStableWritableConnectionPingInterval` | 2,500 ms | stabilized pair keepalive |
| `kWeakOrStabilizingWritableConnectionPingInterval` | 900 ms | stabilizing pair |
| `kBackupConnectionPingInterval` | 25 s | keep backup pairs warm |
| `kReceivingSwitchingDelay` | 1 s | hysteresis before switching pairs |
| `kRegatherOnFailedNetworksInterval` | 5 min | periodic regather |
| `kConnectionWriteConnectTimeout` | **5 s** | → pair becomes unwritable |
| `kConnectionWriteConnectFailures` | **5 pings** | with the above |
| `kConnectionWriteTimeout` | **15 s** | → pair write-timed-out |
| `kStunKeepaliveInterval` | 10 s | STUN binding keepalive |
| `kWeakConnectionReceiveTimeout` | 2,500 ms | |
| `kDeadConnectionReceiveTimeout` | **30 s** | connection declared dead |
| `kConnectionResponseTimeout` | **60 s** | wait for a ping response ("in some networks (2G), we observe up to 60s RTTs") |
| `kMinConnectionLifetime` | 10 s | min time before destroying a connection |

On top of that, **RFC 7675 STUN consent freshness** is mandatory for WebRTC and independently fires: consent checks every **4–6 s** (default 5 s, randomized 0.8–1.2×, MUST NOT be < 4 s), and **"consent expires after 30 seconds… the endpoint MUST cease transmission on that 5-tuple."** So 30 s is the hard ceiling on how long a dead path can pretend to be alive.

## 7. The connect-timeout budget a real product actually uses

**Signal: 60 seconds, one number, applied to everything.**
```rust
const TIME_OUT_PERIOD: Duration = Duration::from_secs(60);
```
Started via `incoming_call.start_timeout_timer(TIME_OUT_PERIOD)` on the incoming path and `call.start_timeout_timer(TIME_OUT_PERIOD)` on the outgoing path. On expiry: `terminate_active_call(true, CallEndReason::Timeout)`. The same constant is the default group-ring duration (`INCOMING_GROUP_CALL_RING_TIME`, overridable by env var `INCOMING_GROUP_CALL_RING_SECS`) and the expiry for `OutstandingGroupRing::has_expired()`. And it equals `MAX_MESSAGE_AGE` — so the freshness window for an offer and the ring duration are the same 60 s, which means an offer can never be delivered late enough to ring past its own deadline.

**What the 60 s must cover** and the empirical distribution to calibrate against (callstats.io): **80 % of sessions establish within 5 s**; 80th-percentile setup < 2 s; 50th percentile < 4 s; **67 % of failures occur after 10 s of waiting**; the majority of setup failures land within 30 s. INFERRED design read: sub-5 s is the "it worked" experience, 5–15 s is the danger zone, and everything past ~30 s is a timeout you're just being polite about. 60 s is a ring duration, not a connect budget — the connect budget inside it is ~10–15 s before you should already be relaying.

Jitsi's 1:1 tuning for comparison: `p2p.enabled: true` for "exactly 2 participants," `backToP2PDelay: 5` seconds before returning to P2P after a third participant leaves (explicitly "to filter out page reload"), and a default STUN server on **port 443** (`stun:meet-jit-si-turnrelay.jitsi.net:443`).

## 8. Quality adaptation

- **libwebrtc's loop is Google Congestion Control** (`draft-ietf-rmcat-gcc-02`, Holmer/Lundin/Carlucci/De Cicco/Mascolo): a delay-based estimator fed by **transport-wide congestion control (TWCC)** feedback — inter-arrival-time delta run through a filter to detect queue growth — combined with a loss-based estimator; **the lower of the two wins**.
- **Signal caps relayed calls harder than direct ones.** `BandwidthController::max_send_rate()` = `min(local_max, remote_max, relay_max)` clamped up to `MIN_SEND_RATE`, where:
  ```rust
  const MIN_SEND_RATE: DataRate = DataRate::from_kbps(30);       // never below this
  const RELAYED_MAX_SEND_RATE: DataRate = DataRate::from_mbps(1); // when relayed
  ```
  and `relay_max()` returns `Some(RELAYED_MAX_SEND_RATE)` iff `network_route.local_relayed || network_route.remote_relayed`. This is a policy your app should copy directly: **a relayed call is bandwidth you are paying for, so cap it.** Signal's tick loop runs at `TICK_INTERVAL = 200 ms` (stats, RTP retransmit, audio levels) with RTP data messages retransmitted every 1000 ms.
- **Discord's cheapest win is silence.** They "avoid sending audio during silence periods," which requires both client and server to stop receiving at any time and to **rewrite audio/video packet sequence numbers**. They kept RTCP purely for video quality optimization and bandwidth reporting.

## 9. Android incoming-call delivery — the part that actually decides whether the phone rings

### 9a. FCM: what is documented, precisely
- **Priority.** `AndroidConfig.Priority.HIGH` is what wakes a dozing device: "FCM attempts to deliver high priority messages immediately, allowing FCM to wake a sleeping device… and to run some limited processing (including very limited network access)." Normal priority is deferred to a Doze maintenance window. Google's own listed acceptable use includes "incoming phone calls."
- **App Standby Buckets throttle you.** "Based on which bucket your app belongs to, there might be a cap for the number of high priority messages you are allowed to send per day. Once you reach the cap, any subsequent high priority messages will be downgraded to normal priority." Google does **not** publish the per-bucket numbers. Additionally FCM may deprioritize an app whose high-priority messages don't produce a user-visible notification, evaluated over a **7-day** pattern. INFERRED consequence: if your app sends high-priority pushes that don't ring, you will be silently demoted and calls will start arriving minutes late.
- **Force-stopped is fatal and unrecoverable by you.** Documented drop reason: "Messages were dropped due to the application being force-stopped on the device at the time of delivery, and retries were unsuccessful." The platform contract is explicit: the system must not start the app again "until the user specifically asked for it by launching the app via the launcher icon." No push, no alarm, no broadcast will revive it.
- **Queue limits.** Max **100 pending non-collapsible messages** per device instance; if the cap is hit **all stored messages are discarded** and you get `onDeletedMessages()`. Pending messages survive **28 days**. `onDeletedMessages()` is not called if you haven't sent to that device in 4 weeks.
- Signal's answer to all of this: FCM is best-effort, so Signal-Android **falls back to its own persistent websocket** if FCM registration fails three consecutive days, or immediately on devices without Play Services.

### 9b. Full-screen intent on Android 14+ — and the one place your setup is *advantaged*
- Android 14 (API 34) turned `USE_FULL_SCREEN_INTENT` into a special app access. "For apps targeting Android 14 or higher, apps that are allowed to use this permission are limited to those that provide calling and alarms only."
- **The revocation is performed by the Play Store, not by the OS.** AOSP: "For all apps being installed on Android 14, the `USE_FULL_SCREEN_INTENT` permission is enabled by default. **Upon installation, the Google Play Store revokes** the full-screen intent (FSI) permission for apps that don't have calling or alarm functionalities." Third-party installers set the initial grant explicitly via `PackageInstaller.SessionParams` with `PERMISSION_STATE_DEFAULT` / `_DENIED` / `_GRANTED`.
- Play Console policy: developers must complete an FSI declaration on the App content page (available April 2024); changes took effect **May 31, 2024**; enforcement deadline **January 22, 2025**. Non-qualifying apps must "prompt users to grant permission on new installs and gracefully degrade."
- Runtime: `NotificationManager.canUseFullScreenIntent()` to check, `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` to send the user to the toggle. When it's false the system falls back to a heads-up notification.

### 9c. What Signal-Android actually builds for an incoming call
From `app/src/main/java/org/thoughtcrime/securesms/webrtc/CallNotificationBuilder.java`:
```java
builder.setPriority(NotificationCompat.PRIORITY_HIGH);
builder.setCategory(NotificationCompat.CATEGORY_CALL);
builder.setFullScreenIntent(pendingIntent, true);
// and, on supported API levels:
builder.setStyle(NotificationCompat.CallStyle.forIncomingCall(...));
```
`CallStyle` (API 31+) is what gets a call notification top rank in the shade and lets the system forward it to other devices; on API ≤ 30 the docs say a CallStyle notification "should be associated with a foreground service in order to assign them the high rank."

Foreground service types, from `ActiveCallManager.kt` — note this is composed, not a single type:
```kotlin
ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL   // (else DATA_SYNC on older API)
type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
```
And it implements the Android 15 timeout contract: `override fun onTimeout(startId: Int, fgsType: Int)` → logs "has timed out. Hanging up." → `activeCallManager?.shutdown(fromTimeout = true)`.

### 9d. Telecom / ConnectionService
`MANAGE_OWN_CALLS` + a self-managed `ConnectionService` (or Jetpack `androidx.core:core-telecom` `CallsManager`) is what integrates your call with the platform: hold/switch against the cellular dialer, correct audio routing, Bluetooth. Two hard timeouts are documented in the Core-Telecom guide: **you must post a notification within 5 seconds of adding the call**, and **remote-surface callbacks (`onAnswerCall`, `onSetCallActive`, `onSetCallInactive`, `onSetCallDisconnected`) must complete within 5 seconds** — "failure to do so (either by not returning or by throwing an exception) is considered a transaction failure and may tear down the call session." Also documented: use `AudioManager.STREAM_VOICE_CALL` and **do not** call `AudioManager#setCommunicationDevice` or `startBluetoothSco` — doing so breaks audio. Legacy path additionally needs `BIND_TELECOM_CONNECTION_SERVICE` on the service and the `android.telecom.ConnectionService` intent filter, plus `TelecomManager#addNewIncomingCall()` → `onCreateIncomingConnection()`.

### 9e. Android 14 / 15 changes that break the naive implementation
- **Android 14:** every FGS must declare a type; VoIP wants `phoneCall`. Background activity launch from a `PendingIntent` now requires opt-in: `ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)`; `bindService` needs `BIND_ALLOW_ACTIVITY_STARTS`. Implicit intents are only delivered to exported components.
- **Android 15:** `BOOT_COMPLETED` receivers **cannot** start `phoneCall`, `microphone`, `camera`, `mediaPlayback`, `mediaProjection` or `dataSync` FGS — `ForegroundServiceStartNotAllowedException` (test: `adb shell am compat enable FGS_BOOT_COMPLETED_RESTRICTIONS <pkg>`). `SYSTEM_ALERT_WINDOW` no longer buys a background FGS start unless an overlay window is actually visible (`FGS_SAW_RESTRICTIONS`). `dataSync` and the new `mediaProcessing` types are capped at **6 hours per 24 h** and must implement `Service.onTimeout(int,int)`. Audio focus requires being the top app or running a FGS. TLS 1.0/1.1 disallowed.

### 9f. OEM battery restrictions — what is actually documented vs folklore
Google's own guidance on OEM delivery problems is thin ("check if the issue is observed on a specific OEM device, model, or Android version… upgrade… to the latest OTA"). The substantive documentation is community-maintained (dontkillmyapp.com), and it is the honest state of the art:
- **Huawei EMUI 9+ (Android P+) ships PowerGenie**, which "kills everything not whitelisted by Huawei and does not give users any configuration options." It measures wakelocks, temperature, power consumption and network utilization and terminates offenders. The whitelist (Google system apps, Facebook, Baidu) is not editable. User mitigation: Settings → Battery → App launch → "Manage manually" with all options on.
- **Xiaomi MIUI/HyperOS:** apps are removed from background unless protected; clearing recents kills unpinned apps; Ultra battery saver terminates unprotected apps. **MIUI 14+ added a per-app "Background autostart" permission** under Settings → Apps → *app* → App permissions, which on HyperOS is **separate from** the Security-app "Autostart" toggle — both must be enabled. Also needs Battery Manager → Power Plan → "Performance", app marked Protected, and App battery saver → "No restrictions".
- Vendor severity rating on that site: Xiaomi, Samsung, OnePlus (OxygenOS) and Huawei all at the worst tier; AOSP/Nokia/HTC clean.
- INFERRED but reliable: no API exists to detect or request these exemptions. The only shippable mitigations are (a) `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` for the AOSP layer, (b) a first-run screen that deep-links the user into the OEM settings page, (c) measuring push→ring latency in telemetry per OEM so you know when you're broken.

## Invariants
- Signalling durability is a property of a server-side per-recipient queue, not of the socket. The offer is committed to durable storage before any push is sent; the push carries no state and can be lost, duplicated or delayed without affecting correctness. (Signal: offer travels the normal Signal Protocol message pipeline; FCM payload is the literal string "newMessageAlert".)
- Every call-setup message is stamped with an age and gated against a single freshness constant, so a late delivery degrades to a missed call instead of ringing a phone about a conversation that ended ten minutes ago. Signal: MAX_MESSAGE_AGE = 60 s, checked by validate_offer() before any UI is shown.
- The ring deadline and the offer freshness window are the same number (both 60 s in RingRTC), which makes it impossible for an offer to be accepted-as-fresh yet expire before it can be answered. Two constants that must agree are better expressed as one.
- Signalling is serialized: one message in flight per call, a FIFO queue behind it, and an explicit reset on new call start. This is what lets trickle ICE satisfy RFC 8838's exactly-once, in-order delivery requirement without sequence numbers on the wire.
- Messages that arrive before the state they refer to are buffered by call_id in a bounded, typed structure rather than dropped or replayed blindly: ICE candidates capped at 30 per call_id, candidates after a hangup for the same call_id discarded, buffers for a stale call_id evicted. Out-of-order arrival is a designed-for case, not an error path.
- Glare is resolved by a total order over a value both peers already have (the 64-bit call_id), so both sides independently reach the same decision with zero extra round trips. There is no negotiation about who wins.
- The glare state machine distinguishes 'same peer, same device, not yet accepted' (tie-break) from 'same peer, same device, already connected' (ReCall — the peer redialled; tear down silently and accept) from 'same peer, different device' (busy). Collapsing these is what produces the 'cannot call back for 30 seconds' bug.
- A hangup carries its own reason and the originating DeviceId (AcceptedOnAnotherDevice / DeclinedOnAnotherDevice / BusyOnAnotherDevice / NeedPermission), so multi-device outcomes are explicit in the protocol rather than inferred from timing.
- TURN credentials have two TTLs — the one requested from the provider and the shorter one advertised to the client — with the relationship enforced at config-load time. A client therefore always refreshes before real expiry; there is no window in which a client trusts a dead credential.
- TURN endpoints are shipped to clients as pre-resolved IP literals plus a separate hostname for SNI, so call setup contains no DNS round trip and survives DNS-level blocking without weakening certificate validation.
- Recovery from a network change uses continual ICE gathering on the existing ICE generation (regather + trickle) rather than an ICE restart, because an ICE restart needs the signalling channel to be alive at exactly the moment the network change has broken it.
- A relayed path is bandwidth you are paying for, so it is capped independently of what congestion control would allow: RingRTC's max_send_rate() = min(local, remote, relay) with relay = 1 Mbps whenever either side is relayed, floored at 30 kbps.
- Push is treated as best-effort with a documented fallback: Signal switches to its own persistent websocket after three consecutive days of failed FCM registration, and on devices with no Play Services at all.
- Every foreground-service and Telecom deadline the platform imposes has an explicit handler rather than being assumed not to fire: onTimeout(startId, fgsType) hangs the call up cleanly, and the 5-second notification and 5-second callback contracts are respected.

## Failure modes designed for
- Callee's socket is down at the instant the offer is sent — solved by a durable server-side per-recipient queue plus a content-free high-priority push that only wakes the client, which then drains the queue in order (Signal-Android drains with a 5-minute budget, 2 minutes when censored).
- Offer delivered far too late (phone was off, in Doze, or in a tunnel) — rejected by validate_offer() at age > 60 s and surfaced as a missed call rather than ringing a stale call.
- ICE candidates arriving before the offer they belong to — buffered in PendingCallMessages keyed by call_id, capped at 30, replayed the moment the offer lands.
- ICE candidates arriving after the call already ended — dropped by design ('Ice candidates arriving after a hangup are never needed').
- Both users dial each other simultaneously (true glare) — resolved by comparing call_id as u64; loser terminates its own leg and sends a hangup, winner ignores the incoming offer.
- Peer hangs up and immediately redials faster than the hangup propagates, or their ICE fails before yours does — the ReCall branch tears down the stale leg without sending a hangup and accepts the new offer.
- Peer calls from a different linked device while you are already in a call with them — answered as Busy, not misread as glare.
- Callee has several linked devices and you don't know which will answer — ICE forking rings all of them, sharing one ICE gatherer across child PeerConnections so all are media-ready before the human picks up.
- Both endpoints behind carrier-grade symmetric NAT so hole punching is impossible — TURN relay (22% of sessions in the callstats corpus; higher for cross-carrier mobile).
- UDP blocked entirely by a corporate or captive network — TURN over TCP/TLS on port 443, multiplexed with the web frontend by SNI (Jitsi's documented pattern). Note Cloudflare TURN does NOT implement RFC 6062 TCP allocations, only TLS wrapping.
- DNS resolution of the TURN hostname is blocked or slow — server resolves it and ships literal IPs plus a hostname for SNI.
- The TURN credential vending service is down or slow — Signal wraps it in a circuit breaker plus a retry policy with multiple parallel HTTP clients, and a non-201 is a hard failure rather than a silent empty ICE server list.
- A long call outlives its TURN credential — existing allocations survive because they are bound to a 5-tuple, but any subsequent ICE restart would fail, so clients refresh on the shorter client-facing TTL.
- WiFi to cellular handover mid-call — continual gathering plus regather_on_all_networks() surfaces new candidates on the same ICE generation; libwebrtc's 5 s unwritable / 15 s write-timeout / 30 s dead-connection ladder and RFC 7675's 30 s consent expiry bound how long a dead path can linger.
- A path that silently stops carrying media without any error — RFC 7675 consent freshness checks every 4–6 s force cessation after 30 s.
- Relayed call consuming unbounded egress — hard 1 Mbps cap the moment either side is relayed.
- App is force-stopped by the user or an OEM task killer — FCM drops the message outright and nothing can revive the app until the user taps the launcher icon. Signal's mitigation is a persistent websocket fallback, not a push workaround.
- High-priority push quota exhausted via App Standby Buckets, silently downgrading calls to normal priority — mitigated by only ever sending high priority for messages that actually produce a user-visible notification (Google evaluates this over a 7-day window).
- More than 100 non-collapsible messages pending for a device — all stored messages are discarded and onDeletedMessages() fires, requiring a full client-side resync.
- USE_FULL_SCREEN_INTENT not granted on Android 14+ — check canUseFullScreenIntent() and degrade to a CATEGORY_CALL / PRIORITY_HIGH / CallStyle heads-up notification, with a deep link to ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT.
- Android 15 forbidding phoneCall/microphone foreground services started from BOOT_COMPLETED, and revoking the SYSTEM_ALERT_WINDOW shortcut for background FGS starts.
- The foreground service being timed out by the platform mid-call — Service.onTimeout() logs and hangs up cleanly instead of being killed with the call in limbo.
- Telecom tearing down the call session because a remote-surface callback took longer than 5 seconds, or no notification was posted within 5 seconds of addCall().
- OEM battery managers (Huawei PowerGenie, MIUI/HyperOS autostart plus App battery saver, OxygenOS) killing the process or withholding the wake — no API exists; mitigations are the AOSP battery-optimization exemption prompt, first-run deep links into OEM settings, and per-OEM push-to-ring latency telemetry.
- Voice/relay server dying mid-call — Discord's client detects the severed voice websocket and requests reassignment through the gateway; WhatsApp checkpoints critical call state to state servers immediately so a relay container can be replaced under the call.

## Applicability to Supabase
## Transfers directly, with no new component

**1. The three-layer signalling stack maps cleanly.** Postgres table = Signal's durable queue; Supabase Realtime = the fast path; FCM = the doorbell. Concretely: a `call_signals` table (`id`, `call_id uuid`, `to_user`, `from_user`, `from_device`, `type` in `('offer','answer','ice','hangup','busy')`, `payload jsonb`, `created_at timestamptz default now()`, `consumed_at`), RLS restricting `select` to `to_user = auth.uid()`, and a `bigserial seq` column so the callee can drain in a total order with a monotonic cursor. This is the single most important thing to copy and the one thing Supabase Realtime cannot do for you.

**2. Supabase Realtime Broadcast is NOT durable and must not be the offer transport.** DOCUMENTED: messages from client libraries or the REST API "are not persisted—they exist only as live WebSocket transmissions." Only `realtime.broadcast_changes()` from a database trigger persists, into `realtime.messages`, in daily partitions **dropped after 72 hours**, with Broadcast Replay capped at **25 messages per request** on private channels. If you send the offer over `channel.send()` and the callee's socket is down, the offer is simply gone. Use the table as the source of truth and `broadcast_changes()` from an `AFTER INSERT` trigger as the low-latency notification — that gives you both durability and sub-second delivery from one write.

**3. Copy the 60-second freshness gate verbatim.** `age = now() - created_at` computed **server-side** (or from `created_at` returned by Postgres, never from the sender's device clock — you have two phones with independent clocks). Offer age > 60 s → insert a missed-call row and never ring. This single check removes an entire class of "why did my phone ring at 3am about a call from yesterday" bugs.

**4. Copy the glare tie-break exactly.** Generate `call_id` as a random `uuid`/`int8` per attempt; on receiving an offer while you have an active call with the same peer, compare the two ids as unsigned integers. Implement all four outcomes (`GlareWinner`, `GlareLoser`, `GlareDoubleLoser`, `ReCall`) plus `Busy`. **Do not implement W3C perfect negotiation for call setup** — polite/impolite is for renegotiation inside an established `RTCPeerConnection` and doesn't map to "two people dialled at once." Do keep perfect negotiation available for in-call renegotiation if you ever add screen share or camera toggling.

**5. Copy the pre-offer ICE buffer.** In Dart, a `Map<String, List<RTCIceCandidate>>` keyed by `call_id`, capped at 30, drained when the offer's `PeerConnection` exists, and cleared when a hangup for that `call_id` arrives. `flutter_webrtc`'s `addCandidate()` before `setRemoteDescription()` throws or silently no-ops depending on platform — you need this buffer regardless.

**6. Serialize signalling sends.** One outbound message in flight per call, FIFO behind it. In Dart this is a small `Queue` plus a `bool _inFlight`. Free-tier Realtime is **100 messages/second** (documented), and trickle ICE naturally bursts 15–30 candidates in the first second or two — see scale notes.

**7. Cloudflare TURN credential handling maps 1:1 onto an Edge Function.** Your Deno function is Signal's `CloudflareTurnCredentialsManager`. Do all four things:
- Two TTLs: request e.g. `ttl: 7200` from Cloudflare, tell the client it may cache for e.g. 3600, and assert `client <= requested` in code. Cloudflare's documented max is **48 hours**.
- The API token stays in the function's secrets; it must never reach the APK. Your existing `app_secrets` + `turn-credentials` function pattern is already the right shape — this just adds the two-TTL discipline.
- Resolve the TURN hostname in the Edge Function (`Deno.resolveDns(host, "A")`) and return both `urls` (hostnames) and `urlsWithIps` (literals) so the handset skips a DNS lookup on a carrier resolver. Deno supports this natively.
- Wrap the Cloudflare call with a timeout and a retry, and cache the last-known-good token in Postgres so a Cloudflare blip doesn't mean "no calls."

**8. Copy the relayed-path bitrate cap.** `flutter_webrtc` exposes the selected candidate pair through `getStats()`; when `remoteCandidateType == 'relay' || localCandidateType == 'relay'`, clamp the video sender to ~1 Mbps via `RTCRtpSender.setParameters` with `encodings[0].maxBitrate`. This is Signal's `RELAYED_MAX_SEND_RATE` and it directly controls your Cloudflare bill.

**9. Recovery on network change: regather, don't restart.** `flutter_webrtc` exposes `restartIce()`, but prefer Signal's approach — leave `continualGatheringPolicy: 'gather_continually'` in the peer connection config, listen to `onIceConnectionState`, and only fall back to a full `restartIce()` (which needs a fresh offer/answer through Supabase) if the connection is still `disconnected` after several seconds. Note the RFC dependency: an ICE restart needs a **new TURN allocation**, so re-fetch TURN credentials before calling `restartIce()` if the cached one is near its client TTL.

**10. Connect-timeout budget.** Adopt Signal's numbers: 60 s ring deadline == 60 s offer freshness. Inside it, target the callstats distribution — if you are not connected in ~10 s you are in the 67%-of-failures zone. Practical policy: start with `iceTransportPolicy: 'all'`, and if no candidate pair is selected within ~8–10 s, do a relay-only retry (`iceTransportPolicy: 'relay'`) rather than waiting out libwebrtc's 15 s write timeout and 30 s dead-connection timeout.

## Needs a paid tier or a rethink

**Realtime free tier is the binding constraint, and messages/second bites before connections.** Documented free limits: **200 concurrent connections, 100 messages/second, 100 channel joins/second, 100 channels per connection, 256 KB payload**. At thousands of users:
- **Do not hold a Realtime socket for every user.** Signal doesn't hold a socket for offline users either — FCM wakes the client, which *then* connects. Subscribe to the call channel only when the app is foregrounded or a call push arrives. This is what keeps you under 200 concurrent.
- 100 msgs/sec is roughly **3–5 simultaneous call setups** at typical trickle-ICE burst rates. Pro tier ($25/mo) raises this to 500 connections / 500 msgs-sec; Pro without a spend cap goes to 10,000 / 2,500.
- Reduce message count per call: **batch ICE candidates**. Instead of one Realtime message per candidate, buffer for ~150–250 ms and send an array. That cuts a call's signalling from ~60 messages to ~8–12 with negligible latency cost, and buys you roughly 5× headroom on both the per-second and per-month budgets.

**Cloudflare TURN economics are comfortable — the math (INFERRED arithmetic from documented rates).** $0.05/GB after 1,000 GB free (shared with SFU). Cloudflare bills egress from its edge to the TURN client, so a fully relayed call is charged in both directions.
- Opus audio at ~32 kbps ≈ 0.24 MB/min per stream; a relayed audio call ≈ **0.5 MB/min** billable → the 1,000 GB free tier ≈ **~2 million minutes** of relayed audio per month.
- Video at ~1 Mbps ≈ 7.5 MB/min per stream; a relayed video call ≈ **15 MB/min** → free tier ≈ **~66,000 minutes (~1,100 hours)** of relayed video per month.
- At a 22% relay rate, that supports a lot of thousands-of-users traffic before you pay anything. The 1 Mbps relay cap from item 8 is what keeps this true.
- Watch the documented ceilings instead: **no TCP relay allocations** (only TLS wrapping) and **no IPv6 relay addresses**. On IPv6-only mobile carriers (increasingly common) you are relying on the carrier's NAT64/464XLAT. Verify on your actual Vivo/OnePlus handsets rather than assuming.

**Edge Functions:** 500k invocations/month free. TURN credential mint is 1–2 invocations per call. Non-issue.

## Needs a component that does not exist yet

**A. A push sender that marks call pushes urgent, and only call pushes.** Signal's entire priority model is one boolean on the server. You need an Edge Function (triggered from the same `AFTER INSERT` on `call_signals` where `type='offer'`) that sends an FCM **data-only** message with `android.priority = "high"` and a short `ttl` (60 s — matching your freshness gate, so FCM itself discards a push that would arrive too late to ring). Critically: **do not** send high-priority pushes for chat messages that don't produce a visible notification, or FCM will deprioritize the app over its documented 7-day evaluation window and your *calls* will start arriving late.

**B. Content-free push + fetch-on-wake.** Do not put the SDP in the FCM payload. Send `{"type":"call","call_id":"..."}` and have the client fetch the row. Reasons: FCM has a 4 KB payload limit that a full SDP with candidates will exceed; pushes can be delivered out of order; and the push is the one part of the path with no delivery guarantee. Mirror `FcmFetchManager`: on wake, connect Realtime and drain unconsumed `call_signals` rows ordered by `seq`.

**C. Android incoming-call surface.** Currently missing and it's the highest-risk piece:
- `MANAGE_OWN_CALLS` + a self-managed `ConnectionService` (or `androidx.core:core-telecom` `CallsManager`). Respect both documented 5-second deadlines: notification within 5 s of `addCall()`, and every remote-surface callback returning within 5 s.
- A foreground service with `foregroundServiceType="phoneCall|microphone|camera"`, implementing `onTimeout(startId, fgsType)` → hang up (Android 15 requirement).
- `CallStyle.forIncomingCall()` + `CATEGORY_CALL` + `PRIORITY_HIGH` + `setFullScreenIntent(pi, true)`, gated on `canUseFullScreenIntent()`.
- **You have a real advantage here that Play-Store apps don't.** AOSP documents that `USE_FULL_SCREEN_INTENT` is *granted by default at install on Android 14+*, and it is the **Play Store** — not the OS — that revokes it for non-calling apps. This app is sideloaded and not on the Play Store, so the revocation never happens. Still call `canUseFullScreenIntent()` and degrade gracefully, because a user (or an OEM ROM) can revoke it manually.
- Do **not** start the call foreground service from a `BOOT_COMPLETED` receiver — Android 15 throws `ForegroundServiceStartNotAllowedException` for `phoneCall` and `microphone` types started that way.

**D. A conflict you must resolve before building C — the launcher disguise.** Per project memory, the Android launcher name and icon are intentionally disguised ("News", Google-style icon). A self-managed `ConnectionService` registers a `PhoneAccount` that surfaces under **Settings → Apps → Default apps → Calling accounts**, and a `CallStyle` full-screen incoming-call UI displays the app label prominently on the lock screen. That is a loud, system-level advertisement of what the app actually is. You have three options and should pick deliberately: (1) keep the disguise and skip Telecom entirely — use a plain full-screen-intent Activity plus a `phoneCall`-typed foreground service, losing cellular-call interop and clean Bluetooth routing; (2) drop the disguise for calling; (3) register the PhoneAccount with the disguised label, which keeps the cover but makes the Settings entry confusing. There is no configuration that gives you both full Telecom integration and full concealment.

**E. OEM survival flow.** Your target handsets (OnePlus IN2015, Vivo, OnePlus 7) are all on the worst tier of the vendor-restriction list. Ship a first-run screen that requests `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and deep-links into the OEM autostart/battery pages, and record a `push_sent_at` → `ring_shown_at` delta per device so you can see which OEMs are silently broken. Nothing can recover a force-stopped package — that is a documented platform contract, not a bug to work around.

**F. A `calls` state table separate from `call_signals`.** One row per call attempt holding `call_id`, `caller`, `callee`, `state`, `created_at`, `answered_at`, `ended_at`, `end_reason`, and `answered_by_device`. This is what makes `Busy`, `ReCall` and multi-device hangup reasons implementable, and it is your missed-call log. Signal's `Hangup` enum (`Normal`, `AcceptedOnAnotherDevice`, `DeclinedOnAnotherDevice`, `BusyOnAnotherDevice`, `NeedPermission`) is a good starting vocabulary for `end_reason`.

## Scale
## Where each mechanism breaks, and what it costs

**Supabase Realtime — free tier, in order of which limit you hit first**
- **100 messages/second** is the first wall, not the 200 connections. A naive trickle-ICE call emits roughly 15–30 candidates per side plus offer/answer/hangup ≈ 40–60 messages, most of them bursting inside the first 1–2 seconds. That is **~2–4 concurrent call setups** before you start dropping. Mitigation before money: batch candidates on a 150–250 ms timer (drops a call to ~8–12 messages, ~5× headroom). Cost to fix with money: Pro at $25/mo → 500 msgs/sec; Pro without spend cap → 2,500 msgs/sec.
- **200 concurrent connections** breaks at ~200 simultaneously-connected users. Thousands of registered users is fine *if you don't hold a socket for idle users*. If you do subscribe every launched app, 200 concurrent is roughly 2–5k MAU depending on session overlap. Pro → 500; Pro uncapped/Team → 10,000. Overage is documented at $10 per 1,000 connections.
- **2M realtime messages/month** (pricing page; the official limits page does not document a monthly figure). At ~50 messages/call ≈ **40,000 calls/month**; with candidate batching at ~10 messages/call ≈ 200,000 calls/month. Overage $2.50 per 1M.
- **256 KB max broadcast payload on free tier** (3 MB on Pro). An SDP offer is 2–8 KB, so this is not a constraint for signalling — but it does mean you cannot lazily stuff media or images through the same channel.
- **Hard architectural limit:** Realtime gives you no replay for client-sent broadcasts and only 72 hours / 25 messages for database-sourced ones. This never scales into a durable signalling channel at any tier. The Postgres table is not a free-tier workaround; it is the correct design at every tier.

**Postgres as the signalling queue**
- Cheap to thousands of calls/day. The failure mode is not throughput, it's **table growth and index bloat** from ICE candidate rows. Partition `call_signals` by day or add a `pg_cron` job deleting rows older than ~1 hour — signalling rows have no value past the 60 s freshness window. Free tier gives 500 MB of database storage; unpruned candidate rows will eat it.
- RLS on every select adds a predicate per row; with a `(to_user, seq)` index this stays sub-millisecond well past your scale.

**FCM**
- No documented per-app rate limit on message volume, but the **App Standby Bucket per-day cap on high-priority messages is real and its numbers are unpublished**. This is the single scariest undocumented cliff in the whole design: you cannot measure it from the server, only observe latency regressions on the client. Instrument push→ring latency per device from day one.
- The **100 pending non-collapsible messages** per device cap means a user who is offline for a long time and receives many messages can have *all* stored messages discarded. Your offer will be among them. This is a correctness reason to keep the durable queue in Postgres, not to rely on FCM's own retention.
- Force-stopped packages are an absolute wall. On a 3-device test fleet this shows up as "one phone never rings" and looks like a code bug for a week.

**TURN (Cloudflare)**
- Free 1,000 GB shared with SFU. INFERRED from documented $0.05/GB and codec bitrates: ~2M minutes/month of relayed *audio*, or ~66,000 minutes (~1,100 hours) of relayed *video*, before the first dollar. At a 22% relay rate that covers a very large amount of couple-app traffic.
- The cost curve is entirely governed by the relay bitrate cap. Without Signal's 1 Mbps clamp, GCC on good WiFi will happily push 2.5 Mbps of video through the relay and roughly triple your bill for no perceptible quality gain on a phone screen.
- Documented per-client ceilings: packet loss expected above **50–100 Mbps or 5–10 kpps**. Irrelevant for 1:1 calls; would matter for group.
- Credential issuance starts at **500/sec** and scales linearly. Not a constraint. But do not mint per-ICE-candidate — mint once per call and cache for the client TTL.
- **The real scaling risk is not cost, it's the two documented gaps:** no TCP relay allocations (RFC 6062 unimplemented) and no IPv6 relay addresses. On a network that blocks UDP entirely, TURN/TLS on 443 is your only path and it is a wrapper, not a TCP allocation — verify it actually works on the restrictive networks your users hit. On IPv6-only carriers you depend on 464XLAT.

**Edge Functions**
- 500k invocations/month free. TURN mint at 1–2 per call plus the push-sender at ~1 per call ≈ 3 invocations/call ≈ 160,000 calls/month before the limit. Not the binding constraint.
- The binding constraint is **cold start** on the credential mint sitting in the call-setup critical path. Mitigate by caching the TURN token client-side for its full client TTL and refreshing in the background, not at dial time — which is exactly why Signal has a client-facing TTL at all.

**Where the top-tier designs themselves break**
- **Signal's ICE forking** costs the caller N child PeerConnections for N callee devices. It shares the IceGatherer so UDP port count doesn't multiply, but connectivity checks do. Fine at 2–5 devices; it is a per-user constant, not a per-load one.
- **Signal's 60 s constant** is a product decision, not a scaling one; it is identical at 1 user and 100M.
- **Jitsi's P2P mode** applies only at exactly 2 participants and hands off to the JVB SFU at 3 — the mesh never scales and they never pretend otherwise. If this app ever adds a third participant, the P2P design does not extend; you need an SFU (Cloudflare Realtime SFU shares the same 1,000 GB allowance).
- **Discord's model inverts the economics deliberately:** by relaying 100% of traffic through their SFU they pay 220+ Gbps of egress but eliminate ICE, NAT traversal failures and IP leakage entirely. That is the right trade at 2.6M concurrent users and the wrong trade for a two-person app, where 78% of calls cost you nothing.
- **WhatsApp built WASP** specifically because TURN's multi-ephemeral-port model doesn't survive a distributed relay fleet with failover. That is a "billion calls a day" problem. You are on the other side of that line — standard TURN through a managed anycast provider is correct and replacing it would be pure cost."

## Sources
- [Signal RingRTC — call_manager.rs: offer expiry, call timeout, glare tie-break, pending-message buffering, signalling message queue](https://raw.githubusercontent.com/signalapp/ringrtc/main/src/rust/src/core/call_manager.rs) — MAX_MESSAGE_AGE = Duration::from_secs(60) and TIME_OUT_PERIOD = Duration::from_secs(60); validate_offer() returns OfferValidationError::Expired for age > 60s; check_for_collision() breaks glare by comparing active_call.call_id().as_u64() to incoming_call_id.as_u64() yielding GlareWinner/GlareLoser/GlareDoubleLoser, plus a distinct ReCall branch when state >= ConnectedAndAccepted; PendingCallMessages buffers pre-offer ICE candidates capped at 30 per call_id.
- [Signal RingRTC — connection.rs: bandwidth control, network route change, regather](https://raw.githubusercontent.com/signalapp/ringrtc/main/src/rust/src/core/connection.rs) — MIN_SEND_RATE = 30 kbps, RELAYED_MAX_SEND_RATE = 1 Mbps applied whenever network_route.local_relayed || remote_relayed; max_send_rate() = min(local, remote, relay) clamped to MIN; TICK_INTERVAL = 200 ms; recovery on network change is regather_on_all_networks() + IceNetworkRouteChanged events, not restartIce().
- [Signal RingRTC — signaling.rs: the complete signalling message vocabulary](https://raw.githubusercontent.com/signalapp/ringrtc/main/src/rust/src/core/signaling.rs) — Exactly five message types: Offer, Answer, Ice, Hangup, Busy. Hangup carries a reason enum including AcceptedOnAnotherDevice / DeclinedOnAnotherDevice / BusyOnAnotherDevice / NeedPermission with a DeviceId — multi-device disambiguation is in the protocol, not inferred client-side.
- [Signal-Server — CloudflareTurnCredentialsManager.java](https://raw.githubusercontent.com/signalapp/Signal-Server/main/service/src/main/java/org/whispersystems/textsecuregcm/auth/CloudflareTurnCredentialsManager.java) — Signal proxies Cloudflare's TURN credential API server-side with a Bearer token, resolves the TURN hostname to literal IPs via DnsNameResolver and returns urlsWithIps plus the hostname for SNI, wraps the call in a circuit breaker + retry, and returns TurnToken(username, password, clientCredentialTtl, urls, urlsWithIps, hostname).
- [Signal-Server — CloudflareTurnConfiguration.java (the two-TTL invariant)](https://raw.githubusercontent.com/signalapp/Signal-Server/main/service/src/main/java/org/whispersystems/textsecuregcm/configuration/CloudflareTurnConfiguration.java) — requestedCredentialTtl (asked of Cloudflare) is distinct from clientCredentialTtl (time clients may cache), and @AssertTrue isClientTtlShorterThanRequestedTtl() enforces clientCredentialTtl <= requestedCredentialTtl at config load.
- [Signal-Server — FcmSender.java and PushNotification.java](https://raw.githubusercontent.com/signalapp/Signal-Server/main/service/src/main/java/org/whispersystems/textsecuregcm/push/FcmSender.java) — AndroidConfig.setPriority(pushNotification.urgent() ? HIGH : NORMAL); DEFAULT_TTL_MILLIS = Duration.ofDays(28); the data payload is a bare key such as "newMessageAlert" — the push carries no call content, it is only a wake-up.
- [Signal-Android — FcmFetchManager.kt (wake → drain websocket → job fallback)](https://raw.githubusercontent.com/signalapp/Signal-Android/main/app/src/main/java/org/thoughtcrime/securesms/gcm/FcmFetchManager.kt) — WEBSOCKET_DRAIN_TIMEOUT = 5 minutes normally, 2 minutes when censored; retrieveMessages() calls WebSocketDrainer.blockUntilDrainedAndProcessed() and on failure schedules FcmJobService (API 26+) or a MessageFetchJob.
- [Signal-Android — CallNotificationBuilder.java](https://raw.githubusercontent.com/signalapp/Signal-Android/main/app/src/main/java/org/thoughtcrime/securesms/webrtc/CallNotificationBuilder.java) — Incoming ringing notification uses PRIORITY_HIGH + CATEGORY_CALL + setFullScreenIntent(pendingIntent, true) + NotificationCompat.CallStyle.forIncomingCall(...) on supported API levels.
- [Signal-Android — ActiveCallManager.kt (foreground service types + Android 15 onTimeout)](https://raw.githubusercontent.com/signalapp/Signal-Android/main/app/src/main/java/org/thoughtcrime/securesms/service/webrtc/ActiveCallManager.kt) — Composes FOREGROUND_SERVICE_TYPE_PHONE_CALL (DATA_SYNC on older APIs) OR MICROPHONE OR CAMERA OR MEDIA_PROJECTION, and implements onTimeout(startId, fgsType) which hangs up the call.
- [Signal blog — Multi-device calls with ICE forking](https://signal.org/blog/ice-forking/) — One offer is sent to all of the recipient's devices; a parent PeerConnection acts as an ICE gatherer and each answer creates a child PeerConnection sharing the parent's IceGatherer, so ICE negotiation with all devices completes before the callee accepts.
- [RFC 8838 — Trickle ICE](https://www.rfc-editor.org/rfc/rfc8838.html) — The using protocol must deliver each trickled candidate exactly once and in the same order it was conveyed, correlate it to an ICE session by ufrag/pwd, and support an end-of-candidates indication after which no further candidates may be trickled. Remote candidates arriving before local ones are merely stored, then paired once gathering starts.
- [RFC 7675 — STUN Usage for Consent Freshness](https://www.rfc-editor.org/rfc/rfc7675.html) — Consent expires after 30 seconds without a valid STUN binding response, at which point the endpoint MUST cease transmission on that 5-tuple; checks default to a 5-second interval randomized 0.8–1.2x (4–6 s) and MUST NOT be shorter than 4 seconds.
- [libwebrtc p2p/base/p2p_constants.h — the actual ICE timing defaults](https://webrtc.googlesource.com/src/+/refs/heads/main/p2p/base/p2p_constants.h) — kConnectionWriteConnectTimeout = 5 s with kConnectionWriteConnectFailures = 5 pings; kConnectionWriteTimeout = 15 s; kDeadConnectionReceiveTimeout = 30 s; kConnectionResponseTimeout = 60 s (comment: "in some networks (2G), we observe up to 60s RTTs"); kStrongPingInterval 480 ms / kWeakPingInterval 48 ms; kReceivingTimeout 2500 ms; kRegatherOnFailedNetworksInterval 5 min; kStunKeepaliveInterval 10 s; kBackupConnectionPingInterval 25 s.
- [libwebrtc p2p/base/ice_transport_internal.h — continual gathering policy](https://webrtc.googlesource.com/src/+/refs/heads/main/p2p/base/ice_transport_internal.h) — ContinualGatheringPolicy has GATHER_ONCE (all port allocator sessions stop once a writable connection is found) and GATHER_CONTINUALLY (the most recent session keeps running) — GATHER_CONTINUALLY is what makes candidate discovery after a network change possible without an ICE restart.
- [draft-uberti-behave-turn-rest-00 — TURN REST API ephemeral credentials](https://datatracker.ietf.org/doc/html/draft-uberti-behave-turn-rest-00) — username = colon-delimited expiry-timestamp:userid, password = base64(hmac(secret, username)); TTL of one day (86400 s) recommended; expiry does not affect existing allocations (tied to a 5-tuple) but new allocation requests fail after expiry, so ICE restarts require re-fetching credentials.
- [webrtcHacks — The Big Churn, callstats.io production statistics](https://webrtchacks.com/usage-stats/) — 12 months (Jan 2015–Feb 2016), billions of minutes, 100+ customers: 22% of sessions required TURN relay; 9% required TCP; 12% overall session failure rate with 85% of failures attributable to NAT/firewall traversal; 80% of sessions established within 5 s; 67% of failures occurred after 10 s of waiting.
- [Cloudflare Realtime TURN — Generate Credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/) — POST https://rtc.live.cloudflare.com/v1/turn/keys/$TURN_KEY_ID/credentials/generate-ice-servers with Bearer auth and body {"ttl": seconds} returns 201 with iceServers[{urls, username, credential}]; credentials can be revoked via POST .../credentials/$USERNAME/revoke (204); mid-session refresh uses RTCPeerConnection.setConfiguration().
- [Cloudflare Realtime TURN — FAQ (pricing and hard limits)](https://developers.cloudflare.com/realtime/turn/faq/) — $0.05/GB egress with a 1,000 GB free tier shared between SFU and TURN; RFC 6062 TCP relaying is NOT implemented and REQUESTED-TRANSPORT is ignored (TURN over TLS exists as a wrapper); no IPv6 relay addresses are issued; max credential TTL 48 hours; credential issuance starts at 500/sec; packet loss expected above 50–100 Mbps or 5–10 kpps per client; allocations are anycast-homed to the nearest data centre.
- [WhatsApp @Scale — Calling Relay Infrastructure at WhatsApp Scale](https://atscaleconference.com/calling-relay-infrastructure-at-whatsapp-scale/) — WhatsApp replaced TURN with WASP because "TURN… uses multiple ephemeral ports, doesn't work well with firewalls, and doesn't scale well with a distributed architecture"; WASP uses a single port and pushes connection-state tracking to the device to make relay failover work; relay selection applies targeting algorithms to historical latency data and can change mid-call on WiFi↔cellular switch; well over a billion calls a day.
- [Discord engineering — How Discord Handles 2.5M Concurrent Voice Users with WebRTC](https://discord.com/blog/how-discord-handles-two-and-half-million-concurrent-voice-users-using-webrtc) — Native clients drop ICE, DTLS, SRTP and most of SDP, exchanging ~1000 bytes of raw parameters over a second (voice) websocket and encrypting with Salsa20; NAT is handled by periodic pings to an always-server-side SFU; failover is client-initiated reconnect after the voice websocket severs; 850+ voice servers, 220+ Gbps, 120+ Mpps.
- [AOSP — Full-screen intent limits](https://source.android.com/docs/core/permissions/fsi-limits) — On Android 14 USE_FULL_SCREEN_INTENT is enabled by default at install; it is the Google Play Store — not the OS — that revokes it for apps without calling/alarm functionality. Third-party installers control the initial grant via PackageInstaller.SessionParams (PERMISSION_STATE_DEFAULT/DENIED/GRANTED). Runtime APIs: NotificationManager#canUseFullScreenIntent() and ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT.
- [Android 14 behavior changes (foreground service types, FSI, background activity launch)](https://developer.android.com/about/versions/14/behavior-changes-14) — Apps targeting API 34+ must declare a foregroundServiceType (phoneCall for VoIP); FSI limited to calling and alarm apps with a May 31, 2024 policy deadline; background activity launch from a PendingIntent requires setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED) and bindService requires BIND_ALLOW_ACTIVITY_STARTS.
- [Android 15 behavior changes (BOOT_COMPLETED FGS ban, SAW restriction, FGS timeouts)](https://developer.android.com/about/versions/15/behavior-changes-15) — BOOT_COMPLETED receivers cannot start phoneCall, microphone, camera, mediaPlayback, mediaProjection or dataSync foreground services (ForegroundServiceStartNotAllowedException); SYSTEM_ALERT_WINDOW now also requires a visible TYPE_APPLICATION_OVERLAY window to start an FGS from background; dataSync/mediaProcessing capped at 6 hours per 24 h with a mandatory Service.onTimeout(); audio focus requires top-app or an active FGS.
- [Android Core-Telecom — self-managed calling app guide](https://developer.android.com/develop/connectivity/telecom/selfManaged) — Requires MANAGE_OWN_CALLS; CallsManager.registerAppWithTelecom(capabilities) then addCall(attributes, onAnswer, onDisconnect, onSetActive, onSetInactive); you must post a notification within 5 seconds of adding the call, and each remote-surface callback must complete within a 5-second timeout or the call session may be torn down; use AudioManager.STREAM_VOICE_CALL and never setCommunicationDevice / startBluetoothSco.
- [Firebase — Set and manage Android message priority](https://firebase.google.com/docs/cloud-messaging/android/message-priority) — High priority wakes a dozing device and grants limited network access; App Standby Buckets impose a per-day cap on high-priority messages after which they are downgraded to normal priority (numbers unpublished); FCM may deprioritize an app whose high-priority messages do not produce user-visible notifications, assessed over a 7-day pattern.
- [Firebase blog — Understanding FCM message delivery / delivery rates](https://firebase.blog/posts/2024/07/understand-fcm-delivery-rates/) — Documented drop reasons include force-stopped applications ("retries were unsuccessful"), collapse-key collapsing, TTL expiry, and inactive devices; a device instance stores at most 100 non-collapsible pending messages and if the limit is reached all stored messages are discarded; pending messages are held 28 days.
- [dontkillmyapp.com — Huawei (PowerGenie) and Xiaomi (MIUI/HyperOS)](https://dontkillmyapp.com/xiaomi) — EMUI 9+ ships PowerGenie which kills everything not on a non-editable Huawei whitelist and exposes no user configuration; MIUI 14+ adds a per-app "Background autostart" permission that is separate from the Security-app Autostart toggle and both must be enabled, on top of Battery Manager "Performance" power plan and App battery saver "No restrictions".
- [Jitsi Meet — Setting up TURN (handbook) and config.js P2P settings](https://jitsi.github.io/handbook/docs/devops-guide/turn/) — Ephemeral REST-style TURN credentials are distributed over XMPP via XEP-0215 / mod_external_services; static turnserver.conf credentials are explicitly not recommended for production; TURN on TCP/TLS 443 is multiplexed with the web frontend by nginx on SNI; defaults are UDP 3478 and TCP/TLS 5349. config.js: p2p.enabled true for exactly 2 participants, backToP2PDelay 5 s, default STUN on port 443.
- [W3C WebRTC 1.0 — perfect negotiation and ICE restart](https://www.w3.org/TR/webrtc/) — The perfect negotiation pattern is §10.7; rollback (setLocalDescription({type:'rollback'})) returns a pending description to null and restores transceivers to their last stable state; RTCOfferOptions.iceRestart forces ICE credentials different from the current local description, and the spec recommends restarting when iceConnectionState transitions to failed.
- [draft-ietf-rmcat-gcc — Google Congestion Control](https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02) — Two cooperating controllers — a delay-based estimator driven by inter-arrival time deltas fed back through transport-wide congestion control (TWCC), and a loss-based estimator — with the lower of the two estimates governing the send rate.
- [Supabase — Realtime quotas (official limits page)](https://supabase.com/docs/guides/realtime/limits) — Free tier: 200 concurrent connections, 100 messages/second, 100 channel joins/second, 100 channels per connection, 256 KB max broadcast payload, 20 presence messages/second. Pro: 500 connections / 500 msgs-per-sec. An "event" is any WebSocket message delivered to or sent from a client, covering broadcast, presence and postgres_changes alike.
- [Supabase — Realtime Broadcast durability and replay](https://supabase.com/docs/guides/realtime/broadcast) — Messages sent from client libraries or the REST API are NOT persisted — they exist only as live WebSocket transmissions. Only Broadcast-from-Database messages land in realtime.messages, stored in daily partitions dropped after 72 hours, with Broadcast Replay limited to a maximum of 25 messages per request on private channels. An optional ack setting confirms server receipt; no at-least-once guarantee is documented.
