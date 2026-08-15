# BRAIN.md — session handoff

Working state for **Miles** (Flutter + Supabase couples app). Read this instead
of the chat history. Last updated 2026-08-15.

---

## 0. The thing to get right

**Raza gives a complaint, not a spec.** He has corrected this four times in one
session. The failure mode, verbatim from the memory file:

> If my change list contains one file and his complaint contains one screen, I
> have almost certainly done it again.

Before touching anything: grep for **every** call site, every widget that renders
that kind of thing, every entry point. Fixing one and missing four is the thing
he keeps catching. See `~/.claude/projects/E--LDR/memory/expand-the-idea-dont-transcribe-it.md`.

**Second lesson, learned expensively this session:** four separate bugs were
*schema mismatches* — client code writing to columns that were never migrated.
None are catchable by `flutter test`; they compile perfectly and fail only
against the real database. **Query `information_schema` before believing a
client-side diagnosis.**

---

## 0b. Instruction system rebuilt (2026-08-15)

- **`~/.claude/CLAUDE.md` is now the single live rulebook** — 26 sections, global
  (every project, every model, every message). It contains everything that used
  to be scattered: the working agreement, all session instructions, LDR + Us
  project rules, plus 8 new engineering sections from a 14-agent mythos-run
  synthesis (No silent failures, Round-trip every serialization boundary, Least
  privilege and secrets, Rollback before rollout, Debugging one-hypothesis, Red
  gate is a wall, Conflicts resolve by rank, A reversed "fixed" amends the file).
- New standing rule: **"Mythos-peak intelligence, every message"** — max depth +
  multi-agent orchestration on every substantive task.
- Readable snapshot with verbatim quotes: `docs/guides/instructions.md`.
- **Precedence: CLAUDE.md > this file.** BRAIN.md records state; CLAUDE.md
  records what he wants. This file already burned one session by carrying a
  stale "build unprompted once green" line — when they disagree, CLAUDE.md wins.
- Nothing app-side changed in this session: no code, no migrations, no build.
  Working tree additions: `docs/guides/instructions.md` (this repo), CLAUDE.md
  edits (outside the repo). Nothing committed.

---

## 1. Where things are

- Repo `E:\LDR`, app in `mobile/`, branch **`fix-sprint`** (no remote, 260+ commits).
- New since the audit: `docs/guides/PLAY-RELEASE-RUNBOOK.md`,
  `docs/legal/privacy-policy.md`, and a top-level `web/` holding the two pages
  that must be publicly hosted (`privacy-policy.html`, `delete-account.html`).
- Supabase prod **`sopictusdonlvuezmfep`** (staging `zqltaobarpcuantrqxha`).
- Test device: OnePlus 8 / **IN2015**, Android 13, arm64. adb at
  `C:/Users/razaa/AppData/Local/Android/Sdk/platform-tools/adb.exe`.
- Current build **22** (`pubspec.yaml` + `lib/core/app/release_gate.dart` must
  match — nothing enforces that, so check both by hand). APK shipped as
  `E:\LDR\Miles.apk`, **one universal APK**, 218.4 MB, arm64-v8a + armeabi-v7a
  + x86_64. Not split per ABI: he asked for a single file, and
  `build.gradle.kts` already keeps R8 off for exactly that "directly-shared
  universal APK" case.
- **Debug-signed.** No `android/key.properties`. Release keystore steps were
  given; he hasn't made one. Debug SHA-1:
  `A1:05:79:47:08:8B:7A:21:4B:DA:C3:C2:BE:95:B3:03:95:74:64:C7`, package
  `com.miles.miles`.

---

## 2. Live on the server — already working, no rebuild needed

| Fix | Migration |
|---|---|
| `couple_intimate` accepts `application/octet-stream` (vault upload was 415) | `20260601006400` |
| `vault_items.storage_path` + `media_mime_type` added (was PGRST204) | `20260601006500` |
| `memory_threads` 4 delete columns (delete threw PGRST204) | `20260601006600` |
| `rituals` 6 columns incl. `deleted` — **the list query itself was failing** | `20260601006600` |
| `afterglow_entries` unique index on unsealed rows | `20260601006400` |
| `key_escrow` table | `20260601006700` |

Vault upload is **confirmed working** by the user.

---

## 3. In code, needs an APK to reach the phone

- **Maps back on Mapbox** (`world_map_screen.dart`, restored from `02350cb`).
  Token via `map-token` edge function ← `app_secrets.MAPBOX_PUBLIC_TOKEN`. Never
  in the APK.
- **Home no longer mounts a map.** `_MapDoor` panel in
  `partner_location_card.dart` — Home used to stream tiles centred on the
  partner on open, with no interaction.
- **WebView disposed** in `world_map_screen` — its error card was compositing
  over the screen behind it.
- **Vault picker** → `PhotoPickerService` (was a bare `ImagePicker`, so it opened
  the file manager; also brings HEIC/ProRAW support).
- **Key escrow** (§5).
- **`CryptoCore.encryptBytesOffThread`** — 100 MB AES on the UI thread.

---

## 4. Open, with diagnosis

### 4-0. FULL PRODUCTION AUDIT — 2026-08-15 — read this first

`docs/guides/PRODUCTION-AUDIT-2026-08-15.md`. 8 dimensions, every critical/high
adversarially re-verified against live prod + the working tree. **6 critical, 21
high.** Two findings were REFUTED in verification and are listed there as
do-not-action (per-message push fanout; redeem_pairing_invite couple-splitting).

**The fixes are IN THE WORKING TREE, UNCOMMITTED**, across six tracks — `sql`,
`edge`, `android`, `crypto`, `scale`, `docs`. Nothing was committed and nothing
was built. `git status` before assuming a file is yours; six tracks touched this
tree in one day.

**The ordered release procedure is now written: `docs/guides/PLAY-RELEASE-RUNBOOK.md`.**
It carries the real commands (keystore, `key.properties`, `maps.properties`, the
AAB build for the new `play` flavor), every Play Console declaration, the
Supabase upgrade, the NOTIFY_SHARED_SECRET seeding, and the sideload→Play
migration sequence. Do not reconstruct any of that from this file.

The six criticals, short form, with where each now stands:
1. Launcher disguise = Play Deceptive Behavior → account strike, not just
   rejection. **Addressed:** the android track added a `play` product flavor
   (`src/play/AndroidManifest.xml` strips the nine aliases and the disguised
   label/icon; `BuildConfig.DISGUISE_ENABLED=false` stops the Dart covers
   mounting). `sideload` is unchanged.
2. Release build is debug-signed (no `key.properties`) → upload rejected.
   **Addressed in build config:** `play` now *fails the build* with an explicit
   GradleException when the key is missing, rather than falling back to debug.
   The keystore itself still does not exist — that is a human step.
3. 218 MB universal APK, not an AAB → format rejected before review.
   **Addressed:** `flutter build appbundle --release --flavor play`, R8 +
   resource shrink on for that flavor only. **Never built or device-tested.**
4. No privacy policy anywhere. **Written:** `docs/legal/privacy-policy.md` +
   `web/privacy-policy.html`. Derived from the code, honest about what is *not*
   E2EE. Needs three placeholders filled and hosting.
5. No **web** account-deletion URL. **Built:** `web/delete-account.html`, wired
   to the deployed `account-delete` edge function (email → 6-digit code →
   `delete_my_account` on the caller's own JWT). Contract verified live:
   `{"ok":true}` on request, 401 `invalid_code` on a bad code. Needs the Magic
   Link email template to contain `{{ .Token }}` or step two has nothing to
   verify.
6. **Prod Supabase is on the FREE plan.** Verified again 2026-08-15: org
   `fpmfuptznczuuksqybnx` plan=free, storage **525 MB / 1 GB across 651
   objects**, DB 35 MB. 200-connection realtime ceiling; auto-pause. **Still
   free. Blocks everything else** and no code change touches it.

Three things the audit found broken on prod — **all three now fixed and verified
live** (`rewrap_table=t | notify_secret=1 | cron_jobs=10 | deliver_rituals=1`):
- `partner_rewrap_requests` now exists, applied as `20260815065624_partner_rewrap`.
  Note the ledger name: prod records migrations under **different timestamps than
  the local filenames**, which is why `db push` is not the deployment mechanism
  here.
- `deliver_rituals` proc + cron job now exist.
- `care-notify` now has `verify_jwt=true`; `reach-notify` and `reap-storage`
  **fail closed** on a missing `NOTIFY_SHARED_SECRET` (403). The secret IS seeded
  on prod today — a restored or rebuilt project must seed it or pushes and
  storage reaping die silently.

Also still open and unfixed at release time: HIBP leaked-password protection is
disabled in Auth settings, and `reach_notifications.dart:65,157` still dresses
**Reach** as `AndroidNotificationCategory.call` with a full-screen intent — which
is exactly what Play's USE_FULL_SCREEN_INTENT declaration refuses.

**Root process problem — STILL UNFIXED, and it is the one that will bite.** Local
migrations and prod have drifted BOTH ways. The two previously-unapplied files
(008400 `deliver_rituals`, 008700 `partner_rewrap`) have now landed, but the
ledger records them under **different timestamps than the local filenames**
(`20260815070944_deliver_rituals`, `20260815065624_partner_rewrap`) — 102 local
files against a differently-numbered `supabase_migrations.schema_migrations`. On
top of that: SQL applied on prod with no local file (`no_message_push`, the
pairing-retirement statements), and `20260601006000` is 18 lines of comments and
zero SQL. A rebuild from `supabase/migrations` produces a different and in places
more vulnerable schema than prod, and `supabase db push` is NOT how this project
deploys. Reconcile before any release — runbook phase 1.5.

The audit found `release_gate.dart:27` at `buildNumber = 26` against pubspec
`+27` (broken at commit 5d70262). **Re-checked 2026-08-15: both now read 27.**
prod `app_release.min_build` is still 2, so the trap is unarmed — but the first
real min_build raise locks out the entire fleet, and nothing enforces that the
two numbers stay in lockstep. Check both by hand every build.

Baseline at audit time: `flutter analyze` exit 0 (470 info lints, no
errors/warnings), `flutter test` `+680: All tests passed!`. Both are green and
caught none of the above. **Re-run both before believing the tree is clean** —
six tracks edited it after that baseline was taken.

### 4a. Vault read path — THE next job
He asked for this and it is not done. Current design: thumbnails are encrypted
`bytea` **inside the `vault_items` row**, so every grid tile costs a decrypt.
That is why wheels appear on the grid, the pager and while scrolling.

Copy the chat pipeline, which is the working reference:
`core/media/media_decode.dart` (shared decode widths — **cache-key identity is
the whole trick**), `core/widgets/net_image.dart` (`thumb`, `decodeWidth`, never
`memCacheHeight`), `core/media/thumb_backfill.dart` (heal-on-read),
`features/chat/widgets/media_viewer.dart` (progressive thumb→full, neighbour
`precacheImage`, unconditional Hero).

`vault_media_cache.dart` already has isolate decrypt + dedup. Needs: thumbnails
as separate storage objects, decrypt-to-disk cached by item id, progressive
display, neighbour precache.

### 4b. Google Maps — dead, not fixable in code
Billing account **closed**, "not in good standing", cannot be reopened. Killed
both the 3D map and `google_maps_flutter`. Photorealistic 3D needs Google
billing; there is no free photogrammetry anywhere (Cesium resells Google's).
Mapbox is the ceiling without it. **Do not re-litigate this.**

### 4c. `google_fonts` leak
No bundled font assets → Fraunces + Inter fetched from `fonts.gstatic.com` on
first launch, before login, behind the disguise. Fix: bundle two `.ttf` files.
Needs him to supply them, or accept a system-font fallback.

### 4d. Unverified on hardware
Call **glare** (needs two phones dialling within a second) and **Watch Together**
sync (needs two phones on one video). Logic is unit-tested; the two-device
behaviour is not.

### 4e. Never verified at all
The Mapbox map has **never rendered on a device**. Not once, across the whole
session.

---

## 5. Key escrow — read before touching crypto

`FlutterSecureStorage` is wiped by Android on uninstall, so every reinstall used
to mint a new X25519 keypair, change the ECDH shared secret, and permanently
orphan every encrypted row. That is the `SecretBoxAuthenticationError` on memory
threads, fantasy jar and vault tiles. **The data was never corrupted; the key
was destroyed.**

`core/data/key_escrow.dart` seals the seed and stores it server-side. Server
sees ciphertext, a salt and a nonce only.

**The KDF line above is out of date — read §11 and §11a for the current one.**
It is now `Argon2id(HMAC(password, 'miles/key-escrow/wrap/v2'), salt)` at
m=19456 kB / t=2 / p=1, and every row carries its own `kdf` + `kdf_params` so
hardening the constants later cannot orphan existing rows. The labelled HMAC
buys domain separation and nothing more: **the same password goes to GoTrue in
plaintext on every sign-in**, so anyone holding the password holds the escrow.
The privacy policy states that plainly — do not soften it there.

**`restore` runs BEFORE `backup` in `SupabaseRepository.signIn` — that ordering
is the entire fix.** Backing up first seals the throwaway key over the good one.

Not retroactive: rows under already-destroyed keys stay unreadable.
**Unverified — needs a real reinstall + sign-in to prove the round trip.**

---

## 6. Commands that matter

```bash
cd /e/LDR && flutter analyze mobile      # from ROOT — catches warnings the
                                         # in-mobile run misses, and the
                                         # hygiene test uses this
cd /e/LDR/mobile && flutter test         # 550 passing
cd /e/LDR/mobile && flutter build apk --release --split-per-abi
```

- Always `cd /e/LDR/mobile` before flutter build (CWD drifts).
- **Never build the APK unless he asks, and don't ask whether to.** This line
  used to say "build unprompted once green" and it was wrong: builds take ~5
  minutes, compete with his own Gradle daemon for memory, and he does not want
  them. Leave the work in the tree and say what changed. Installing likewise
  needs an explicit request.
- Repo hygiene tests enforce: 0 analyzer warnings, no translucent surfaces
  behind text (annotate genuine scrims `// scrim over <what>`), unique migration
  ordering keys, disguise intact.

**Logcat** (invaluable — it produced three root causes in one pass):
```bash
adb logcat -c
adb logcat -v time flutter:V chromium:W ActivityManager:I AndroidRuntime:E System.err:W *:E
```
Filter for `I/flutter` — the app's real errors are there, not on screen.

---

## 7. Standing constraints

- Never handle his API keys/tokens — give him the SQL, let him run it.
- Secrets go in `app_secrets` + an edge function, never the APK (pattern:
  `turn-credentials`, `map-token`).
- The launcher disguise ("News", 9 covers) is deliberate. Never revert it.
  There's a guard test; its `_tells` wordlist is easy to slip past.
- Plan for **thousands of users**, not the two test phones. No update channel —
  breaking changes need the server-side version gate.
- E2E encryption stays. If crypto is why something is slow, design around it.
- Verify every checkable claim **before** asserting it. Twice this session I
  reported a diagnosis that was stale or backwards (billing; the flutter_map
  disk cache) and had to correct myself to him.

---

## 8. NEXT JOB — Memory Threads, full redesign (asked 2026-08-14)

Not started. He asked for a redesign, not patches, and was explicit that
piecemeal fixing is the thing he keeps having to correct. **Design the whole
mechanism before writing anything.**

His requirements, verbatim intent:

1. **Attractive alignment / UI.** Current screen is cards with a date, a state
   chip and raw error text. He called it "ugly line up, not well maintained,
   not professionally designed."
2. **Silky smooth — opening, uploading, rendering, closing.** No buffering, no
   loading wheels, no quality drop.
3. **Genuinely shared between partners.**
4. **Delete with BOTH partners' permission** (dual consent). The columns now
   exist — `20260601006600` — but the UI never surfaced it.
5. **Gallery-style preview.**
6. **Multi-select upload, exactly like the chat album flow.**
7. **Expand it** — he wants invention, not just the literal list.

### What is already known about why it is broken

- Photos are encrypted `bytea` **inline in the row** (`photo_cipher`), so every
  card costs a decrypt. Same architectural mistake as the vault.
- `SecretBoxAuthenticationError` cards are rows encrypted under keys destroyed
  by earlier reinstalls (§5). Escrow stops it recurring; **those rows are
  permanently unreadable** and the UI must say so honestly instead of printing
  a crypto exception at the user.
- Delete columns exist and are unused by the UI.

### The reference implementations to copy

- **Media pipeline:** `core/media/media_decode.dart`, `core/widgets/net_image.dart`,
  `core/media/thumb_backfill.dart`, `features/chat/widgets/media_viewer.dart`.
  Cache-key identity is the whole trick — same key AND same decode width, and
  never `memCacheHeight`.
- **Multi-select upload + album grouping:** `features/chat/chat_send_queue.dart`
  (`albumId` when `items.length > 1`), `features/chat/widgets/album_bubble.dart`.
- **Gallery picker:** `core/services/photo_picker_service.dart` — never a bare
  `ImagePicker`, or it opens the file manager.
- **Dual consent already modelled:** `features/closer/private_vault` has
  request → confirm → hard delete with a 14-day escape hatch. Reuse the shape.

### Do not repeat

Thumbnails must be **separate storage objects**, not encrypted blobs in the
row. Generate before encryption, cache decrypted-to-disk keyed by item id.
That is the single decision that makes the difference between the chat pipeline
(fast) and the vault/threads (wheels everywhere).

---

## 9. State at end of session, 2026-08-14

**Build 21** at `E:\LDR\Miles.apk` (93 MB, arm64), sha256
`587b5e0d24dff9370af59798918c009525261aa8962ffd8a0376e75ba883523c`.
NOT installed — the phone was unplugged. Device on build 20.

**The redesign spec is written:** `docs/guides/memory-threads-spec.md`, 1264
lines. Its headline finding is not a UI problem — **a memory proposal fires no
notification at all.** `supabase/functions/` has care-notify, map-token,
reach-notify, turn-credentials and nothing for memories. Nine proposals across
two couples, zero acceptances, because the only way to find one is to open a
disguised app, pass the app lock, find the ninth tile in Closer, and enter a
PIN. Fix the notification before touching a pixel.

Fixed ahead of the redesign, both live:
- **Dual consent was a convention, not a rule.** `memory_threads_delete_member`
  allowed a plain DELETE by either partner — the whole request/confirm flow was
  bypassable with one PostgREST call. Policy dropped, grant revoked, rows now
  leave only via the state machine. Guard trigger makes `proposer` and
  `couple_id` immutable and rejects self-acceptance.
- **17 tables granted DELETE with no DELETE policy.** RLS denied them, but that
  is one layer. Revoked, catalogue-driven so it can be re-run.

Still open, in priority order:
1. Memory Threads redesign — spec is written, implementation not started.
2. Vault read path — same root cause (encrypted bytea inline in the row).
3. `google_fonts` fetches from Google on first launch.
4. Debug signing.

---

## 9b. LANDED 2026-08-14 (evening session) — server side is done

Everything here is **applied to production `sopictusdonlvuezmfep` and verified
live**, not just written. Migrations are applied by name via `apply_migration`;
the repo files are mirrors.

| migration (by name) | repo mirror | what |
|---|---|---|
| `memory_threads_redesign` | `20260601007000` | `memory_photos` + triggers + RLS; parent cover columns; both FK regressions; CHECKs; `storage_reap`; purge cron; index collapse; realtime |
| `revoke_truncate_grants` | `20260601007010` | TRUNCATE/REFERENCES/TRIGGER swept off every public table; default privileges disarmed |
| `memory_consent_rpcs` | `20260601007100` | table UPDATE revoked → 8 SECURITY DEFINER RPCs + a column-grant allowlist; the same DELETE hole closed on 4 more tables |

**The sanity-check audit found a fifth instance of the schema-drift bug** (the
one BRAIN §0 warns about): `afterglow_entries` was missing all six delete
columns. Closed by `20260601007200`.

**Afterglow and Body Map were then removed from the client entirely.** Both
Closer tiles, all three routes and the five files under
`features/closer/afterglow/` and `features/closer/body_map/` are gone.
`closer_crypto.dart` stays — `packFull` reads as afterglow-owned because its
docstring cited `afterglow_entries.photo_a`, but Memory Threads photos and
Vault uploads are its real callers.

The two tables were deliberately **left on the server** with their rows intact
(3 afterglow entries, all carrying inline `bytea` photos; 1 body-map pin). Any
DROP is a separate, sequenced decision: `_guard_dual_consent_delete()` is
attached to `vault_items` and `rituals` as well, so it must survive; and
001400/006300/006400/007100 each carry unguarded statements against
`afterglow_entries`, so after a drop they become replay-in-order-only. Older
sideloaded builds still write to both tables until `app_release.min_build`
is raised.

Also found, latent: `SupabaseRepository.joinCouple` (`:233`) calls
`join_couple_by_code`, dropped by 003200. Zero callers, so it is dead code that
throws PGRST202 the moment anything wires it up. Delete the method.

Two things verified live that are worth knowing:

- **One production row is entirely cleartext.** 24-zero nonce and 16-zero MAC on
  its title, note *and* photo — the `_isLegacy` signature. That photo is
  readable by anyone with database access right now. `memory_heal` re-encrypts
  it as a side effect, and the §3.9 refuse-cleartext guard is what stops heal
  from *propagating* it instead.
- **`TRUNCATE` ignored RLS on `key_escrow`.** Any authenticated user could have
  wiped every couple's sealed private seed — the only copy that survives a
  reinstall — in one statement. Caused by Supabase's default privileges landing
  on tables created after the sweep that revoked it everywhere else. Both the
  grants and the default are now fixed.

**Breaking for installed builds, accepted deliberately:** build 20 updates
`state`/`accepted_by`/`archived_at` directly and now gets 403. All nine
production rows are still `proposed`, so the broken path is one nobody has ever
completed. `memory_revisits` was NOT dropped for the same reason in reverse —
build 20 still writes to it, so only its FK was neutralised; drop the table once
builds have rolled.

Two corrections to the spec, both load-bearing, both found by applying it:

1. **§2.4's widened guard does not compile.** `confdeltype` is `"char"`, and
   `text || "char"` has no unique operator — `confdeltype::text` is required.
2. **§2.4's `proposer` SET NULL would have broken account deletion outright.**
   The referential action arrives as an ordinary UPDATE, so 006800's
   `memory_threads_guard` sees `proposer` go uuid → null and raises
   "proposer is immutable", aborting `delete_my_account`. The guard now permits
   exactly that one transition, one-way.

Also replaced §2.4's `from lateral (...)` cover triggers with correlated scalar
subqueries: an UPDATE's target relation is not reliably visible to a LATERAL
item in its own FROM list, and the cover choice must read `cover_photo_id` off
the row being written.

### The notification — build step 2, DONE

| piece | where |
|---|---|
| `notify_memory()` + `memory_threads_notify` trigger | migration `memory_proposal_notify` / `20260601007300` |
| `kind: 'memory'` | `supabase/functions/reach-notify/index.ts`, **deployed v9**, `verify_jwt` still false |
| `showMemoryNotification` + background-handler branch | `core/services/reach_notifications.dart` |
| `MemoryTap` + foreground/tap branches | `core/services/fcm_service.dart` |
| tap → opens the thread | `features/shell/app_shell.dart` `_onPendingMemory` |
| count dot on the tile | `closer_screen.dart`, fed by `pendingProposalCount` |

Four deliberate departures from spec §7.0:

1. **A database trigger, not a client call.** The insert and the push then
   succeed or fail together. A client that inserts and is killed on the walk
   back — which this app *invites*, because backgrounding raises the disguise
   cover — would otherwise leave a proposal nobody is told about, which is
   exactly the state all nine rows are in.
2. **No new edge function.** `reach-notify` already multiplexes four kinds;
   a second copy of the RS256/OAuth path is a second thing to keep correct.
3. **The push carries no words.** The spec asked for *"She proposed a memory."*
   Every notification in this app is `currentNotificationStyle()` — generic,
   wearing the active disguise — because the launcher is disguised. Putting the
   word *memory* on a lock screen is the same defect as the care reminder that
   once arrived as "News update" on a calculator.
4. **`from_name` omitted, and TTL 86400s.** Nothing renders the name (the
   notification is built on the receiving device), so sending it was the
   partner's real name through Google in cleartext for nothing — the same
   reasoning `call` already used. And a 30 s TTL makes FCM *discard* rather
   than queue, which is precisely how a proposal waits forever.

Careful: `fcm_service.routeFromPayload`'s final branch **assumes reach**, and
`firebaseMessagingBackgroundHandler`'s fall-through **is** the reach branch. Any
new push kind without its own branch in BOTH rings a full-screen alarm carrying
someone else's id. Both branches were added.

### Read path + consent client — build steps 3 and part of 4, DONE

`memory_thread_repository.dart` rewritten: named-column select (no
`photo_cipher`), realtime **delta** on `ManagedSubscription` instead of
`.stream()` re-reading the table on every tick, every mutator now an `rpc()`,
`withdraw` added, revisit API deleted, `pendingProposalCount` added.
`proposer` is now nullable throughout (the FK is SET NULL).

Screen: `Take it back` for the proposer (the state all nine rows are in used to
render an empty action row), `Keep it` shown to **both** partners, delete
reachable from `archived`, `_unarchive` got the busy guard and error handling it
never had, and `'Failed: $e'` is gone — `_friendly()` maps the RPC's three
actionable failures to sentences and everything else to a generic. The delete
dialog no longer claims "cannot be undone" over a column flip; it says erased
within 30 days, which is now true.

### New: the test that would have caught all five

`mobile/test/unit/hygiene/schema_drift_test.dart` + `supabase/schema_snapshot.json`.
Parses every `.from(...).insert/update/upsert/select/eq(...)` and `.rpc(...)` in
`lib/` and diffs against a checked-in dump of `information_schema`. Three checks:
column exists, column is inside the `authenticated` UPDATE grant (a 403 and a
missing column are the same defect to a user), and the RPC exists.

Two traps it fell into first, both worth remembering:
- Ternary values read as keys — `'retention': x ? 'ephemeral' : 'keep'` reported
  a column called `ephemeral`. A key is preceded by `{`, `,` or `)`; a ternary
  branch by `?` or `:`.
- **It passed vacuously.** It looked for `.rpc(` and every call site in this repo
  is `.rpc<dynamic>(`. It now asserts it found >10 calls before believing a
  clean result — the same guard `repo_hygiene_test` uses on `git ls-files`.

It immediately caught `SupabaseRepository.joinCouple` → `join_couple_by_code`,
dropped by 003200, zero callers. Method deleted.

`flutter analyze mobile` 0 errors 0 warnings; `flutter test` 550 passing plus
the 4 new ones.

### The shared media foundation — BRAIN §10 steps 1–4, DONE

| file | what |
|---|---|
| `core/media/encrypted_media_cache.dart` | **new.** L1 ciphertext on disk / L2 plaintext in RAM / L3 ImageCache, plus the 403 owner and `MediaFailure` |
| `core/media/media_decode_queue.dart` | **new.** concurrency 2, `isWanted` re-read at dequeue, id held until completion |
| `core/media/thumbnails.dart` | `deriveImage()` — ONE decode → 1024px cover + 400px tile + EXIF date |
| `core/data/crypto_core.dart` | `keyEpoch` notifier; `decryptBytesOffThread(packed)` with no base64 round trip |
| `closer/memory_threads/memory_photo_repository.dart` | **new.** the three objects, frozen AD, refuse-cleartext, compensating delete |
| `main.dart` | one listener on `showRealApp` drops all plaintext when the cover goes up |
| `session_provider.dart` | sign-out also drops the ciphertext layer |
| `memory_threads_screen.dart` | `_MemoryCover` — the first real consumer |

Decisions that differ from spec §3, each for a reason:

- **It lives in `core/media/`, not the memory feature.** BRAIN §10 is explicit
  that the vault and Memory Threads share one foundation; a
  `memory_media_cache.dart` would be copied into the vault within a week and the
  copy would drift on exactly the cache-key discipline that makes it fast.
- **L2 is bounded by BYTES (48 MB), not by per-role entry counts.** A 400px tile
  and a 12-megapixel original differ by three orders of magnitude, so "96 tiles,
  3 fulls" is a budget that is either far too loose or far too tight depending
  on what was opened. A byte ceiling self-balances.
- **The disk layer holds ciphertext and is NOT cleared on a cover raise.** It is
  unreadable without the key, and re-downloading a couple's whole timeline every
  time they glance at their phone is a lot of traffic to protect nothing.
  Sign-out clears it; the cover raise clears only plaintext.
- **`photo_nonce` is now in the select list** (24 bytes a row) while
  `photo_cipher` is not. 007000's pair CHECK makes the nonce an exact, nearly
  free predicate for "this row still has a legacy inline photo". Without it the
  named-column select silently makes every legacy photograph invisible — I
  introduced that regression and this closes it.

Non-obvious things now pinned by `test/unit/media/encrypted_media_test.dart`
(17 tests): a COPY of the same bytes is a different `MemoryImage` key, so the
cache must return the identical instance or every hand-off silently re-decodes;
`ResizeImage(m, width: w)` and `ResizeImage(m, width: w, height: w)` are
different keys, which is why height is never passed; the cover's bound and the
tile's unboundedness are deliberately non-sharing; and the AD strings are golden
so nobody can change the one thing that destroys all data irreversibly.

**The repo's own dead-code gate caught the foundation before I did** — two new
files imported by nothing. That is the correct complaint: a foundation with no
consumer is not finished, which is why `_MemoryCover` is wired in the same pass.

`flutter analyze mobile` 0/0; `flutter test` **571 passing**.

### Heal-on-read, the vault, and the zoom layer — DONE

**`memory_heal.dart`** migrates a legacy inline photo to `memory_photos` on
read: dwell-gated at 2 s of stillness, one row at a time, ids remembered so a
failure is not retried every scroll frame.

**Upload-then-claim is now enforced by the DATABASE**, not by client ordering.
`memory_clear_inline_photo` (migration `memory_clear_inline_photo` /
`20260601007400`) refuses while no `memory_photos` row exists for that memory.
`thumb_backfill` states that rule the hard way in a comment; here a client that
clears first and uploads second simply cannot destroy the only copy of a
photograph whose key exists on two devices in the world. Verified against
production in a rolled-back transaction:
`clearWithoutPhoto=blocked | afterUpload cleared=t`.

The guard in heal is the load-bearing part and it is **pinned by two tests**.
Subtlety worth re-reading: `decryptBytes` short-circuits on the legacy zero-nonce
signature and returns plaintext *with no key at all*, and one production row is
in exactly that state — so without the guard heal would succeed on it in
plaintext mode, re-upload a cleartext JPEG behind a shareable signed URL, and
then null the evidence. The key check also runs BEFORE the row is marked seen,
so declining does not burn the retry.

**Vault** (BRAIN §10 step 5):
- keys on `CryptoCore.keyEpoch` and clears on a bump. It keyed on a per-PROCESS
  random id, which is stable across exactly the event it needed to notice — so
  after an escrow restore it kept serving files decrypted under the key that had
  just been replaced. The epoch is in the filename too, so a stale file cannot
  be mistaken for a current one even if the delete fails.
- originals decrypt through `decryptBytesOffThread` on the **packed bytes**. The
  old route built an `EncryptedPayload` first, whose fields are base64 strings:
  +33 % allocation and two extra full passes over a 4 MB blob, per view.
- previews decrypt inline — `compute` spawns an isolate per call, which costs
  more than the work.
- **both `Image.file` call sites were unbounded.** A grid tile decoded the
  preview at source resolution; the viewer decoded a 12-megapixel original at
  full size to fill a screen that shows a tenth of it. Now `kTileDecodePx` and
  viewport width, width only.

**`kZoomUpgradeScale` finally has a call site.** It and `kZoomRevertScale` sat in
`media_decode.dart` with a test asserting their order and zero widgets using
them. Bounding the viewer's decode is what made them necessary — otherwise
pinching to 4× would now magnify a viewport-width bitmap. Above 1.5× the vault
viewer mounts the unbounded image, below 1.2× it drops back; the two thresholds
differ so jitter at the boundary does not mount and unmount a full-size decode
every frame. The upgrade costs one decode and no network — the bytes are already
decrypted and resident.

`flutter analyze mobile` 0/0; `flutter test` **573 passing**.

### Chat zoom + PIN recovery — DONE

**Chat's viewer got the zoom layer too.** `media_viewer.dart`'s own comment
above `decodePx` has promised it since the decode work — *"zoom is served by a
separate layer that is mounted only while pinched"* — describing something that
did not exist. Above 1.5× it now mounts an unbounded `CachedNetworkImage` on the
same `cacheKey` (so the disk cache is untouched; only the decode differs), below
1.2× it drops back. **Only the page with `full == true` upgrades** — the pager
builds ±1, and letting neighbours react to the current page's pinch would be
three full-size decodes for one gesture.

**PIN recovery.** `clearAppPin` finally has a call site.
- **Forgot PIN** re-authenticates with `signInWithPassword` against the current
  user's email before clearing. Required, not offered: without the password,
  "forgot my PIN" is a button that removes the lock.
- **Confirm-entry on setup.** You used to type four digits once and that was
  your PIN forever — a typo you could not have noticed, guarding data whose only
  other key is on a device you might reinstall.
- `tryBiometricOrRequirePin` **deleted** — it returned `authenticateBiometric`'s
  result unchanged behind a name promising it handled the PIN. Zero call sites.

**Still 4 digits, deliberately, and this reverses the spec.** §6.4 wants 6
shipped in the same commit as Forgot PIN. But widening invalidates every PIN
already set — the stored hash is of whatever string was typed, so an existing
user would be asked for six digits and could never enter their four. That was
unrecoverable before today; now that Forgot PIN exists it is merely a forced
reset for everyone who has one, which is a decision to take on purpose rather
than as a side effect. The file's doc claimed 6 while the code did 4; the doc is
now the code, with the reasoning written down.

`flutter analyze mobile` 0/0; `flutter test` **573 passing**.

### The reaper actually deletes now, and vault photos left the disk

Committed to `c5d9f47` was everything up to here. What follows is after it.

**`delete from storage.objects` does not delete a file — it destroys the only
pointer to one.** Verified on this project: `storage.objects` carries a
`version` column and Supabase stores the object at `<bucket>/<name>/<version>`.
That version string lives nowhere else, so deleting the row leaves the bytes in
the backing store, unreachable, still billed, and now impossible to erase.

Two callers were doing exactly that, both believing the opposite:

- `reap_storage_objects()` — mine, from 007000, mirroring 003400. So §5's
  "the encrypted files are erased within 30 days" was false.
- **`delete_my_account()`** — the serious one. It erased a couple's whole media
  library when the last member left, which means **"delete my account" left
  every photograph, video and voice note that couple ever sent on the server,
  permanently.**

Fixed in migration `storage_reaper_actually_deletes` / `20260601007500` plus a
new `reap-storage` edge function (service role, secret-guarded, `verify_jwt`
false because the caller is pg_cron). Postgres now only QUEUES and pokes; the
Storage API does the deleting, because it is the only thing that deletes both
the row and the object. Account deletion inserts into `storage_reap` instead of
deleting rows. Drain runs hourly (`23 * * * *`); the memory purge stays nightly.

Verified end to end against production with a throwaway path:
`{"ok":true,"drained":1}`, queue back to 0, and the 74 real objects untouched.
Note `pg_net` is asynchronous — checking the queue four seconds later still
showed the row; `net._http_response` is where the truth is.

**Vault photographs are RAM-only now.** `photoProvider` / `photoBytes` hold
plaintext in memory keyed by epoch, hand out `ImageProvider`s, and evict from
`ImageCache` on drop. The grid tile and the viewer both use them; the viewer's
zoom layer builds its unbounded provider from the same resident bytes. Video and
audio keep `getDecryptedFile` because a player needs a path and there is no
streaming decrypt here — that exposure is named, not pretended away.

Two things found while doing it:
- **The video tile decrypted the preview and wrote it to disk to draw a black
  rectangle with a play glyph.** It never rendered the file. Now it decrypts
  nothing at all.
- `_NotePage` rendered `'Could not decrypt: $e'` — a MAC failure showed
  `SecretBoxAuthenticationError` to whoever opened the note.

`flutter analyze mobile` 0/0; `flutter test` **573 passing**.

### Still open
2. **The `MemoryFailure` classification** (spec §6.6). The stream error, the
   empty-vs-unreadable split and every `'Failed: $e'` on the lifecycle paths are
   fixed, but a per-row decrypt failure still has no `KeyGoneForever` /
   `KeyNotYetShared` / TOFU-mismatch copy, and there is no TOFU pin.
3. **6-digit PINs**, now safe to do — see above for why it was not bundled.
4. Multi-select composer + persisted queue, gallery pager, timeline redesign,
   visit linking, authored acceptance.
5. Multi-select composer, gallery pager, timeline redesign, visit linking,
   authored acceptance — the largest remaining block.

### LIVE REGRESSION FOUND AND FIXED — 006900 revoked DELETE from six tables

`20260601006900`'s predicate was `left join pg_policy p on … and p.polcmd = 'd'`.
**`polcmd='d'` matches only a `FOR DELETE` policy. A `FOR ALL` policy is
`polcmd='*'` and covers DELETE too** — so every table whose delete permission
came from a FOR ALL policy looked identical to a table with no delete policy.
Six were stripped: `personal_vault_items`, `vault_pin`, `cycle_events`,
`cycle_logs`, `cycle_settings`, `call_signals`. `love_reasons` and
`intimacy_signals` survived only because they happen to be written FOR DELETE.

**`vault_repository.dart:98` deletes from `personal_vault_items`, so "delete
from vault" had been failing in production since that migration shipped.**
006900's commit claimed "Verified after: 0 tables remain in that state" — it
re-ran the same wrong predicate, so it confirmed nothing.

Fixed in `restore_delete_and_seal_vault_pin` / `20260601007600`, which also
closes a second hole in the same table: `verify_vault_pin` implements a real
bcrypt lockout (5 strikes, 15 min) that was **worthless because `vault_pin_self`
is FOR ALL, so the person being locked out could PATCH their own
`failed_attempts` back to 0.** 004900 wrote that exact reasoning down for
pairing and it was never carried across. Direct DML on `vault_pin` is now
revoked; all three entry points are SECURITY DEFINER and unaffected.

Verified live, rolled back:
`vaultDelete=works | resetCounter=blocked | hasVaultPin=works`

### BUILD 24 — built 2026-08-15. THE ONE TO INSTALL. Not installed yet.

`E:\LDR\Miles.apk`, one universal APK, 218.5 MB (229,161,936 bytes),
sha256 `7ce2be53f97be4d3b31ffd2b15c626803ee5af74721104453a84710e8a8af694`,
versionCode 24, arm64-v8a + armeabi-v7a + x86_64.
Gate: `flutter analyze mobile` 0/0, `flutter test` **615 passing**.

Everything in 23, plus everything 23 was missing:

| what | why it matters on a device |
|---|---|
| Gallery dual-consent delete + multi-select | long-press to select, "ask to delete", partner answers the whole set |
| Delete-request limit (3 refusals settles it) | stops the same picture being raised every evening |
| **Video posters and a real player** | videos had NO poster and NO player — a tile handed an .mp4 to an image widget, which can never paint |
| Daily routine chart ("Today") | seeded 10 routines, custom add, long-press remove, resets by date |
| **Map pin** | drew a Maki sprite the STANDARD_SATELLITE style does not carry, so the pin rendered nothing, silently |
| Watch Together fix (other session) | youtube_player_flutter past an upstream int.parse bug; a real play button |

**Test in this order, because each depends on the last being true:**
1. Gallery — does a tile paint at all? (never verified before 23)
2. A video — poster on the tile, then does it play?
3. Map — is there a dot on her position, not just her city centred?
4. Today — does the chart seed, tick, and show her column?
5. Memory Threads — "Take it back" on your own pending proposal.

**Raise the gate only AFTER installing**, or you lock out the device that needs
the install:
`update app_release set min_build = 24, latest_build = 24;`

Still debug-signed. Sideload only, not a market build.

### BUILD 23 — superseded by 24

`E:\LDR\Miles.apk`, one universal APK, 218.5 MB (229,162,033 bytes),
sha256 `1564a80b662d1508c688dfbe79c773843470d288e5fd6da9b913e1a37c6820ed`,
versionCode 23. Gate: `flutter analyze mobile` 0/0, `flutter test` 564 passing.

Carries: the six hardening streams (chat sending/failed + persisted queue,
server-side reach rate limits + mute, ErrorReporter → `client_errors`, proguard
wired, empty-catch sweep, MemoryFailure classification) and **the new shared
gallery**.

**The Closer tile now opens `/app/gallery`, not the vault.** Without that the
gallery was unreachable and the build could not test the one thing it was built
for. The vault ROUTE still exists (`/app/closer/vault`) so the couple's existing
encrypted items remain reachable — nothing has migrated them yet.

**Gallery is unverified on hardware.** It analyzes clean and 564 unrelated
assertions still hold; no photograph has been shown to appear. Given the Mapbox
map has never once rendered on a device in this project, treat "compiles" as
very weak evidence for a rendering feature. What to check first: does a tile
paint, does the pager swipe without a spinner, does a partner's upload appear
without a refresh.

### BUILD 22 — superseded by 23

`E:\LDR\Miles.apk`, one universal APK, 218.4 MB (228,981,716 bytes).
sha256 `a068b8cd4601c79aa76340518d0615bab459a66b51789ca9cdfd9616c2081bce`.
versionCode 22, package `com.miles.miles`, minSdk 24, targetSdk 36,
ABIs arm64-v8a + armeabi-v7a + x86_64. Gate before building: `flutter analyze
mobile` 0/0, `flutter test` 573 passing.

**Two things must happen together, in this order, or users break:**

1. Install build 22 on every handset that matters.
2. THEN `update app_release set min_build = 22, latest_build = 22;`

The gate currently reads `min_build = 2`, which waves every old build straight
through — and today's `memory_consent_rpcs` revoked the table-level UPDATE that
build 20 uses for accept/archive/delete, so build 20 now 403s on those with no
forced-update prompt. Raising the gate BEFORE installing locks out the device
that has to receive the install.

### The industrial-readiness gap list (audited 2026-08-15, evidence attached)

Ranked by what hurts a real user base first. Nothing here is speculative.

1. **Chat silently loses messages.** `chat_screen.dart:145-149` swallows a failed
   `sendText`; the optimistic bubble lives only in an in-memory `List` (no
   sqflite/hive/drift/isar in `pubspec.lock`), so it dies with the widget. Worse,
   `_MsgStatus` (`:1691`) has no `failed`/`sending`, and `_rawStatusFor:819`
   returns `sent` for `seq <= 0` — **a message that never reached the server
   renders with the same tick as one that did.** Voice notes are worse:
   `chat_input_bar.dart:346-351` has no catch at all, so the throw lands in
   `main.dart`'s handler, the recording is gone, no bubble, no error. The media
   path next door does this correctly (`chat_send_queue.dart:234` +
   `chat_screen.dart:2314` "Didn't send · tap to retry") — text was just never
   given it.
2. **No observability whatsoever.** `Diag` is dead code: `_enabled` defaults
   false and is only ever set true by `resetForTest`, so **all 75
   `Diag.record` call sites are no-ops** — including the realtime subscribe
   status, the socket-flap counter, and `push_msg_received`. `main.dart:44-51`
   catches Flutter and platform errors and only `debugPrint`s them. No
   Crashlytics/Sentry/Bugsnag in `pubspec.yaml`. On a sideloaded fleet with no
   cable attached, **you cannot know the app is broken for anyone.**
3. **Zero backups.** Plan is `free` (region ap-south-1): no PITR, no dashboard
   backups, and no `pg_dump`/export script anywhere in the repo. Current RPO is
   total loss. Note DB backups never cover Storage objects (471 MB) even after
   upgrading.
4. **309 commits, 0 remotes, 0 tags.** Everything exists on one disk with no
   offsite copy, and build 22 was built from a dirty tree (HEAD `b6b309d` still
   reads `0.1.0+21`), so no build maps to a commit and none can be reproduced.
5. **A secret ships inside the APK.** `pubspec.yaml` declares `.env` as an
   asset; `assets/flutter_assets/.env` is in `Miles.apk` and contains
   `GIPHY_API_KEY`. (Supabase URL + anon key there are fine — public by design.)
   No `--dart-define` anywhere: `String.fromEnvironment` has zero hits.
6. **Rate limiting exists for pairing and nothing else** — no throttle on
   `reach_events`, `care_nudges`, `messages`, `call_invites`, or signed-URL
   minting.
7. **`proguard-rules.pro` is dead config** — `proguardFiles` appears nowhere in
   gradle, while `build.gradle.kts:83` claims it is "written and ready". Flipping
   `isMinifyEnabled` today applies R8 defaults only and produces exactly the
   WebRTC/ML Kit reflection crashes the comment says it avoids.
8. **`.env.example` has drifted** — it documents `NEXT_PUBLIC_*` and
   `GOOGLE_MAPS_3D_KEY`, and omits `GIPHY_API_KEY` and the `METERED_TURN_*` trio
   the code actually reads via `maybeGet(...) ?? ''`. A fresh build machine
   following it ships with Giphy dead and the TURN fallback missing, silently.
9. **No block, mute, or report — and Reach is an unbounded screen-waking
   channel.** The only cooldown is `State` in `reach_button.dart:20-46`: client
   side, reset by a restart, bypassed entirely by posting to PostgREST.
   `reach_events` has one trigger straight to a high-priority full-screen-intent
   push. Zero hits for block/mute/report anywhere in migrations or `mobile/lib`.
   A partner who turns hostile has an unlimited way to wake the other's screen,
   plus live location, and the only remedy in the app is dissolving the
   relationship. **For an intimacy product this is the largest design-level
   gap**, and it is not a crypto problem.
10. **`messages.body` is plaintext, and so is location and cycle data** — while
    `vault_items`, `memory_threads`, `afterglow_entries` and
    `fantasy_jar_entries` are all bytea ciphertext with working `partner_keys` +
    `key_escrow` sitting right next to them. `presence.latitude/longitude` is
    populated at ~32 m accuracy; `cycle_logs`/`cycle_events` are GDPR Art. 9
    special-category data in the clear. `presence.current_screen` is
    partner-surveillance telemetry with no feature behind it. Chat is the
    highest-volume intimate surface in the app and the one users would most
    assume is covered by the encryption the product advertises.
11. **118 empty catches swallow user writes** (e.g. `vault_screen.dart:76`
    `catch (_) {}` around `addNote`), and 16 screens render raw exceptions —
    `fantasy_jar_screen.dart:102`→`:213` prints
    `Failed host lookup: 'sopictusdonlvuezmfep.supabase.co'`, leaking the
    backend host to the user.
12. Accessibility and localisation are unaddressed (hardcoded English, hardcoded
    font sizes).

**It is debug-signed, and that is disqualifying for a market release.** Proven,
not assumed — `apksigner verify --print-certs` reports
`Signer #1 certificate DN: C=US, O=Android, CN=Android Debug`, SHA-1
`a1057947088b7a214bdac3c2be95b303957464c7`. The debug keystore's password is the
documented string `android`, so anyone can re-sign this APK and it will install
over the real one as an update. Play also rejects it outright. `key.properties`
does not exist; `build.gradle.kts` falls back deliberately and logs a banner.
Nothing about the code fixes this — it needs a keystore.

### Heads-up: this tree had a second writer

Mid-session, files nobody in this session touched changed underneath it —
`crypto_core.dart` (+51 lines making `deriveSharedKey` **fail closed** rather
than silently downgrading to plaintext on a malformed partner key: a genuinely
good change, and it complements §3.9's refuse-cleartext guard), plus
`config.dart`, `key_escrow.dart`, `vault_media_cache.dart` and four disguise
covers. `schema_drift_test.dart` was moved to `docs/guides/wip/` as a `.draft`
and has been copied back into the test tree; the draft was left in place rather
than deleted. Nothing was reverted. If two sessions are running on `E:\LDR`,
they will fight over `memory_thread_repository.dart` next.

---

## 10. IMPLEMENTATION ORDER — read before touching either spec

Two specs exist:
- `docs/guides/memory-threads-spec.md` (1264 lines, complete)
- `docs/guides/vault-read-path-spec.md` (813 lines, complete)

**They have the same root cause and must not be implemented twice.** Both store
encrypted media as `bytea` INLINE in a database row, so every tile costs a
decrypt before it can paint. That single decision is why both features show
loading wheels everywhere while chat does not.

### Build the shared foundation FIRST

Neither feature works properly without it, and building it twice is how the two
drift apart:

1. **Encrypted thumbnail as a separate storage object.** Generated BEFORE
   encryption, encrypted with its own associated-data binding, uploaded as
   `application/octet-stream` to `couple_intimate`. Note: that bucket has
   SELECT/INSERT/DELETE storage policies but **no UPDATE policy**, so
   `upsert: true` returns 403 — either add the policy or never upsert.
2. **Decrypt-to-disk cache keyed by item id**, with an explicit security policy.
   This is plaintext on a device whose entire premise is that nothing is
   readable: decide when it is written, when wiped, and whether it survives the
   app lock, backgrounding, the disguise cover, sign-out and an adb backup.
   `vault_media_cache.dart` already has isolate decrypt + in-flight dedup and is
   the right place to grow this.
3. **Honest presentation of unreadable rows.** Rows encrypted under keys
   destroyed by pre-escrow reinstalls can never be read. The UI must say that
   plainly instead of printing `SecretBoxAuthenticationError` at the user.
4. **Cache-key identity**, copied from `core/media/media_decode.dart`: same key
   AND same decode bounds, and `memCacheHeight` never set anywhere. Two surfaces
   painting one object must produce ONE `ImageCache` entry or every hand-off
   silently starts from scratch. This is the trick that makes chat fast.

### Then, in this order

5. **Vault read path** — smaller surface, no new UX, proves the foundation.
6. **Memory Threads** — needs the foundation plus a notification edge function,
   multi-select upload, dual-consent delete UI, and the timeline redesign.
   **Do the notification first.** Nine proposals produced zero acceptances
   because nothing tells the partner a proposal exists; a beautiful timeline
   nobody knows to open changes nothing.

### Sanity check before starting

Run the audit that would have caught four of this session's bugs — every column
name the repositories write, diffed against `information_schema`. All four were
client code shipped against a schema that was never applied, and none were
catchable by `flutter test`.

### 10a. Traps the vault spec found — do not step in these

Its own critique pass caught twelve defects in the first draft. Four would have
shipped a broken app, so they are recorded here rather than left inside an
813-line document:

- **A named-column SELECT must still include `ciphertext`.** `VaultItem.fromJson`
  starts with `byteaToBytes(json['ciphertext'])`, and `byteaToBytes(null)`
  throws. Drop the column to save bandwidth and every row fails to parse, the
  screen counts them unreadable, and an intact vault renders as EMPTY.
- **Do not put a column list on the realtime publication.** `SupabaseStreamBuilder`
  replaces a cached row wholesale with `payload.newRecord`; without `ciphertext`
  that throws and the row silently disappears. It would break build 14, which is
  on both handsets, with no update channel to fix it.
- **`storage.objects` has a `protect_delete` BEFORE DELETE trigger** that raises
  42501 on any direct delete. A server-side reaper cannot work; the existing
  client-side `storage.remove()` is the mechanism and must not be removed.
- **`deriveSharedKey` is NOT idempotent** despite a comment saying so — it
  recomputes ECDH+HKDF and reassigns on every call, and there are 12 call sites.
  Any cache keyed on a "key epoch" bumped per call thrashes on every navigation.

Two live bugs it surfaced in passing, unrelated to the redesign:

- **Plaintext downgrade is still open.** `deriveSharedKey` returns *normally*
  with `_sharedKey = null` on a malformed partner key, and `encryptBytes` with a
  null key emits zero-nonce/zero-MAC CLEARTEXT. A corrupt partner key silently
  turns encryption off.
- **One vault row (`f9853e45`) has a 16-byte ciphertext** — an empty payload that
  passes the length guard. No read path handles it.

## §11 Pre-ship audit — 2026-08-15 (build 21)

7-dimension multi-agent audit + adversarial verification. 6 findings confirmed,
0 refuted, 29 lower-severity findings left unverified (not investigated).

**Server (live, no rebuild):**
- `_memory_cover_sync()` now sets `cover_photo_id`. It never did, so the AD string
  for the cover decrypt could not be built and every healed memory was a blank
  tile forever. Its own ORDER BY tiebreak read that same unwritten column.
- `dice_tier_consents` INSERT/UPDATE/DELETE now require `user_id = auth.uid()`.
  They were couple-scoped only, so either partner could forge the other's consent
  to an explicit tier. SELECT stays couple-scoped by design.
- `key_escrow` gained `kdf` + `kdf_params`, defaulting to `hkdf-sha256`.

**Client (build 22):**
- Escrow wrapping key is Argon2id (m=19456 kB, t=2, p=1 — OWASP baseline),
  off-isolate via `compute`. Was HKDF-SHA256: ~2 HMAC ops per guess, so a table
  dump cracked any human password offline. `restore` dispatches on `kdf` and
  re-wraps legacy rows in place on the sign-in that opens them.
- X25519 seed is now stored per account (`miles_x25519_priv_v1_<uid>`).
  It was device-wide, so account B on the same handset inherited A's private key,
  published A's identity as its own and escrowed it under B's password.
  `bindAccount` claims the pre-migration seed for the FIRST account to bind and
  no other; `forgetAccount` on sign-out clears memory only. **Deliberately does
  not delete the seed** — anyone without an escrow row has no other copy.
- Background FCM guard now allows `type == 'memory'`. The memory branch existed
  and was unreachable, so proposal pushes only ever fired with the app open.
  This is the SECOND time this guard shipped missing a type ('message' was first).
- Memory photo viewer reads the storage object when `coverPath != null`.
  `MemoryHeal` (wired at memory_threads_screen.dart:584) nulls the inline copy,
  and `decryptPhoto` returns null without throwing — a black screen with no error.
  Null bytes now always set an error string.

**Cleanup:** removed dead `GOOGLE_MAPS_3D_KEY` (was shipping in the APK — REVOKE
it in Cloud Console, builds 13/14 leaked it), 3 unused deps incl. `webview_flutter`,
8 dead symbols, 7 dead imports, orphaned `assets/emoji/heart.json`, 178MB of stale
root APKs.

**Still open:** the 29 unverified findings; advancement ideas recorded in the audit
(recovery-code escrow instead of password-derived; envelope-encrypt the couple key
so identity rotation stops destroying history; `app_release.flags` kill switch for
destructive client migrations like MemoryHeal; push-type registry instead of the
hand-maintained allowlist that has now failed twice).

### §11a Second pass — the 28 unverified findings, verified 2026-08-15

21 confirmed, 6 refuted. **5 fixed, 16 still open.**

**Fixed (server, live):**
- Dual-consent guard trigger on `vault_items`, `afterglow_entries`, `rituals`.
  The consent check was a client-side `if` plus a plain PATCH; either partner
  could destroy shared content alone. Done as a BEFORE UPDATE trigger, NOT by
  revoking UPDATE + RPCs as proposed — a revoke 403s the delete buttons on every
  installed build, and there is no update channel. 14-day window now uses the
  SERVER clock (the client derived it from DateTime.now(), so moving the handset
  clock skipped the wait). Verified: unilateral delete raises 42501.
- `presence` INSERT/UPDATE now constrain `couple_id`. They checked only user_id,
  so a user could write presence + coordinates into another couple's feed.

**Fixed (client, build 22):**
- Turning location sharing off now nulls the coordinates. `setSharingMode` wrote
  only the mode, leaving the last precise fix readable by the partner.
- `prompt_responses` upsert gained `onConflict: 'prompt_id,user_id'` — the
  conflict target was the surrogate key, so editing an answer never replaced it.
- Reach notification payload strips `|` from the display name (delimiter
  collision routed the tap nowhere).
- `updatePassword` now re-wraps the escrow. It was left sealed under the old
  password — the one a reset flow means the user has forgotten.

**STILL OPEN (16 confirmed, unfixed).** High: escrow prompt seals under an
unverified password (typo = unopenable row, and the one-shot flag is spent
before the seal); failed chat text insert renders as delivered with no retry;
personal vault swallows read AND save errors. Medium: account deletion orphans
storage objects; AD is the bare author uuid in 3 features (ciphertexts
interchangeable between rows); all-zero nonce/MAC accepted as authenticated
plaintext on every read path; vault temp plaintext not purged on process death;
vault pager prefetches whole VIDEOS; vault photo spinner despite cached preview;
filmstrip decode bounds differ from grid; recycled memory card shows previous
cover; vault + afterglow render "empty" when rows are merely unreadable;
media send queue is memory-only.

**DO NOT apply the proposed fix for the realtime inline-photo finding** (drop
columns from the publication via a column list). A column list on the realtime
publication is the exact trap recorded in §10a that made rows silently vanish
and broke build 14 on both handsets. Drop the legacy columns outright once heal
has migrated everything instead.

### §12 Watch Together — the X embed rewrite, reverted 2026-08-15

**Build 26 shipped a regression I introduced and could not test.** `_rewrite()`
in `watch_source.dart` turned x.com/status links into
`platform.twitter.com/embed/Tweet.html?id=<id>`. That URL is internal — it is
what widgets.js fetches *with* `origin` and `widgetsVersion` params, and on its
own it 404s. Result: X went from "plays, but the controls eject you" to "Not
found". His words: *"previously X is working atleast on my screen but this time
it's worst, nothing is showing."*

Reverted: the rewrite block and `_tweetId()` are gone from `watch_source.dart`,
and the 5 `_xEmbedTests()` with them. **Do not reintroduce an embed URL for X
without loading it in a real WebView first.** A URL you cannot open is a guess.

**Kept from that pass:** `_refused()` in `watch_viewer.dart` is now throttled to
once a minute, and its "Open in browser" uses `source.original`. These pages fire
an app handoff on *every* touch of the player — unmute, scrubber, fullscreen — so
the unthrottled version showed a snackbar per tap. That is what made the controls
feel dead and made "open in browser" look like the only thing that worked.

**The unfixed part, stated honestly:** x.com in a WebView still has no sound and
its controls still fire `intent://`. The viewer refuses those by design (that
refusal is what keeps the evening in the app), so the controls will keep doing
nothing. This is not fixable by rewriting URLs.

### §12a Screen share — the actual answer to "watch the exact same video"

Two WebViews on two phones are two independent browsers with two cookie jars.
Logging in on one does nothing for the other, so *"one of us logs in and we both
watch it"* is impossible through any in-app browser — that is a property of the
web, not a missing feature. Each partner logs in with their **own** account.

The mechanism that does deliver it is **screen share on the existing call**:
one phone captures its screen, the other sees the same pixels. No second login,
no sync protocol (there is one stream), and it works for any site or app.
`flutter_webrtc` already ships `getDisplayMedia` — verified in
`lib/src/native/mediadevices_impl.dart:53`.

Known ceilings to state up front rather than discover: DRM apps (Netflix, Prime,
Disney+) render black to a capture; internal audio needs Android 10+
`AudioPlaybackCapture` or she sees the video and hears only your voice; and
capture is whole-screen, so the vault, the disguise cover and notifications are
all in frame.

### §12b Screen share — built 2026-08-15

One partner captures their whole display into the existing call; the other sees
the same pixels. `getDisplayMedia` → `replaceTrack` onto the **already-negotiated
camera sender**, because this class has no renegotiation path at all — a second
track would never reach the far side. Partner is told via a fifth broadcast kind,
`screen`, so their renderer letterboxes instead of cropping.

`android/AndroidManifest.xml` (FOREGROUND_SERVICE_MEDIA_PROJECTION + service type
`microphone|camera|mediaProjection`), `call_foreground.dart` (`callServiceTypes`,
`addScreenShare` — the service is **stop+started**, not updated, because
`updateService` cannot change `serviceTypes`), `call_controller.dart`,
`call_screen.dart`, `call_pip.dart`.

**No Kotlin was needed.** flutter_webrtc ships its own `ScreenRequestPermissionsFragment`
and registers the Android-14 `MediaProjection.Callback` itself.

**Layout bug caught before shipping, and worth remembering.** The share button made
the control row **six** 60dp circles = exactly 360dp, the full width of the common
phone. Measured, not guessed: fits at 360dp with *zero* gap, **overflows at 320
and 340dp** — which is also what a 411dp phone becomes when its owner raises
Android's display-size setting. Row → `Wrap`. Guarded by
`test/unit/call/call_controls_layout_test.dart`, which also asserts the plain Row
*would* overflow, so the Wrap cannot be "simplified" away later. This is the third
time a Row has silently clipped a control (gallery consent band, Watch Together
Play). **Widths are measurable — measure them.**

**Skeptic findings, fixed:** `startScreenShare` had no generation check after its
4th await (a teardown landing inside `replaceTrack` re-set `sharingScreen=true`
and sent `screen:on` with a null call_id, which the far side does *not* drop —
letterboxing their NEXT call), and no try/catch around `replaceTrack` while
`_screenStream` was already assigned (a throw left MediaProjection recording with
`sharingScreen=false`, and the next tap orphaned that capture for the life of the
process). `dispose()` now drops the capture too.

**AUDIO — settled from source, do not re-litigate.** `GetUserMediaImpl.getDisplayMedia`
creates `audioTracks` empty at :583 and returns it untouched at :614;
`AudioPlaybackCaptureConfiguration` has **zero** occurrences package-wide. The
shared screen's own sound **cannot** be transmitted. The voice call is unaffected —
only the *video* sender's track is swapped.

The "play it on speaker and let the mic pick it up" fallback is a dead end, also
proven: hardware AEC is ON for SDK>=29 (`MethodCallHandlerImpl.java:259-263`) and
will cancel exactly that. The only lever, `WebRTC.initialize({'bypassVoiceProcessing': true})`,
is **process-global and one-shot** (`utils.dart:29-39` auto-initializes on first
call), so it cannot be scoped to a share — it would remove echo cancellation from
every call for the life of the process, and howl. For watching a video *with*
sound, Watch Together's synced local playback is the right tool: each phone plays
its own audio.

Related trap found while verifying: audio constraints are only read under
`mandatory`/`optional` (`MediaConstraintsUtils.parseMediaConstraints`). A flat
`{'audio': {'echoCancellation': false}}` parses to EMPTY and silently discards the
platform defaults too. `'audio': true` must stay a bare bool.

**Still device-only:** that `startForeground(microphone|mediaProjection)` succeeds
at the escalation moment. Nothing in source settles it.

### §12c Watch Together — fullscreen and close, fixed 2026-08-15 (build 27)

**Fullscreen was three bugs stacked.** A YouTube link renders through
`YoutubeWatchPlayer` → a bare `YoutubePlayer` with **no `YoutubePlayerBuilder`**
anywhere in the app. That package's `toggleFullScreenMode()` does exactly one
thing — `SystemChrome.setPreferredOrientations([landscapeLeft, landscapeRight])`.
It does not resize, reparent or hide anything; `YoutubePlayerBuilder` is the part
that swaps the tree, sets immersive mode and wires the back button, and it was
absent. So:

1. The AppBar, the paste field and the footer kept painting over the "fullscreen"
   video.
2. `_PlayerHost` was the ONLY branch of that if-chain not wrapped in `Expanded`.
   A Column hands an unflexed child unbounded height, so the package's 16/9 box
   demanded ~450dp against the ~150dp landscape leaves — the player was clipped
   from the bottom, and the clipped region is exactly where the package draws its
   control bar. **The exit-fullscreen button was rendered off-screen. That is why
   it was stuck.**
3. Nothing ever restored portrait. The app has no orientation policy at all
   (zero `SystemChrome` calls in `lib/` before this), so one tap left the whole
   app sideways for the rest of the session — popping the route did not undo it.

Fixed without adopting `YoutubePlayerBuilder` (which would have meant hoisting it
above the Scaffold and threading its player back down, and would only have helped
YouTube): **landscape IS fullscreen** — same rule the package's own builder uses —
so the AppBar/drawer/paste row/footer drop out, the player is `Expanded`, a
`PopScope` makes back the way out, and `dispose()` releases the orientation lock
with `setPreferredOrientations([])` rather than pinning portrait. Works for every
player kind, not just YouTube.

**Close-for-both was also two bugs.** `_restore()` began
`if (!mounted || session == null) return;` — a deleted row and "nothing to
restore" are indistinguishable to that line, so the host closing did nothing on
the partner's phone. And `watch_sessions` has RLS on with **no
`REPLICA IDENTITY FULL`**, so the DELETE event is not guaranteed to be delivered
at all. Now: a `close` broadcast (reliable while both are on the screen) sent
BEFORE the player is torn down, so build 26 — which resolves an unknown intent to
`beat` — reads an accurate beat and ignores it instead of seeking to 0; plus the
row delete, which `_restore` now acts on, for the partner who arrives later.

**Mistake to not repeat:** I ran `dart format` on `watch_together_screen.dart`.
This repo is NOT dart-formatted (verified against HEAD), so that added ~90 lines
of pure whitespace churn to an otherwise small diff. Do not run `dart format`
here.

### §13 Partner Rewrap — skeptic round 2, fixed 2026-08-15

Round-1 verdict FAIL → 12 findings fixed → round-2 re-verify: 10/12 PASS,
1 FAIL (H3) + 2 new highs (N1, N2). All three now fixed:

- **H3 (real fix this time):** the current-key exclusion in `adoptRetiredKeys`
  read `_sharedKey`, which is null on the entire claim path — the guard was
  dead code. `claim()` now calls `deriveSharedKey` BEFORE adopting, so the
  disaster shape (chain whose only key is the already-rotated one) counts
  added == 0 and the screen refuses to say "your history is back" over it.
- **N1:** the 15s poll ran `claim()` ~40×/window and its blanket catch tore the
  ceremony down on any dropped packet, then told the user "start again" — into
  the 60s rate limiter. Now only `SecretBoxAuthenticationError`/`ArgumentError`
  abort; everything else retries silently (claim is idempotent up to the delete).
- **N2 (archive-fatal chain):** `open()`'s failure path released a hold it did
  not create — rate-limited second tap destroyed the FIRST request's publication
  guard; opening Closer then rotated the key. Now captures the prior hold and
  restores it on failure.
- **N3/N4:** `_rewrapOpen` re-checked after awaits (two stacked screens claiming
  over each other); all screen exits use pop-when-pushed so AppShell's offer
  flag actually resets.

**CONCURRENT SESSION WARNING, verified twice:** another session is editing this
tree at the same time — it moved `android:label` out of `<application>` (its own
comment says deliberate), added `ServerClock.observe` inside `PartnerRewrap.open`
(good fix: presence never feeds the clock on the pre-shell path), added
`deferRecovery()` + a "Not now" button to `rewrap_screen`. Two of my edit scripts
aborted safely on drifted anchors. Full-suite failures in disguise/manifest/
sync_state/permissions_bootstrap belong to THAT session's in-flight work, not
rewrap. Verify which failures are yours before fixing anything.

Migration 20260601008700 is APPLIED to production (verified live: 4 policies,
column-grant-only UPDATE, rate case, trigger, realtime). Staging not touched.

---

## §12 Audit fixes — end state, 2026-08-15

Full audit: `docs/guides/PRODUCTION-AUDIT-2026-08-15.md`. Release procedure:
`docs/guides/PLAY-RELEASE-RUNBOOK.md`. Everything below is UNCOMMITTED in the
working tree; HEAD is still `a650c1f`.

**Gates, actual output at end of session:**
- `flutter analyze` → exit 0, 473 issues, **0 errors, 0 warnings**
- `flutter test` → **692 tests, All tests passed!**, exit 0

**Applied to prod `sopictusdonlvuezmfep` (9 migrations, local files match versions):**
deliver_rituals worker (171 successful cron runs) + a catch-up loop so a ritual
that slips >1h is not trapped forever; pairing invites consumed on leave_couple
and redeem refuses dissolved couples (0 live codes on dead couples, 5 dissolved
couples existed); 20 FK indexes on the delete_my_account cascade; RLS initplans
and duplicate cycle SELECT policies merged; couples UPDATE narrowed to
name/anniversary_date/modest_mode/primary_tz; orphaned notify_care_nudge dropped.
Performance advisor now returns only `unused_index` INFO.

**Edge functions:** care-notify → 410 tombstone (was anon-reachable, no secret,
acted on caller-supplied couple_id); turn-credentials → 401 for anon + real
auth check; reach-notify/reap-storage fail CLOSED with constant-time compare;
account-delete deployed for the Play-required web deletion path.

### TWO THINGS ARE STAGED, NOT DONE — read before touching escrow

1. **The escrow wrap-key fix is half-shipped ON PURPOSE.** Build 27 READS the
   new `argon2id-v2` format but still WRITES `argon2id`. Flipping the write now
   would brick recovery for every phone still on build 26: it cannot open a v2
   row, mints a stand-in seed, and seals the stand-in over the real one. Order
   is the protocol in `release_gate.dart` — ship 27, raise `min_build` to 27,
   THEN flip the write in 28. `min_build` is still **2**.
2. **`ReleaseGate.buildNumber` is now 27 and matches pubspec `0.1.0+27`.** They
   drifted at commit `5d70262` (pubspec went 25→27, gate went 25→26). Nothing
   enforces this; check both by hand every release.

### Still open, and why
- **Supabase org is on the FREE plan.** One couple already uses 520 MB of the
  1 GB storage cap; 200 concurrent realtime connections; auto-pause after ~7
  days idle. Thousands of users is impossible until this is Pro. Payment — user only.
- **No release keystore.** The `play` flavor now FAILS the build without one
  (sideload keeps the debug fallback deliberately). Keystore creation needs a
  password — user only.
- **Maps API key is still live in git history** and cannot be pinned to a release
  SHA-1 until the keystore exists. Rotate + restrict in GCP — user only.
- **`--flavor sideload` is now required** for `flutter run` and `flutter build apk`.
  A bare `assembleRelease` enters the play graph and fails on the missing key.
- **The play flavor's R8 output is UNVERIFIED on device.** Tap through calls,
  touch-map and ML Kit before shipping an AAB.
- **Chat is not E2EE.** `chat_repository.dart:371` inserts `'body'` in the clear;
  there is no `CryptoCore.encrypt` anywhere under `lib/features/chat/`. Only
  Memory Threads, the Closer vault and Fantasy Jar text are encrypted. The new
  privacy policy states this honestly. Encrypting chat is a large separate job
  (search, media, push previews, decode pipeline all touch it).
- **Vault previews are still in-row bytea** (avg 64 KB, max 323 KB). The list
  query is now projected and paginated, but moving previews to storage objects
  is still the §4a job.
