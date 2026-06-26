# BRAIN.md — Tethered engineering brain

Living notes for the realtime subsystems. Companion to `TETHERED_FULL_DOCUMENTATION.md`
(full reference). This file tracks the *moving parts*, the *open issues*, the
*gotchas*, and a dated *work log*.

---

## 1. Subsystem map (overview)

| Subsystem | Transport | Key files |
|---|---|---|
| Chat messages | postgres_changes (`messages:<coupleId>`) + ephemeral broadcast `'msg'` on `mood_burst:<coupleId>` + optimistic local | `lib/features/chat/chat_screen.dart`, `chat_repository.dart` |
| Presence (online / typing / read / mood) | postgres_changes (`presence:<coupleId>`) + broadcast `'typing'` on the chat mood channel | `lib/core/services/presence_service.dart` |
| Partner profile (avatar/name) | postgres_changes (`profile-sync:<coupleId>`) | `lib/core/session_provider.dart`, `lib/core/supabase_repository.dart` |
| Socket re-arm | `realtime.onOpen` → `realtimeResumed` fan-out; resume forces disconnect→connect | `lib/core/realtime_resume.dart`, `lib/features/shell/app_shell.dart`, `lib/main.dart` |
| Generic couple channels | `RealtimeService.coupleTable` / `.broadcast` | `lib/core/realtime_service.dart` |

---

## 2. Chat / Realtime / Presence subsystem map (detailed)

### Message delivery (three paths, deduped by client UUID)
1. **Optimistic** — `_sendTextFast` / `_sendImageFast` insert a local `Message`
   (client `Uuid().v4()`, `createdAt = DateTime.now()`) via `_onIncoming` → instant.
2. **Broadcast fast-path** — same payload sent on `mood_burst:<coupleId>` event
   `'msg'` carrying `createdAt = now.toUtc().toIso8601String()`. Receiver
   `_onMsgBroadcast` parses it `.toLocal()` (sender's true instant) → instant on
   the partner side.
3. **DB persist + postgres echo** — `ChatRepository.sendText/sendImage` insert with
   the SAME id. `messages:<coupleId>` postgres_changes delivers the authoritative
   row → `_onIncoming(fromDb:true)`.

`_onIncoming` dedups by `_ids`; on a **DB echo for an already-shown id** it calls
`Message.reconcileWith(server)` (adopts the **server `created_at`** + paths, flips
`sendStatus → sent`) then `_sortMessages()` — this is what makes cross-device
order converge to server time.

### Channels (CRITICAL semantics — see Gotchas)
- `client.channel(topic)` **never dedupes** — it always `channels.add(chan)`.
- `RealtimeChannel.unsubscribe()` only sends an async *leave*; the channel stays
  registered until the leave acks (then the close event removes it).
- ⇒ `unsubscribe()` + immediate re-`channel(sameTopic)` = **two channels, one
  topic** → the second join is rejected → **joined-but-dead**.
- **Rule:** to re-subscribe a topic, `await client.removeChannel(old)` FIRST,
  then create + subscribe. One re-entrancy-guarded `_subscribe()` per screen.

### Presence freshness (liveness TTL)
- Every presence write (`PresenceService._upsert`) stamps `updated_at = now (UTC)`.
- The chat refreshes `chat_last_read` (→ `updated_at`) every 5s while open.
- `Presence.isFresh` = `updated_at` within **30s**. `onlineNow = isOnline && isFresh`.
- A force-killed app never writes `is_online=false`; the TTL makes it read offline
  within ~30s anyway. `_statusFor` returns "sent" unless the row `isFresh`.
- `isInChatNow` = `chat_last_read` within 18s (drives the "is here" avatar).

---

## 3. Issues

### ISSUE-001 — Chat doesn't render live (must leave & return) — **RESOLVED 2026-06-26**
Root cause: duplicate-topic dead channels from `unsubscribe()`+re-`channel()` on
every `realtimeResumed` / resume. Fix: idempotent guarded `_subscribe()` using
awaited `removeChannel`. See Work Log 2026-06-26.

### ISSUE-002 — False "seen"/"delivered"/"is here" when partner is offline — **RESOLVED 2026-06-26**
Root cause: no presence liveness TTL (`is_online` stuck true on kill) + the
partner-presence channel was itself a duplicate-topic dead channel (so the
`is_online=false` on `paused` never arrived) + clock-skew on the "seen" compare.
Fix: `Presence.isFresh`/`onlineNow` 30s TTL, `_statusFor` gated on freshness,
and the presence channel re-subscribe uses `removeChannel`.

### ISSUE-003 — Simultaneous messages render out of order — **RESOLVED 2026-06-26**
Root cause: downstream of ISSUE-001 — the DB echo never arrived, so the
optimistic/broadcast copies (sender-clock timestamps) never reconciled to server
`created_at`. Fix: ISSUE-001 restores delivery; `reconcileWith` + `_sortMessages`
on every echo were already correct.

### ISSUE-004 — Presence liveness/TTL missing (false online app-wide) — **PARTIALLY RESOLVED 2026-06-27**
The chat-only ISSUE-002 root cause generalised: `is_online` had no liveness TTL,
so a killed app read online forever on Home, drawer, everywhere. Fix (Phase 1):
freshness-derived `Presence.isOnline`, 20s foreground heartbeat, 15s provider
refetch so the TTL ticks. Reads on Home/chat now honest. Mark RESOLVED once
verified on 2 devices.

### ISSUE-005 — Realtime subscription health app-wide (R1) — **IN PROGRESS 2026-06-27**
The chat-only ISSUE-001 duplicate-topic bug was copied across ~15 features
(unsubscribe+re-channel, or no `realtimeResumed` re-arm at all) → live updates
die after doze until you leave & re-enter. Fix: `ManagedSubscription` primitive +
migrate every touchpoint. Core infra done (Phase 2a); feature screens Phase 2b.

### ISSUE-006 — Timestamp/UTC + ordering (R3) — **RESOLVED (mostly N/A) 2026-06-27**
Investigated the 19 flagged `fromJson` zone inconsistencies: benign. Dart
`compareTo`/`difference` are absolute-instant, so `.toLocal()`/`.toUtc()` tags
don't change sorts or now-comparisons; chat already reconciles to server time.
Wall-clock/date-only logic (cycle predictions) is intentionally local. No code
change; documented in §3b so it isn't "re-fixed" harmfully later.

---

## 3b. Canonical realtime / presence / timestamp patterns (A / B / C)

These are the rules every realtime/presence touchpoint must follow. Established
during the 2026-06-27 app-wide hardening pass.

**Pattern A — realtime subscription lifecycle.** Supabase `channel(topic)` never
dedupes and `unsubscribe()` only schedules an async leave, so `unsubscribe()` +
immediate re-`channel(sameTopic)` leaves duplicate-topic *joined-but-dead*
channels (the app-wide "stops updating until you leave & re-enter" bug). Rules:
subscribe once + keep the ref; re-subscribe on `realtimeResumed` by **awaiting
`removeChannel(old)` before re-creating** (re-entrancy guarded); broadcast SENDS
only after subscribe; receive callback updates state via setState/StateNotifier;
dispose = removeListener + `removeChannel`. **Use `ManagedSubscription`**
(`core/realtime_service.dart`) which bakes all of this into one primitive —
`_sub = ManagedSubscription.start(() => client.channel(..).on...().subscribe());`
send via `_sub.channel?.sendBroadcastMessage(..)`; `_sub.dispose()`.

**Pattern B — presence liveness.** `is_online` is advisory only (a killed app
never writes it false). Truth = freshness window over a heartbeat-updated
timestamp. `Presence.isOnline = isOnlineFlag && isFresh` (updated_at < 45s);
`isInChatNow` = chat_last_read < 18s; receipts gate on `isFresh`. Foreground
heartbeat (main.dart) re-stamps every 20s; the shared `partnerPresenceProvider`
refetches every 15s so the TTL ticks in the UI. Readers use the derived getters —
**never `isOnlineFlag`**. Partner state comes only from the partner row
(`.neq('user_id', myUid)`), never the local user's own payload.

**Pattern C — timestamp/UTC + ordering.** NOTE: Dart `DateTime.compareTo` /
`.difference` operate on the absolute instant, so `.toLocal()` vs `.toUtc()` is a
**cosmetic tag difference that does NOT affect sorts or now-comparisons**. Sorts
already converge via `reconcileWith` to the server `created_at` + an id
tiebreaker. The ONLY real risk is **wall-clock math** (`.year/.month/.day`,
`DateUtils.dateOnly`) — and there the local zone is usually *intended* (a cycle
predictor wants the user's local "today"; forcing UTC would shift the date a day
and is a BUG). So Pattern C is mostly "leave it alone, with rationale"; the model
`fromJson` `.toLocal()`/`.toUtc()` inconsistencies the audit flagged are benign.

## 3c. Audit register (2026-06-27 — 70 touchpoints)

23 high · 14 med · 12 low · 21 clean. Pattern A subscription-health is the real
issue (most "Pattern C" rows are benign per 3b). Status after this pass:

| Feature | Channel | Pattern A issue | Status |
|---|---|---|---|
| session_provider | profile-sync | unsubscribe+re-channel | ✅ Phase 2a |
| call_controller | call: | unsubscribe + no clean re-arm | ✅ Phase 2a |
| app_shell (reach) | reach: | unsubscribe+re-channel | ✅ Phase 2a |
| realtime_service.coupleStream | * | unsubscribe on cancel | ✅ Phase 2a |
| chat_screen | messages/mood_burst | (fixed earlier) | ✅ ISSUE-001 |
| presence_service | presence: | (fixed earlier) | ✅ ISSUE-002 |
| home / chat / drawer presence reads | — | raw is_online | ✅ Phase 1 (derived getter) |
| care, reasons, cycle-card, breath, desire_temp | postgres | no re-arm / unsubscribe | Phase 2b → ManagedSubscription |
| touch_map, heartbeat, watch, together, mood_lamp | broadcast | no re-arm / unsubscribe | Phase 2b → ManagedSubscription |
| games: gchat, gcard, truth_dare | broadcast | unsubscribe + Timer race | Phase 2b → ManagedSubscription |
| capsule_list, capsule_detail | postgres | no re-arm | Phase 2b → ManagedSubscription |
| reach_screen (reach_pulses) | reach: | no re-arm | SKIP — legacy/dead path |
| proximity_service | capsule_proximity: | no re-arm (manual start) | deferred (low) |
| Pattern C model fromJson (Couple, Profile, Message, etc.) | — | .toLocal vs .toUtc | benign (see 3b) — no change |

---

## 4. Gotchas

- **`client.channel(topic)` never dedupes; `unsubscribe()` is async-leave only.**
  Always `await removeChannel(old)` before re-subscribing the same topic. Use one
  guarded `_subscribe()`; never `unsubscribe()` + immediate re-`channel()`.
- **Build only from `E:\LDR\mobile`** (`flutter build apk --release`). Running from
  `E:\LDR` → *"No pubspec.yaml."* Realtime fixes need BOTH phones on the new build.
- **Timestamps are absolute instants** — `DateTime.compareTo` is zone-independent,
  so mixed `.toLocal()`/`.toUtc()` sort correctly. Don't trust a *partner-device*
  timestamp for liveness — gate on freshness, not just the raw value.
- **`messages` + `presence`** are in the `supabase_realtime` publication with
  REPLICA IDENTITY FULL (verified). If live render breaks, it's a **client channel
  health** problem, not a DB/publication one.
- Presence writes are best-effort (`_upsert` swallows errors) — never surface to UI.
- `kRtChatDebug` (in `chat_repository.dart`) logs channel join status + incoming
  messages. Compile-time const `false` ⇒ dead-code-eliminated in release.

---

## 5. Work Log

> Template: `### YYYY-MM-DD — <title>` · **Files** · **Root cause(s)** · **Fix** ·
> **Verified** · **Regression risk**

### 2026-06-26 — Chat realtime: live render + honest receipts + correct order (ISSUE-001/002/003)
**Files changed**
- `lib/features/chat/chat_screen.dart` — unified `_resubscribe`+inline-subscribe into
  one guarded async `_subscribe()` (awaited `removeChannel` before re-create);
  `_init`/`realtimeResumed`/dispose route through it; `dispose` uses `removeChannel`;
  lifecycle-resume now only refreshes presence; `_statusFor` gated on `p.isFresh`;
  guarded incoming-message log.
- `lib/core/services/presence_service.dart` — `Presence.updatedAt` + `isFresh`(30s)
  + `onlineNow`; `PartnerPresenceNotifier._subscribe` rewritten with guard + awaited
  `removeChannel`; dispose uses `removeChannel`.
- `lib/features/chat/chat_repository.dart` — `subscribe()` now passes a join-status
  callback (logged behind `kRtChatDebug`); added the const flag.

**Root causes**
1. Supabase `channel()` never dedupes + `unsubscribe()` is async-leave-only ⇒
   re-subscribe created duplicate-topic, joined-but-dead channels ⇒ no live
   delivery (ISSUE-001) ⇒ no DB-echo reconcile ⇒ wrong order (ISSUE-003) ⇒ stale
   partner presence (ISSUE-002).
2. No presence liveness TTL ⇒ killed app stuck "online"; clock-skew faked "seen"
   (ISSUE-002).

**Verified**
- `flutter analyze` = 0 errors; release build OK.
- 2-device checklist below to be run on the same fresh build (NOT yet run on real
  hardware in this session — no devices were connected).

**Regression risk**
- Low. Optimistic send path untouched (still inserts locally first). RLS/couple
  scoping untouched. The awaited `removeChannel` on reconnect adds a brief (<~1s,
  socket-healthy) re-join window — only on a real reconnect, not steady state.
- Watch: if a reconnect's leave-ack is slow on a flaky socket, the re-subscribe is
  delayed (bounded by the client's leave timeout). Acceptable; steady-state
  delivery is unaffected (channels stay joined, no thrash).

**2-device acceptance checklist** (both phones, same fresh release build)
- [ ] D1: A sends → appears on B within ~1s, no navigation; repeat 5×; then
      background each phone 3 min, resume, repeat — still live.
- [ ] D2: force-close B (swipe). A's just-sent message = single "sent" tick, NO
      "seen", NO "is here". Open B in the chat → A flips to delivered/seen + "is
      here"; close B → clears within ~30s ("is here" within ~18s).
- [ ] D3: rapid back-and-forth from both → correct chronological order on BOTH,
      and stays correct after a second (no reshuffle when the DB echoes land).
- [ ] No regression: optimistic send instant; typing dots; mood/GIF flings;
      reply/slide-to-reply; delete-for-me / delete-for-everyone.
- [ ] (Optional) set `kRtChatDebug=true`, watch `adb logcat | grep '\[rt\]'` —
      expect `join=RealtimeSubscribeStatus.subscribed` and `incoming … fromDb=true`
      when the partner sends.
