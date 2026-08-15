# Play release runbook — Miles

Ordered. Each phase depends on the one before it. Everything here is derived
from `docs/guides/PRODUCTION-AUDIT-2026-08-15.md` and from what the six fix
tracks changed in the working tree on 2026-08-15.

**Read once before starting:** phases 1–3 are irreversible in the "you cannot
un-ring this bell" sense — a lost keystore ends the app's life on Play, and a
migration to Play wipes every existing user's encryption keys. Do not start at
phase 4 because it looks like the interesting one.

Facts verified live on prod `sopictusdonlvuezmfep` (ap-south-1) on 2026-08-15:
org `fpmfuptznczuuksqybnx` plan = **free**; storage **525 MB across 651 objects**
of a **1 GB** cap; DB 35 MB; `NOTIFY_SHARED_SECRET` seeded; `partner_rewrap`,
`deliver_rituals` and the deletion-cascade indexes all applied.

---

## Phase 0 — decide, then don't re-decide

**0.1 The disguise is not going to Play.** The `play` product flavor strips the
nine activity-aliases and the disguised label/icon
(`mobile/android/app/src/play/AndroidManifest.xml`) and sets
`BuildConfig.DISGUISE_ENABLED = false` so the Dart covers do not mount. If any
of that is put back, stop — a "News"-labelled calculator hiding an encrypted
intimate vault is the pattern Google account-strikes, and no declaration makes
it pass.

**0.2 The play channel and the sideload channel are two products from here on.**
`sideload` keeps the disguise, the universal APK and R8 off. `play` is an AAB,
R8 on, disguise off. They cannot update over each other (phase 3).

**0.3 Rating.** The Closer module (Fantasy Jar, Desire, Touch Trace, Private
Vault) puts this at **IARC Mature 17+** with honest listing disclosure. Decide
now whether that is acceptable, because it is not negotiable at review time.

---

## Phase 1 — Supabase, before anything is built

### 1.1 Upgrade the org to Pro. Everything else is moot until this is done.

Free plan today:

| Limit | Where it stands | What breaks |
|---|---|---|
| 1 GB storage | **525 MB used by one test couple** | second couple's media fails to upload |
| 200 concurrent realtime connections | fine at 2 | user 201 gets no chat, presence or calls, silently |
| Auto-pause after ~7 days idle | has happened before | DNS record withdrawn, every client sees "Failed host lookup" |
| No PITR, no backups | RPO = total loss | one bad migration ends the product |

Dashboard → Organization → Billing → upgrade to Pro. Then enable PITR on the
project. **Note: database backups never cover Storage objects** — the 525 MB of
photos needs its own copy plan.

### 1.2 Seed the notifier secret — a restored or rebuilt project sends nothing without it

`reach-notify` and `reap-storage` now **fail closed**: no secret configured
means every caller looks like an attacker, so they answer 403. Pushes stop and
storage reaping stops, silently, with a 403 in the function log and nothing in
the app.

Verify:

```sql
select key, length(value) from public.app_secrets
 where key = 'NOTIFY_SHARED_SECRET';
```

Seed if absent (idempotent — `do nothing` protects an existing value):

```sql
insert into public.app_secrets (key, value)
values ('NOTIFY_SHARED_SECRET', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;
```

The triggers read it through `public.notify_secret()` at call time, so seeding
takes effect immediately with no redeploy. The same applies to
`MAPBOX_PUBLIC_TOKEN`, `CF_TURN_KEY_ID`, `CF_TURN_API_TOKEN` and
`FUNCTIONS_BASE_URL`, all of which are present today.

### 1.3 Turn on leaked-password protection

The security advisor reports **Leaked Password Protection Disabled**. Escrow is
only as strong as the password that wraps it (see phase 3), so this is not
cosmetic.

Dashboard → Authentication → Policies → enable "Prevent use of leaked
passwords" (HIBP). Confirm the advisor clears afterwards.

### 1.4 Configure the Magic Link email template — the web deletion page depends on it

`web/delete-account.html` calls the `account-delete` edge function, which uses
`signInWithOtp` + `verifyOtp`. **If the Magic Link template does not contain
`{{ .Token }}`, Auth sends a link instead of a 6-digit code and step two of the
page has nothing to verify.**

Dashboard → Authentication → Email Templates → Magic Link → include `{{ .Token }}`.

Smoke-test after changing it (this creates nothing and mails nothing for an
unknown address):

```bash
curl -s -X POST "https://sopictusdonlvuezmfep.supabase.co/functions/v1/account-delete" \
  -H "Content-Type: application/json" \
  -d '{"email":"nobody@example.invalid"}'
# expect: {"ok":true}

curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "https://sopictusdonlvuezmfep.supabase.co/functions/v1/account-delete" \
  -H "Content-Type: application/json" \
  -d '{"email":"nobody@example.invalid","code":"000000"}'
# expect: 401
```

Then do it once for real with a throwaway account, end to end, and confirm the
account is gone. A deletion URL that does not delete is worse than none.

### 1.5 Reconcile migrations — `supabase db push` is NOT the deployment mechanism here

The prod ledger records migrations by the **name** they were applied under, with
timestamps that do not match the local filenames:

| local file | applied on prod as |
|---|---|
| `20260601008700_partner_rewrap.sql` | `20260815065624_partner_rewrap` |
| `20260601008600_watch_session_persists.sql` | `20260815025758_watch_session_persists` |

102 local files, a differently-numbered ledger, plus SQL applied on prod with no
local file at all (`no_message_push`, the pairing-retirement statements) and one
local file that is 18 lines of comments and zero SQL (`20260601006000`).

**Consequence: any environment rebuilt from `supabase/migrations` deploys a
different — in places more vulnerable — schema than prod.** Before release,
diff `supabase/migrations` against `supabase_migrations.schema_migrations` and
make the repo the truth. This is a real piece of work, not a checkbox.

Verify the state the fix tracks left behind:

```sql
select
  to_regclass('public.partner_rewrap_requests') is not null as rewrap_table,
  (select count(*) from public.app_secrets where key='NOTIFY_SHARED_SECRET') as notify_secret,
  (select count(*) from cron.job) as cron_jobs,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='deliver_rituals') as deliver_rituals;
-- expect: t | 1 | 10 | 1
```

---

## Phase 2 — signing. Do this once, correctly, or never publish an update again.

The `play` flavor **fails the build** when there is no upload key — deliberately,
so the build stops rather than handing you an artifact Play rejects
(`build.gradle.kts:169-181`):

> `android/key.properties is missing, so the play channel has no upload key.
> Create the keystore and key.properties, or build --flavor sideload.`

### 2.1 Create the upload keystore

The command documented in `mobile/android/key.properties.example`:

```bash
keytool -genkey -v -keystore miles-release.jks -storetype JKS \
  -keyalg RSA -keysize 4096 -validity 10000 -alias miles
```

Run it somewhere **outside the repo** (the root `.gitignore` covers `*.jks`
anywhere, but a keystore that is never in the tree cannot be leaked by a future
`git add -f`). Back the file and both passwords up to two places that are not
this laptop — the repo has **no remote**, so losing this disk today already
loses everything.

### 2.2 `mobile/android/key.properties`

Not tracked (`mobile/android/.gitignore` covers it). Copy the example and fill
it in:

```properties
storeFile=C:/keys/miles-release.jks
storePassword=<yours>
keyAlias=miles
keyPassword=<yours>
```

`storeFile` is resolved by `rootProject.file(...)`, whose root is
`mobile/android/`. An absolute path is unambiguous; the example's default
`../miles-release.jks` resolves to `mobile/miles-release.jks`.

Confirm gradle picked it up — this must **not** print the "NO
android/key.properties" banner:

```bash
cd /e/LDR/mobile/android && ./gradlew :app:signingReport
```

### 2.3 `mobile/android/maps.properties` — the Google Maps key

The committed manifest no longer carries the key. It is substituted from an
untracked properties file via `manifestPlaceholders["mapsApiKey"]`
(`build.gradle.kts:24-36`, `AndroidManifest.xml:76-78`), and a build without it
logs a banner and substitutes `MISSING_MAPS_API_KEY` so the failure is loud.

```properties
# mobile/android/maps.properties
mapsApiKey=<the NEW key>
```

**The old key is burned.** `AIza…DTyH4` is in git history at commit `5403769`
and cannot be un-published. In Google Cloud Console:

1. Create a **new** Android key.
2. Restrict it to package `com.miles.miles` **plus the SHA-1 of the Play App
   Signing certificate** (phase 2.4 — not your upload key, or Maps fails for
   every Play install).
3. Enable **only** "Maps SDK for Android" on it.
4. **Delete** the old key. Restricting it is not enough; it is public.

The Maps SDK reads the key from the merged manifest and nowhere else, so it
ships inside the artifact regardless. Restrictions are the only protection it
has.

### 2.4 Enrol in Play App Signing

Play Console → your app → Test and release → **Setup → App integrity → App
signing**. Let Google generate and hold the app signing key; you keep the upload
key from 2.1 and sign every AAB with it.

Once enrolled, copy the **app signing certificate SHA-1 and SHA-256** from that
page. You need them for:

- the Maps key restriction (2.3),
- Firebase — add both fingerprints to the `com.miles.miles` Android app, or
  **FCM stops delivering to Play installs**. Re-download `google-services.json`
  afterwards.

---

## Phase 3 — prove key recovery BEFORE the first Play install exists

This is the phase most likely to be skipped and the one that destroys user data
if it is.

**The problem:** every install in the field today is debug-signed. A Play-signed
build has a different certificate, so Android refuses to update over it. Users
must **uninstall** — and uninstall wipes `flutter_secure_storage`, which is
where the X25519 private key lives. Everything end-to-end encrypted (Memory
Threads, Private Vault, Fantasy Jar) becomes unreadable on the new install
unless recovery works.

Two recovery paths exist. Both must be **proven on real hardware**, not
reasoned about:

1. **Key escrow** (`key_escrow.dart`) — the seed sealed under an Argon2id key
   derived from the account password, restored at sign-in. Test: install play
   build → sign in → confirm Memory Threads / vault content decrypts.
2. **Partner rewrap** (`partner_rewrap.dart`, `rewrap_screen.dart`) — the
   partner's phone hands the retired keys across for anyone whose password
   cannot open the escrow. The table now exists on prod
   (`partner_rewrap_requests`, applied as `20260815065624_partner_rewrap`), so
   the path is live for the first time.

**The test, in order, on two handsets:**

```
1. sideload build installed, couple paired, encrypted content written on both
2. uninstall on phone A  (this is the destructive step — do it deliberately)
3. install the play AAB on phone A (via internal testing, phase 5)
4. sign in with the password        -> escrow restore should return the seed
5. open Memory Threads + the vault  -> content must render, not error
6. repeat on phone B with a FORGOTTEN password, driving the /rewrap ceremony
   from phone A
```

If step 5 fails, **stop the release**. Shipping the migration before recovery
works converts an inconvenience into permanent data loss for every user, and
there is no update channel to fix it with.

Also raise the version gate only **after** installs land, never before:

```sql
-- prod currently: min_build = 2, latest_build = 2  (gate unarmed)
update public.app_release set min_build = <N>, latest_build = <N>;
```

Raising it first locks out the device that has to receive the install.

---

## Phase 4 — build the AAB

Do not run this until phases 1–3 are done.

Pre-flight (both must be clean; the repo's hygiene tests enforce zero analyzer
warnings):

```bash
cd /e/LDR && flutter analyze mobile
cd /e/LDR/mobile && flutter test
```

Keep `pubspec.yaml`'s `version:` and `release_gate.dart`'s `buildNumber` in
lockstep — nothing enforces it, and they have drifted before. Today both read
**27**.

```bash
cd /e/LDR/mobile && grep -n '^version:' pubspec.yaml
cd /e/LDR/mobile && grep -n 'buildNumber' lib/core/app/release_gate.dart
```

Build:

```bash
cd /e/LDR/mobile
flutter build appbundle --release --flavor play
```

Output: `mobile/build/app/outputs/bundle/playRelease/app-play-release.aab`.

The `play` flavor turns **R8 minify + resource shrink on** (via the
`androidComponents.beforeVariants` block) while `sideload` keeps them off.
`proguard-rules.pro` is wired, but R8 has never run against this app's WebRTC
and ML Kit reflection paths — **a shrunk build can fail only on a device.**
Install the AAB through internal testing and exercise a video call, screen
share, camera capture and the map before promoting it anywhere.

Verify what you actually built before uploading:

```bash
# signed with the upload key, not the debug key
cd /e/LDR/mobile && jarsigner -verify -verbose -certs \
  build/app/outputs/bundle/playRelease/app-play-release.aab | head -20

# the merged manifest: no READ_MEDIA_IMAGES / READ_MEDIA_VIDEO, no
# activity-alias, label "Miles". The manifest inside an AAB is protobuf, so read
# it with bundletool rather than unzip:
java -jar bundletool.jar dump manifest \
  --bundle build/app/outputs/bundle/playRelease/app-play-release.aab
```

If bundletool is not to hand, the same check against the APK the AAB is built
from is nearly as good and needs no extra tool:

```bash
cd /e/LDR/mobile && flutter build apk --release --flavor play
aapt2 dump permissions build/app/outputs/flutter-apk/app-play-release.apk
```

The sideload channel is unchanged and still builds as before:

```bash
cd /e/LDR/mobile && flutter build apk --release --flavor sideload
```

---

## Phase 5 — Play Console declarations

Every one of these is a form that blocks the release if it is wrong.

### 5.1 Photo and video permissions

The manifest now declares only `READ_MEDIA_VISUAL_USER_SELECTED` and
`READ_EXTERNAL_STORAGE` (maxSdkVersion 32) — `READ_MEDIA_IMAGES` and
`READ_MEDIA_VIDEO` were removed because every gallery entry point goes through
the system photo picker or `ACTION_GET_CONTENT`, both of which hand back a URI
carrying its own read grant.

Answer: the app does **not** require broad photo/video access. **Verify against
the merged manifest of the actual AAB first** (command in phase 4) — the
declaration is a statement about the artifact, not about the source.

### 5.2 USE_FULL_SCREEN_INTENT

Play restricts this to calling and alarm apps. **Known problem, unfixed:**
`reach_notifications.dart:65,157` sets `AndroidNotificationCategory.call` and
`fullScreenIntent` on **Reach** alerts, which are not calls.

Either fix that before submitting — full-screen intent for real calls only,
Reach demoted to a high-priority notification — or expect the declaration to be
rejected. Do not claim Reach is a call.

### 5.3 Foreground service types — three, each needing a use case and a demo video

Declared in `AndroidManifest.xml:199-203` as
`microphone|camera|mediaProjection` on one service:

| Type | Use case to declare | Demo video must show |
|---|---|---|
| `microphone` | keeping a voice/video call alive while the app is backgrounded | starting a call, backgrounding the app, audio continuing |
| `camera` | the outgoing video track of a video call while backgrounded | a video call surviving a home-button press |
| `mediaProjection` | screen share into an active call | the user starting a share and the system consent dialog |

Each video must show the in-app path a user takes to trigger it. Host them
somewhere Google can watch (unlisted YouTube is fine) and paste the links into
the declaration.

### 5.4 Data safety form

Answer from the privacy policy — `docs/legal/privacy-policy.md` is the source of
truth and was written from the code, so the two cannot drift if you copy from
it.

Collected and linked to the user: email address, name, photo, approximate and
precise location, messages, photos and videos, voice recordings, files, health
and fitness (the cycle tracker), sexual-orientation-adjacent / intimate content,
app diagnostics, crash logs, device identifiers (the FCM token).

- **Encrypted in transit:** yes.
- **End-to-end encrypted:** answer honestly per data type. Memory Threads,
  Closer's Private Vault and Fantasy Jar entry text are E2EE. **Chat, location,
  cycle data, presence and the personal vault are not.** Do not tick a blanket
  E2EE claim.
- **Data deletion:** "users can request that data be deleted", with the URL from
  phase 6.
- **Shared with third parties:** no data is sold or shared for advertising.

### 5.5 Content rating (IARC) — Mature 17+

Answer the questionnaire truthfully about the intimacy module. Understating it
is a policy violation with worse consequences than the rating itself.

### 5.6 The rest of the forms

- **Target audience:** adults only, 18+. No child-directed content.
- **Ads:** none.
- **News app:** no (the play flavor carries no "News" label).
- **Government app / financial:** no.
- **Location:** foreground only, so the background-location declaration does not
  apply. Confirm the AAB has no `ACCESS_BACKGROUND_LOCATION` — it should not;
  the manifest removed it with a comment explaining why.
- **Account deletion:** paste the URL from phase 6 into App content → Data
  safety, and again into the store listing where Play asks for it.

---

## Phase 6 — host the two documents

Both files are in the repo and both must be at **stable public HTTPS URLs**
before the listing can be submitted.

| File | Goes to | Used by |
|---|---|---|
| `web/privacy-policy.html` | e.g. `https://<domain>/privacy-policy` | Play listing "Privacy policy" field **and** an in-app link |
| `web/delete-account.html` | e.g. `https://<domain>/delete-account` | Play Data Safety "account deletion" URL |

Both are single self-contained files with no external assets and no CDN
dependencies, so any static host works — GitHub Pages, Cloudflare Pages, Netlify,
or an S3 bucket.

**Before publishing them, replace every placeholder:**

- `{{PUBLISHER_NAME}}`, `{{POSTAL_ADDRESS}}`, `{{PRIVACY_CONTACT_EMAIL}}` — in
  both `web/privacy-policy.html` and `docs/legal/privacy-policy.md`
- `{{DELETE_URL}}` — in the privacy policy, pointing at the hosted deletion page
- `{{PRIVACY_CONTACT_EMAIL}}` and `{{PRIVACY_POLICY_URL}}` — in
  `web/delete-account.html` (the email appears in the footer **and** inside the
  script's failure message)

`web/delete-account.html` already points at the live endpoint
`https://sopictusdonlvuezmfep.supabase.co/functions/v1/account-delete` with the
project's anon key, both in the CONFIG block at the top of its `<script>`. If
the project ever changes, that block is the only thing to edit.

**The privacy policy must also be reachable inside the app** — Play requires
both. There is currently no policy link in `mobile/lib`; add one to the settings
screen alongside the deletion entry.

---

## Phase 7 — release

1. **Internal testing track first.** Upload the AAB, add your own accounts, and
   run the phase 3 recovery test against the real Play-installed artifact.
2. **Closed testing** long enough to see the R8 build behave on more than one
   device model.
3. **Production**, staged rollout. There is no way to un-publish a build that
   has already destroyed someone's keys.
4. After the fleet has moved, raise `app_release.min_build` (phase 3) — never
   before.

---

## What this runbook does not fix

Carried forward from the audit and still open at release time. None of them
block the *listing*, all of them bite a real cohort:

- Presence heartbeat writes twice per 5 s per user via `postgres_changes` — the
  documented non-scaling path. ~200 writes/s at 1k concurrent chatters.
- Realtime reconnect has no backoff; a service restart leaves rejected channels
  silently dead.
- Vault previews are in-row `bytea` streamed without `.limit()` — 1k couples
  ≈ 6.4 GB of **database**.
- `care-notify` and `turn-credentials` hardening — check the fix tracks landed
  before shipping, since both were anon-reachable at audit time.
- Sign-out does not empty `DefaultCacheManager`, so a previous couple's images
  stay readable on disk after an account switch.
- Full-screen-intent on Reach (phase 5.2) is a policy problem *and* a user-hostile
  one.
