# Threat model — Miles

**Last reviewed: 18 August 2026.** Every claim here was checked against the tree
at `E:\LDR` on that date, against the migrations in `supabase/migrations/`, and
against the live-production findings recorded in `docs/guides/BRAIN.md` §19,
§41, §43, §44, §49, §50, §54, §55, §56, §58, §59 and §60.

This document exists so that a security reviewer, a Play reviewer, or whoever
maintains this app next can answer three questions without reading the whole
codebase: **who is this app defending against, who is it not defending against,
and where is the line drawn.**

It is written to be accurate rather than reassuring, the same rule the privacy
policy and the child-safety page follow. Its entire value is that it does not
lie: an aspirational threat model is worse than none, because it invites people
to rely on protections that are not there. Where a defence is partial, this says
so. Where something is planned but not shipped, it appears in §5 as a residual
risk and **not** in §4 as a defence.

If you change what the app stores or how it stores it, this file is part of that
change. A row that becomes readable, or stops being readable, moves in §1 in the
same commit.

---

## 0. The shape of the app, in one paragraph

Miles is a private app for exactly two paired adults. There is no feed, no
directory, no search for people, no discovery, and no way for an unpaired
account to reach another account inside the app; pairing happens only through a
single-use invite code one person hands the other, and the two-member cap is
enforced server-side (`redeem_pairing_invite`,
`20260818180000_pairing_code_alphabet_within_eight_chars.sql`). It runs behind a launcher
disguise — one of nine covers — and it holds the most private material two
people produce. User data lives in one production Supabase project (Postgres +
storage + realtime + edge functions, `ap-south-1`; a second project exists for
staging and holds no user data), and the app ships through two channels:
sideloaded APK with a self-updater, and Google Play.

Two structural facts drive everything below. **The app has no strangers in it**,
so the classic open-network adversaries — spam, grooming by an unknown account,
mass scraping — have no route. And **the phone, not the server, is where this
app is most often attacked**, because the person most likely to want this data is
standing next to the person who owns it.

---

## 1. What this app holds, and who can read it today

"Who can read it" has exactly three answers in the table below:

| answer | meaning |
| --- | --- |
| **Couple** | The two paired accounts, through RLS-scoped queries. Nobody else, including the operator, without breaking the crypto or holding a password. |
| **Couple + operator** | The two accounts, **and** anyone with database or storage access to the Supabase project: the operator, a support engineer with the service-role key, a stolen backup, a subpoena. Stored so that it *could* be read. |
| **Owner + operator** | Same, but scoped to one account rather than the couple — the partner cannot read it either. |

Nothing in this app is protected from the paired partner. That is the product,
not a gap, and §3 says so plainly.

### 1.1 The table

| Data class | Where it lives | Who can read it today | Notes |
| --- | --- | --- | --- |
| **Chat text** | `messages.body` (text) **and** `messages.body_cipher` / `body_nonce` (bytea) | **Couple + operator** | Dual-written. The plaintext `body` still goes on every send; the AEAD ciphertext goes beside it. See §1.2. |
| **Chat media** — photos, video, voice notes | `couple_media` / `couple_intimate` buckets, paths on `messages` | **Couple + operator** | Private buckets, short-lived signed URLs. The **bytes are not encrypted**. |
| **Chat documents** | `couple_files` bucket; the filename is `messages.body` with `kind='file'` | **Couple + operator** | Filenames stay plaintext even after the cipher-only flip — encrypting them is its own change (BRAIN §58 item 6). |
| **Shared gallery** | `gallery_items` + `couple_intimate` objects | **Couple + operator** | Captions in the clear, image and video bytes in the clear. |
| **Memory Threads** | `memory_threads` (`title_cipher`, `note_cipher`, `partner_note_cipher`, `place_cipher`), `memory_photos` (`caption_cipher`, encrypted objects) | **Couple (E2EE)** | Contents only. `happened_on`, `photo_count`, `created_at`, `proposer`, `state` are in the clear — the operator cannot read a memory but can see that you have one, and when. |
| **Wish Jar entry text** | `fantasy_jar_entries.ciphertext` / `nonce` | **Couple (E2EE)** | |
| **Wish Jar categories** | `fantasy_jar_entries.tag_hashes` | **Couple + operator** | Unkeyed 32-bit FNV-1a over a fixed twelve-item list, so all twelve are computable and reversible by anyone with database access. The words are private; the category is not. |
| **Private Vault files** | `personal_vault` bucket, keyed by `personal_vault_items.storage_path` | **Owner + operator** | **Plaintext since build 60**, by the owner ruling of 2026-08-28: the E2EE tile pipeline produced three builds of black tiles, so the vault's guarantee is the PIN gate, FLAG_SECURE and owner-only RLS instead (`VaultRepository.saveMedia` calls `_uploadPlain`). Owner-scoped in both storage policy and RLS — the partner cannot read them either (`20260816150000_personal_vault_owns_its_media.sql`). Legacy `.enc` objects keep their decrypt read-path. |
| **Private Vault notes and labels** | `personal_vault_items.content`, `media_url` (repurposed as the display label) | **Owner + operator** | Written in the clear by `VaultRepository.addNote`. As of build 60 the vault's files are not encrypted either, so the old files-vs-text distinction is gone: nothing in the Personal Vault is E2EE. The privacy policy, security page, terms, CSAE page and in-app FAQ were corrected to match on 2026-08-30. |
| **Cycle / health** | `cycle_logs`, `cycle_events`, `cycle_settings` | **Owner + operator**, plus the partner when `share_with_partner` is on | Off until switched on; sharing defaults **on** once it is. The partner-read path is gated on the consent flag on all three tables since `20260817160000`. |
| **Precise location** | `presence.latitude` / `longitude` / `location_accuracy` / `location_label` | **Couple + operator** | Foreground only, ~15s cadence, no background-location permission. City mode stores a label and no coordinates. Off writes empty values over the stored ones. |
| **Presence** | `presence.*` — online, last seen, current screen, typing, mood, check-in photo, avatar emoji | **Couple + operator** | |
| **Call metadata** | `call_invites` (caller, callee, video flag, status, `offer_sdp`), `call_signals` | **Couple + operator** | Who called whom, when, and whether it was video. The **media** is peer-to-peer DTLS-SRTP; when a direct path fails it relays through Cloudflare, which sees encrypted packets and both IP addresses. |
| **Time capsules** | `capsules`, `capsule_items.content_text`, `capsule-media` bucket | **Couple + operator** | Sealed-until-unlock is enforced against the media policy since `20260818091000`. |
| **Body-map notes** | `body_map_pins.note_cipher` / `note_nonce` | — | Cipher columns exist; **no client writes this table**. Treat as unused. |
| **Afterglow entries** | `afterglow_entries` (`gratitude_a/b`, `nonce_a/b`) | — | Same: cipher columns, no live writer. |
| **`vault_items`** (couple-scoped) | `ciphertext` / `nonce` / `ad` | — | Same again. The Closer-vault table predates the Private Vault and has no Dart call site. Some older comments in the tree still describe it as a live encrypted surface; it is not. |
| **Other Closer surfaces** | `dice_rolls.result_tags`, `desire_temps.score`, `intimacy_signals.state`, `body_touches` | **Couple + operator** | In the clear. 7-day retention on touches. |
| **Rituals, visits, prompts, check-ins, routines, reasons, watch sessions** | own tables | **Couple + operator** | In the clear. |
| **Profile** | `profiles` — display name, avatar, birth date, gender, timezone, status, wake/sleep, chat theme, FCM token | **Couple + operator** | |
| **Escrowed private key** | `key_escrow` — `wrapped_seed`, `salt`, `nonce`, `kdf`, `kdf_params` | **Owner's password only** | The operator holds the wrapped blob and its parameters and can derive nothing from them alone. What breaks this is the password, not the crypto — see §2(d). |
| **Reports** | `content_reports` | **Operator only** | Deliberately has **no select policy for any account**, including the reporter. A screen listing "reports you filed about your partner", on a phone that partner may pick up, is the most dangerous thing this app could draw. |
| **Crash reports** | `client_errors` | **Operator only** | Insert-own, no read for anybody. Exception *messages* are discarded on the device before sending; type, machine code and Dart frames go. |
| **Push payloads** | Firebase Cloud Messaging | **Google, in transit** | A type word, the couple id, the triggering row id, and for a call whether it is video. No names, no message text, no media, no coordinates. The visible notification is composed on the receiving phone from those identifiers. |

### 1.2 Chat is the one line that moves

Chat text is the only data class in this table that is mid-migration, and it is
the single most important thing a reviewer needs to understand correctly.

- The AEAD path exists and is proven end to end: seal → pack → `bytea` → the
  row decoder → unpack → open, with the row id bound as associated data at both
  ends (`ChatRepository.bodyAd`, `test/unit/chat/message_cipher_codec_test.dart`).
- Sends **dual-write**: plaintext `body` *and* `body_cipher` / `body_nonce`
  (`chat_repository.dart`, the insert around `sendText`).
- Dropping the plaintext is one server-side boolean,
  `app_release.chat_cipher_only`, applied to staging and production by
  `20260818110500_chat_cipher_only_switch.sql`, **default false**.
- The client refuses to drop the plaintext unless *both* the flag is true and
  *this particular body actually sealed*
  (`ChatRepository.omitPlaintext`, `chat_repository.dart:521`). A cipher-only row
  whose cipher never got written is a message nobody can read — not the partner,
  not the sender, not later — which is strictly worse than a row the operator can
  read. `ReleaseGate.chatCipherOnly` defaults false and stays false on **any**
  failure to read it, so the safe direction is also the resting state.
- The flip is blocked on a release, not on code. Every client that has not
  updated reads only `body` and would draw blank bubbles forever; the release
  gate fails open, so no build number proves those clients are gone. BRAIN §58
  records the ordered preconditions.

**Until that flag is thrown, chat text is operator-readable, and every document
in this app must say so.** The in-app copy does
(`faq_text.dart`, `safety_sheets.dart`), the privacy policy §2 does, and the
child-safety page §4 does. Moving that copy before the flip is live and holding
would make the app claim more than it does.

### 1.3 Why gallery and chat media are not encrypted

This is a decision, not an oversight, and it should be read as one. Encrypting
chat and gallery media would mean every thumbnail in a 500-item grid costs a
full-size ciphertext fetch and a decrypt before it can paint — which is exactly
why the vault and Memory Threads show loading wheels where chat does not
(`core/media/encrypted_media_cache.dart`). The app took the encrypted path for
the two surfaces where the cost is worth it and left the high-volume surfaces on
private buckets plus RLS. The consequence is stated in §1.1 and in the privacy
policy rather than hidden: **do not treat chat or the gallery as end-to-end
encrypted.**

---

## 2. Adversaries, ranked by how likely they are for this app's users

Ranked by likelihood for *these* users, not by sophistication. The first
adversary on this list is the reason half the app's UI exists.

### (a) Someone with physical access to the unlocked phone

**The core threat.** A partner, a parent, a sibling, a flatmate, a border
officer, anyone who picks up a phone that is already unlocked. They are not
forensic: they will tap an icon, look for about two seconds, maybe scroll once,
and move on — *if nothing is odd*.

**What they can do:** open any app on the launcher, read anything on screen,
take a screenshot, scroll a chat, look at the recent-apps thumbnails.

**What stops them today:**

- **The launcher disguise.** One of nine covers owns the launcher name and icon
  and *is* the app until it is unlocked — a working news reader, calculator,
  notepad, weather app, converter, recorder, timer, level or device-info screen
  (`features/disguise/`, `docs/guides/disguises.md`). Each cover is a real,
  functioning app, because an app that does nothing when tapped is what gets
  looked at twice.
- **A hidden entry gesture per cover**, printed inside the picker under every
  option so nobody locks themselves out, and chosen so a curious person does not
  hit it by accident.
- **App Lock** — biometric with a 4-digit PIN fallback, and it is a
  **precondition for applying a cover at all**: the picker refuses to set a
  disguise unless App Lock is enrolled (`disguise_picker_screen.dart:51`),
  because a cover with no lock behind it is a one-tap bypass with extra steps.
- **Silent failure at the gate.** A wrong biometric returns to the cover with no
  error, no toast, no ripple (`features/disguise/cover_gate.dart`). Someone
  probing gets no signal that they were close.
- **The panic lock** — three shakes in 1.5s, or volume-up plus volume-down within
  1s, drops the app straight back to the cover
  (`core/services/emergency_lock_service.dart`).
- **The app raises its cover on background**, so the recent-apps card shows the
  disguise.
- **A second gate on the two most sensitive surfaces**: the Private Vault PIN
  (bcrypt server-side, 5 failures then a 15-minute lockout that a PIN reset can
  no longer clear — `20260818090100`) and the Memory Threads PIN
  (`memory_pin_gate.dart`).
- **`FLAG_SECURE`** on the Private Vault, Memory Threads, Touch Trace and Touch
  Map (`features/closer/secure_screen.dart`) — those screens are absent from
  screenshots and from the recent-apps thumbnail. In the chat media viewer the
  flag follows the *page*, and only a **video** page raises it: a photo page
  clears it (`features/chat/widgets/media_viewer.dart:200`). Chat photos are
  screenshotable.
- **Contact pause** (`features/safety/contact_pause.dart`): silent, reversible,
  one-way. Nudges stop, an incoming call is dropped instead of ringing, and the
  partner is not told and cannot read the setting. A stop that announces itself
  is one nobody in a controlling relationship can afford to use.

**What does NOT stop them:**

- Anyone who watches the user unlock the app, once, has the gesture and the
  biometric prompt.
- The chat list itself is **not** `FLAG_SECURE` — chat is screenshotable.
- App Lock's *enabled* flag lives in SharedPreferences (only the PIN hash moved
  to the keystore), so anything that can rewrite app files can clear it.
- Four digits are four digits. The salted hash lives in the platform keystore,
  which is what buys resistance — 10,000 candidates fall instantly to anyone who
  holds the stored value.
- Notification content on the lock screen is the OS's business, not the app's.
- Nothing in this app defends against a person who simply asks the user to open
  it while standing over them.

### (b) Someone who knows the user and has their password

**Second most likely, and the most damaging.** A partner who knows the email and
the password; someone who has watched it typed; someone reusing a password the
user reused.

**What they can do:** sign in as the user from any device, and — because the
escrow seal is derived from that same password — **unwrap the escrowed private
key and decrypt everything the E2EE surfaces protect.** Memory Threads, Wish Jar
text and vault files are not out of reach of a stolen password.

**What stops them today:**

- The escrow wrap is Argon2id at OWASP baseline — m=19456 KB, t=2, p=1, 32-byte
  output (`core/data/key_escrow.dart`), measured at roughly half a second on the
  oldest test handset. Memory-hardness is what actually blunts offline GPU
  cracking, and it is correct.
- The wrap has its own label, distinct from the auth secret
  (`KeyEscrow._wrapLabel`), and every row carries the parameters it was sealed
  with so hardening the constants never orphans existing rows.
- Sign-out-everywhere exists in Settings (`SignOutScope.others`), so a session
  the user did not authorise can be revoked.
- Email change is built to confirm on both the old and the new address — though
  the GoTrue setting that enforces the old-address half is dashboard-only and
  has not been verified (BRAIN §44). Do not rely on it until someone has.
- TOFU key pinning (§2(d)) means a new device signing in as the user does not
  silently become the partner's trusted counterparty — the partner's phone
  refuses to derive until a human confirms the change.

**What does NOT stop them:**

- **Nothing, once they have the password.** The password is sent to GoTrue in
  plaintext on every sign-in *and* is the key that opens the seal; the two
  secrets are one secret. This is stated in `key_escrow.dart`'s own header, in
  privacy policy §3, and in child-safety §4. The seal defends against a stolen
  database backup, not against a stolen password.
- The password floor is **8 characters** (owner decision, BRAIN §60) and
  **leaked-password checking (HIBP) is off** because it is a Pro-plan feature and
  the project is on the free plan. `Password1!` satisfies the policy and sits in
  every cracking wordlist.
- Nothing detects a sign-in from a new device and tells the user.

### (c) A network attacker

**What they can do:** sit on the wire — hostile Wi-Fi, a hostile ISP, a hostile
country — and try to read or modify traffic.

**What stops them:** TLS on every Supabase call, realtime channel and edge
function. Storage objects are reachable only through short-lived signed URLs.
Call media is DTLS-SRTP end-to-end between the two devices. On the E2EE
surfaces, the payload is already ciphertext before it reaches the socket, so the
transport is not the only thing standing there.

**What does NOT stop them:** everything in §1.1 marked *operator-readable* is
readable by anyone who breaks TLS, because TLS is the only thing protecting its
confidentiality in flight. Traffic analysis is untouched — message timing, sizes
and frequency are visible to anyone watching the connection, and encryption
covers contents, never shape.

### (d) The operator, or a compromised Supabase project

**The adversary this app is least able to hide from, and the one it is most
careful to describe honestly.** Treat "the operator" and "anyone who steals the
service-role key or a backup" as the same adversary — they have identical
access.

**What they can read, plainly:** every row in §1.1 marked *operator-readable*.
Chat text and chat media. The gallery and its captions. Time capsules. Vault
notes and item labels. Cycle data. Coordinates. Presence. Call metadata. Profiles.
Wish Jar *categories*. All of it, without breaking anything.

**What they cannot read:** Memory Thread contents and Wish Jar entry text.
Those arrive as ciphertext under a key derived by ECDH +
HKDF between two X25519 keys that never leave their devices, sealed with
XChaCha20-Poly1305 (`core/data/crypto_core.dart`).

**What stops the operator from cheating that, today:**

- **The plaintext door is closed.** Until 18 August 2026 `crypto_core` had a
  "plaintext-agreed" mode and an all-zero-nonce / all-zero-MAC read acceptance
  left over from a rollout. That was a **forgery primitive**: anything with
  database write access could mint a zero-MAC row and every device would render
  it as authentically the partner's. Both halves are gone — `deriveSharedKey`
  throws on the no-key sentinel, `encryptBytes` refuses without a derived key,
  and `decryptBytes` verifies every row or fails. A zero-MAC row now dies on
  Poly1305 like any other tampered row (BRAIN §55, `crypto_core.dart` header).
- **TOFU key pinning closes the substitution attack.** `partner_keys` is a
  directory the *server* controls, so every E2EE guarantee used to reduce to
  "the server hands back the key it was given" — a coerced or compromised
  database could substitute its own key and quietly become the couple's second
  member for all future content. `core/data/partner_key_pin.dart` stores
  `sha256(partner public key)` in the keystore, scoped `myUid:partnerId`, pins on
  first sight, and **refuses to derive** on a change until a human says the
  change is real. All four derive doors are guarded:
  `couple_key.dart:99` (chat), `closer_crypto.dart:56` (Closer),
  `wish_jar_repository.dart:107` (Wish Jar), `partner_rewrap.dart:427` (the
  recovery ceremony).
- **Only two things may repin**, and both prove a human: the rewrap ceremony
  after its voice-read six-digit code passes, and the change sheet after the
  couple compares a 20-digit safety code aloud
  (`PartnerKeyPin.safetyCode`, `features/closer/partner_key_change_sheet.dart`).
  What can never repin is silence.
- The safety code in Settings is deliberately computed from the **published**
  key, so a substitution shows up as two phones reading different codes.
- RLS is enabled on every public table and identity is derived from `auth.uid()`
  inside every `SECURITY DEFINER` function, never taken from the caller — so a
  compromised *client* still cannot read another couple, and the 39 advisor
  warnings about definer functions measure the size of the API, not a hole
  (BRAIN §59).

**What does NOT stop them:**

- **The escrow.** The operator holds every user's wrapped seed. Combined with
  the password — captured at the auth endpoint, guessed, or leaked — that
  unwraps the private key and every ciphertext it protects. Child-safety §4 says
  this in as many words: *we do not claim it is mathematically beyond our reach.*
- **First sight.** TOFU concedes the first fetch (§3).
- **Metadata.** Who talks to whom, when, how often, how many photographs a
  memory holds, when it was created and who proposed it — all in the clear.
- **The dual-write.** While `chat_cipher_only` is false, chat ciphertext buys
  nothing against this adversary, because the plaintext is sitting in the next
  column.

### (e) Another app on the same device

**What they can do:** try to read this app's files, intercept its intents,
observe it through the OS.

**What stops them:** the Android sandbox and app-private storage; `allowBackup`
is off; key material lives in the platform keystore via
`flutter_secure_storage`, not in a prefs file; the encrypted-media disk cache
holds **ciphertext only — plaintext never touches disk**
(`core/media/encrypted_media_cache.dart`); `FLAG_SECURE` on the intimate screens
also blocks screen-recording apps there.

**What does NOT stop them:** anything with root or a filesystem image (§3). An
accessibility-service abuser reads the screen the same way the user does. The
data export writes **decrypted** copies into a user-chosen folder — the screen
warns in those words, and drops a `.nomedia` so the media scanner does not index
it, but any app with access to that folder can read what is in it
(`core/services/data_export_service.dart`, BRAIN §56).

### (f) Law enforcement, or a lawful production order

**What they can compel:** whatever the operator can read — which is everything
in §1.1 marked *operator-readable*.

**The app's stated position** (`web/csae.html` §5, and it is deliberate):

- Apparent child sexual abuse material reported to the app is referred onward,
  not handled internally and closed — to the National Cyber Crime Investigation
  Agency in Pakistan, where the developer is established, and to NCMEC's
  CyberTipline.
- A lawful request is complied with *to the extent the data exists and can be
  read*. Chat text, chat media and Personal Vault contents can be produced.
  Memory Threads and Wish Jar text are held only as ciphertext, **and the response says so
  together with the escrow limit in §2(d)** — rather than letting an authority
  believe the material is further out of reach than it is.
- Nothing is proactively scanned. There is no automated detection, no hash
  matching, no classifier, no moderation queue and nobody employed to review
  content. Enforcement is report-driven, manual, and acts on the account.

**What does NOT change under compulsion:** the app cannot produce a key it does
not hold — but it *does* hold every user's wrapped seed, so "we cannot read it"
is true only while the password is unknown. Saying otherwise would be the single
most dishonest sentence this app could publish.

### (g) A curious stranger with the APK

The sideload channel means the binary is public. Everything in it is public:
unpack an APK in seconds and you have the Supabase URL, the anon JWT, every
table and RPC name, every cover's entry gesture, and the whole client-side
logic. **This is expected, and nothing in the app's security may depend on the
binary being secret.**

**What stops them:** the anon key is only a ticket to the API — RLS is what
holds the doors, and it denies by default. No public tables, no views or
materialised views in `public` (the usual silent bypass in a Supabase app), all
six storage buckets private, `profiles.couple_id` deliberately absent from the
`authenticated` UPDATE column grants so no one can self-assign into a stranger's
couple, and trigger functions revoked by *shape* so the next one is covered the
day it is written (`20260816090100`). A 26-agent white-box pentest against tree
and live production produced **zero criticals**: no stranger-facing auth bypass
and no cross-couple read survived verification (BRAIN §49).

**What does NOT stop them:**

- A repacked APK controls what it reports. The release gate is client-side and
  **fails open**, and the channel string comes from a MethodChannel the repacker
  owns — so claiming `play` yields `min_build_play ?? 0` and the version gate
  never blocks. **A security fix cannot be forced onto the field.**
- Pairing codes are **40.7 bits** — eight characters drawn uniformly (with
  rejection sampling) from a 34-symbol alphabet, single-use, expiring within a
  day — `20260818180000_pairing_code_alphabet_within_eight_chars.sql`. Eight
  characters is not a preference: the shipped invite field is `maxLength: 8`
  (couple_page.dart:274) and this app cannot upgrade its fleet, so the space
  had to grow through the alphabet rather than the length. A twelve-character
  attempt earlier that day was reverted for exactly this reason.
  The failed-attempt limiter that used to sit in `redeem_pairing_invite` is
  **gone, deliberately**: it counted rows inserted on paths that `raise`, and
  Postgres rolled every one of them back with the exception, so production held
  0 failure rows after months of use. It could not be repaired in place — a
  PostgREST RPC is one transaction, plpgsql has no autonomous commit, and the
  shipped clients read these errors by message, so a function that stops raising
  would report a failed pairing as a success. Entropy replaced it because
  entropy needs no state and therefore cannot be rolled back. Do not re-add a
  counter without first solving that; a control that cannot fire is worse than
  none, because it is what the next audit ticks off.
- `create_pairing_invite(p_ttl_minutes)` is now bounded at **both** ends —
  floor 1 minute, ceiling 1440 (the value the shipped client already asks for).
  It previously had no ceiling, so a patched client could mint a code that
  outlived the couple.
- Rate limits are per-account server-side (5 reports / 24h, 10 TURN mints / hour,
  send throttles on every push-generating path) — a client that lies about its
  own build cannot lie about `auth.uid()`.

---

## 3. Explicitly out of scope

These are not oversights. They are the boundary, and naming them is what makes
the rest of the document trustworthy.

**A rooted or compromised device.** Root reads app-private storage, extracts
keystore-backed material on many devices, and observes the process directly. App
Lock, the vault PIN, the disguise and the ciphertext cache all assume an intact
sandbox. If the OS is against you, this app cannot help.

**A malicious partner who is legitimately in the couple.** The person you paired
with can see everything you send them — that *is* the product. The app cannot
make a partner forget, cannot take back what has been shown, and does not try
to. What it does offer is a silent, reversible contact pause, an unpair that
dissolves the couple for both sides at once, an in-app report route that does
not notify the person reported, and account deletion. The only content the
partner cannot reach is the Private Vault, and the cycle log while sharing is
switched off — plus reports and crash rows, which no account can read at all.

**First-sight trust-on-first-use.** A server that lies from the very first fetch
of a partner's key is undetectable by the pin, because there is no earlier
honest value to contradict it. The safety code exists for exactly that doubt: two
people reading twenty digits aloud is the out-of-band channel the pin does not
have. This is the standard TOFU concession and it is written into
`partner_key_pin.dart`'s own comments.

**Screenshots and re-photography.** `FLAG_SECURE` covers the intimate screens; it
does not cover the chat list, it does not cover a chat photo in the viewer, and
it does not cover a second phone pointed at the first. Nothing can.

**The user's own account password.** Choosing it, storing it, and not reusing it
are the user's job. §2(b) is what happens when that fails.

**Malicious Android OEM software, a hostile baseband, and nation-state device
implants.** Out of reach of an app.

**Availability.** See §5 — the app is on a free tier that auto-pauses. This
model is about confidentiality and integrity; uptime is a business decision, not
a defence.

---

## 4. The defences, and which threats they actually address

Only shipped defences appear here. Anything planned is in §5.

| Defence | Where it lives | Addresses |
| --- | --- | --- |
| **RLS on every public table, deny by default; identity derived from `auth.uid()` inside every definer function; no views in `public`; all buckets private** | `20260601000100_schema.sql` (base + `current_user_couple_id()`), every migration since | (d) partial, (e), (g) |
| **`profiles.couple_id` excluded from the `authenticated` UPDATE grants** | column-level grants, pinned in `supabase/schema_snapshot.json` | (g) — nobody can self-assign into a stranger's couple |
| **AEAD with no plaintext fallback** — sentinel derive throws, `encryptBytes` refuses without a key, `decryptBytes` verifies or fails, zero-MAC rows die on Poly1305 | `mobile/lib/core/data/crypto_core.dart` | (d) — closes the forgery door |
| **TOFU partner-key pinning on all four derive doors**, human-only repin, 20-digit safety code | `mobile/lib/core/data/partner_key_pin.dart`; `couple_key.dart:99`, `closer_crypto.dart:56`, `wish_jar_repository.dart:107`, `partner_rewrap.dart:427`; `features/closer/partner_key_change_sheet.dart`; Settings › Security code | (d) — closes server key substitution |
| **Argon2id key escrow**, per-row parameters, distinct wrap label | `mobile/lib/core/data/key_escrow.dart` | (d) against a stolen backup; **not** against (b) |
| **Partner-assisted rewrap ceremony** — six digits read over a call, Argon2id-committed, publishes only at claim | `mobile/lib/core/data/partner_rewrap.dart`, `features/auth/rewrap_screen.dart` | recovery without handing the operator a second door |
| **Launcher disguise + per-cover hidden gesture + silent failure** | `mobile/lib/features/disguise/`, `docs/guides/disguises.md` | (a) |
| **App Lock as the covers' precondition** — biometric, PIN fallback, salted hash in the keystore | `core/services/app_lock.dart`, `features/disguise/disguise_picker_screen.dart:51`, `features/disguise/cover_gate.dart` | (a) |
| **Panic lock** — shake ×3 or volume up+down | `core/services/emergency_lock_service.dart` | (a) |
| **Vault PIN** — bcrypt server-side, 5 fails / 15 min, reset cannot clear a live lockout | `20260601001100_private_vault.sql`, `20260818090100_*.sql` | (a) |
| **`FLAG_SECURE`** on vault, Memory Threads, Touch Trace, Touch Map; video pages only in the chat media viewer | `features/closer/secure_screen.dart`, `features/chat/widgets/media_viewer.dart:200` | (a), (e) |
| **Ciphertext-only disk cache; plaintext RAM-only** | `core/media/encrypted_media_cache.dart` | (a), (e) |
| **Contact pause** — silent, reversible, one-way, covers messages, calls, reaches and nudges | `features/safety/contact_pause.dart`, `20260816120000_*.sql`, `20260817160100_*.sql` | (a), the malicious-partner boundary in §3 |
| **Report flow** — write-only table, server-resolved subject, 5 per 24h, `csam` category handled first | `features/safety/report_service.dart`, `safety_sheets.dart`, `20260816120000_*.sql`, `web/csae.html` §3–§5 | (f), the §3 boundary |
| **Capsule seal covers its media**; `unlock_date` / `unlock_mode` not client-writable | `20260818091000_capsule_seal_covers_its_media.sql` | the malicious-partner boundary in §3 |
| **Cycle sharing gated on consent across all three tables** | `20260817160000_audit_close_anon_rpc_and_cycle_consent.sql` | the §3 boundary |
| **Pairing code entropy**: 8 chars x 34 symbols (40.7 bits), uniform via rejection sampling; TTL floored at 1 min and capped at 1 day; the dead failed-attempt counter removed rather than left looking like a control | `20260818180000_pairing_code_alphabet_within_eight_chars.sql` | (g), a stranger guessing their way into a couple |
| **Pairing**: single-use TTL'd codes, server-enforced two-member cap, no directory or discovery | live definitions: `20260818180000_pairing_code_alphabet_within_eight_chars.sql` (both) | (g), grooming by a stranger |
| **Rate limits**: TURN mints 10/hour, per-path send throttles, memory-proposal throttle, crash-report cap | `20260816090000_*.sql`, `20260818090200_*.sql`, `20260601007800_client_errors.sql` | (g), cost and push abuse |
| **Crash reports discard the exception message on-device** | `mobile/lib/core/diag/diag.dart` (`ErrorReporter`) | (d) — a message like `no key for <your text>` is how content escapes an encrypted app |
| **Data export** — decrypted copies, only the owner's device can build them, SAF-scoped, `.nomedia`, explicit warning | `core/services/data_export_service.dart`, `features/settings/export_screen.dart` | user rights; note the §2(e) caveat |
| **Account deletion**, in-app and via a web page with an emailed code | Settings › Account, `web/delete-account.html`, `delete_my_account` | user rights |

---

## 5. Known residual risks

Each of these is real, currently open, and named on purpose. If you close one,
move it out of this section in the same commit.

| Risk | Status | What it costs |
| --- | --- | --- |
| **Chat plaintext at rest** | **Open — gated flip built, not thrown.** `chat_cipher_only` exists, defaults false; the client dual-writes and refuses to drop the plaintext unless the flag is true *and* the body sealed. Blocked on a released build the fleet actually runs, then sideload first, Play last (BRAIN §58). | Chat text is operator-readable, and every document must keep saying so until the flip is live and holding. |
| **Chat and gallery media** | **Open by decision** (§1.3). No plan to encrypt. | Media bytes are operator-readable. Documents keep plaintext filenames even after the chat flip. |
| **Escrow is only as strong as the password** | **Open, and structural.** Password floor is 8 (owner decision, BRAIN §60). **HIBP leaked-password protection is OFF** — Pro-plan only, project is on free. | Anyone with the password holds what opens the encrypted history. HIBP is also not retroactive: turning it on later never re-checks passwords already stored. **Before raising the floor, test that an existing below-policy account can still sign in** — GoTrue's behaviour there was not settled from the client, and getting it wrong locks out the installed base. |
| **First-sight TOFU** | **Open by design** (§3). | A server lying from the very first fetch is undetectable. The safety code is the mitigation, and it requires the couple to actually use it. |
| **Pins are per-device** | **Open by design.** A reinstall forgets the pin and re-trusts first sight; escrow and the ceremony repopulate it. | The window a reinstall opens is the same window §3 concedes. |
| **Wish Jar category leakage** | **Open.** `tag_hashes` is unkeyed 32-bit FNV-1a over a fixed twelve-item list, so all twelve are computable. | The words are private; the category is not. Stated in privacy policy §2. |
| **Metadata is not encrypted anywhere** | **Open, and inherent.** | Who, when, how often, how many — visible to the operator on every surface, including the E2EE ones. |
| **The version gate cannot be forced** | **Open, and unfixable client-side.** Client-side, fails open, channel string comes from a MethodChannel a repacked APK controls. | A security fix cannot be pushed onto the field. Anything that must reach every client goes through a *server-side* switch, the way `chat_cipher_only` does. |
| **Sideload channel has no update guarantee** | **Open.** No app store to force an upgrade on the sideload fleet. | Every breaking change needs a server-side gate, never a coordinated install. |
| **Availability — free tier** | **Open, owner decision.** Production is on the Supabase **free** plan; a project auto-pauses after ~7 idle days and its DNS is withdrawn (this project paused once already). Free ceilings are couple-scale: 1 GB storage, 5 GB/mo egress, 500k/mo edge invocations against a notifier that fires per message. | Not a confidentiality risk. It is a total-loss-of-service risk, and Pro is a launch precondition. |
| **No external security audit** | **Open.** Every audit on record is internal — BRAIN §19 (backend + client crypto), §41 (pre-market, 15 agents), §49 (white-box pentest, 83 verified findings, 0 critical), §50, §55. | No independent party has verified any claim in this document. Treat it as a self-assessment, because that is what it is. |
| **`personal_vault_items.content` is plaintext** | **Open.** Vault *files* are encrypted; vault *notes and labels* are not. | Named in §1.1 and in privacy policy §2 so nobody infers otherwise from the word "vault". |
| **Legacy encrypted tables with no writer** | **Open, low.** `vault_items`, `afterglow_entries` and `body_map_pins` carry cipher columns and have no Dart call site; some older comments still describe `vault_items` as a live encrypted surface. | No data at risk (they are empty), but the stale comments mislead the next reader. |

---

## 6. How to keep this file honest

1. **A row moving between "couple" and "couple + operator" in §1.1 is a change
   to this file**, in the same commit as the code.
2. **Never move a claim from §5 to §4 before the code is live in the field.** A
   defence that exists in the tree and not on the handset belongs in §5.
3. **Copy in the app, in `web/privacy-policy.html` §2, in `web/csae.html` §4 and
   in this table must agree.** If they disagree, the code is right and all four
   documents are wrong.
4. Re-read this file whenever the app gains a feature that changes what two
   people can send each other — the same review trigger `web/csae.html` §7
   commits to.
