# Play release runbook — Miles

Ordered. Each phase depends on the one before it.

**Provenance.** Written 2026-08-15 from `docs/archive/PRODUCTION-AUDIT-2026-08-15.md`,
corrected 2026-08-17 against the tree and against
`docs/archive/PLAY-READINESS-AUDIT.md` (2026-08-16), which is the current
readiness source and outranks this file wherever the two disagree on *what is
still open*. This file is the *order of operations*; the audit is the *state*.

**Read once before starting:** phases 1–3 are irreversible in the "you cannot
un-ring this bell" sense — a lost keystore ends the app's life on Play, and a
migration to Play wipes every existing user's encryption keys. Do not start at
phase 4 because it looks like the interesting one.

Verified live on prod `sopictusdonlvuezmfep` (ap-south-1) on **2026-08-17**:

| Fact | Value |
|---|---|
| org plan | **free** (org `fpmfuptznczuuksqybnx`) |
| storage | 8 objects / **4.2 MB** of a 1 GB cap — prod was wiped to zero users on 2026-08-16 (BRAIN §29). Before the wipe, **one couple held 525 MB**. That is the number to plan capacity with, not 4 MB. |
| `app_release` | `min_build = 39`, `latest_build = 39` — **the gate is armed** |
| `partner_rewrap_requests` | exists |
| `NOTIFY_SHARED_SECRET` | seeded (1 row) |
| `cron.job` | 10 jobs |
| `public.deliver_rituals` | exists |
| migration ledger | 167 rows against **108** local `.sql` files |

Repo state: `version: 0.1.0+40`, `ReleaseGate.buildNumber = 40`,
`mobile/android/key.properties` **does not exist**, and no `.aab` has ever been
built.

---

## Phase 0 — decide, then don't re-decide

### 0.1 The covers ship on Play, and the listing discloses them

This reverses what this section said until 2026-08-17. The owner chose it
(BRAIN §34); the flavor now matches. **Read the flavor before you fill in any
Console form:**

- `mobile/android/app/build.gradle.kts` → `create("play")` sets
  `DISGUISE_ENABLED = true`, `PLAIN_DEFAULT = true`.
- `mobile/android/app/src/play/AndroidManifest.xml` **keeps all nine cover
  activity-aliases** — ten aliases in total. `AliasMiles` is
  `android:enabled="true"`; the nine covers (`News`, `Calculator`, `Notes`,
  `Weather`, `Convert`, `Recorder`, `Timer`, `Level`, `Device Info`) are
  `android:enabled="false"`. The app installs as
  Miles, under `@mipmap/ic_launcher_play`, and stays that way until the owner
  changes it from Settings.
- `test/unit/disguise/disguise_manifest_test.dart` pins exactly this ("the play
  channel installs as itself, covers off", "exactly one way in"). If a change
  reds that test, it is a policy change, not a test problem.

**The five shipping requirements are written beside the flag in
`build.gradle.kts` and all five are mandatory.** Status as of 2026-08-17:

| # | Requirement | Where | Status |
|---|---|---|---|
| 1 | No unprompted cover offer on first run | `app_shell.dart` | **done** — `_offerCoverAtFirstOpen()` removed; grep for it returns nothing |
| 2 | Confirmation naming the consequence *and* the way back, before any cover applies | `disguise_picker_screen.dart` | **done** — a PIN is set, the owner records their own move on the cover, then the dialog names the new label, says Miles will not be findable by name, and states the backup hold |
| 3 | A way back the owner can find on every cover screen | `cover_gate.dart`, `entry_trigger_layer.dart` | **done** — the backup hold: two still fingers on the opening screen for ten seconds, landing on the PIN. Undisclosed to users since 2026-09-03; the Console App access note is the only place it is written. No About sheet any more — the app ships no door it could describe. **Not a policy requirement** — items 4-5 carry the disclosure. See `disguises.md`. |
| 4 | The listing describes the feature, with the picker in ≥1 screenshot | store listing | **OPEN — phase 7** |
| 5 | The unlock gesture + a working test account in Console → App access | Console | **OPEN — phase 5.6** |

Requirements 4 and 5 are **not optional and not cosmetic**. Shipping 1–3 without
them is shipping an undisclosed app-hider, which is the Behavior Transparency
("hidden, dormant, or undocumented features") violation and an account-level
enforcement, not a resubmit. If you are not going to do 4 and 5, the decision to
reverse is 0.1 itself, before the build — not the declaration.

The exact way back, the same on every cover and in every state — **press and
hold two fingers still in the middle of the cover's opening screen for ten
seconds, then unlock with the app PIN (a fingerprint prompt may appear first;
cancel it to type the PIN)**. That sentence goes in the Console App access
notes verbatim.

**Ten, not five, and the Console notes are now the ONLY place this gesture is
written for anyone outside the repo.** The owner ruled on 2026-09-03 that users
are not told it exists: it is gone from the app's dialogs, the in-app FAQ and
the public web FAQ, and `disguise_test.dart` fails the build if it reappears
there. Google still needs it — a reviewer who cannot get back in rejects the
app — so it belongs here and nowhere else. If the duration changes again, this
sentence and `kCoverRecoveryHoldSeconds` move together. The owner's own recorded move is per phone and is not something the
notes can state.

### 0.2 One app, one channel that reaches people

Owner's ruling, 2026-09-03: **everything a real person installs is the `play`
flavour.** `bash tool/release.sh` builds it as an APK for testers; the same
flavour builds the AAB for the Console. Same R8, same upload key, same code —
the tester build is the shipping **code**, delivered by cable instead of by
Play. (One flag differs, deliberately; see the ABI note below.)

Code, not certificate. §2.4 enrols this app in Play App Signing, so Google
re-signs the bundle with a key it holds and a Play-delivered install does NOT
carry the upload certificate. A tester who took the APK by cable therefore
still needs phase 3's escrow-then-uninstall before Play can update them. That
migration is not closed by the ruling below and must not be assumed away.

What the ruling does close is the two problems the old arrangement had:

- **Testers were never testing the shipping code.** `play` shrinks and
  minifies and `sideload` does not, so every finding from a sideload APK was a
  finding about code R8 had never touched — and R8 is what strips the
  reflection/JNI paths in WebRTC and ML Kit that only fail on a device.
- **A sideload APK could not update a handset.** `sideload` is debug-signed by
  design; the handsets carry the upload key, so Android refused it with
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the only way past was an uninstall,
  which takes the X25519 seed with it (BRAIN §262 addendum 2).

`sideload` still exists for debugging the unshrunk build
(`bash tool/release.sh --sideload`). It warns, and it writes
`Miles-sideload-debug.apk` so it cannot be mistaken for the tester artifact.
`Miles.apk` at the repo root is the play build from the last run that
**succeeded**. A refused artifact is never copied, so after a failed run the
file is the previous build — the script says so when it refuses.

One difference between the two play artifacts, deliberate: the **APK** carries
arm64 only (`-PmilesPlayApkArm64`), because it is handed to a tester whole and
a partial APK installs on a 32-bit phone and then dies on a missing engine
(build 64, BRAIN §193). The **AAB** keeps every ABI, because Play splits per
device itself. An arm64 handset gets the same libraries either way.

### 0.3 Rating and category

The Closer module (Touch Trace, Wish Jar, Closeness, Private Vault, Memory
Threads) puts this at **IARC Mature 17+**, category **Social** (not Dating —
there is no discovery surface; pairing is invite-code only), target audience
**18+ only**, no ads, no IAP. Decide now; it is not negotiable at review time.

The app authors no sexual content — the 18+ rating covers what users bring. Keep
it that way in every listing asset (phase 7).

---

## Phase 1 — Supabase, before anything is built

### 1.1 Upgrade the org to Pro. Everything else is moot until this is done.

Free plan today:

| Limit | Where it stands | What breaks |
|---|---|---|
| 1 GB storage | 4.2 MB now, but **one couple reached 525 MB** before the wipe | the second or third couple's media fails to upload |
| 200 concurrent realtime connections | fine at 2 | user 201 gets no chat, presence or calls, silently |
| Auto-pause after ~7 days idle | has happened before | DNS record withdrawn, every client sees "Failed host lookup" |
| No PITR, no backups | RPO = total loss | one bad migration ends the product |

Dashboard → Organization → Billing → upgrade to Pro. Then enable PITR on the
project. **Note: database backups never cover Storage objects** — user media
needs its own copy plan.

### 1.2 Seed the notifier secret — a restored or rebuilt project sends nothing without it

`reach-notify` and `reap-storage` **fail closed**: no secret configured means
every caller looks like an attacker, so they answer 403. Pushes stop and storage
reaping stops, silently, with a 403 in the function log and nothing in the app.

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

The security advisor reported **Leaked Password Protection Disabled**
(2026-08-15; *not re-checked since — confirm in the dashboard*). Escrow is only
as strong as the password that wraps it (phase 3), so this is not cosmetic.

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

**108** local `.sql` files against **167** ledger rows (both counted
2026-08-17), plus SQL applied on prod with no local file at all
(`no_message_push`, the pairing-retirement statements) and one local file that
is 18 lines of comments and zero SQL (`20260601006000`).

**Consequence: any environment rebuilt from `supabase/migrations` deploys a
different — in places more vulnerable — schema than prod.** Before release,
diff `supabase/migrations` against `supabase_migrations.schema_migrations` and
make the repo the truth. This is a real piece of work, not a checkbox.

Verify the state the fix tracks left behind (this returned `t | 1 | 10 | 1` on
2026-08-17):

```sql
select
  to_regclass('public.partner_rewrap_requests') is not null as rewrap_table,
  (select count(*) from public.app_secrets where key='NOTIFY_SHARED_SECRET') as notify_secret,
  (select count(*) from cron.job) as cron_jobs,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='deliver_rituals') as deliver_rituals;
```

---

## Phase 2 — signing. Do this once, correctly, or never publish an update again.

The `play` flavor **fails the build** when there is no upload key — deliberately,
so the build stops rather than handing you an artifact Play rejects. The check
is the `gradle.taskGraph.whenReady` block at `build.gradle.kts:208-220`:

> `android/key.properties is missing, so the play channel has no upload key.
> Create the keystore and key.properties, or build --flavor sideload.`

### 2.1 Create the upload keystore — run the script, do not retype the command

```bash
bash /d/Miles/mobile/tool/make-keystore.sh
```

`mobile/tool/make-keystore.sh` is the whole of steps 2.1 and 2.2. Run it
yourself rather than through an agent: it reads the password interactively, so
the password never lands in a transcript, a shell history line or a log. What it
does, so you know what you are agreeing to:

- **PKCS12, not JKS.** keytool warns that JKS is proprietary on every single
  invocation. (The command in `mobile/android/key.properties.example` still says
  `-storetype JKS` and is stale — ignore its header, the script is the truth.)
- RSA 4096, `-validity 10000` (~27 years) — Play needs an upload certificate
  valid well past 2033.
- Writes `mobile/android/miles-upload.jks` (alias `miles-upload`) **and**
  `mobile/android/key.properties` with `umask 077`. Both are gitignored — three
  gitignores cover `*.jks`, `*.keystore` and `key.properties`.
- **Refuses to overwrite** either file. That refusal is the script working:
  regenerating over a key that has already signed an uploaded bundle locks you
  out of your own listing.
- Finds `keytool` under the JDK / Android Studio JBR when it is not on PATH.
- Certificate identity defaults to `O=R&D Dev, C=PK`, `CN=Miles`. Baked in
  permanently — change it at the prompt if that is wrong.

**Back up the `.jks` and its password to two places that are not this laptop.**
The repo has **no git remote** (`git remote -v` → empty), so losing this disk
today already loses everything.

### 2.2 Confirm gradle picked the key up

This must **not** print the "NO android/key.properties" banner:

```bash
cd /d/Miles/mobile/android && ./gradlew :app:signingReport
```

`storeFile` is resolved by `rootProject.file(...)`, whose root is
`mobile/android/` — which is why the script writes a bare `miles-upload.jks`
and it resolves correctly. If you write `key.properties` by hand instead, use an
absolute path.

### 2.3 The leaked Google Maps key — delete it, don't replace it

**There is no `maps.properties` step any more, and no Maps key to install.**
Mapbox replaced Google Maps on 2026-09-02 and the whole plumbing went with it.
Verified in the tree on 2026-09-03: no `mapsApiKey` or `manifestPlaceholders`
in `mobile/android/app/build.gradle.kts`, no `com.google.android.geo.API_KEY`
in `src/main/AndroidManifest.xml`, no `maps.properties` or `.example` on disk,
no `.gitignore` entry for one, and `pubspec.yaml` ships
`mapbox_maps_flutter: ^2.28.1`. This section used to tell you to create that
file and cited line numbers that no longer hold anything — following it would
have produced a file nothing reads.

**The old key is still burned, and that part is not stale.** The Maps key
`AIzaSyBa6XGz…` is in git history at commits `5403769`, `b591d90` and `75a4459`
(`git log --all -S'AIzaSy'` — all three re-confirmed present 2026-09-03) and
cannot be un-published. Because nothing in the app uses it any more, the action
is simpler than it used to be:

1. In Google Cloud Console (project `ldrc-120a2`), **delete the Android key
   beginning `AIzaSyBa6XGz`** outright. Do not rotate it, do not restrict it —
   nothing needs a Maps key now, so there is no replacement to create.

**Match the prefix before you click.** That project holds more than one
`AIzaSy…` Android key and the console lists them by name and value, not by
repo path. Deleting the wrong one breaks FCM on both handsets.

| prefix | what it is | do |
|---|---|---|
| `AIzaSyBa6XGz…` | the leaked Maps key, no consumer left | **delete** |
| `AIzaSyBHUOM-…` | Firebase **Android** client key (`google-services.json:18`, `firebase_options.dart:63`) | keep — FCM dies without it |
| `AIzaSyC93dDX…` | Firebase **web** client key (`firebase_options.dart:53`) | keep; it is tree-shaken out and is not in the APK |

How urgent: the key is enabled, but the last probe against it (recorded in
`75a4459`'s findings) came back `REQUEST_DENIED` — *"You must enable Billing on
the Google Cloud Project"* — so billing was **off** and nothing is accruing.
The exposure is unauthorised use and quota, not a running bill. This repo is
private, so the deadline is "before the repo goes public or a collaborator is
added", not today. Confirm the billing state in the console rather than
trusting this paragraph; it is one probe old.

**About the two Firebase keys.** They ship on purpose — every Firebase client
embeds one, and `AIzaSyBHUOM-…` is present in `Miles.apk` by design. The
Android one is restricted by package name plus signing-certificate fingerprint;
the **web** one cannot be (that restriction type is Android-only), so it is
protected only by being unused and unshipped. Neither is guarded by Firebase
Security Rules — this app runs no Firestore, Realtime Database, Firebase
Storage or Firebase Auth (`pubspec.yaml` carries only `firebase_core` and
`firebase_messaging`); user data lives in Supabase under RLS. Do not cite
Security Rules as the mitigation for these keys.

### 2.4 Enrol in Play App Signing

Play Console → your app → Test and release → **Setup → App integrity → App
signing**. Let Google generate and hold the app signing key; the key from 2.1
stays an *upload* key, which is what makes it recoverable if you lose it.

Once enrolled, copy the **app signing certificate SHA-1 and SHA-256** from that
page. You need them for one thing now — Firebase: add both fingerprints to the
`com.miles.miles` Android app, or **FCM stops delivering to Play installs**.
Re-download `google-services.json` afterwards.

(They used to be needed for the Maps key restriction as well. There is no Maps
key any more — see 2.3.)

---

## Phase 3 — prove key recovery BEFORE the first Play install exists

This is the phase most likely to be skipped and the one that destroys user data
if it is. **It has never been run** (audit §5, phase 5).

**The problem:** every install in the field today is signed with the **upload**
key — measured off the handset, BRAIN §262 addendum 2 and §263; the older
"debug-signed" note here predates the play-APK ruling in §0.2 and was wrong by
the time phase 3 mattered. It changes nothing about this phase. Under Play App
Signing (§2.4) Google re-signs with an app signing key it holds, so a
Play-delivered build still has a different certificate from anything installed
by cable, and Android still refuses to update over it. Users
must **uninstall** — and uninstall wipes `flutter_secure_storage`, which is
where the X25519 private key lives. Everything end-to-end encrypted (Memory
Threads, Private Vault, Wish Jar entry text) becomes unreadable on the new
install unless recovery works.

Two recovery paths exist. Both must be **proven on real hardware**, not
reasoned about:

1. **Key escrow** (`key_escrow.dart`) — the seed sealed under an Argon2id key
   derived from the account password, restored at sign-in. Test: install play
   build → sign in → confirm Memory Threads / vault content decrypts.
2. **Partner rewrap** (`partner_rewrap.dart`, `rewrap_screen.dart`) — the
   partner's phone hands the retired keys across for anyone whose password
   cannot open the escrow. The table exists on prod
   (`partner_rewrap_requests`, applied as `20260815065624_partner_rewrap`).

**The test, in order, on two handsets:**

```
1. the current cable-installed build (upload-key signed, §0.2) on both
   handsets, couple paired, encrypted content written on both
2. uninstall on phone A  (this is the destructive step — do it deliberately)
3. install the play AAB on phone A (via internal testing, phase 8)
4. sign in with the password        -> escrow restore should return the seed
5. open Memory Threads + the vault  -> content must render, not error
6. repeat on phone B with a FORGOTTEN password, driving the /rewrap ceremony
   from phone A
```

If step 5 fails, **stop the release**. Shipping the migration before recovery
works converts an inconvenience into permanent data loss for every user.

### The version gate is already armed — check it before you build

Prod reads `min_build = 39, latest_build = 39` (verified 2026-08-17), so the
"unarmed, min_build = 2" note this section used to carry is gone. Build 40 is
above the floor; anything at or below 38 is hard-blocked at the block screen.

Raise it again only **after** the Play installs have landed:

```sql
update public.app_release set min_build = <N>, latest_build = <N>;
```

Raising it first locks out the device that has to receive the install.

---

## Phase 4 — build the AAB

Do not run this until phases 1–3 are done. **No AAB has ever been built**, which
means R8, resource shrinking, dexing and the play manifest merge have never once
run together. Budget a debugging pass, not a build step.

Pre-flight (both must be clean; `test/unit/hygiene/repo_hygiene_test.dart:221`
asserts zero analyzer errors **and** zero warnings, so a dirty analyze reds the
suite too):

```bash
cd /d/Miles/mobile && flutter analyze --no-pub
cd /d/Miles/mobile && flutter test
```

Keep `pubspec.yaml`'s `version:` and `release_gate.dart`'s `buildNumber` in
lockstep. Two things enforce it — `test/unit/hygiene/version_lockstep_test.dart`
and `release.sh` itself, which exits on a mismatch — so this is a check, not a
discipline. The two commands below print the live values; no number is repeated
here, because a number written into a runbook is stale by the next build.

```bash
cd /d/Miles/mobile && grep -n '^version:' pubspec.yaml
cd /d/Miles/mobile && grep -n 'buildNumber' lib/core/app/release_gate.dart
```

Build — through the script, not by hand:

```bash
cd /d/Miles/mobile
bash tool/release.sh --play
```

Output: `mobile/build/app/outputs/bundle/playRelease/app-play-release.aab`.

`release.sh --play` is the supported path and it is the only one that carries
the gates: analyze, the full test suite, the version lockstep, the
production-`.env` wall, and — the one that matters most here — the stale-snapshot
check, which reads every `libapp.so` inside the AAB and refuses to ship one whose
Dart is not the Dart just compiled. That guard is not theoretical: it fired on a
real build on 2026-08-30, and this repo has already shipped releases carrying
build-31 code under fresh version numbers. A hand-run `flutter build appbundle`
skips all of it, and a stale AAB on Play costs a review cycle rather than a
re-upload.

Note it does **not** upload, publish, or touch `app_release` — the `--play` path
deliberately stops at the artifact.

The `play` flavor turns **R8 minify + resource shrink on** (via the
`androidComponents.beforeVariants` block at `build.gradle.kts:190-199`) while
`sideload` keeps them off. `proguard-rules.pro` is wired, and Mapbox and
InAppWebView ship consumer rules, but R8 has never run against this app's WebRTC
and ML Kit reflection paths — **a shrunk build can fail only on a device.**
Install through internal testing and exercise a video call, screen share, camera
capture and both maps before promoting it anywhere.

Verify what you actually built before uploading:

```bash
# signed with the upload key, not the debug key
cd /d/Miles/mobile && jarsigner -verify -verbose -certs \
  build/app/outputs/bundle/playRelease/app-play-release.aab | head -20

# the manifest inside an AAB is protobuf, so read it with bundletool:
java -jar bundletool.jar dump manifest \
  --bundle build/app/outputs/bundle/playRelease/app-play-release.aab
```

**What the merged play manifest must show** (this list changed on 2026-08-17 —
the aliases are supposed to be there now):

- `android:label="Miles"`, icon `@mipmap/ic_launcher_play`.
- **`MainActivity` with no intent-filter, plus ten activity-aliases:
  `AliasMiles` enabled and the nine covers all `android:enabled="false"`.**
  Zero aliases means you built the wrong thing; a second enabled alias means
  the manifest test would have caught it, so check that test ran.
- No `READ_MEDIA_IMAGES`, no `READ_MEDIA_VIDEO`, no `ACCESS_BACKGROUND_LOCATION`.
- No `REQUEST_INSTALL_PACKAGES` and no FileProvider — both are declared only in
  `src/sideload`.

If bundletool is not to hand, the same check runs against the play APK, which
is the one testers are running. A bare Gradle build is enough for a permission
audit — `tool/release.sh` would also work but insists on apksigner, the exact
upload fingerprint, a production `.env` and a full analyze + test pass, none of
which a manifest check needs:

```bash
cd /d/Miles/mobile && flutter build apk --release --flavor play
aapt2 dump permissions build/app/outputs/flutter-apk/app-play-release.apk
```

The unshrunk sideload build, for debugging only:

```bash
cd /d/Miles/mobile && bash tool/release.sh --sideload
```

---

## Phase 5 — Play Console declarations

Every one of these is a form that blocks the release if it is wrong.

### 5.1 Photo and video permissions

The manifest declares only `READ_MEDIA_VISUAL_USER_SELECTED` and
`READ_EXTERNAL_STORAGE` (maxSdkVersion 32) — `READ_MEDIA_IMAGES` and
`READ_MEDIA_VIDEO` were removed because every gallery entry point goes through
the system photo picker or `ACTION_GET_CONTENT`, both of which hand back a URI
carrying its own read grant.

Answer: the app does **not** require broad photo/video access. **Verify against
the merged manifest of the actual AAB first** (phase 4) — the declaration is a
statement about the artifact, not about the source.

### 5.2 USE_FULL_SCREEN_INTENT

Play restricts this to calling and alarm apps. **Known problem, still unfixed as
of 2026-08-17:** `lib/core/services/reach_notifications.dart:65` and `:157` set
`category: AndroidNotificationCategory.call`, and `:67` / `:158` set
`fullScreenIntent`, on **Reach** alerts — a partner nudge, not a call.

Fix it before submitting (the fix is a deletion of those lines plus the dead
`fullScreen` parameter) or expect the declaration to be rejected. Do not claim
Reach is a call — it also undermines the declaration you need for real calls.

### 5.3 Foreground service types — resolve `camera` before you fill this in

Declared in `src/main/AndroidManifest.xml` on the flutter_foreground_task service
as `microphone|camera|mediaProjection`. But the runtime set is smaller:
`call_foreground.dart:43-49` requests **microphone**, plus **mediaProjection**
while screen-sharing, and **never camera**.

So `camera` is a type you must either delete or start using — you cannot film a
demo video of a code path that does not run.

| Type | Use case to declare | Demo video must show |
|---|---|---|
| `microphone` | keeping a voice/video call alive while the app is backgrounded | starting a call, backgrounding the app, audio continuing |
| `mediaProjection` | screen share into an active call | the user starting a share and the system consent dialog |
| `camera` | **only if you wire `ForegroundServiceTypes.camera` for video calls** — otherwise remove the type and the `FOREGROUND_SERVICE_CAMERA` permission | a video call surviving a home-button press |

Each video must show the in-app path a user takes to trigger it. Host them
somewhere Google can watch (unlisted YouTube is fine) and paste the links into
the declaration.

### 5.4 Data safety form

Answer from the privacy policy — `web/privacy-policy.html` is the source of
truth and was written from the code, so the two cannot drift if you copy from
it.

Collected and linked to the user: email address, name, photo, approximate and
precise location, messages, photos and videos, voice recordings, files, health
and fitness (the cycle tracker), sexual-orientation-adjacent / intimate content,
app diagnostics, crash logs, device identifiers (the FCM token).

- **Encrypted in transit:** yes.
- **End-to-end encrypted:** answer honestly per data type. Memory Threads,
  Closer's Private Vault and Wish Jar entry text are E2EE. **Chat, location,
  cycle data, presence, `desire_temps`, `dice_rolls`, `body_touches`,
  `intimacy_signals` and the personal vault are not.** Do not tick a blanket
  E2EE claim — the app's own FAQ (`faq_text.dart:61-68`) states the narrow
  version, and a blanket claim would contradict it inside the same binary.
- **Shared with third parties:** no data is sold or shared for advertising.
  Declare the two real egresses deliberately: **Giphy** receives GIF search
  terms, **Mapbox** receives viewport / approximate location.
- **Data deletion:** "users can request that data be deleted", with the URL from
  phase 6.

### 5.5 Content rating (IARC) — Mature 17+

Answer the questionnaire truthfully about the intimacy module. Understating it
is a policy violation with worse consequences than the rating itself.

### 5.6 The rest of the forms

- **Target audience:** adults only, 18+. No child-directed content.
- **Ads:** none. **IAP:** none.
- **News app:** **no.** (The old rationale here — "the play flavor carries no
  News label" — is wrong: the play manifest does declare a `News` cover alias.
  It is disabled, it is a launcher cover, and the app publishes no news content.
  Answer no on the substance, not on the label.)
- **Government app / financial:** no.
- **Location:** foreground only, so the background-location declaration does not
  apply. Confirm the AAB has no `ACCESS_BACKGROUND_LOCATION` — the manifest
  removed it with a comment explaining why.
- **Account deletion:** paste the URL from phase 6 into App content → Data
  safety, and again into the store listing where Play asks for it.
- **App access** — *this is cover requirement 5, and it is mandatory.* The
  reviewer cannot see anything without an account, and pairing is invite-code
  only. Provide:
  - a working test account (email + password) that is already paired, or a
    second account plus the invite code so the reviewer can pair the two;
  - the 18+ age gate and Terms gate stand in front of the app — say so;
  - **the cover feature and the exact way out of it**: "Miles installs as
    itself. If you turn a cover on (Settings → How this app looks) the app asks
    you to set a 4-digit PIN and record your own gesture before anything
    changes. To get back in from any cover: press and hold two fingers still in
    the middle of the cover's opening screen for ten seconds, then unlock with
    that PIN (a fingerprint prompt may appear first; cancel it to type the
    PIN)." A
    reviewer who enables a cover and cannot get back writes the rejection you
    cannot appeal.

### 5.7 Child safety standards (CSAE) — mandatory, and it blocks publishing

Play requires every app in the Social / dating / UGC category to publish child
safety standards and self-certify in Console → App content → **Child safety
standards**. Miles is Social with user-generated content, so this applies. There
is **no way to publish without it**, and today the repo has nothing: a
repo-wide grep for `csae|child safety|ncmec` hits only in-app Terms copy at
`terms_text.dart:115`.

What Console asks for:

1. **A published standards document at a public HTTPS URL** stating the app
   prohibits child sexual abuse and exploitation (CSAE), including CSAM and
   grooming. → does not exist yet; write `web/csae.html` and host it (phase 6).
2. **In-app reporting** for CSAE content. → **built**
   (`lib/features/safety/report_service.dart:48`, RPC `submit_report` at :63,
   three report entry points, mute/unmute, contact pause).
3. **A commitment to act on reports** — remove violating content and enforce
   against accounts. Say what you actually do, in the document.
4. **A named child-safety point of contact** with a role, reachable by Google
   and by users. Today the only published contact is a bare personal Gmail
   (`Razaaslam3210@gmail.com`, developer "R&D Dev"), which is thin for this
   purpose — decide whether that is the published child-safety contact.
5. **Compliance with applicable CSAE law**, including reporting to the relevant
   authority (NCMEC in the US, or your jurisdiction's equivalent).

*Unverified:* the precise Console wording and whether the form counts five items
or four has not been read against a live Console in this session — the audit
counted five. Read the form before writing the document so the document answers
it, not the other way round.

---

## Phase 6 — host the public documents

All of these must be at **stable public HTTPS URLs** before the listing can be
submitted.

| File | Status 2026-08-17 | Used by |
|---|---|---|
| `web/privacy-policy.html` | exists; **hosted copy still renders the "Before publishing" TODO box** (local file line 95) | Play listing "Privacy policy" field **and** the in-app link |
| `web/delete-account.html` | exists; **404 at the hosted URL** | Play Data Safety "account deletion" URL |
| `web/faq.html` | exists; **404 at the hosted URL** | support link |
| `web/csae.html` | **does not exist — write it (5.7)** | Child safety standards URL |

Terms are **in-app only** (`terms_text.dart`, deliberately not a URL — the gate
must work offline). No `terms.html` is required for the listing.

**Host:** the current `pub-…​.r2.dev` bucket is a rate-limited dev host
Cloudflare tells you not to depend on. Register a domain or stand up Cloudflare
Pages before the listing goes in. Every file is single, self-contained, no
external assets, so any static host works.

**Before publishing, fix these in the sources:**

- delete the "Before publishing" block — `web/privacy-policy.html:95`;
- the privacy policy's own deletion link points at `functions/v1/delete-account`,
  which 404s — the real slug is `account-delete`, and it should point at the
  hosted deletion **page** anyway;
- `milesPrivacyPolicyUrl` (`terms_text.dart:17-18`) currently points at the r2.dev
  bucket. It moves when the domain does, and it ships inside the APK — so change
  it **before** the build, not after.

`web/delete-account.html` already points at
`https://sopictusdonlvuezmfep.supabase.co/functions/v1/account-delete` with the
project's anon key, in the CONFIG block at the top of its `<script>` (line 182).
If the project ever changes, that block is the only thing to edit.

The privacy policy is reachable in-app from Settings (`settings_screen.dart:983`,
`_openPrivacyPolicy`) — Play requires both the listing field and the in-app path.

---

## Phase 7 — the store listing, and the cover disclosure

This phase is where cover requirement 4 is satisfied. It is not optional
(0.1).

**7.1 Disclose the cover feature in the full description.** Plain words, no
euphemism, describing what it does and how the user gets back. Something of this
shape, adjusted to your voice:

> **Choose how the app appears.** Miles installs under its own name and icon.
> If you would rather it looked like something ordinary on your home screen,
> Settings → How this app looks lets you pick a different launcher name and
> icon (for example Notes, Weather or Calculator). You choose it; nothing
> changes until you have set a PIN, recorded your own way back in on that
> screen, and confirmed. Only the move you record opens the cover, so choose
> one you will not forget.

(The backup gesture used to be named here. The store listing is public, so it
is not — see the App access note above: Google gets that sentence, users do
not.)

Three properties matter more than the wording: the feature is **named**, it is
**user-initiated**, and the **way back is stated**. Do not bury it in the last
line of a 4000-character description.

**7.2 Show the picker in at least one screenshot.** The disguise picker screen
itself — the list of covers with the confirmation dialog is even better. A
described-but-invisible feature is what Behavior Transparency exists to catch.

**7.3 The rest of the assets** (none exist in the repo today — no fastlane
directory, no screenshots, no descriptions):

- 512×512 32-bit icon, rendered from the `ic_launcher_play` vectors.
  `tool/generate_icon.dart` has no play spec yet.
- 1024×500 feature graphic.
- 4–8 phone screenshots, ≤80-char short description, ≤4000-char full
  description.
- **Keep Touch Trace, Touch Map and the rest of Closer out of every screenshot
  and out of the promo video.** The features are defensible as private UGC; a
  screenshot of them in a public listing is not. The cover picker (7.2) is the
  one Closer-adjacent screen that must be visible.

---

## Phase 8 — release

1. **Internal testing track first.** Upload the AAB, add your own accounts, and
   run the phase 3 recovery test against the real Play-installed artifact.
2. **Closed testing** long enough to see the R8 build behave on more than one
   device model. A personal developer account must also run a closed test with
   12+ opted-in testers for 14 continuous days before it can apply for
   production access. *(Thresholds change — confirm the current numbers in
   Console; organisation accounts with a D-U-N-S number are exempt. Unverified
   against a live Console in this session.)*
3. **Production**, staged rollout. There is no way to un-publish a build that
   has already destroyed someone's keys.
4. After the fleet has moved, raise `app_release.min_build` (phase 3) — never
   before.

---

## What this runbook does not fix

Carried forward and still open at release time. None of them block the
*listing*; all of them bite a real cohort.

- Presence heartbeat writes twice per 5 s per user via `postgres_changes` — the
  documented non-scaling path. ~200 writes/s at 1k concurrent chatters.
- Realtime reconnect has no backoff; a service restart leaves rejected channels
  silently dead.
- Vault previews are in-row `bytea` streamed without `.limit()` — 1k couples
  ≈ 6.4 GB of **database**.
- Sign-out does not empty `DefaultCacheManager`, so a previous couple's images
  stay readable on disk after an account switch.
- Full-screen-intent on Reach (5.2) is a policy problem *and* a user-hostile one.
- `GIPHY_API_KEY` is live in `.env`, shipped, and read by nothing — delete and
  rotate it.
- The migration ledger drift (1.5) is unresolved.

Fixed since this list was first written, so do not re-open them: the blanket
end-to-end-encryption strings were narrowed (`closer_screen.dart:378` now scopes
the claim; `settings_screen.dart` makes none); `care-notify` is retired to a 410
tombstone (`supabase/functions/care-notify/index.ts` — the deployed slug still
answers, which is why the tombstone exists rather than a deleted file); and
`turn-credentials` now requires a JWT (401 without one) and rate-limits to ten
mints an hour per account.
