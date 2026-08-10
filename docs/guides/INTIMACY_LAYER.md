# Miles — Intimacy Layer ("Closer") Spec

> **Pitch:** An opt-in, end-to-end encrypted module for adult couples to deepen intimacy across distance.
> **Status:** Draft v0.1 — 2026-06-24
> **Compliance owner:** Founder (you) — read this whole section before shipping.

---

## 1. Play Store Compliance (read this first)

Google Play's **Sexual Content and Profanity policy** prohibits:
- Pornography and sexually explicit media
- Sexual services / escort content
- Content that sexualizes minors (handled by the 18+ gate, §3)

It **does NOT** prohibit:
- Apps about relationships, romance, intimacy, or communication between consenting adults
- Educational or connection-oriented intimacy tools
- Artistic / abstract representations of the body

**How every feature below stays compliant:**
1. **No explicit media.** Photos in Private Vault are user-uploaded and stored E2EE on-device — Miles never displays them on Google's servers, never markets them, and the Play Store listing shows zero nudity.
2. **The Play Store listing itself is SFW.** Screenshots, description, and icon contain no sexual content. Closer is described as "private connection tools for couples."
3. **18+ age gate** at signup + DB-enforced (see §3).
4. **Body Map uses an abstract silhouette**, never a photo. It's an artistic diagram, not pornography.
5. **Touch Trace / Mood Lamp / Desire Temperature** carry no media at all — they are abstract gestures, colors, and numbers.
6. **Revenge-porn mitigation:** Private Vault content is E2EE and cannot be exported by the developer. The breakup purge (§5.4) ensures no data lingers after dissolution.

> **If challenged by Google:** the defense is "Miles is a relationship communication app for adults; the Closer module is encrypted private messaging with custom affordances. We do not host or transmit sexual content."

---

## 2. Consent & Permission Framework

A reusable **dual-consent gate** underpins every feature in this module. Both partners must independently opt in; either can revoke.

### Schema

```sql
create table public.consent_state (
  couple_id    uuid not null references public.couples(id) on delete cascade,
  feature      text not null,           -- 'touch_trace' | 'fantasy_jar' | etc.
  user_id      uuid not null references public.profiles(id) on delete cascade,
  granted      boolean not null default false,
  granted_at   timestamptz,
  revoked_at   timestamptz,
  primary key (couple_id, feature, user_id)
);
```

### Rules
- A feature is **active for a couple** only when **both** rows exist with `granted = true`.
- Revoking by either partner instantly deactivates the feature for both — UI surfaces a soft "your partner paused this" notice.
- Re-granting requires both to opt in again (no asymmetric reactivation).
- Modest Mode (`couples.modest_mode = true`) is a **super-switch** that overrides all features to off, regardless of consent rows.

---

## 3. Age Verification

- **At signup:** DOB picker (date only) on the welcome page. Hard-block under 18.
- **Stored:** `profiles.birth_date` (date column).
- **DB-enforced:** `profiles_must_be_adult` CHECK constraint — even a malicious client cannot set a DOB under 18. See `supabase/intimacy_additions.sql`.
- **Listing-level:** Google Play also supports a content rating; we declare "Teen → Mature" appropriately and rely on the in-app gate.
- **Periodic re-check (v1.1):** when profile reloads, if `birth_date` is null or under 18, force re-onboarding.

---

## 4. Modest Mode

- **Where:** Settings → Privacy → "Closer (intimacy module)"
- **Default:** ON (intimacy module hidden). Couples must consciously opt in.
- **Scope:** couple-wide — flipping it affects both partners. Either can flip; we don't require dual consent for *hiding* (modesty is the safe default).
- **Revealing requires a confirm dialog** explaining what's being enabled.
- **When ON:** the Closer tab still appears in the bottom nav, but routes to a "this space is hidden by Modest Mode" screen with a single CTA to Settings.
- **When OFF:** all 9 features are visible in the Closer screen's feature grid.

---

## 5. Privacy & Security (E2EE)

### 5.1 Cryptographic approach (Private Vault + Memory Threads)
- **Library:** `cryptography` (Flutter) wrapping libsodium.
- **Key exchange:** X25519 — each partner has a long-term keypair generated on-device at first Closer enable. Public keys exchanged via a `partner_keys` table (public keys only; safe to store in plaintext).
- **Symmetric:** XChaCha20-Poly1305 with a couple-derived shared key = `X25519(my_private, their_public)`.
- **Per-item:** a random 24-byte nonce per ciphertext. Associated Data = item UUID (binds ciphertext to metadata).
- **KDF:** if a user-set "Vault PIN" is desired (recommended), Argon2id derives a key-wrapping key from the PIN. The X25519 shared key is wrapped by this; PIN never leaves the device.

### 5.2 Key storage
- Private keys live in platform secure storage: **Android Keystore** (hardware-backed where available).
- **Never** in Supabase, never in SharedPreferences, never in app logs.

### 5.3 What's stored in Supabase (NEVER plaintext)
```sql
create table public.vault_items (
  id              uuid primary key default gen_random_uuid(),
  couple_id       uuid not null references public.couples(id) on delete cascade,
  kind            text not null,                  -- 'photo' | 'note' | 'voice'
  ciphertext      bytea not null,                 -- XChaCha20-Poly1305 blob
  nonce           bytea not null,
  ad              text,                           -- item UUID, used as AD
  created_by      uuid not null references public.profiles(id),
  created_at      timestamptz not null default now(),
  retention       text not null default 'keep',   -- 'keep' | 'ephemeral'
  reconfirm_due   timestamptz,                    -- set if ephemeral, +90d
  deleted         boolean not null default false,
  deleted_by      uuid references public.profiles(id),
  deleted_at      timestamptz
);
```

### 5.4 Breakup / dissolution purge
- When either partner triggers "end this relationship" in Settings:
  1. A `couple_dissolution` row is created with `purge_at = now() + 7 days`.
  2. Both partners get a notification. Either can cancel within 7 days.
  3. After 7 days, a Supabase Edge Function deletes: `vault_items`, `memory_threads`, `fantasy_jar_entries`, `afterglow_entries`, etc. for that couple. Cascade is via `on delete cascade` from the `couples` row.
- **Rationale:** prevents a vengeful ex from holding intimate content hostage. The 7-day window is short enough to protect, long enough to undo an accidental trigger.

### 5.5 Key loss recovery (honest tradeoff)
- If a partner loses their device AND has no encrypted backup, **their previous Vault content is unrecoverable.** This is the cost of true E2EE — even Miles cannot decrypt it.
- **Mitigation:** at Closer enable, show a one-time recovery-phrase screen (BIP39-style 12 words) that encrypts their private key. User is *strongly* warned to write it down. Without it, no recovery.
- This tradeoff is **explicitly disclosed** in the Terms of Service.

---

## 6. Feature Specs

### F1. Touch Trace ✏️

**Purpose:** The most poetic feature in Miles. One partner traces a glowing line on their screen with a finger; the other sees the same line trace in real time, in the same color. What they draw is up to them — the tech is agnostic. Nobody does this well in the couples-app space.

**UX flow:**
1. Both enter Touch Trace (within Closer). Establish a realtime presence channel.
2. Drawer strokes (`PointerDownEvent` x/y + timestamp) are streamed via Supabase Realtime broadcast.
3. Partner's device replays them with a 0–200ms buffer; we use timestamp-based interpolation so network jitter doesn't make the line choppy.
4. Tap to clear; long-press to fade-out rather than hard-clear (matches the "soft" design language).

**Schema (no persistence by default — strokes are ephemeral):**
- Realtime broadcast channel `touch_trace:<couple_id>`.
- Optionally: an opt-in "save this trace?" → encrypted blob into `vault_items` with `kind = 'trace'`.

**Network jitter handling:** Client-side jitter buffer (200ms). Stroke points are timestamped at source; receiver schedules playback at `now - 200ms` and interpolates between points if gaps exceed 60ms.

**Consent:** Active for couple only when both `touch_trace` consent rows are `granted`.

**Compliance:** No media exchanged — just coordinate streams. Fully compliant.

---

### F2. Fantasy Jar 🍯

**Purpose:** Both partners privately add ideas ("things I want to try when we're together"). The app only reveals a "match" when *both* have independently expressed interest in the same tagged category. Protects against rejection, builds serendipity.

**Reveal mechanic (the magic):** NOT exact-string match (too brittle + privacy-leaky). Instead:
1. Each entry has 1–3 tags from a fixed taxonomy (e.g. `location`, `time_of_day`, `mood`, `pace`, `role`, `sensation` — ~30 tags total).
2. Each partner's tag set is hashed (HMAC-SHA256 with the couple-shared key) before storage. Tags are never stored in plaintext.
3. Background job compares tag overlaps; when both partners share ≥1 tag, the app surfaces a soft "you both seem curious about ✨ morning ✨" nudge to both — no detail beyond the shared tag.
4. Tapping the nudge opens an optional mutual-reveal: both must tap "reveal" within 24h to see each other's matching entries.

**Schema:**
```sql
create table public.fantasy_jar_entries (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  author       uuid not null references public.profiles(id),
  ciphertext   bytea not null,           -- the text, E2EE
  nonce        bytea not null,
  tag_hashes   text[] not null,          -- HMAC-SHA256(couple_key, tag)
  created_at   timestamptz default now()
);

create table public.fantasy_jar_reveals (
  couple_id      uuid not null,
  entry_pair     text not null,          -- sorted "id1|id2"
  user_id        uuid not null,
  revealed_at    timestamptz,
  primary key (couple_id, entry_pair, user_id)
);
```

**Compliance:** Text-only, E2EE, user-authored. We never read or moderate it. Compliant.

---

### F3. Afterglow 🌙

**Purpose:** Most apps end at the deed. Afterglow starts *after* — a soft 10-minute wind-down space: shared gratitudes, an optional photo from the moment (auto-ephemeral unless both opt to keep), a "thank you for tonight" prompt. The tenderness after.

**UX flow:** One partner opens Afterglow, taps "start." Other gets a gentle prompt. Together they:
- Add 1 line each ("what I'm grateful for")
- Optionally attach 1 photo each (E2EE; defaults to ephemeral)
- Tap "seal" → entry is added to their Afterglow timeline.

**Schema:**
```sql
create table public.afterglow_entries (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  happened_at  timestamptz not null,
  -- Two encrypted gratitude lines + optional photo refs:
  gratitude_a  bytea, nonce_a bytea, photo_a bytea,
  gratitude_b  bytea, nonce_b bytea, photo_b bytea,
  retention    text not null default 'ephemeral',  -- ephemeral by default here
  sealed_at    timestamptz
);
```

**Compliance:** Photo E2EE, never visible to us, no listing mentions of explicit content.

---

### F4. Private Vault 🔒

**Purpose:** E2EE photo/note storage with **user-controlled** retention. The headline paid feature.

**User requirements (verbatim from founder):**
- No auto-delete by default. Retention is fully user-controlled.
- Each item has a per-item toggle: "Keep" (permanent) or "Ephemeral" (both must re-confirm every 90 days or it expires).
- Hard delete of a shared item requires MUTUAL consent.
- Breakup escape hatch: dissolving the couple triggers a forced purge with a 7-day undo window.

**Per-item states:**
```
keep         → permanent; never auto-expires
ephemeral    → reconfirm_due = created_at + 90d; both must re-confirm or it expires
```

**Delete state machine:**
- Either partner taps delete → entry moves to `delete_requested` with `requested_by` + 14-day window.
- Other partner confirms → hard delete.
- 14-day timeout → if no confirmation, the requesting partner can force-delete (escape hatch for stale items).
- Either can cancel within the 14 days.

**Schema:** See §5.3 (`vault_items`).

**Pricing:** **Paid feature.** Storage cost + crypto complexity + the most defensible revenue hook. Free tier = 3 items. Paid tier = unlimited.

---

### F5. Desire Temperature 🌡️

**Purpose:** Daily private 1–10 slider ("how much you're feeling it today"). App only reveals when **both** scored high (≥7). Protects egos from mismatched states — you never see "I'm at 9, they're at 2."

**UX:** Slider at top of Closer screen each day. Tapping reveals: if both ≥7, a "tonight could be ✨" card; otherwise, a soft "you're a little out of sync today, that's okay" message. Both partners see the *same* message.

**Schema:**
```sql
create table public.desire_temps (
  couple_id  uuid not null,
  on_date    date not null,
  user_id    uuid not null,
  score      int not null check (score between 1 and 10),
  primary key (couple_id, on_date, user_id)
);
```

**Compliance:** Pure number, no media. Compliant.

---

### F6. Mood Lamp Sync 🎨

**Purpose:** Realtime shared color representing mood. Pick a color that represents you right now; it glows on their screen ambiently, no words.

**UX:** Color wheel on the Closer screen. Selecting broadcasts via Realtime; partner's screen tints to the color softly. Lasts until either picks a new one or 4 hours pass (auto-fade).

**Schema:** Realtime broadcast only — no persistence. (Optional: `mood_lamp_log` if we want a mood history, deferred.)

**Compliance:** Color only. Compliant.

---

### F7. Body Map 🗺️

**Purpose:** Stylized **abstract human silhouette** (vector, NOT a photo) where each partner pins spots they love to be touched / want explored. Revealed to the other. Surprisingly intimate, fully non-explicit.

**Compliance — critical:** The silhouette is an artistic line drawing, like a medical diagram or a fashion croquis. No nudity, no anatomical detail. This is the line that keeps the app safe.

**UX:**
- Tap to drop a pin on the silhouette. Add a 1-line note ("here, slowly").
- Color-code by partner.
- Both see both pin sets overlaid.
- Tap a pin → reveal its note.

**Schema:**
```sql
create table public.body_map_pins (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  author      uuid not null references public.profiles(id),
  x           real not null,    -- 0.0–1.0 normalized
  y           real not null,    -- 0.0–1.0 normalized
  note_cipher bytea not null,
  note_nonce  bytea not null,
  created_at  timestamptz default now()
);
```

---

### F8. "Pick for us" dice 🎲

**Purpose:** Consensual spontaneity. Pre-approved category tiers (warm → hot). Both partners tap yes to escalate.

**UX:**
- Both pre-approve categories during onboarding (warm always included; hotter tiers opt-in).
- Tap the dice together → it lands on a random combo (e.g. "slow," "morning," "whispered").
- Escalation: both must tap "let's go hotter" to advance to next tier.

**Schema:**
```sql
create table public.dice_rolls (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null,
  rolled_at    timestamptz default now(),
  tier         text not null,    -- 'warm' | 'warm_hot' | 'hot'
  result_tags  text[] not null
);

create table public.dice_tier_consents (
  couple_id    uuid,
  tier         text,
  user_id      uuid,
  granted      boolean,
  primary key (couple_id, tier, user_id)
);
```

---

### F9. Memory Threads 🧵

**Purpose:** A shared, **PIN-locked** timeline of past intimate milestones ("that night in Lisbon"). Both must mark a moment to add it. Tap-to-revisit together — rekindling old sparks.

**State machine:**
```
proposed → accepted (live) → archived
                          ↘ deletion_requested → deleted
```

**Add flow (dual-consent):**
1. Partner A taps "new memory," fills in title + date + optional encrypted photo, taps "propose."
2. Partner B sees a gentle "A wants to remember something from June 12" prompt.
3. Partner B taps "add to our thread" → memory becomes `accepted (live)`.
4. Either can archive (non-destructive) at any time.

**Revisit-together flow:**
- Tap any memory → "revisit with A?" prompt sent to partner.
- If partner is online + accepts: both see the memory full-screen with a synced ambient candle + soft music.
- If offline: deferred notification queued; when they next open the app, both see the pending revisit and can complete it.

**PIN gate:** Memory Threads sits behind its OWN 6-digit PIN / biometric prompt, on top of the general Closer gate. Required at every entry.

**Schema:**
```sql
create table public.memory_threads (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  proposer     uuid not null references public.profiles(id),
  title_cipher bytea not null, title_nonce bytea not null,
  happened_on  date not null,
  photo_cipher bytea, photo_nonce bytea,
  note_cipher  bytea, note_nonce bytea,
  state        text not null default 'proposed',  -- proposed|accepted|archived|deletion_requested|deleted
  accepted_by  uuid references public.profiles(id),
  accepted_at  timestamptz,
  archived_at  timestamptz,
  created_at   timestamptz default now()
);

create table public.memory_revisits (
  memory_id    uuid not null,
  initiated_by uuid not null,
  partner_acknowledged_at timestamptz,
  primary key (memory_id)
);
```

**Edge cases:**
- **Breakup:** dissolving the couple cascades delete on all memory_threads (per §5.4 7-day undo).
- **Key loss:** E2EE content unrecoverable without recovery phrase (§5.5).
- **One wants to revisit, other doesn't:** revisit is per-session, never stored. The un-acknowledged revisit prompt expires after 24h.
- **Archived vs deleted:** archived = hidden from main timeline but recoverable; deleted = gone (after dual consent).

---

## 7. Pricing Tier Implications

| Feature | Free | Paid ($5/mo or $39/yr) | Rationale |
|---|---|---|---|
| Touch Trace | ✅ | ✅ | Hook feature — too viral to gate. |
| Fantasy Jar | ✅ (3 entries) | ✅ unlimited | Free tier makes it discoverable; storage limits convert. |
| Mood Lamp | ✅ | ✅ | Cheap, no storage. |
| Desire Temp | ✅ | ✅ | Cheap daily engagement; keep free. |
| Afterglow | ❌ | ✅ | Storage + E2EE complexity. |
| Private Vault | 3 items | unlimited | **The paid anchor.** Storage + crypto cost + emotional lock-in. |
| Body Map | ❌ | ✅ | Moderate complexity. |
| Pick for us dice | ✅ (warm) | ✅ (hotter tiers) | Hot tier is upsell. |
| Memory Threads | 5 memories | unlimited | Emotional retention feature; gate at high volume. |

**Net:** Vault + Afterglow + Body Map + unlimited-everything = the paid pitch. Free tier is generous enough to be lovable, restricted enough to convert.

---

## 8. Phasing Plan

### v1.0 (ship first)
- Age gate, Modest Mode, dual-consent framework
- **Touch Trace** (viral hook, no storage)
- **Mood Lamp Sync** (cheap, instant gratification)
- **Desire Temperature** (daily engagement)
- Closer shell + Settings wiring (already built)

### v1.1 (4 weeks later)
- **Fantasy Jar** (needs crypto + tag-hashing infra)
- **Pick for us dice** (builds on consent infra)
- Stripe + Play Billing integration (Vault launch needs payment)

### v2.0 (8 weeks later)
- **Private Vault** (E2EE infra is the heaviest lift — needs full crypto, recovery phrase, dual-consent delete state machine)
- **Afterglow** (reuses Vault crypto)
- **Body Map** (needs silhouette asset + pin UI)
- **Memory Threads** (PIN gate + revisit-together realtime)

**Rationale:** Vault is the most valuable feature but also the riskiest. Ship the cheap viral features first to build an audience, then introduce payment alongside Vault.

---

## 9. Honest Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Google flags the app anyway | High | Listing stays SFW; appeal with the §1 defense; have a backup plan to strip Closer from the listing and ship it via direct APK if needed |
| User loses keys + recovery phrase | High (data loss) | Strong UX warnings at enable; consider opt-in cloud-wrapped key backup (degrades E2EE slightly) |
| Abusive partner uses features coercively | Medium | All features are non-coercive by design (no "must respond in X seconds," no surveillance). Modest Mode off-switch is always 1 tap away. |
| Revenge porn via Vault screenshots | Out of scope | We can't prevent screenshots, but we can warn. Android 14+ supports `FLAG_SECURE` per-screen — enable it inside Closer. |
| Founder subpoena for content | Low | True E2EE means we have nothing to hand over. Document this in privacy policy. |

---

*Last updated: 2026-06-24*
*Status: Draft v0.1 — ready for build*
