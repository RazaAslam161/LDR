# Miles — Architecture for Scale

Written overnight, 2026-08-10. Grounded in **215 cited primary sources**, a **91-module inventory**
with per-module scale risk, **8 domain architectures**, and an adversarial review that **broke all 8**
before they were revised.

Status of this document: **6 of 8 domains revised and hardened** (transport, messaging, calling,
presence, push, crypto). **2 domains — data/ops and client — have a v1 design and a list of fatal
flaws, but no revision yet**; the session hit its usage limit. Those two are marked ⚠ throughout.

---

## 1. Executive summary

**One sentence explains most of the two-month failure:**

> The app treats the realtime socket as the delivery mechanism and the database as incidental
> bookkeeping, when it must be the reverse — the durable log is the truth and the socket is only a
> doorbell.

Every headline symptom is the same mistake wearing different clothes:

- A message is "delivered" if a broadcast fired — so a socket that was down means the message is gone.
- A receipt is "seen" if two device clocks agree — so a wrong clock means a permanently grey tick.
- A partner is "online" if a timestamp they wrote looks recent to *your* phone — so skew makes
  presence one-directional, which is exactly the asymmetry reported.
- A call rings if a broadcast lands in the same instant it is sent — so a phone in a pocket never rings.

None of these are bugs to fix. They are the same missing invariant: **state was inferred from a
transport event that may never arrive.** Point-fixes cannot hold, because each one repairs a symptom
while leaving the inference in place. That is why fixing one broke another, repeatedly.

The second structural problem is operational: **the database cannot be reproduced from the repo.**
Tables, columns, buckets and deployed functions exist that no file creates. So there is no staging, no
reviewable change, no rollback, and no way to know whether a fix is live. This gates everything else.

---

## 2. The foundations

Five mechanisms. Each eliminates a *class* of bug permanently, and together they subsume most of the
91-module risk list.

### F1 — A per-couple commit-ordered position, allocated under a row lock
**Kills:** lost messages, phantom gaps, stuck receipts, duplicate delivery.

`messages.seq` today is one **global** Postgres sequence. Two consequences, both fatal and both
invisible on two test phones: per-couple gap arithmetic is impossible, and a sequence value is
allocated at INSERT but becomes visible at COMMIT — so 105 can appear before 104 exists, and a
`WHERE seq > cursor` reader loses 104 **permanently**.

The fix is not a bigger cursor. It is that a position is allocated only while holding an exclusive lock
on that couple's stream row, so **position order is commit order by construction**, and the reader can
never observe a hole that will later fill in. This is Synapse's rule ("a cursor must never be published
past an uncommitted write") and Telegram's `pts`.

### F2 — The cursor advances only to a position read from the database
**Kills:** forged, duplicated, replayed, reordered or mangled realtime events.

A `pos` arriving on a socket is *never stored anywhere* — not in the cursor, not in a "highest seen"
variable. The doorbell is one bit: *go read*. This makes the entire transport untrusted by
construction, so a malicious broadcast costs one wasted query instead of silent divergence.

### F3 — Watermarks advanced server-side with `greatest()`, never client integers
**Kills:** receipts moving backwards, un-reading read messages, clock-dependent state.

`delivered` and `read` are separate monotone watermarks with separate owners. No device clock appears
in any comparison, in either direction. A late, replayed or malicious ack cannot move a watermark
back, because the server takes the max.

### F4 — An outbox with a worker, decoupled from the write path
**Kills:** invisible push failures, write-path latency, the entire fatal cluster.

Today every user-visible event runs `trigger → pg_net → edge function cold start → RSA-signed OAuth
exchange → FCM`, per event, synchronously coupled to the insert, fire-and-forget so failures vanish.
That single shape accounts for **4 of the 8 fatal findings**. Replace with: the obligation commits with
the domain row; a worker claims it under a lease; state transitions are observable; retries and
dead-letters exist.

**This is free.** FCM has no per-message cost at any scale in this document. It was a design problem,
never a budget problem.

### F5 — Presence as socket membership, not as a row
**Kills:** presence asymmetry, the hottest table in the system, stuck-online after a kill.

Online is *set membership in a live authorized socket*, not a value any client writes. Durable storage
holds only a monotone, server-stamped `last_confirmed_at`. The table physically cannot express
"online", so it cannot contradict reality. Presence writes drop from ~18/user/minute to a bounded
anchor.

---

## 3. The ordered roadmap

Ordered by: what unblocks everything else → what is silently losing data today → what breaks first as
users arrive.

### Stage 0 — Make the database reproducible ⚠ *(prerequisite for everything)*
Adopt `supabase/migrations` + `config.toml` as the single source of truth; commit the source of every
deployed edge function; add a CI check that the repo reproduces the database. Today several columns the
client writes exist in no SQL file, and the deployed `reach-notify` may not match the repo.

**Why first:** every other stage needs staging, review and rollback. Without this, no fix is verifiable
and no failure is diagnosable.
**Verify:** `supabase db diff` against a fresh project is empty.

### Stage 1 — Instrument before optimising
Add measurement for: peak concurrent connections, realtime messages/day, push delivery outcomes, and
frame timings. Every scale number in this document rests on an **assumed 8% peak concurrency** which is
a rule of thumb, not a measurement — and for a couples app, where both partners are active in the same
evening window, the real figure could be 2×.

**Verify:** the dashboards exist and disagree with, or confirm, the assumption.

### Stage 2 — F1 + F2: the per-couple stream and the untrusted doorbell
The foundation for messaging, receipts and eventually calls.
**Verify:** a SQL-level test that concurrently inserts from two sessions and asserts no reader can
observe a gap; a test that a forged doorbell cannot advance a cursor.

### Stage 3 — F3: receipts on server-side watermarks
Depends on Stage 2. Removes clocks from the state machine entirely.
**Verify:** unit tests with a simulated 120-second-wrong clock — the failure mode that cannot be
reproduced on two synced phones.

### Stage 4 — F4: the push outbox
Depends on Stage 0 (migrations) only. Closes 4 fatal findings.
**Verify:** kill FCM credentials deliberately; the outbox must show `failed` rows with reasons rather
than silence.

### Stage 5 — F5: presence rebuild
Independent of 2–4; can run in parallel.
**Verify:** force-quit a client and assert the observer flips to offline within the stated 47–72 s;
assert the durable row cannot express "online".

### Stage 6 — Calling
Depends on Stage 2 (durable signalling) and Stage 4 (reliable ring). Do **not** attempt before them —
that ordering is why calling has failed repeatedly.
**Verify:** a signalling log replay test; a forced-relay test with `iceTransportPolicy: relay` to
simulate symmetric NAT **without a second network**.

### Stage 7 — Crypto epochs and recovery
Independent. Closes the "reinstall destroys everything" cliff.

### Stage 8 — Client architecture ⚠ *(local-first, outbox, no dead ends)*
Design not yet revised.

---

## 4. Cost at scale

| Users | Supabase | TURN | Notes on what breaks first |
|---|---|---|---|
| 100 | Free ($0) | $0 (1 TB free) | Nothing. Current design survives here — which is why it looks fine |
| 1,000 | Pro $25 + small overage | ~$0 | `postgres_changes` throughput; presence write rate |
| 10,000 | **$500–560/mo** | tens of $ | Realtime message volume; peak connection packages |
| 100,000 | **$5,000–6,500/mo** | hundreds of $ | **Not supported on Supabase Realtime** — messaging ceiling is ~50k |

**FCM is free at every tier.** Cloudflare TURN is $0.05/GB after 1 TB free; relayed video at the
1 Mbps cap is ~15 MB/min plus ~20% overhead.

---

## 5. Decisions only you can make

### D1 — Encryption: recoverability vs zero-knowledge
Today a reinstall destroys the couple's entire Closer history, for both people, permanently.
**Recommendation: recoverable.** Add a user-held recovery credential (WhatsApp's 64-digit key model)
plus partner-assisted recovery. Your users are couples, not activists; silent total loss on a dropped
phone is a worse betrayal than a recovery path they opt into.

### D2 — When to move to Supabase Pro
**Recommendation: before public launch, not after.** Free tier's ~200 concurrent connections is roughly
**2,500 registered users** at 8% concurrency. The failure mode is not graceful — Supabase suspends
Realtime for the tenant and it needs a support ticket.

### D3 — The launcher disguise vs reliable ringing ⚠ **the hard one**
The most reliable Android ringing is Telecom/`ConnectionService`, which surfaces a system call UI
naming the app — directly undoing the disguise. And Android 14 withholds `USE_FULL_SCREEN_INTENT` by
default from apps that are not classified as calling apps.

**The honest position: you cannot have both at full strength.** Recommendation: keep the disguise, use
high-priority data FCM plus a foreground service, and accept a lower ring reliability — but **tell the
user during onboarding** that calls need an autostart exemption on their phone, and walk them to that
screen once.

### D4 — Accept the calling ceiling
**Calling's binding constraint is a handset, not a user count.** On force-stopped apps, `FLAG_STOPPED`
means nothing in your app runs — no receiver, no isolate, nothing — until the user opens it manually.
All three of your target devices score 3–5/5 on dontkillmyapp severity. **This is a platform contract,
not a bug, and no architecture fixes it.** The only lever is guiding users to grant the exemption.

---

## 6. What this does not fix

Stated plainly, because "it's fixed" has been said too often here.

1. **Force-stopped phones will not ring.** No engineering answer exists.
2. **Messaging is supported to ~50k users, not 100k.** The original 100k claim was ~2× optimistic on
   billing arithmetic; the correction is accepted rather than argued away.
3. **Hard-kill offline latency is 47–72 s** and is not controllable — Phoenix's 60 s socket timeout
   plus a flap guard.
4. **Outbound realtime rate cannot be server-enforced.** The SDK's client-side limit is deprecated and
   ignored; Supabase's limits are project-wide.
5. **Durable last-seen is ±5 minutes** when the observer was disconnected at the moment of departure.
6. **A malicious server can withhold key wraps.** Mitigated, not eliminated.
7. **Fantasy-jar tag matching leaks your full tag set to your partner** — overlap requires a shared
   key; anything less needs Private Set Intersection.
8. **⚠ Data/ops and client architecture are not yet revised.** Their v1 designs exist with 8 known
   fatal flaws between them.
9. **Elsa's presence bug was never root-caused.** Two full audits refuted every candidate. The presence
   rebuild (F5) removes the whole class it belongs to, but I cannot claim it fixes the specific report.

---

## 7. Where the detail lives

```
docs/architecture/
  ROADMAP.md              ← this file
  research/*.md           215 cited sources across 7 topics
  inventory/*.md          91 modules, per-module scale risk
  design/*.md             v1 designs + _attacks.json (31 fatal flaws)
  revised/*.md            6 hardened designs with invariants and accepted limits
```

Each revised design is self-contained: current state, target architecture, invariants (each stating
what enforces it), scale ceiling, cost, staged migration, verification without two phones, and an
explicit accepted-limits section.
