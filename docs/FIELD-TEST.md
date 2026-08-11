# Field test — reading the trace

Calls, receipts and presence have each been "fixed" several times and are each still reported broken.
Every diagnosis so far was made from one side of a two-sided failure, using `debugPrint`, which reaches
logcat, which reaches whichever of the two phones has a cable in it. One theory survived two months of
that and was disproved in a single terminal session.

This document exists so the next test ends in an answer instead of another round.

---

## 1. Before the test

Both phones need the new build. A trace from one side proves almost nothing — the whole point is the
join between the two.

- Install on **both** phones, and open the app on both at least once so the session binds.
- Settings → Diagnostics → **Record diagnostics** must be on. It is on by default.
- Both phones should be on **mobile data, not the same wifi**. Two phones on one wifi pair on host
  candidates and every call succeeds, which is exactly why this looked fine for months.

## 2. The three tests

Do them in this order and leave roughly a minute between them, so the traces do not interleave.

| # | Test | What to do |
|---|------|-----------|
| 1 | **Call** | A calls B, let it ring. If it connects, talk for 30s then hang up. If it does not, let it fail on its own — **do not cancel**, the 35s timeout row carries the full candidate census. |
| 2 | **Call, app closed** | Force-close the app on B. A calls B. This tests the FCM ring, which is a completely separate path from the first test. |
| 3 | **Receipts** | B closes the chat entirely. A sends a message. Wait 30s, check A's ticks. Then B opens the chat. Check A's ticks again. |
| 4 | **Presence** | B backgrounds the app for two minutes, then reopens it and moves between two screens. A watches the status the whole time. |

Nothing needs to be collected by hand. The trace uploads on its own.

## 3. If the upload did not work

That is itself a result, and the trace is still on the phone. Settings → Diagnostics → **Copy everything
on disk**, and paste it. The disk copy survives the app being killed, which the server copy does not
always do.

## 4. Reading it

Both devices write to `diag_events`. Join the two sides on `corr`, order by `at`.

```sql
select at, user_id, area, name, corr, fields
from diag_events
where corr = '<the call id>'
order by seq;
```

`at` is each device's clock already corrected by its learned server offset, so the two timelines line up.
`received_at` is Postgres' own `now()` and is the independent check: when the two disagree badly, the
clock correction is itself the bug.

---

## 5. What the patterns mean

This is the point of the exercise. Each row is a pattern that was **indistinguishable** from the others
before this trace existed.

### Calls

| Trace pattern | Cause |
|---|---|
| `init` with `has_couple:false` | The couple had not resolved yet. Harmless on its own now — the binding is driven by the session, so a later `init` with `action:bind` must follow. If none does, calling is dead for the process. |
| `init` with `rebind:true` | A different account (or the partner) signed in on this handset. Every row before it belongs to the previous couple. |
| `signal_subscribe` with `topic` naming a couple that is **not** the one in `init` | The controller is signing on a couple it no longer belongs to. The private-channel policy on `realtime.messages` denies it, so nothing moves in either direction — and `invite_failed` will carry `pg_code:42501` for the same reason. |
| `signal_subscribe` with `status` other than `subscribed` | The signalling channel is not receiving. Nothing will move regardless of TURN. `attempt` counts the retries; if it climbs and never reaches `subscribed`, the topic is being refused, not merely flaky. |
| `call_no_channel` / `accept_no_channel` | The call was refused before it started because signalling was not live within 5s. The user was told. Nothing after this is a WebRTC problem. |
| `relay_wait` with `cold:true, relay:false` | A device with nothing cached spent its whole budget and still has no relay — this call cannot use TURN at all, because `iceServers` are read once at `pc_created`. Check `turn_fetch` in the same window. |
| `signal_dropped_no_channel` | The signal was discarded before it reached the wire. Look at what `rt_resubscribe` was doing at the same instant. |
| `signal_sent` on A, **no** `signal_received` on B | Sent and not delivered — realtime fan-out, not WebRTC. |
| No `signal_received` **and** no `invite_inserted` | B was never told at all, by either path. |
| `invite_failed` | The durable offer never landed, so a closed phone cannot ring. `pg_code:42501` with a `couple` that is not the signed-in user's couple is a stale binding; `42501` with the right couple is a policy problem. |
| `offer_dropped_busy` | B's state machine was stuck non-idle. B is silently unreachable and looks healthy. |
| `connect_timeout` with all `remote_*` at 0 | Their candidates never arrived. Signalling, not TURN. |
| `connect_timeout` with `local_relay:0` | TURN never allocated on this side. Check `turn_fetch` and `pc_created.relay_servers`. |
| `pc_created` with `relay_servers:0` but `turn_error:true` | The credentials arrived **after** the peer connection was built. `setConfiguration` is never called, so they cannot join this call. |
| `connect_timeout` with relays on both sides | The media path itself is blocked. This is the only pattern that is genuinely the network. |
| `answer_failed` | The answer never applied, so every remote candidate queues forever. Presents as candidates that never arrived. |
| `accept_failed` | B tried to answer and could not. From A's side this is identical to being ignored. |

### Receipts

| Trace pattern | Cause |
|---|---|
| `msg_insert_result` with no `server_seq` | The message has no watermark position and can never be acked. |
| `msg_received` with `from_db:false, seq:0` and no later `msg_seq_bound` | Arrived by broadcast, never re-read from the database, stuck at seq 0 forever. |
| `push_msg_received` with no `receipt_ack_attempt` after it | The device **had** the message and had no path to ack it. |
| `receipt_ack_attempt` only ever with `trigger:chat_open` | Delivery is only acked when the chat is open, so a tick cannot advance until the recipient opens it. |
| `receipt_ack_attempt` with `ok:false` | The RPC threw. The error class says whether it was RLS or a missing row. |
| Ack succeeded on B, no `partner_receipt_observed` on A | The write landed and the sender was never told — check `rt_channel_join`. |
| `partner_receipt_observed` advanced but no `tick_rendered` change | The data arrived and the UI did not repaint. |

### Presence

Joined on `corr = hb:<app_last_active_at>`, the server-stamped instant, which is identical on both phones
with no clock reconciliation.

> **Filter the writer's rows to `is_app_activity:true` before building the matrix.** A location-only
> write deliberately does not stamp `app_last_active_at`, so it echoes back the row's **existing** value
> and emits `presence_write` under an older `hb:T` — as does the realtime event it triggers on the
> partner. Counted naively, a GPS ping looks like a heartbeat that arrived twice.

| Trace pattern | Cause |
|---|---|
| `presence_write` on B, **nothing** on A for that `corr` | The write never landed, or RLS hides the row from A. |
| `presence_partner_read` at `hb:T` but no `rt_change` at `hb:T` | The row **is** in the database. Only realtime delivery is broken. |
| Neither | The write never reached the server. Check `presence_write.outcome`. |
| `rt_subscribe` with `status` other than `subscribed` | The subscription failed; the 15s poll limps on and the partner reads as permanently offline. |
| `presence_screen_publish` with `has_couple:false, wrote_db:false`, then `deduped:true` | The screen was published while the couple was null, so it wrote nothing and was then deduped forever. |
| `presence_clock_sync` never `accepted` | The offset is unknown, so freshness is computed against the raw device clock — indistinguishable from "partner is offline". |
| `presence_partner_read` with `rows_len > 1` | A stray presence row for the couple. The wrong row can win, because ordering is by `updated_at` which GPS pings also bump. |
| `presence_heartbeat` with `action:skip_no_couple` | The beat wrote nothing and said nothing. |

---

## 6. What is not covered

- A **force-stopped** app receives nothing at all, by Android design. Test 2 uses force-close
  deliberately, so a silent result there is expected rather than a bug.
- The trace shows what the client observed. It cannot see a push that Firebase dropped before delivery.
- Diagnostics carry **no content** — no message text, no media, no coordinates, no names. That is
  enforced by the redactor and by a test over the call sites. It also means the trace can say a message
  arrived and cannot say which one, beyond its id and seq.
- Rows are deleted after 7 days.
