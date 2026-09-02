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

### Two rules here are contradicted by the current code — owner has not ruled (flagged 2026-08-23)

- Rule as written: *"When a build IS asked for: ONE universal APK, no `--split-per-abi`."*
  `mobile/tool/release.sh:337` runs `flutter build apk --release --flavor sideload
  --target-platform android-arm64`, and `:321` calls that "the ONLY lever that works". The
  output is arm64-only, not universal. **Measured on the real build-64 APK (BRAIN §193),
  the consequence is worse than "cannot install": `lib/armeabi-v7a/` still ships nine
  third-party `.so` files and NO `libflutter.so`/`libapp.so`, because `--target-platform`
  filters only Flutter's own libraries and never the AAR ones. Android matches that ABI
  directory, installs, and the loader then fails — a 32-bit handset installs a broken app
  and crashes on launch.** Do not silently follow either version; ask.
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
