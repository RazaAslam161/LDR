# Miles — production-readiness audit (2026-08-15)

Method: 8-dimension multi-agent audit (crypto, auth, RLS/live-DB, edge functions, Play
policy, scale, silent failures, multi-tenancy). Every critical/high was adversarially
re-verified against **live prod `sopictusdonlvuezmfep`** and the current working tree.
Two findings were **REFUTED** in verification and are excluded from the counts below.

Mechanical baseline (real output):
- `flutter analyze` → exit 0, 470 issues, all `info` lints (no errors/warnings). 468s.
- `flutter test` → `+680: All tests passed!` exit 0.
- A green suite is a floor. Everything below is invisible to both commands.

Tally (post-verification): **6 critical · 21 high · ~21 medium · several low.**

---

## CRITICAL — each one alone blocks a Play release / makes scale impossible

1. **Launcher disguise = Deceptive Behavior violation** — `AndroidManifest.xml:61,147-262`.
   Label "News" + 9 activity-aliases (Calculator/Notes/Weather/…) with hidden entry
   gestures. This is the "vault app" pattern Google account-strikes, not just rejects.
   No declaration makes it pass. Needs a Play build flavor with aliases+covers stripped,
   or Play is not a viable channel for the app as designed.

2. **Release build is debug-signed** — `build.gradle.kts:71`. No `key.properties`, falls
   back to the world-shared debug key. Play rejects the upload outright. Also: every
   existing sideload install is debug-signed, so a Play-signed build can never update
   over them in place.

3. **218 MB universal APK, not an AAB** — `build.gradle.kts:97`, R8 off (`:85-86`). New
   apps must ship `.aab`; format is rejected before content review. Nobody has ever built
   or device-tested an AAB of this app.

4. **No privacy policy anywhere** — grep of `mobile/lib` returns zero policy URLs; the only
   "Privacy" UI is the modest-mode toggle (`settings_screen.dart:645`). Mandatory on the
   listing AND in-app given location+camera+mic+photos+intimate data. Blocks at the listing
   stage, before the harder problems are even reviewed.

5. **No web account-deletion path** — in-app deletion exists (`settings_screen.dart:394` →
   `delete_my_account`) but the Data Safety form requires a **web** deletion URL. Product has
   no web presence. Cheapest critical to fix (a static page + edge function).

6. **Prod Supabase is on the FREE plan** — org `fpmfuptznczuuksqybnx` plan=`free` (verified
   live). One test couple already uses **520 MB of the 1 GB** storage cap. 200-connection
   realtime ceiling = the 201st concurrent user gets no live chat/presence/calls. Auto-pauses
   after ~7 days idle (has happened before). Every other scale fix is moot until this is Pro.

---

## HIGH — breaks for a real cohort, leaks data, or loses data

### Crypto / key-recovery (this sprint's area — highest concentration of data-loss bugs)
- **Escrow wrap password = the account password** — `key_escrow.dart:137`,
  `supabase_repository.dart:33-47,61-85`. The same string goes to GoTrue (plaintext on every
  login) and derives the Argon2id seed-wrap. An active auth-layer compromise/log opens the
  escrowed X25519 seed → decrypts all couple content. Collapses the E2EE claim vs the server
  operator. The migration/comment claim the opposite ("never receives the password"). *(critical→high: needs active endpoint compromise, not a passive dump.)*
- **Password reset destroys escrow recovery** — `supabase_repository.dart:105-114`,
  `key_escrow.dart:131-132`. Reset on a reinstall/new phone (no local seed) → `backup()`
  no-ops, row stays sealed under the forgotten password; next sign-in mints a throwaway key
  and **overwrites the good escrow row**. Silent permanent loss for the exact forgot-password cohort.
- **Sign-in escrow restore reverts a post-rewrap seed** — `supabase_repository.dart:84`
  runs `restore()` unconditionally; `key_escrow.dart:193` `adoptPrivateSeed` replaces the
  local seed. After a completed rewrap ceremony, a later password sign-in can revert to the
  stale seed → the minted-era couple key exists nowhere → weeks of messages/vault permanently
  undecryptable on both phones. *(critical→high: gated on a transient network failure during the pre-ceremony restore.)*
- **Sign-in → `/rewrap` handoff loses the race** — `sign_in_page.dart:42-51`. The auth event
  fires and the router sweeps `/signin`→`/app` before `signIn()`'s Argon2id tail finishes;
  the `if (mounted)` guard then silently drops `context.go('/rewrap')`. The recovery cohort
  never sees the ceremony this sprint exists to provide.
- **No `/rewrap` path on session restore** — `router.dart` never redirects to it; only
  `sign_in_page.dart:51` and the partner-side `app_shell.dart:174` navigate there. A keyless
  device relaunched mid-recovery (the ordinary case — cover-flip backgrounds and Android kills
  the process) is stranded in `/app` with blank encrypted screens, no route back.

### Auth / server
- **Involuntary sign-out never clears the session** — `session_provider.dart:77-91`. Only
  `passwordRecovery` is handled; `copyWith(session: session ?? this.session)` swallows the
  `null` from a `signedOut` event (revoked/expired/reused refresh token). App stays "authed"
  with a dead token, every call 401s, no redirect to `/signin` until the process is killed.
- **`partner_rewrap` migration never applied to prod** — `to_regclass('public.partner_rewrap_requests')`
  = null (verified live). Client hard-references the table (`app_shell.dart:207-215`,
  `partner_rewrap.dart:166+`) with no gate. The entire no-password recovery path is 100%
  dead in production, and the migration (dated 20260601) sorts **before** the last applied
  one (20260815) so `db push` skips it without `--include-all`. Deploy migration **before/with** the build.
- **`care-notify` is an un-hardened twin of `reach-notify`** — `care-notify/index.ts:51`.
  Live/ACTIVE, anon-key reachable, **no shared-secret check**, acts on caller-supplied
  `couple_id`/`from_user`/`message`. Anyone with a couple_id injects "care" pushes with
  chosen text; distinct 200 bodies make it a reachability oracle. This is exactly what
  migration 004700 closed on the sibling. Undeploy it or add the `notifySecret()` gate.
- **`turn-credentials` open to anon, 24h TTL** — `turn-credentials/index.ts:27`. No
  `auth.getUser()` (unlike `map-token`), so the APK's anon key mints unlimited 24h Cloudflare
  TURN credentials → open relay + unbounded third-party billing. Add auth, drop TTL to minutes, rate-limit.

### Scale (verified live against prod)
- **Presence heartbeat writes every 5s per user via postgres_changes** —
  `chat_screen.dart:631` (two durable writes/5s), `presence_service.dart:556` adds a 15s REST
  poll. postgres_changes is Supabase's documented non-scaling path. At 1k concurrent chatters:
  ~200 writes/s, ~500M realtime msgs/month (2M free / 5M Pro). Move to Realtime Presence/Broadcast.
- **Reconnect storm has no retry** — `realtime_service.dart:58-64` only logs the join status;
  no backoff on `CHANNEL_ERROR/TIMED_OUT`. A realtime restart → thousands rejoin at once, the
  rate-limiter rejects the overflow, and rejected channels stay silently dead until the next
  socket drop. (Call signaling is the one exception — it does retry.)
- **`delete_my_account` cascades 18 unindexed FKs under an 8s timeout** —
  `20260601007500` + performance advisor (verified). Each FK check is a full child-table scan;
  once gallery_items/routine_checks/shared_reel_views grow, the RPC hits 57014 and account
  deletion (a GDPR/Play requirement) fails. Fix = add the covering indexes the advisor lists.
- **Vault previews are in-row `bytea`, streamed unbounded** — `private_vault_repository.dart:180`.
  Verified prod: avg 64 KB, max 323 KB ciphertext per row; `.stream()` with no `.limit()`
  re-fetches all rows (hex-doubled) on every reconnect. 1k couples × 100 items × 64 KB ≈ 6.4 GB
  of **DB** — 13× the free cap. Move previews to storage objects, paginate.
- **`deliver-rituals` worker doesn't exist on prod** — verified: no `deliver_rituals` proc,
  no cron job. 20 rituals rows sit with `delivered=false` and nothing reads `deliver_at`.
  Every scheduled ritual silently never fires. (Local migration 008400 unapplied — same drift class.)

### Play policy (beyond the criticals)
- **READ_MEDIA_IMAGES/VIDEO fail the Photo/Video Permissions declaration** —
  `AndroidManifest.xml:44-46`. The app already uses the system photo picker
  (pubspec pins `image_picker_android` for exactly that), so broad access has no
  justification. Remove them (keep `READ_MEDIA_VISUAL_USER_SELECTED`), drop the blast in `PermissionsBootstrap`.
- **Closer intimacy module on the "sexually gratifying" line + disguise** —
  `intimacy_screen.dart`, `features/closer/*` (Fantasy Jar, Desire, Touch Trace, Private Vault).
  Forces Mature 17+ and honest listing disclosure; an encrypted photo vault inside a
  Calculator-disguised app reads to a reviewer as a covert sexting vault → strike risk.
- **Google Maps API key hardcoded + in git history** — `AndroidManifest.xml:70`
  (`AIza…DTyH4`, committed in 5403769). No release keystore exists, so it can't be pinned to a
  release SHA-1; extracted key = quota theft/billing. Rotate + restrict.
- **Blanket first-frame permission blast** — `permissions_bootstrap.dart:24-31` requests
  camera/mic/notif/photos/videos/storage before sign-up (`main.dart:161`). Review flag, and
  Android's second-denial-is-permanent silently breaks calls/capture forever for deny-first users.

### Multi-tenancy
- **Live invites survive couple dissolution → resurrect the couple** — verified full chain on
  prod: `leave_couple` never consumes invites; `redeem_pairing_invite` has no `dissolved_at`
  check; the `clear_dissolved_on_join` trigger un-deletes the couple and cancels the 30-day
  purge. A third party holding an unconsumed code joins a dissolved couple and gains RLS access
  to its retained intimate history. Consume invites in `leave_couple`; refuse dissolved couples.
- **Sign-out leaves plaintext photos on disk** — `session_provider.dart:290` clears only the
  ciphertext cache; chat + intimate-gallery images render via `CachedNetworkImage` →
  `DefaultCacheManager`, which is **never** emptied (grep-verified). Account switch on one
  handset leaves the previous couple's images readable at the filesystem level. Add
  `DefaultCacheManager().emptyCache()` + `imageCache.clear()` to `signOut()`.

---

## MEDIUM — degraded but survivable

- **Fantasy-Jar tags: unkeyed 32-bit FNV over a fixed 12-item taxonomy** — `crypto_core.dart:519`.
  Precompute 12 hashes → reverse every row. Special-category (sex-life) data. Method is misnamed
  `hmacTag` (neither HMAC nor keyed). *(high→medium: entry text stays E2EE; only category metadata leaks, to a DB-read adversary.)*
- **All-zero-nonce/MAC "legacy plaintext" sentinel** — `crypto_core.dart:380,499,572`. Any row
  with zeroed nonce+MAC is returned as authentic cleartext → DB-write attacker forges content
  into E2EE surfaces. Gate to a closed allowlist of pre-migration ids.
- **App-lock PIN = unsalted SHA-256 in SharedPreferences** — `app_lock.dart:37`. World-readable
  plaintext XML, 10^4 space reversed instantly. Move to secure storage + KDF.
- **Personal vault stored server-side plaintext** — `vault_repository.dart:63`. `content` is
  cleartext in Postgres (RLS-only), while the sibling Closer vault is E2EE. Encrypt client-side.
- **Escrow restore ignores per-row `kdf_params`** — `key_escrow.dart:171-192`. Any future
  Argon2id hardening makes all existing rows underivable → the same throwaway-overwrite loss. Read m/t/p from the row.
- **Partner-rewrap gated on biometric that returns false when none enrolled** —
  `partner_rewrap.dart:213`, `app_lock.dart:87`. Lock-less users (a large cohort) can never
  complete the ceremony — the exact users most likely to need it.
- **`couples` lifecycle/billing columns are client-writable** — `couples_update_member` +
  authenticated grants let a member PATCH `dissolved_at`/`active`/`stripe_customer_id`/`invite_code`.
  Move to SECURITY DEFINER RPCs; column-grant the rest.
- **`redeem_pairing_invite` has no row locking** — `20260601004900:102`. Concurrent redeems →
  3-member couple → `fetchPartner` `maybeSingle()` throws → couple unloadable for all members. Add `FOR UPDATE` + advisory lock.
- **Device lock PINs survive account switch** — `app_lock.dart:19`, `memory_pin_gate.dart:29`.
  Not uid-scoped, not cleared on sign-out. A's PIN opens B's gates. Clear/scope in `signOut()`.
- **Key ring is per-account, not per-couple** — `partner_rewrap.dart:218`, `crypto_core.dart:60`.
  A rewrap in a NEW relationship seals a previous relationship's retired keys onto the new
  partner's phone. Scope the ring per (account, couple) or wipe on couple change.
- **Decrypted vault video/audio temp files survive process kill** — `vault_media_cache.dart:216`.
  Photos were moved to RAM; video/audio still write plaintext to temp dir, outlive the cover-flip
  kill, survive sign-out. Sweep `vault_*` on start + sign-out.
- **Disguise notepad persists across sign-out** — `notes_cover.dart:28`. A's typed notes render
  for B (and before any sign-in). Clear/scope the key.
- **`tethered://` custom scheme is interceptable** — `AndroidManifest.xml:102,120`. PKCE
  defangs auth-callback, but `tethered://join?code=` is directly redeemable by any app that
  registers the scheme. (App Links fix conflicts with the disguise — assetlinks.json would name the package.)
- **`EscrowPrompt` seals under an unverified password** — `escrow_prompt.dart:42`, and
  `backup()` swallows all failures. A typo/network blip writes an unopenable row, sets
  `asked_v1`, and the user believes they're protected. Re-auth before sealing.
- **Rewrap waiting screen depends on one realtime delivery** — `rewrap_screen.dart:142`.
  A missed postgres_changes event → the answered row is never claimed → 10-min timeout →
  retries hit the 3/hour limiter. Also poll `_claim` from the 1 Hz timer.
- **ServerClock not observed on the reinstall path** — `rewrap_screen.dart:111`. The countdown
  runs on the raw device clock (presence, its only feeder, hasn't mounted); a fast clock shows
  every code instantly "Expired". Feed `ServerClock.observe` from `open()`'s response.
- **Publication-hold resume is dead code** — `sign_in_page.dart:37` reads `publicationHeld()`
  before `bindAccount`, under the unscoped key → always absent → the `held` branch never fires.
- **USE_FULL_SCREEN_INTENT + 3 foreground-service types need Play declarations** —
  `AndroidManifest.xml:54,315`. FSI is applied to non-call Reach alerts (`category.call`);
  mediaProjection needs a demo video. Prepare declarations, stop dressing Reach as a call.
- **11 RLS policies re-evaluate `auth.uid()` per row; cycle tables have duplicate SELECT policies** —
  performance advisor. Wrap as `(select auth.uid())`, merge the owner/partner policies.
- **Sideload→Play in-place migration is impossible** — signature mismatch; existing users must
  uninstall (wiping secure-storage keys). Sequence escrow/rewrap adoption first, then migrate.

---

## LOW (worth knowing)
- Memory Threads PIN uses FNV-1a of a 4-digit PIN (`memory_pin_gate.dart:93`) — secure-storage-backed, so limited.
- `/new-password` reachable unauthenticated (`router.dart:77`) — dead screen, not a leak.
- Shared-secret compare not constant-time in reach-notify/reap-storage; both fail-open when the secret is unset (safe today, gap during a restore window).
- from_name/couple_id sent through FCM in cleartext for reach/care/message (reach-notify already strips it for call/memory/ritual).
- pg_net http_* funcs EXECUTE-granted to anon/authenticated (not REST-reachable today; one config slip from SSRF).
- Auth leaked-password (HIBP) protection disabled.
- Unbounded list queries: personal vault, memory threads, visits (`.limit()` missing) — metadata-sized, degrades not breaks.
- Uncached Google OAuth token per push invocation (~100-300ms).
- Misc device-scoped state leaks across account switch: chat theme/bg, love-note recipient name, un-nulled `pendingMemory`, disguise-chosen flag.

---

## REFUTED in verification — do NOT action as reported
- **"Per-message push fanout, 1.44M invocations/day"** — REFUTED. Migration `no_message_push`
  (20260812013012) dropped the messages trigger on prod; message push doesn't exist. Residual:
  uncached OAuth token = low.
- **"redeem_pairing_invite silently moves already-paired users / splits couples"** — REFUTED.
  Prod has out-of-band retirement SQL (the 006000 intent) + `ON DELETE CASCADE` on invites, and
  the router blocks paired users from the redeem form. Residual: `too_many_attempts` unmapped (low).

---

## Cross-cutting process finding (the root of several highs)
**Local migrations and prod have drifted in BOTH directions.** Unapplied locally-present:
`deliver_rituals` (008400), `partner_rewrap` (008700). Applied on prod with no local file:
`no_message_push`, the pairing-retirement SQL. `redeem_retires_empty_couple` (006000) is
**18 lines of comments, zero SQL**. Any environment rebuilt from `supabase/migrations` would
deploy a *different, in some places more vulnerable* schema than prod. Reconcile
`supabase/migrations` against `supabase_migrations.schema_migrations` and gate it in CI before release.
