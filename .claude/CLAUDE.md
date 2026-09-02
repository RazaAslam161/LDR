# Project rules — Miles

Loads on top of `~/.claude/CLAUDE.md`, which holds the global working agreement and names
no project. This file holds only what is true of THIS repo. When the two disagree, the
global file wins on *how to work*; this file wins on *facts about Miles*.

Repo moved from `E:\LDR` to **`D:\Miles`** on 2026-08-23 after a disk failure. Any `E:\`
path in `docs/`, in BRAIN.md, or in an older note is dead — the E: drive does not exist on
this machine.

## What it is

- A private long-distance couples app for one couple. Flutter client in `mobile/`,
  Supabase backend in `supabase/`, static legal pages in `web/`.
- **ONE app, and it ships on Google Play.** Not two products, not a sideload edition
  beside a store edition — the Play build IS the app. Flavors are a build mechanism, never
  a reason to split a decision. Never present a choice as "your build keeps X, the store
  build loses X": decide it once, for the app that goes live.
- **The app is a secure private couples app. It authors no sexual content.** What two
  people do inside it is theirs; the app supplies private space and security, not the
  content. NO app-written copy may be sexual or suggestive — not deck cards, dice faces,
  jar prompts, labels, screen titles or settings text. Features stay; the words the app
  puts in a user's mouth get rewritten neutral. The 18+ tag covers what users bring; it
  does not license the app to write it for them.
- E2EE stays; no plaintext at rest.
- Auth and pairing are built — don't rebuild. When "nothing works" it has always been
  backend config, not the code.

## Build and release

- **Don't build the APK unless asked** (said three times: "don't built apk's until i ask
  you"). Never install to a device unprompted. Finish work → gate → report → STOP.
- Always `cd /d/Miles/mobile` before any flutter command. CWD drifts to the repo root and
  fails with "No pubspec.yaml".
- Bump `pubspec.yaml` and `ReleaseGate.buildNumber` together; a test and `tool/release.sh`
  both enforce the pair. `versionName` is enforced nowhere — check it by hand.
- Raise `app_release.min_build` only AFTER the build is installed and proven.
- "Package appears to be invalid" = transfer corruption, not the build.

### The build that goes to people is the PLAY build (owner's ruling, 2026-09-03)

**Verbatim: "always build the apk in a play store variant — means the app is for
play store, the build here is just for final testing using on random real users
to get final feedbacks and testing before go for play store production. and the
apk should always be clean, updated and for real users."**

So: `bash tool/release.sh` with no arguments builds the **play** flavour as an
APK, and that is what any real person ever installs. It is not a separate
edition — same flavour, same R8, same upload key and the same code as the AAB
that goes to the Console. Not literally the same flags: the APK adds
`-PmilesPlayApkArm64` and the bundle must never have it. Same CODE, to be exact: once Play App Signing is on,
Google re-signs with a key it holds, so a build delivered by Play carries a
different certificate than this APK does. Four consequences, all load-bearing:

- **R8 is on.** The play channel shrinks and minifies (`build.gradle.kts`,
  `beforeVariants`); the sideload channel never did. Every sideload APK a
  tester ran was code that had never been through the shrinker that ships, and
  R8 is exactly what strips the reflection/JNI entry points in WebRTC and ML
  Kit that fail only on a device.
- **It installs over what is already on the phone.** The play flavour is signed
  with `miles-upload.jks` (`CN=Miles, O=R&D Dev, C=PK`), which is the
  certificate the handsets already carry. The sideload flavour is DEBUG-signed
  on purpose and cannot update them — `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, and
  the only way past is an uninstall, which takes the X25519 seed with it
  (BRAIN §262 addendum 2).
- **One ABI in the APK, every ABI in the AAB.** `release.sh` passes
  `-PmilesPlayApkArm64`, and that property excludes every other ABI from the
  play **variant** — which feeds the bundle as well as the APK. Only the
  command being run keeps them apart, so a `gradle.taskGraph` check in
  `build.gradle.kts` refuses the property outright when the bundle is being
  packaged, and `release.sh --play` asserts the finished AAB still carries
  armeabi-v7a, arm64-v8a and x86_64. **Never pass it to a bundle build.** The
  APK is arm64-only because a partial APK installs on a 32-bit phone and then
  dies on a missing engine (measured on build 64, BRAIN §193); one ABI means
  that phone is told the app is incompatible instead.
- **It is not the signature Play will ship.** Play App Signing has Google
  re-sign the bundle with an app signing key it generates and holds. A tester
  who installed this APK by cable therefore still cannot be updated by Play:
  moving them over needs the escrow-then-uninstall ceremony in
  `docs/guides/PLAY-RELEASE-RUNBOOK.md` phase 3. Same code, different
  certificate — do not let "same build" blur the two.

`bash tool/release.sh --sideload` still exists for debugging the unshrunk
build. It prints a warning, and it copies to `Miles-sideload-debug.apk` so it
can never be mistaken for the tester artifact. `Miles.apk` at the repo root is
always the play build.

Still true, and unchanged by the above: **don't build unless asked**, and never
install to a device unprompted.
### One rule here is contradicted by the current code — owner has not ruled (flagged 2026-08-23)

- Rule as written: *"Launcher disguise is intentional — 'News' label + generic icon +
  selectable identities. Never revert."* Both manifests set `android:label="Miles"`,
  `PLAIN_DEFAULT=true` on both flavors, and `.AliasMiles` is the only alias shipping
  `android:enabled="true"` — all nine covers are `enabled="false"`. This was a deliberate
  reversal on 2026-08-16 (BRAIN §32/§34) for Play policy: ships under its own name, covers
  disclosed in the listing and opt-in from Settings. Icons still come from
  `mobile/tool/generate_icon.dart`.

## Backend

- Two Supabase projects — production `sopictusdonlvuezmfep`, staging `zqltaobarpcuantrqxha`.
  Migrations to staging first, verify, then production.
- **Staging is drifted and is not a faithful rehearsal** (BRAIN §65). Verify against prod's
  live definitions when it matters.
- Free-tier auto-pause — "Failed host lookup" means the project is paused, not broken;
  restore via the Supabase MCP, data survives.
- Secrets — Cloudflare TURN credentials and `FUNCTIONS_BASE_URL` live in the `app_secrets`
  table, one row per project. Never in the APK, never in git.
- DDL belongs only in `supabase/migrations/`, 14-digit unique ordering prefix. The prefix
  scheme is "next round hour" and does not match the prod ledger's version numbers — two
  timestamp collisions have already happened between concurrent sessions.

## Handoff

- **`docs/guides/BRAIN.md` is the handoff doc.** Append a new numbered section after every
  completed piece of work, before replying — never rewrite it, never edit another
  session's section. Absolute dates.
- Section numbers are duplicated in seven places because concurrent sessions appended at
  once. Read the tail before starting.
- **Never restate the latest section number, the build number, or a line number here.**
  Every one of them written into this file has gone stale and then misled an agent that
  trusted it. Read them from the files instead:
  `grep -o '^## §[0-9]*' docs/guides/BRAIN.md | tail -1`, `grep '^version:' mobile/pubspec.yaml`.

## State of the machine (2026-08-23)

- Flutter 3.44.2 at `C:\src\flutter`, matching the CI pin. **Not on the permanent PATH** —
  each shell needs `export PATH="/c/src/flutter/bin:$PATH"`.
- **The Android SDK IS installed** (corrected 2026-08-29, BRAIN §193). `adb` lives at
  `~/AppData/Local/Android/Sdk/platform-tools/adb` and `adb devices` answers
  `1896b4b3 device` — the OnePlus 8, on build 64. Device inspection, logcat and installs
  all work. The older "no SDK, no adb" note here was stale and made several sessions
  declare device paths unverifiable when they were not.
- The installed package id is **`com.miles.miles`** — not `com.miles.app`.
- `mobile/.env` was recreated by hand (gitignored). The Google Maps SDK is gone (Mapbox
  replaced it), so `maps.properties` no longer exists as a concept; its example file and
  ignore rule were removed 2026-09-02.

## Tests — two gotchas that each cost a fix (2026-09-02)

- `local_auth`'s channel never answers under `flutter test`; anything that
  awaits `AppLock.availableBiometrics()` hangs. It is a swappable static: set
  `AppLock.availableBiometrics = () async => const [];` in `setUp`, restore
  `AppLock.availableBiometricsLive` in `tearDown`.
- `tester.startGesture` without `pointer:` draws ids from a counter shared
  across every test in the file. Two-finger tests must pass explicit, distinct
  ids for BOTH fingers or the second down asserts "unexpectedly has a
  HitTestResult".

## Open, as of BRAIN §75

- **Production may be ahead of this repo.** Builds have shipped to handsets that exist in
  no commit. Read the tree's build number rather than assuming a baseline.
- **Chat is cipher-only since 2026-09-02** (BRAIN §254). `app_release.chat_cipher_only` is
  true on production; both installed clients (build 73) write `body_cipher` + `body_nonce`
  and no plaintext `body`. Proven the same day: one message each way over the realtime
  path on both handsets rendered from ciphertext alone (rows 4638/4639, body NULL, zero
  `chat-decrypt` client_errors). The §208 realtime double-hex defect is fixed and
  confirmed. Rollback is one statement: `update public.app_release set chat_cipher_only
  = false;` — it restores dual-write for NEW rows only. Rows 4636/4637 (pre-flip test
  messages) still hold plaintext.
- The Google Maps API key is in git history at commit `5403769` (and, until it was
  deleted on 2026-09-02, verbatim in `docs/guides/play-readiness-findings.json`). It is
  live/billable. Rotate it. It is **not** in the shipped APK — Mapbox replaced Google
  Maps — and this repo is private, so the deadline is "before the repo is public or a
  collaborator is added", not today.
