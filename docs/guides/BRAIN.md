# BRAIN.md — session handoff

Working state for **Miles** (Flutter + Supabase couples app). Read this instead
of the chat history. Last updated 2026-08-14.

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

## 1. Where things are

- Repo `E:\LDR`, app in `mobile/`, branch **`fix-sprint`** (no remote, 260+ commits).
- Supabase prod **`sopictusdonlvuezmfep`** (staging `zqltaobarpcuantrqxha`).
- Test device: OnePlus 8 / **IN2015**, Android 13, arm64. adb at
  `C:/Users/razaa/AppData/Local/Android/Sdk/platform-tools/adb.exe`.
- Current build **16** (`pubspec.yaml` + `lib/core/app/release_gate.dart` must
  match). APK shipped as `E:\LDR\Miles.apk`, arm64 split, ~70–112 MB.
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
- **Afterglow** `replaceMySide` — was a hard StateError lockout.
- **WebView disposed** in `world_map_screen` — its error card was compositing
  over the Afterglow screen.
- **Vault picker** → `PhotoPickerService` (was a bare `ImagePicker`, so it opened
  the file manager; also brings HEIC/ProRAW support).
- **Key escrow** (§5).
- **`CryptoCore.encryptBytesOffThread`** — 100 MB AES on the UI thread.

---

## 4. Open, with diagnosis

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

`core/data/key_escrow.dart` seals the seed under `HKDF(password, salt)` +
XChaCha20-Poly1305 and stores it server-side. Server sees ciphertext only.

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
- Build unprompted once green; **never install without an explicit request.**
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
one BRAIN §0 warns about). `afterglow_entries` is missing **all six** delete
columns — `delete_requested`, `delete_requested_by`, `delete_requested_at`,
`deleted`, `deleted_by`, `deleted_at`. Two failure modes: `requestDelete`/
`cancelDelete`/`hardDelete` (`afterglow_screen.dart:839,847,858`) throw
PGRST204 against live buttons at `:513`/`:520`; and `streamEntries:672`'s
`if (row['deleted'] == true) continue;` is dead code, so **the delete filter has
never filtered anything**. 006600 fixed exactly this for threads and rituals,
cited afterglow in its own header, and did not add afterglow's columns. **Still
open — next migration.**

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

### Still open

1. **Vault photos are still written to disk as plaintext.** The epoch, decode
   and off-thread fixes landed; moving photographs to RAM-only `ImageProvider`s
   needs `private_vault_screen` and `vault_media_viewer` restructured and was
   not attempted — deliberately left whole rather than half-converted. Video and
   audio need a file regardless (no streaming decrypt exists here).
2. **The `MemoryFailure` classification** (spec §6.6). The stream error, the
   empty-vs-unreadable split and every `'Failed: $e'` on the lifecycle paths are
   fixed, but a per-row decrypt failure still has no `KeyGoneForever` /
   `KeyNotYetShared` / TOFU-mismatch copy, and there is no TOFU pin.
3. **6-digit PINs**, now safe to do — see above for why it was not bundled.
4. Multi-select composer + persisted queue, gallery pager, timeline redesign,
   visit linking, authored acceptance.
5. **Nothing has been built or installed this session.** `Miles.apk` on disk is
   still build 21 from the previous one; the device is on build 20. Everything
   above is uncommitted in the working tree.

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
