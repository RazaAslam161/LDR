# Miles - repository reference

Written 2026-09-02 from the tree at `D:\Miles`. Every path below exists in that tree. Numbers that move (build number, migration count, handoff section) are given as the command that reads them, not as a value to trust later.

## 1. What it is

- A private long-distance couples app for one couple at a time. Flutter client, Supabase backend.
- One Android app, package `com.miles.miles`, launcher label `Miles`. Two build flavors, `play` and `sideload`, are a build mechanism, not two products.
- The app installs as itself. Nine optional launcher covers exist, all `android:enabled="false"` in both manifests, and are switched on only from Settings.
- End-to-end encryption with a per-couple key. The server stores ciphertext for the encrypted tables and private-bucket media.
- The app authors no sexual content. Features stay; app-written copy is neutral.

## 2. Repository layout

| Path | What lives there |
|---|---|
| `mobile/` | The Flutter app. `pubspec.yaml`, `lib/`, `test/`, `tool/`, `android/`, `third_party/`. |
| `mobile/lib/main.dart` | Boot sequence and `MilesApp` (cover, lifecycle, deep links, heartbeat). |
| `mobile/lib/core/` | Cross-feature machinery, one directory per concern (section 5). |
| `mobile/lib/features/` | One directory per feature; screens, controllers and repositories together (section 4). |
| `mobile/test/unit/`, `mobile/test/widget/` | The suite `flutter test` runs. `test/unit/hygiene/` asserts repo shape. |
| `mobile/tool/` | `release.sh`, `dep_audit.dart`, `generate_icon.dart`, `generate_art.dart`, `build_opening.py`, `make-keystore.sh`. |
| `mobile/third_party/flutter_webrtc` | The one vendored fork (two MediaProjection patches, see `pubspec.yaml`). |
| `supabase/migrations/` | The database, in replay order. The only place DDL belongs. |
| `supabase/functions/` | Edge Functions (Deno), one directory each. |
| `supabase/diagnostics/` | Read-only SQL: `verify_applied.sql`, `diagnose_*.sql`. Never applied as migrations. |
| `supabase/scripts/dump_schema_snapshot.sql` | Regenerates `supabase/schema_snapshot.json`, which `schema_drift_test.dart` reads. |
| `supabase/config.toml` | Local stack config for `supabase start` (Postgres 15). No credentials. |
| `web/` | The hosted legal and safety pages, deployed to Vercel (project `miles-legal`) from this directory. The single source for that text; `vercel.json` carries the CSP. |
| `scripts/` | `check-turn.ps1` (does TURN return an `iceServers` array), `film-render/` and `film-shoot/` (intro film pipelines). |
| `docs/` | `REFERENCE.md`, `FIELD-TEST.md`, then `guides/` (current) and `archive/` (superseded). |
| `.github/workflows/gates.yml` | CI: analyze, test, dependency advisories. |

Root working files that are present but gitignored: `Miles.apk`, `archive/`, `art_drop/`. The tracked root is only `README.md` and `.gitignore`; a test enforces that.

## 3. Runtime architecture

### Startup (`mobile/lib/main.dart`)

1. `silenceLogsInRelease()`, then `WidgetsFlutterBinding.ensureInitialized()`.
2. `FlutterError.onError` and `platformDispatcher.onError` route to `ErrorReporter` (`core/diag/`).
3. `dotenv.load()`. Empty `NEXT_PUBLIC_SUPABASE_URL` or `NEXT_PUBLIC_SUPABASE_ANON_KEY` throws before the first frame.
4. One `Future.wait`: `Firebase.initializeApp`, `SupabaseService.init`, `MilesApp.loadSetupFlag`, `DisguiseService.loadEnabled`, `UpdateService.loadAllowed`, `Diag.init`.
5. A second `Future.wait`, after the first on purpose: `TermsGate.load`, `ReleaseGate.check`. `startup_order_test.dart` pins this order.
6. Unawaited: `ErrorReporter.flushBuffered`, `ContactPause.load`, `MilesSound.loadPref`. Sound probes and the fleet kill switch are wired.
7. `FirebaseMessaging.onBackgroundMessage` registered, `TzHelper.ensureInit`, `initRealtimeAutoResume`, `FcmService.init` (unawaited), foreground-task port, `PipMode.wire`.
8. `runApp(ProviderScope(MilesApp))`.

`MilesApp` owns `showRealApp` (cover up or down). Any backgrounding raises the cover on a channel with a disguise; only the cover's own entry flow lowers it. A 30 s foreground heartbeat stamps presence only while the real app is visible. Deep links come through `app_links`. A panic lock (shake three times, or volume up then down) snaps back to the cover.

### State

- Riverpod. `SessionNotifier` (`core/app/session_provider.dart`) is a `StateNotifier<SessionState>` holding session, profile, couple, partner and load failures.
- `core/app/providers.dart` exposes narrow read-only slices (`currentProfileProvider`, `currentCoupleProvider`, ...).
- A few app-wide facts are static `ValueNotifier`s so the router can listen: `CryptoCore.keyless`, `TermsGate.accepted`, `SeveranceState.held`, `UnlinkState.current`.

### Routing (`mobile/lib/core/app/router.dart`)

- `go_router`. `refreshListenable` merges the session and the four notifiers above.
- One redirect enforces the whole funnel, in this order: `/new-password` passes; loading waits; unauthenticated to `/signin`; terms not accepted to `/terms`; profile load failed to `/offline`; no profile to `/welcome`; no couple to `/couple` (with a `/rewrap` allowance when a dissolved couple is still inside its window); no gender set to `/role-setup`; keyless device to `/rewrap` (`/call` excepted); open unlink ceremony to `/unlink` (exits, export and `/call` stay reachable); then auth and onboarding paths sweep to `/app`.
- Routes: `/signin`, `/signup`, `/new-password`, `/welcome`, `/couple`, `/role-setup`, `/terms`, `/offline`, `/rewrap`, `/unlink`, `/app`, `/app/settings` (+ `/export`, `/profile`, `/notifications`, `/account`), `/app/partner`, `/app/disguise`, `/app/rapid-camera`, `/app/capsule` (+ `/new`, `/view`, `/fill`), `/app/vault`, `/app/breath`, `/app/touch`, `/app/reasons`, `/app/care`, `/app/watch`, `/app/cycle`, `/app/heartbeat`, `/app/games` (+ `/truth-dare`, `/would-you-rather`, `/never-have-i-ever`), `/call`, `/app/rituals`, `/app/prompt`, `/app/timeline`, `/app/location-map`, `/app/closer/touch-trace`, `/app/closer/mood-lamp`, `/app/closer/warmth`, `/app/closer/memory-threads` (+ `/propose`), `/app/closer/wish-jar`, `/app/closer/pick-for-us`, `/app/gallery`, `/app/routines`, `/app/watch-list`, and `/` which redirects to `/signin`.
- `PresenceRouteObserver` is installed on the router, so every route publishes which screen the user is on.
- `AppShell` (`/app`) is the bottom bar: Home, Chat, Camera (a push, not a tab), Touch and Closer (the last two conditional).

### Realtime

- `core/realtime/realtime_service.dart`: couple-scoped `postgres_changes` subscriptions and ephemeral broadcast channels, one entry point. RLS still gates delivery.
- `core/realtime/realtime_resume.dart`: `realtimeResumed` ticks on every socket (re)connect; every per-screen subscription re-subscribes on it.
- Screen presence rides a `screen_presence:<coupleId>` broadcast (`core/widgets/partner_here_badge.dart`); the durable presence row is `core/services/presence_service.dart`.
- Call signalling is a `call:<coupleId>` broadcast (`features/call/call_controller.dart`).

### Push

- FCM HTTP v1, data-only messages, sent by the `reach-notify` edge function. Kinds include Reach, call, care, unlink and a silent `msg_sync` that only acks delivery.
- `core/services/fcm_service.dart` wires permission, token lifecycle, the local-notification channels and the foreground and tapped handlers. The background handler is registered before `runApp`.
- `core/services/session_scope.dart` keeps a push addressed to a device token from landing in the wrong signed-in couple.

## 4. Feature map (`mobile/lib/features/`)

- `auth` - sign in, sign up, password recovery, welcome (profile), couple pairing by invite code, role setup, offline wait screen, and the rewrap key ceremony.
- `breath` - shared 4-7-8 breathing pacer; both phones pulse in step over a channel.
- `call` - 1:1 WebRTC video calls, signalling over broadcast, PiP window, foreground service, screen share.
- `capsule` - time capsules whose items stay sealed until `unlocked_at`; a proximity unlock uses coarse location.
- `care` - gentle reminders sent to the partner, who taps Done.
- `chat` - messages (text, image, voice, video, file), rapid camera, reactions, receipts, send queue, GIF picker, chat themes, albums, link cards.
- `closer` - the intimacy module behind modest mode and the couple key: `memory_threads`, `mood_lamp`, `pick_for_us`, `touch_trace`, `warmth`, `wish_jar`, plus `secure_screen.dart`.
- `covers` - the News cover: a working RSS reader with no door of its own.
- `cycle` - period calendar with optional sharing and a partner card. The pooled love notes are held back by `FeatureFlags`.
- `daily_prompt` - one question a day; answers reveal only after both have answered.
- `disguise` - launcher identity switching through `activity-alias`, the nine cover screens under `covers/`, the picker, the cover gate and host, and under `entry/` the owner-recorded move: its model and store, the pointer layer that matches it and the backup hold, and the recorder.
- `gallery` - the couple's shared roll, built on the chat media pipeline.
- `games` - games hub: synced Truth or Dare, plus card decks (Would You Rather, Never Have I Ever).
- `heartbeat` - fingertip over camera and torch reads a pulse; the partner's phone throbs with it live.
- `home` - landing screen: how the partner is right now, the Reach button, partner location card, location map, 3D world map.
- `intro` - the wordmark splash between cover unlock and the app.
- `legal` - `TermsGate` (acceptance enforced in the router), terms and FAQ screens and their text.
- `opening` - the 14 s film a couple sees once after pairing; never blocks entry.
- `photo` - preset filter editor applied after capture.
- `profile` - partner profile and the shared-media window.
- `reach` - hold-to-Reach button, full-screen overlay when a Reach lands, repository.
- `reasons` - a jar of notes; one is featured each day.
- `reels` - links they send each other to watch, with who-has-watched tracking and share intake.
- `rituals` - the couple's recurring rituals, list and create.
- `routines` - daily chart, one list, two columns of ticks, each on their own local date.
- `safety` - contact pause (mute), reconnect sheet, report service, severance state and sheet for a couple that ended.
- `settings` - Settings as one screen with root, profile, notifications and account pages; data export; security code dialog.
- `shell` - `AppShell` bottom navigation and the drawer.
- `timeline` - visit history and the next-visit countdown.
- `touch_map` - one shared photo screen; a touch lands on both phones with haptics.
- `unlink` - the unlinking ritual screen and its Doorstep scene (`scene/`: films, conversation, sync).
- `vault` - PIN or biometric gated private items, owner-only, with a local video server for playback.
- `watch` - watch together: YouTube inline, others by embed or browser; play, pause and seek synced over broadcast.

## 5. Core map (`mobile/lib/core/`)

- `app` - `config.dart` (env keys), `feature_flags.dart`, `logging.dart`, `providers.dart`, `release_gate.dart` (`buildNumber`, `versionName`, `buildStamp`, `min_build` block), `router.dart`, `session_provider.dart`, `root_scaffold_key.dart`.
- `data` - `crypto_core.dart`, `couple_key.dart`, `key_escrow.dart`, `partner_key_pin.dart`, `partner_rewrap.dart`, `models.dart`, `media_urls.dart`, `supabase_repository.dart`, `supabase_service.dart`.
- `diag` - the crash and diagnostic reporter; best-effort, buffered to disk until a launch can deliver it.
- `links` - classify a URL without the network, decide how to open it, and where it points.
- `media` - the encrypted media cache (three layers), decode queue, normalisation, `MediaSource` (a path and a bucket, never a URL), thumbnails and backfill, Mapbox token fetch.
- `net` - `TimeoutHttpClient`, a ceiling under every Supabase call.
- `realtime` - `RealtimeService`, `realtimeResumed`, `PresenceRouteObserver`.
- `services` - app lock, emergency lock, FCM, presence, Reach notifications, location, pickers, save media, data export, GIPHY, server clock, session scope, notification channels, unread tally, update service, haptics, and `sound/` (`MilesSound`, one gate chain for every cue).
- `time` - `TzHelper`, IANA zone conversion for the partner's wall clock.
- `ui` - the Emberlight theme (`MilesColors`, bundled Fraunces and Inter), motion tokens, route motion, tab dissolve, mood data, content language.
- `utils` - `JsonUtils`, defensive parsing for every row.
- `widgets` - shared widgets: ember background, lock screen, stealth overlay, presence figures and badge, `SurfacePanel` (opaque, no blur), update sheet, wordmark, hold-to-confirm, and the rest.

## 6. Backend

- Two Supabase projects. Production `sopictusdonlvuezmfep`; staging `zqltaobarpcuantrqxha`. Migrations go to staging first, then production. Staging is drifted and is not a faithful rehearsal.
- Free-tier auto-pause: "Failed host lookup" means the project is paused, not broken.

### Edge functions (`supabase/functions/`)

- `account-delete` - the browser route to delete an account (Play requires one outside the app). Proves identity with an emailed code, then calls `delete_my_account` on the caller's own session. `verify_jwt` off.
- `care-notify` - retired. Answers 410 and nothing else; the tombstone is what retires the deployed slug.
- `giphy-key` - hands a signed-in, paired caller the Giphy key from `app_secrets`.
- `map-token` - hands a signed-in, paired caller the Mapbox public token from `app_secrets`.
- `reach-notify` - FCM HTTP v1 data-only push, invoked on `reach_events` inserts and by the care trigger. Needs the `FCM_SERVICE_ACCOUNT` and `FCM_PROJECT_ID` function secrets.
- `reap-storage` - deletes the storage objects behind deleted rows through the Storage API. Called by `pg_cron` with the shared trigger secret.
- `turn-credentials` - mints short-lived Cloudflare TURN credentials from `app_secrets`; per-account minting is capped by `claim_turn_mint()`.

### Migrations (`supabase/migrations/`)

- Count them: `ls supabase/migrations/*.sql | wc -l`. 159 on 2026-09-02.
- Ordering is the filename: a 14-digit prefix, replayed lexically. The prefix is an ordering key, not a timestamp; two concurrent sessions have collided on it before.
- Append only. Never edit an applied migration; write a new one. DDL only; diagnostics live in `supabase/diagnostics/`.
- `migrations_hygiene_test.dart` enforces the unique prefix, no hardcoded project URL, and that every table the client queries is created by a migration.
- Full rules and the baseline procedure: `supabase/migrations/README.md`.

### Secrets

- The `app_secrets` table, one row per project, holds `CF_TURN_KEY_ID`, `CF_TURN_API_TOKEN`, `MAPBOX_PUBLIC_TOKEN`, `GIPHY_API_KEY` and the functions base URL. Never in the APK, never in git.
- `mobile/.env` (gitignored) holds only the Supabase URL and anon key, which RLS assumes are public. `mobile/.env.example` documents the keys; a test checks it matches `config.dart`.
- Release signing lives in `android/key.properties` and a keystore, both gitignored; `tool/make-keystore.sh` creates them.

### Encryption

Each device holds one X25519 private key in the platform keystore through `flutter_secure_storage`, scoped per signed-in account and never backed up. It publishes its public key through `partner_keys` and derives the couple's shared key by ECDH plus HKDF; that shared key is cached for the session and never persisted. `CryptoCore.encryptBytes` refuses without a derived key, and `decryptBytes` authenticates every row or fails. The partner's public key is pinned on first use (`partner_key_pin.dart`); a changed key refuses to proceed until confirmed. `key_escrow.dart` seals the seed under a key derived from the user's password and keeps the sealed form server-side so a reinstall can recover history; the rewrap ceremony (`/rewrap`) handles the case where it cannot. `couple_key.dart` makes the same key available to paths outside Closer, such as chat, answering with a bool and never throwing. Sources: `mobile/lib/core/data/crypto_core.dart`, `couple_key.dart`, `key_escrow.dart`, `partner_key_pin.dart`.

## 7. Build, flavors and release

```bash
cd /d/Miles/mobile          # every flutter command runs here; the root has no pubspec
export PATH="/c/src/flutter/bin:$PATH"
flutter pub get
flutter test
bash tool/release.sh        # sideload: gates, build, hash only
bash tool/release.sh --play # gates, then the play AAB for the Console
```

- `release.sh` flags: `--ship` (bump, build, upload to R2, verify hosted bytes, publish the `app_release` row), or any of `--bump`, `--upload`, `--verify`, `--publish` alone, or `--play`. `--play` cannot combine with the sideload flags. It refuses to run if `mobile/.env` does not point at production unless `MILES_ALLOW_NONPROD=1`.
- The sideload build is `flutter build apk --release --flavor sideload --target-platform android-arm64`; packaging excludes strip every other ABI so a 32-bit phone is told "not compatible" instead of installing a broken app. The play build is `flutter build appbundle --release --flavor play`.
- Version: `grep '^version:' mobile/pubspec.yaml` (0.1.0+73 on 2026-09-02). Bump the `+N` and `ReleaseGate.buildNumber` together; `version_lockstep_test.dart` and `release.sh` both enforce the pair. `versionName` is checked by hand.
- Raise `app_release.min_build` only after a build is installed and proven.
- Do not build an APK or install to a device unless asked.

### Flavors (`mobile/android/app/build.gradle.kts`)

| | `sideload` (default) | `play` |
|---|---|---|
| `DISGUISE_ENABLED` | true | true |
| `PLAIN_DEFAULT` | true | true |
| `SELF_UPDATE` | true | false |
| Signing | always the debug key (keeps the installed base updatable) | release upload key, no fallback; the build stops without it |
| R8 minify and shrink | off | on |
| Artifact | one arm64-v8a APK | AAB |
| Manifest extras | `REQUEST_INSTALL_PACKAGES` and a `FileProvider` in `src/sideload/AndroidManifest.xml` | none |

- Both `src/play/AndroidManifest.xml` and `src/sideload/AndroidManifest.xml` set `android:label="Miles"`, enable only `.AliasMiles`, and declare nine covers disabled: News, Calculator, Notes, Weather, Convert, Recorder, Timer, Level, Device Info. `disguise_profile.dart` and `tool/generate_icon.dart` must stay in step with them.
- `namespace` and `applicationId` are `com.miles.miles`; `compileSdk` 36; `minSdk` comes from the Flutter SDK (24).
- Permissions are declared in `src/main/AndroidManifest.xml` with a reason per line; there is no background-location permission.

### Dependencies (`mobile/pubspec.yaml`)

- Backend and state: `supabase_flutter`, `flutter_riverpod`, `go_router`, `flutter_dotenv`, `shared_preferences`.
- Crypto and locks: `cryptography`, `crypto`, `flutter_secure_storage`, `local_auth`.
- Push: `firebase_core`, `firebase_messaging`, `flutter_local_notifications`.
- Calls: `flutter_webrtc` (overridden to `third_party/flutter_webrtc`), `wakelock_plus`, `flutter_foreground_task`, `permission_handler`.
- Media: `image_picker` (+ `_android`, `_platform_interface`), `image_cropper`, `image`, `flutter_image_compress`, `camera`, `video_thumbnail`, `record`, `just_audio`, `audio_session`, `video_player`, `chewie`, `youtube_player_flutter`, `flutter_inappwebview`, `cached_network_image`, `flutter_cache_manager`, `file_picker`, `screen_brightness`, `google_mlkit_subject_segmentation`, `google_mlkit_pose_detection`.
- Location and maps: `geolocator`, `geocoding`, `mapbox_maps_flutter`.
- Motion and misc: `lottie`, `flutter_animate`, `vibration`, `sensors_plus`, `app_links`, `url_launcher`, `http`, `xml`, `uuid`, `path_provider`, `intl`, `timezone`, `cupertino_icons`. Dev: `very_good_analysis`.
- Not in the tree any more: `google_fonts` (Fraunces and Inter are bundled), `workmanager`, `google_mobile_ads`, `flutter_map`, `webview_flutter`.
- Assets: `.env`, `assets/emoji/`, `assets/sound/`, `assets/art/`, `assets/scene/`, `assets/presence/`, `assets/opening/`, `assets/unlink_films/`, the two OFL texts, and the two font families. `asset_hygiene_test.dart` holds each directory to a size ceiling.

## 8. Gates and hygiene rules

### CI (`.github/workflows/gates.yml`)

- Runs on push to `main` and `fix-sprint`, and on every pull request. Read-only token. Flutter pinned to 3.44.2.
- Job `gates`: `flutter pub get`, a placeholder `.env` so the asset bundle builds, `flutter analyze` counted on errors and warnings only (the tree carries infos), with a blindness check that fails when the analyzer prints no summary, then `flutter test`.
- Job `dependency-advisories`: `flutter pub outdated` (report only) and `dart run tool/dep_audit.dart` against osv.dev. Exit 0 clean, 1 an advisory or an unreadable lock, 75 inconclusive (warned, not red).
- `pubspec.lock` is gitignored, so CI resolves fresh on every run. Written down in the workflow as a known limit.

### Repo hygiene (`mobile/test/unit/hygiene/repo_hygiene_test.dart`)

- The tracked root holds only `README.md` and `.gitignore`; no `.apk`, `.aab`, `.ipa`, `.jar`, `.so` or `.zip` is tracked; no web-stack config sits at the root.
- `docs/` root holds only `REFERENCE.md` and `FIELD-TEST.md`; everything else is filed under `docs/guides/` or `docs/archive/`.
- `.env.example` documents every key `config.dart` reads.
- Zero dead code: every file under `lib/` is referenced by another, no line of commented-out code, every declared dependency is imported or referenced.
- The suite runs `flutter analyze` itself and requires zero errors and zero warnings; `// ignore:` occurrences are capped at 4.
- Every source path a test names must exist.
- No glassmorphism: no `BackdropFilter` or `ImageFilter.blur`, the old glass vocabulary is banned, and any surface with content on it is opaque.

### The other hygiene tests

- `asset_hygiene_test.dart` - nothing ships unreferenced, nothing referenced is missing, per-directory size ceilings.
- `migrations_hygiene_test.dart` - unique 14-digit prefixes, no hardcoded project URL, every client table created by a migration.
- `schema_drift_test.dart` - every column the client writes or filters on exists in `supabase/schema_snapshot.json`.
- `leave_couple_privacy_test.dart` - `leave_couple()` keeps its presence scrub.
- `notification_channel_rows_test.dart` - every notification channel has a row in Settings.
- `motion_hygiene_test.dart` - the motion set stays opacity and transform only.
- `source_is_reviewable_test.dart` - no NUL byte in a source file, so git can diff it.
- `startup_order_test.dart` - `ReleaseGate.check` and `TermsGate.load` stay after `SupabaseService.init`.
- `version_display_source_test.dart` and `version_lockstep_test.dart` - one home for the version string; pubspec `+N` equals `ReleaseGate.buildNumber`.

Never pass a gate by weakening it. A red gate is reported, not edited around.

## 9. Other documents

- `docs/guides/BRAIN.md` - the session handoff log. Append a numbered section after every completed piece of work; never rewrite. Latest section: `grep -o '^## §[0-9]*' docs/guides/BRAIN.md | tail -1`.
- `docs/guides/PLAY-RELEASE-RUNBOOK.md` - the ordered Play release phases.
- `docs/guides/THREAT-MODEL.md` - the threat model (last reviewed 2026-08-18; path references inside it predate the move to `D:\Miles`).
- `docs/guides/disguises.md` - the nine launcher identities and how to get back in from each.
- `docs/guides/DEVICE-CHECKLIST.md` - checks that need a handset: sound, haptics, motion.
- `docs/guides/design-system.md` - the Emberlight design system. `docs/guides/ART-PROMPTS.md` - the art prompts behind the bundled illustrations.
- `docs/FIELD-TEST.md` - how to run a two-phone test and read the trace.
- `docs/archive/` - superseded audits, plans and specs, including the old architecture set under `docs/archive/architecture/` and `docs/archive/SIDELOAD-UPDATE-RUNBOOK.md` (the self-update channel `release.sh --ship` drives). History only.
- Legal text has one source, `web/`. The in-app copies (`mobile/lib/features/legal/faq_text.dart`, `terms_text.dart`) mirror it by hand in the same change.
- `D:\Miles\.claude\CLAUDE.md` - project working rules; `~/.claude/CLAUDE.md` - the global working agreement.
