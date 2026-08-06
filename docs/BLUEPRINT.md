# LDR / Tethered — Technical Blueprint

This document describes the state of the codebase at `E:\LDR` on branch `fix-sprint`, HEAD `e01e30b` (2026-08-06). It covers the Flutter client at `mobile/`, the Supabase backend at `supabase/`, and an abandoned Next.js web project at the repo root. Every claim here is anchored to a file path and, where useful, a line number. Where source material was contradictory or unverifiable, the section says so rather than resolving it silently.

## 1. Executive summary

**What this is.** A Flutter 3.44 / Dart 3.12 Android app (`com.miles.miles`) backed by a single Supabase project (`sopictusdonlvuezmfep`, ap-south-1, Postgres 17, **Free plan**). It is a long-distance-relationship app for exactly one couple: 28 feature modules covering chat, WebRTC voice/video calls, live location, shared breathing, haptic "reach" pings, time capsules, cycle tracking, and an adult intimacy module called Closer. It ships as a sideloaded APK disguised on-device as a news reader.

**Its real state.** The app builds and runs. `flutter analyze` reports 0 errors and ~1476 info/warning lints; `flutter test` passes 32 tests; a release APK builds at 152.5 MB across three ABIs. That is where the good news stops. The codebase carries three distinct classes of problem that a launch decision must confront:

| Class | Representative facts |
|---|---|
| **Cannot ship as-is** | Release builds are signed with the **debug keystore** (`mobile/android/app/build.gradle.kts:32-36`) — no `signingConfigs` block, no `key.properties`. AdMob runs on Google's public **test** App ID and test unit IDs; production IDs are literal `REPLACE_WITH_YOUR_BANNER_UNIT_ID` strings. |
| **Security claims are false** | `mobile/lib/core/crypto_core.dart` is an identity pass-through as of 2026-06-25 — `encryptString` returns `base64Encode(utf8.encode(plaintext))` with a zero-filled 24-byte nonce and zero-filled 16-byte MAC. Every Closer `bytea` column stores recoverable plaintext. Five separate UI strings still tell the user their data is "end-to-end encrypted." |
| **Backend is not reproducible** | `supabase/` has no `migrations/`, no `config.toml`, no lockfile of applied scripts — 27 loose `.sql` files ordered by header comments. Four tables the shipped client reads and writes (`love_reasons`, `cycle_settings`, `cycle_events`, `care_nudges`) have **no DDL anywhere in the repo**. A fresh Supabase project cannot be rebuilt from this directory. |

**The single biggest decision.** The team must decide, explicitly and first, whether this app is going to a public store or staying a private sideload — because the two answers produce different codebases and the repo currently contains both.

The public-launch path requires reverting the disguise (`android:label="News"` plus a Google-News-style icon, which conflicts head-on with Play's Deceptive Behavior policy), obtaining Play Console declarations for `ACCESS_BACKGROUND_LOCATION`, `USE_FULL_SCREEN_INTENT` and the media permissions, adding real signing, replacing the ad IDs, and either restoring E2EE or deleting every encryption claim in the UI. The private path requires none of that, but makes the Free-plan Supabase project the whole product's single point of failure: **the backend auto-paused after ~7 days idle on 2026-08-06, its DNS record was withdrawn, and the app went down with `Failed host lookup … errno = 7`.** Data survived (5 users, 5 profiles, 4 couples, 24 messages) and the project was restored via the Supabase API. This will recur on every idle week.

Everything else in this document — dead modules, duplicated realtime teardown logic, an untested router, a contradictory doc set — is downstream of that fork. Deciding it is not a planning exercise; it determines which half of the current work is waste.

## 2. Product overview

### Vision and users

The current product is described in `TETHERED_FULL_DOCUMENTATION.md:3-4` as "a private, invite-only long-distance couples app, built for ONE couple… Not on any store — sideloaded APK." The code matches this: 28 feature directories under `mobile/lib/features`, including `closer` (adult intimacy), `intimacy`, `vault`, `touch_map`, `cycle`, `call`, and `fake_news`.

An older vision persists in the repo and contradicts it. `ROADMAP.md` (last updated 2026-06-23) describes "Miles": a public Android app, Play Store launch, freemium pricing ("Together" at $5/mo or $39/yr), a $100/mo MRR goal in six months, four MVP features (Countdown, Sky Bridge, Breath Sync, Reach), and a "Maya & Jordan" persona. Two of those four MVP features — Countdown and Sky Bridge — are now dead code with no route and no import.

`README.md` is the most stale artefact in the repo. It describes a Next.js 14 / Tailwind / Stripe / Resend / Vercel web app and does not mention Flutter at all; its status line reads "Phase 0 — Listening." The dead Next.js scaffold it describes is still physically present at `E:/LDR/src` with `package.json`, `next.config.js`, and 19 source files across 7 routes. Exactly 1 of the repo's 106 commits touches `src/` (the initial commit, 2026-06-24); 104 touch `mobile/`. `node_modules/` is empty, there is no lockfile, no `.next/`, and no git remote.

**A new developer reading `README.md` first will build the wrong thing.** That file should be replaced or deleted before this blueprint is circulated.

### Naming

Four names are in simultaneous use, none of them wrong in its own context:

| Name | Where it lives | Meaning |
|---|---|---|
| **Tethered** | `mobile/lib/main.dart:441` (in-app wordmark); the 16 loose `Tethered-*.apk` artefacts in the repo root | Current user-facing product name |
| **Miles** | `mobile/pubspec.yaml:1` (`name: miles`), `MilesApp`/`MilesColors`/`MilesConfig`, `com.miles.miles` | Legacy name, baked into the Dart package and Android applicationId — cannot be changed without a reinstall |
| **News** | `mobile/android/app/src/main/AndroidManifest.xml:45` (`android:label`), plus a matching Google-News-style icon generated by `mobile/lib/tools/generate_icon.dart` | **Deliberate disguise, not a bug.** Do not revert. |
| **LDR** | The repo root directory `E:\LDR`, the Supabase project display name | Working name for the repo itself |

`ROADMAP.md:224` still lists "Final name + Play Store package ID (current: `com.miles.app`)" as an open question; the shipped id is `com.miles.miles`. `TETHERED_FULL_DOCUMENTATION.md` states in three places (lines 4, 24, 50) that the on-device label is "System Services" — it is "News", and there is a full fake-news cover feature at `mobile/lib/features/fake_news/`.

### Design language — "Emberlight"

`docs/_design_spec.md:3` defines the real design system: "a wine-dark room… lit by one low flame." It is implemented in `mobile/lib/core/theme.dart` (271 lines).

| Element | Value |
|---|---|
| Palette | `night` `#120A0C`, `surface1` `#221017`, `ember` `#E8674A`, `blush` `#C84B6A`, `gilt` `#D9A86C`, `star` `#8B7CF0`, `cream` `#FCEFE6` |
| Type | Fraunces (display/headline) + Inter (title/body/label), via `google_fonts` — `theme.dart:119-143` |
| Surfaces | `GlassPanel` (`glass_panel.dart:11-53`): `ClipRRect` → `BackdropFilter` → tinted container with a gilt hairline |
| Backdrop | `EmberBackground` (`ember_background.dart:11-88`): one 36s `AnimationController` driving a `CustomPainter` over 14 embers and 34 stars |
| Named motion | EmberPress, CandleBreath, DissolveIn, StarfieldDrift, OrbBreathe, GiltSelect, ReachPulse, CountTick, GravityFloat |

Two structural notes. First, `milesDarkTheme()` (`theme.dart:145-267`) deliberately sets `scaffoldBackgroundColor: Colors.transparent` and `colorScheme.surface: Colors.transparent` so the globally-mounted `EmberBackground` shows through every screen. Second, the theme keeps back-compat aliases (`navy950`→`night`, `coral500`→`ember`) at `theme.dart:19-20, 26, 43-46` for screens written against `ROADMAP.md`'s superseded "cream + deep navy + soft coral" palette.

There is **no light theme for the real app**. The News cover uses a completely separate inline `ThemeData` (`main.dart:358-366`): light, white scaffold, seed colour `#1A73E8` — chosen to share nothing with Emberlight.

Two drifts worth fixing: the design spec's flagship Welcome screen shows a "Miles" wordmark where the code renders "Tethered", and the spec assumes a 5-tab dock where `TETHERED_FULL_DOCUMENTATION.md:129` lists six tab screens and the shipped `AppShell` has four or five depending on adult status. `docs/_design_spec.md:1` also opens with leftover assistant prose ("I'll synthesize the spec directly. The three directions all share coral-on-deep-night DNA…") that needs trimming.

## 3. Architecture

### Client architecture

A thin, deliberately hand-rolled foundation: 5,920 lines across `mobile/lib/main.dart` and 46 files under `mobile/lib/core/`, plus 28 feature directories. There is no dependency injection, no code generation (no `freezed`, no `json_serializable`), and no interfaces — every file in `core/services/` is a class with a private constructor and only static members. Nothing is mockable.

`mobile/lib/core/models.dart` (293 lines) hand-writes `fromJson` for `Couple`, `Profile`, `Visit`, `Ritual`, `DailyPrompt`, `PromptResponse`, with no `toJson` — writes go through explicit maps in the repository. Every field routes through `mobile/lib/core/utils/json_utils.dart`, whose header states the rule explicitly: never cast raw inside a `fromJson`, because one malformed row would crash a whole list.

**The repository layer is bypassed by most of the app.** `mobile/lib/core/supabase_repository.dart:7` claims "All Supabase queries go through here so the screens stay thin," but 45 files reference `SupabaseService.client` directly versus 16 that use `SupabaseRepository`. RLS is the only thing enforcing couple-scoping for those 45; there is no client-side chokepoint to audit.

### State management — two parallel systems

**System 1: Riverpod, used narrowly.** `ProviderScope` wraps the app at `main.dart:78`. The entire app declares **15 providers**: 7 in `core/providers.dart`, 1 router, 1 session, 1 partner-presence, 2 in `partner_here_badge.dart`, and 3 feature controllers (call, chat theme, intimacy).

The hub is `sessionProvider` (`session_provider.dart:236-239`), a `StateNotifierProvider<SessionNotifier, SessionState>` bundling `{loading, session, profile, couple, partner, partnerOnline, error}` into one immutable record with derived getters `isAuthenticated`/`hasProfile`/`isLinked`. `core/providers.dart:11-33` exposes five read-only slices (`authStateProvider`, `currentProfileProvider`, `currentCoupleProvider`, `partnerProfileProvider`, `isPairedProvider`) with a doc comment telling features to watch the narrowest one. Two `StateProvider`s hold transient UI state: `pendingInviteCodeProvider` and `shellTabProvider`. `partnerPresenceProvider` (`presence_service.dart:441-444`) is the only `.autoDispose` provider and the only one owning a realtime channel plus a 15s polling timer.

Everything else in the app is `StatefulWidget` + `setState` calling Supabase directly.

**System 2: global `ValueNotifier`s and static mutable fields.** This carries the app's most security-sensitive state, because the lifecycle observer must flip it without a `setState` or a `ref`:

| Global | Location | Purpose |
|---|---|---|
| `MilesApp.showRealApp` | `main.dart:89` | `ValueNotifier<bool>` — cover vs. real app |
| `MilesApp.authInProgress` | `main.dart:94` | Guards the biometric prompt's `inactive` transition |
| `MilesApp.systemOverlayActive` | `main.dart:102` | Guards system pickers/camera |
| `MilesApp.setupCompletedOnce` | `main.dart:109` | Mirrored into SharedPreferences `setup_completed_once` |
| `AppLock.locked` | `app_lock.dart:24` | App-lock overlay |
| `stealthActive` | `stealth_overlay.dart:4` | Fake "Syncing your news…" scrim |
| `realtimeResumed` | `realtime_resume.dart:13` | `ValueNotifier<int>` socket-reconnect fan-out |
| `pendingReach` / `pendingCall` | `fcm_service.dart:17, 28` | Tapped-notification payloads |

The choice is documented at `main.dart:87-92` ("Static so the cover screen and the lifecycle handler share one source of truth") and is defensible. The cost is that the app has two state mechanisms with no shared discipline.

One latent defect in the Riverpod half: `SessionState.copyWith` uses `x ?? this.x` for every field (`session_provider.dart:43-51`), so `couple`, `partner`, `session` and `profile` **cannot be nulled through it** — `loadProfile` works around this by constructing a whole new `SessionState` at lines 107-113. Meanwhile `error: error` (line 50) is assignment-through, so any unrelated `copyWith` silently wipes a previously-set error.

### Routing and the redirect funnel

`buildRouter(Ref)` (`mobile/lib/core/router.dart:51-311`) returns **one flat `GoRouter` with 43 `GoRoute` entries and zero `ShellRoute`s**. `/app` mounts `AppShell`, which owns the bottom nav as an in-widget list swap, not a nested navigator; every detail screen (`/app/settings`, `/app/capsule/*`, `/app/closer/*`, `/call`) is a flat sibling.

The global `redirect` (`router.dart:54-100`) runs on **every** route in strict order:

| # | Condition | Destination |
|---|---|---|
| 1 | `session.loading` | `null` — don't bounce mid-resolution |
| 2 | not authenticated | `/signin` (unless already on `/signin` or `/signup`) |
| 3 | `profile == null \|\| !isOnboarded` | `/welcome` |
| 4 | `couple == null` | `/couple` |
| 5 | `!profile.genderSet` | `/role-setup` |
| 6 | fully set up | `/app` (bounces off all auth/onboarding routes and `/`) |

`Profile.isOnboarded` is `birthDate != null` (`models.dart:112`), because the signup DB trigger auto-creates a bare profile row — profile existence alone is not a signal. The comment at `router.dart:70-72` records that step 6 deliberately runs on `/app` too, "so a half-onboarded user can never slip straight into the app and get stuck." Re-evaluation is wired by `_SessionListenable` (`router.dart:315-320`), a `ChangeNotifier` bridging `sessionProvider` to `refreshListenable`.

**This funnel is the single gate in front of all 43 routes and it has no test.** The entire suite is three files (`test/unit/json_utils_test.dart`, `test/unit/love_notes_pool_test.dart`, `test/widget/love_note_preview_sheet_test.dart`), 32 tests, importing exactly three lib files. No screen and no routed destination is exercised; the one widget test targets a modal bottom sheet that is not a route. Grepping the test directory for `router|gorouter|redirect` returns nothing.

Two concrete routing defects:

- **Cold-start network failure dumps a paired user into onboarding.** `loadProfile()`'s catch (`session_provider.dart:172-176`) sets `loading: false` with `session` still non-null and `profile` still null; its comment claims the router will "redirect to sign-in." It does not — `router.dart:65` sees `isAuthenticated == true`, falls through to `needsProfile`, and lands the user on `/welcome`, the profile-creation screen. Any failure before line 107 triggers this, including a timeout on the *couples* or *partner* query after the profile itself loaded fine. There is no auto-retry: the user is stuck until they submit the form (overwriting their `display_name`/`timezone`/`birth_date`) or a token refresh re-runs `loadProfile`. This affects cold start and immediate post-sign-in only — on any later reload, `copyWith`'s `profile ?? this.profile` preserves the loaded state and the user stays put.
- **Deep-link crash surface.** `/app/capsule/view` and `/app/capsule/fill` both do `state.extra! as Capsule` in the route builder (`router.dart:154, 159`). Any navigation without the extra — a deep link, a restored route, an external intent — throws rather than degrading. The sibling routes `/app/rapid-camera` and `/app/location-map` default their extras safely, so this is an inconsistency inside one file.

Deep links land outside the router entirely: `_handleLink` (`main.dart:308-314`) parses `tethered://join?code=…`, stashes the code in `pendingInviteCodeProvider`, and calls `ref.read(routerProvider).go('/couple')`.

### Realtime

This is the most carefully engineered part of the codebase, and also where the largest volume of duplicated logic lives.

**The fan-out bus.** `mobile/lib/core/realtime_resume.dart` is 26 lines. `initRealtimeAutoResume()` hooks `SupabaseService.client.realtime.onOpen(() => realtimeResumed.value++)` exactly once, called from `main.dart:71`. Every long-lived subscription listens and rejoins.

**The forcing function** lives in `AppShell`, not core. `_reconnectRealtime()` (`app_shell.dart:68-78`) runs on `AppLifecycleState.resumed` and does `realtime.disconnect()` then `realtime.connect()`, because Android doze kills the socket without a close event. The reconnect re-opens → `onOpen` fires → `realtimeResumed` increments → everyone rejoins. The comment at `app_shell.dart:70-73` records that re-subscribing synchronously there raced the closing socket and left channels joined-but-dead.

**The canonical primitive.** `ManagedSubscription` (`realtime_service.dart:96-141`) encapsulates the correct pattern, documented at lines 78-84: Supabase's `channel()` never dedupes by topic and `unsubscribe()` only *schedules* an async leave, so the naive re-subscribe produced racing dead channels — "the app-wide subscription-health bug." `_resubscribe` is re-entrancy-guarded by `_busy`, nulls `_channel` first, **awaits** `removeChannel(old)`, re-checks `_disposed`, then rebuilds.

**Nine hand-rolled copies of that pattern exist. Six are correct, three are not.**

| Site | Awaits `removeChannel`? | Re-entrancy guard? |
|---|---|---|
| `core/realtime_service.dart:112-128` (`ManagedSubscription`) | yes | yes |
| `core/session_provider.dart:181-204` | yes | yes |
| `core/services/presence_service.dart:398-429` | yes | yes |
| `features/call/call_controller.dart:55-74` | yes | yes |
| `features/chat/chat_screen.dart:300-318` | yes | yes |
| `features/shell/app_shell.dart:83-98` | yes | **no** |
| `core/widgets/partner_here_badge.dart:37-61` | **no** | **no** |
| `features/closer/touch_trace/touch_trace_canvas.dart:87-91` | **never calls it** — `unsubscribe()` + immediate re-`channel()` | **no** |
| `features/cycle/cycle_screen.dart:63-77` | **never calls it** — same anti-pattern | **no** |

The last two are the literal pattern the doc comment names as the bug. `partner_here_badge.dart:42` carries a comment claiming the fix it does not perform. The badge's failure mode is degradation rather than death — `partner_here_badge.dart:104` falls back to the DB presence value on a 15s poll — but `_subscribe()` never resets `state`, so a stale non-null broadcast value pins the `??` and blocks the fallback, leaving the badge showing a screen the partner has left.

All nine should collapse onto `ManagedSubscription`, which already exists for exactly this purpose and is currently used by none of them. `BRAIN.md` tracks this as ISSUE-005, still IN PROGRESS as of 2026-06-27, with the note that the bug "was copied across ~15 features."

**The facade nobody uses.** `RealtimeService` (`realtime_service.dart:13-74`) sits in the same file with three statics: `coupleTable`, `coupleStream`, `broadcast`. Grep shows `coupleStream` and `broadcast` have **zero** call sites and `coupleTable` has exactly one (`presence_service.dart:414`). Its own doc comment claims features subscribe "through here instead of hand-rolling channels" — an invariant the codebase does not hold.

**Presence** deserves a note because it encodes a deliberate correctness model. `presence_service.dart` (444 lines) exposes three clocks and forbids two for UI: `isOnlineFlag` is ADVISORY ONLY (a force-killed app never writes it false), `updatedAt` is written by every upsert including GPS, and `appLastActiveAt` is the only honest clock. `isTrulyOnline` is a 45s freshness window over `app_last_active_at`, and a 30s foreground heartbeat (`main.dart:186-200`) keeps it fresh. The write side enforces the split via one private `_upsert` with an `isAppActivity` flag: location writes never stamp it, so GPS pings while the user sleeps cannot fake presence. That is a genuine product decision, not an accident.

### Startup sequence

`main()` (`main.dart:36-79`) runs ten strictly-ordered steps, several with comments explaining why the order matters:

| # | Step | Why |
|---|---|---|
| 1 | `WidgetsFlutterBinding.ensureInitialized()` | — |
| 2 | `FlutterError.onError` + `platformDispatcher.onError` | Global error nets, full exception + stack |
| 3 | `dotenv.load()` + masked length check | Throws `StateError` if Supabase URL/key empty, rather than a FormatException on every request |
| 4 | `Firebase.initializeApp` | — |
| 5 | `FirebaseMessaging.onBackgroundMessage(...)` | Must precede `runApp`; runs in its own isolate |
| 6 | `TzHelper.ensureInit()` | Loads the IANA database |
| 7 | `await SupabaseService.init()` | — |
| 8 | `await MilesApp.loadSetupFlag()` | Must land before the first lifecycle event, or a restart hands the first-run cover exemption back |
| 9 | `initRealtimeAutoResume()`, `AdService.init()`, `FcmService.init()` | — |
| 10 | `FlutterForegroundTask.initCommunicationPort()`, then `runApp` | Call foreground service |

**The router is not the cold start.** `main.dart:367` sets `home: FakeNewsScreen(onAuthenticated: () => MilesApp.showRealApp.value = true)` inside a *separate* light-themed `MaterialApp` titled "News". Only when `showRealApp` flips does `main.dart` build `MaterialApp.router`. `router.dart:302-308` comments that `/` is not the real cold start and redirects to `/signin`.

`_MilesAppState.initState` (`main.dart:135-158`) then adds the lifecycle observer, post-frame-schedules `PermissionsBootstrap.requestAllOnce()` and `AppLock.lockIfEnabled()`, starts deep links and the presence heartbeat, initialises `EmergencyLockService`, and installs the `miles/volume_keys` MethodChannel handler. A final phase lives in `AppShell._onReady()` (`app_shell.dart:100-116`): subscribe the reach channel, register the FCM token now that login and pairing are known good, prompt once for the Android-14 full-screen-intent permission, and drain any pending reach/call tap.

The real app's widget tree (`main.dart:388-419`) is a `Stack` of six always-present layers: `EmberBackground`, the routed child (or `_SessionLoading`), `CallPill`, `PartnerHereBadge`, the `AppLock` overlay, and `StealthLayer`.

`didChangeAppLifecycleState` (`main.dart:202-296`) is ~95 lines and is mostly concealment logic, not presence: drop to the cover on `paused`/`hidden` unless `systemOverlayActive`; drop unconditionally on `detached`; on `inactive`, defer 300ms and re-check, with a first-time-setup exemption gated on `setupCompletedOnce` so keyboard and dialog bounces do not make account creation impossible. Presence handling comes after, and `inactive` is deliberately left alone so presence does not flicker.

## 4. Feature inventory

All 28 directories under `mobile/lib/features`. "Reachable" means a user can get there through the shipped UI without a deep link.

| Module | Purpose | Route(s) | Reachable from UI? | Notes |
|---|---|---|---|---|
| `auth` | Sign-up, sign-in, and the onboarding funnel (profile → couple-link → gender/role) | `/signin`, `/signup`, `/welcome`, `/couple`, `/role-setup` | Yes — forced entry, then barred | Outside the shell. `router.dart:91-97` bars re-entry once fully set up. `role_setup_screen.dart` gates the cycle feature. |
| `breath` | Shared 4-7-8 breathing pacer; "both phones pulse in unison across the world" | none — bottom-nav index 3 | Yes — bottom nav | Single file. **The only tab showing an AdMob banner** (`app_shell.dart:210`, `selected == 3 && !isCloserTab`). |
| `call` | Full-screen WebRTC voice/video UI with minimise-to-pill | `/call` | Yes — chat header + auto-push | Started from `chat_screen.dart:421/425`. `AppShell` auto-pushes on idle→ringing/calling/connected (`app_shell.dart:178-187`). `CallPill` is mounted globally in `main.dart`. |
| `capsule` | Time capsules unlocking on date or physical proximity | `/app/capsule`, `/new`, `/view`, `/fill` | Yes — drawer + Home quick action | `proximity_service.dart` does a geolocator distance check. `/view` and `/fill` hard-cast `state.extra! as Capsule` and throw on a bare deep link. |
| `care` | "Gentle reminder" nudges (sleep/break/move) with a Done ack | `/app/care` | Yes — drawer ("Care Reminders") | Writes `care_nudges` — **a table with no DDL in the repo**. |
| `chat` | Realtime chat: typing, read receipts, moods, GIFs, media viewer, themed backgrounds, emoji "flings"; plus the rapid snap camera | `ChatScreen` none (nav index 1); `RapidCameraScreen` → `/app/rapid-camera` | Yes — bottom nav; camera from centre nav button, Home, and the input bar | 15 files. Largest module by file count. Sets `FLAG_SECURE`. |
| `closer` | Adult module hub + 9 sub-features (touch-trace, mood lamp, desire, private vault, afterglow, memory threads, fantasy jar, body map, pick-for-us) | hub: none (last nav tab); 11 sub-routes under `/app/closer/*` | Yes — nav tab, **adults only** (`app_shell.dart:192-198`) | The hub publishes an E2EE public key and "derives" a shared key — **both are no-ops**; see `crypto_core.dart`. `add_fantasy_screen.dart` has no route (pushed from the jar screen). |
| `countdown` | Next-visit countdown; "Your countdown", `SetVisitSheet` | **none** | **No — dead code** | `grep -rn "CountdownScreen"` returns only its own 4 self-referential lines. Superseded by `timeline`, which owns `Visit` data. |
| `cycle` | Menstrual cycle logging/prediction with opt-in partner share | `/app/cycle` | Yes — drawer + partner card on Home | **The only module with tests.** Reads `cycle_settings`/`cycle_events` — no DDL in repo. Has one of the three broken realtime resubscribe copies. Its pooled love-note feature is flag-gated off (`FeatureFlags.pooledLoveNotes = false`). |
| `daily_prompt` | Daily question; both answers revealed only after both respond | `/app/prompt` | Yes — drawer ("Daily Question") | — |
| `fake_news` | The disguise cover and the real cold-start entry point | **none — outside the router** | N/A — it is above the shell | Live RSS (BBC/Al Jazeera/NPR), external article links, pull-to-refresh. Three hidden triggers: 5 logo taps, the search word `home`, a 2.5s long-press on Local. |
| `games` | Mini-game hub; Truth or Dare is turn-synced, the rest are local card games | `/app/games`, `/truth-dare`, `/would-you-rather`, `/never-have-i-ever` | Yes — drawer | The last two are both `SyncedCardGameScreen` with different pools/gameKey/accent. |
| `heartbeat` | Camera PPG pulse — fingertip + torch reads your pulse, partner's phone throbs with it | `/app/heartbeat` | Yes — drawer ("Feel My Heartbeat") | `ppg_detector.dart` |
| `home` | Landing tab: partner presence, Reach button, live location map, 5 quick actions | `HomeScreen` none (nav index 0); `LocationMapScreen` → `/app/location-map` | Yes — default tab | `Map3DScreen` has **no route** — pushed via `MaterialPageRoute` from `partner_location_card.dart:114`. Hosts the "📍 Sharing live location" indicator with a one-tap off switch. |
| `intimacy` | "In the Mood" — mutual opt-in closeness signal, revealed only when both are open in the same window | `/app/intimacy`, `/app/intimacy/prefs` | **No — deep link only** | Registered but orphaned: nothing anywhere pushes `/app/intimacy`. The only pushes are to its child, from inside itself. **Not the same as `closer`** — `settings_screen.dart:476` labels the Closer toggle "Closer (intimacy module)", but that drives `couple.modestMode`, not these routes. |
| `intro` | Full-screen cinematic unlock video between cover and real app | **none** | Yes — pushed by the cover | Plays bundled `intro.mp4` (no loop, volume 0.6); tap or end advances; calls `onComplete` and does **not** navigate the router itself. Single import site: `fake_news_screen.dart:156`. |
| `photo` | Post-capture beauty/enhance filter editor, run in a background isolate via `compute` | **none** | Yes — via `PhotoPickerService` | Exposes its own static entry `FilterEditorScreen.edit(...)`. Invoked from `photo_picker_service.dart:81`, used by chat input, chat theme picker, settings, and touch map. |
| `reach` | Haptic "reaching for you" ping — hold to send a heartbeat pattern the partner feels | **none** | **Partially** | LIVE: `ReachButton` on Home; `ReachRepository.subscribe` wired app-wide in `AppShell`; `ReachOverlayScreen` pushed on the root navigator, de-duped by reach id. DEAD: `reach_screen.dart` — nothing imports it. Easiest of the three dead files to mistake for working code. |
| `reasons` | Shared "reasons I love you" jar; one featured daily | `/app/reasons` | Yes — drawer | Writes `love_reasons` — **no DDL in repo**. |
| `rituals` | Recurring couple rituals | `/app/rituals` | Yes — drawer | **Naming trap:** `create_ritual_screen.dart` is not a screen and has no route — it defines `CreateRitualSheet`, opened via `showModalBottomSheet` at `rituals_screen.dart:55-62`. |
| `settings` | Account, profile photo, timezone picker, app lock, FCM + FSI permission, location/presence, Closer toggle, unpair, sign-out | `/app/settings` | Yes — drawer's dedicated tile | Single file. Also reached from `CloserScreen`'s modest-mode button (via `context.go`, not `push`). **This is the sign-out path that correctly clears the FCM token.** |
| `shell` | The bottom-nav scaffold + side drawer — the navigation hub | `/app` | It *is* the shell | Two files. Bodies are a const list of 4; Closer is sliced off for non-adults; nav index 2 (Camera) has no body, so indices map past it. Also owns app-wide realtime lifecycle, FCM registration, and pending-notification handling. Drawer = 13 feature tiles + Settings + Sign out. |
| `skybridge` | "What the sky looks like right now in your partner's world vs. yours. No timezone math, just colour." | **none** | **No — dead code** | `grep -rn "SkyBridgeScreen"` returns only its own 4 lines. Carries an unresolved note that its timezone handling is a v1 approximation pending tzdata — shipping it needs work, not just a route. |
| `timeline` | Visit history and days-apart stats | `/app/timeline` | Yes — drawer | Live successor to the dead `countdown` module; both work off `Visit` data. Adds past visits via `_AddPastVisitSheet`. |
| `together` | Synced avatar affection gestures — cuddle/kiss/hug plays on both screens in real time | `/app/together` | Yes — drawer | Single file. |
| `touch_map` | Both partners' photos on one shared surface; touches land on the same body on both phones with synced haptics, simultaneous multi-touch, synced pan/zoom, neon "hot line" comet trails | `/app/touch` | Yes — drawer + Home quick action | **Largest single screen file (~1500+ lines).** Glows are keyed to *whose body* they hit, not screen position, so the two phones stay in sync. Sets `FLAG_SECURE`. |
| `vault` | PIN/biometric-gated personal notes; auto-locks on background | `/app/vault` → `VaultGateScreen` | Yes — drawer + Home quick action | **Distinct from Closer's Private Vault** at `/app/closer/vault`. Two vaults, two routes, both shown with a lock icon. `vault_screen.dart` has no route of its own. Does **not** set `FLAG_SECURE`. Biometric unlock does `setState(() => _unlocked = true)` with no server call, sidestepping the bcrypt PIN, the 5-try counter and the 15-minute lockout. |
| `watch` | Loosely synced YouTube co-watching — play/pause/seek stay in sync over a broadcast channel | `/app/watch` | Yes — drawer ("Watch Together") | "Whoever touches the controls drives; the other follows." Single file. |

**Reachability summary:** 24 of 28 modules are reachable through the shipped UI. Three are verifiably dead (`countdown`, `skybridge`, and `reach/reach_screen.dart` inside an otherwise-live module) — their classes appear nowhere except their own definitions. One (`intimacy`) is fully built, routed, and orphaned: entering it requires an explicit deep link.

**Routes not in the drawer:** `/app/intimacy` (no entry point), `/app/rapid-camera` (nav button + in-screen), `/app/location-map` (Home card), `/call` (call state), and all 11 `/app/closer/*` (the Closer tab grid).

## 5. Data and backend

The backend is a single Supabase project — ref `sopictusdonlvuezmfep` ("LDR"), region `ap-south-1`, Postgres 17, **Free plan**. It auto-paused after ~7 days idle on 2026-08-06, which withdrew its DNS record and took the app down with `Failed host lookup … errno = 7`. It was restored via the Supabase API with data intact (5 users, 5 profiles, 4 couples, 24 messages). This will recur on the Free plan.

> Do not confuse this with Supabase project `yppqsnfzjfoqqqsnxdyp` ("us-app"), which belongs to a separate Expo/React Native app at `E:/us-app`.

### 5.1 The schema of record problem — read this first

`E:/LDR/supabase` is **not** the schema of record. It holds 29 files: 27 loose hand-run `.sql` scripts and 2 Deno edge functions. There is no `supabase/migrations/`, no `config.toml`, no seed file, and no ordering manifest — only 6 files carry date prefixes and the rest self-document ordering in header comments ("Run AFTER schema.sql", "RUN THIS LAST"). `presence_status_v2.sql:3` records the actual workflow: `-- Applied 2026-06-27 (via Supabase MCP)`.

The following are used by shipped client code and have **no DDL anywhere in the repo or in git history**. Verified by mechanical diff of client `.from()` targets against every `create table` in `supabase/*.sql`, plus a recursive name grep that returned zero `CREATE`/`ALTER` hits:

| Missing object | Used at | Consequence |
|---|---|---|
| `love_reasons` | `mobile/lib/features/reasons/reasons_repository.dart:34,48,56` | RLS posture unverifiable from source |
| `cycle_settings` | `mobile/lib/features/cycle/cycle_repository.dart:184,196,239` | same |
| `cycle_events` | `mobile/lib/features/cycle/cycle_repository.dart:212,233` | same; RLS described only in prose at `FIX_REPORT.md:352` |
| `care_nudges` | `mobile/lib/features/care/care_repository.dart:47,57,64` | same |
| `profiles.gender`, `profiles.gender_set` | `mobile/lib/core/supabase_repository.dart:263` | column drift |
| `profiles.chat_theme_id`, `profiles.chat_bg_image_url` | `mobile/lib/core/supabase_repository.dart:270-271,280` | column drift |
| `messages.voice_path`, `video_path`, `reply_to_id` | `mobile/lib/features/chat/chat_repository.dart:188,236,266` | column drift |
| `presence.chat_last_read` | `mobile/lib/core/services/presence_service.dart:217` | breaks `leave_couple()` — see below |
| `public.app_secrets` | `supabase/functions/turn-credentials/index.ts:35` | holds Cloudflare TURN secrets |
| buckets `couple_media`, `couple_intimate`, `chat-bg` | chat, touch map, chat theme picker | no `storage.objects` policy in repo |

**Consequence:** a fresh Supabase project cannot be rebuilt from `E:/LDR/supabase`, and no staging environment can be stood up. This is a launch blocker independent of any code change.

The `chat_last_read` gap is already latent damage. `supabase/20260628_leave_couple_privacy.sql:47` sets `chat_last_read = NULL` inside the plpgsql body of `leave_couple()`. Because Postgres only syntax-checks plpgsql bodies (`check_function_bodies` binds at call time), `CREATE FUNCTION` succeeds and the error would surface only when a user unpairs — aborting the whole transaction, so the sensitive-presence wipe, the `profiles` unlink and the `couples` deactivation all roll back. The live project already has the column (added out-of-band), so nothing is broken today; a repo-only rebuild produces a `leave_couple()` that throws on every call.

### 5.2 Tables

35 tables are created in the repo SQL, all with RLS explicitly enabled (verified by diffing every `create table` against every `enable row level security`; `call_invites` splits the statement across `20260627_call_invites.sql:17-18`, which a naive single-line grep undercounts).

**Identity and pairing**

| Table | Defined at | Purpose |
|---|---|---|
| `couples` | `schema.sql:22` | `invite_code` (unique), `primary_tz`, `modest_mode` (default `true`), `anniversary_date`, `active` |
| `profiles` | `schema.sql:31` | FK to `auth.users` ON DELETE CASCADE; `couple_id` ON DELETE SET NULL; `birth_date` with a `profiles_must_be_adult` CHECK (`intimacy_additions.sql:26`); `fcm_token` |
| `pairing_invites` | `pairing_invites.sql:9` | expiring single-use join codes |

There is **no `couple_members` join table** — the couple link is the single `profiles.couple_id` column, as documented at `functions/reach-notify/index.ts:19-20`.

**Relationship content**

| Table | Defined at | Notes |
|---|---|---|
| `visits` | `schema.sql:43` | drives Timeline; indexes on `(couple_id, is_upcoming, start_date)` |
| `daily_prompts` / `prompt_responses` | `schema.sql:56` / `:64` | `prompt_responses` has no `couple_id`; policies join through `daily_prompts` |
| `rituals` | `schema.sql:73` | enum `ritual_type`; `rituals_pending_idx(delivered, deliver_at)` |
| `visit_memories` | `schema.sql:84` | no `couple_id`; policies join through `visits` |
| `messages` | `messages.sql:6` | plus `sender_mood`, `deleted_for_everyone`, and `deleted_by uuid[]` — the per-user hide mechanism (`settings_and_delete.sql:25-26` records that the earlier single boolean could not hide a received message for the receiver) |
| `presence` | `presence_and_mood.sql:5` | one row per user, self-write / couple-read |
| `capsules` / `capsule_items` | `capsules.sql:17` | `unlock_mode` enum `proximity`/`date`/`both` |
| `call_invites` | `20260627_call_invites.sql:3` | durable WebRTC offer so a backgrounded app can still be called |
| `reach_pulses`, `reach_events`, `breath_events`, `body_touches`, `intimacy_signals` | various | ephemeral signals, several with `expires_at` |

**Closer / intimacy — 13 tables**, all in `intimacy_tables.sql`, all `couple_id`-scoped: `consent_state`, `desire_temps`, `mood_lamp`, `fantasy_jar_entries`, `fantasy_jar_reveals`, `afterglow_entries`, `vault_items`, `body_map_pins`, `dice_rolls`, `dice_tier_consents`, `memory_threads`, `memory_revisits`, `couple_dissolutions`.

**Two distinct vaults, deliberately.** `vault_items` (`intimacy_tables.sql:72`) is the couple-scoped Closer vault at route `/app/closer/vault`. `personal_vault_items` (`private_vault.sql:24`) is owner-only, at route `/app/vault`, guarded by `vault_pin` (`private_vault.sql:12`). `private_vault.sql:4-5` names the collision explicitly. Any doc that says "the vault" without qualification is wrong.

**Five tables are fully provisioned but have zero client call sites:** `consent_state`, `fantasy_jar_reveals`, `couple_dissolutions`, `visit_memories` (0 references each in `mobile/lib`), and `mood_lamp` (2 references, both a screen path and a broadcast channel name — `mood_lamp_screen.dart:43` subscribes to broadcast channel `mood_lamp:$coupleId` and never reads the table). `consent_state` is described at `intimacy_tables.sql:243` as the dual-consent gate "shared by all intimacy features" — that gate is not enforced anywhere in the app. Four of the five are still published to realtime with `REPLICA IDENTITY FULL`.

### 5.3 RLS posture

One idiom dominates: `public.current_user_couple_id()` (`schema.sql:105`, a SECURITY DEFINER lookup of `profiles.couple_id` for `auth.uid()`) compared against a `couple_id` column. Applied via two `DO` loops — `schema.sql:150-187` over `visits`/`daily_prompts`/`rituals`, and `intimacy_tables.sql:179-214` over 12 intimacy tables. Scoping is therefore **couple-level, not user-level**, almost everywhere.

Deviations:

| Shape | Tables |
|---|---|
| Self-scoped writes, couple-scoped reads | `profiles`, `presence`, `partner_keys` |
| Owner-only (`= auth.uid()`) | `intimacy_prefs`, `vault_pin`, `personal_vault_items` |
| Couple-scoped + actor pinned (`sender_id`/`from_user`/`author_id` `= auth.uid()`) | `messages` (insert), `reach_events`, `body_touches`, `capsules`, `capsule_items`, `prompt_responses` |
| Join-through (no `couple_id` column) | `visit_memories` → `visits`, `prompt_responses` → `daily_prompts`, `memory_revisits` → `memory_threads` |
| SELECT-only, writes via RPC | `pairing_invites` (`pairing_invites.sql:22`) — correct, since the joiner is not yet in the couple |

`intimacy_signals` is the one genuinely clever policy: SELECT requires `couple_id` match **and** (own row **or** `has_active_intimacy_signal()`), so a signal is only visible when both partners are signalling. Two SECURITY DEFINER helpers (`intimacy_signals.sql:39,47`) exist purely so the policy never self-references the table, avoiding a `42P17` recursion error.

**Known RLS defects.** All three are confirmed against the live database, not just the `.sql` files.

| Defect | Location | Detail |
|---|---|---|
| `messages` UPDATE is couple-scoped, not sender-scoped | `settings_and_delete.sql:29-32` | `messages_update_member` uses only `couple_id = current_user_couple_id()` in both USING and WITH CHECK, with no column restriction. Either partner can rewrite the other's `body`, `kind`, `image_path`, flip `deleted_for_everyone` — and, because WITH CHECK tests only `couple_id`, **reassign `sender_id` itself**, which is forgery, not just tampering. `messages_insert_member` (`messages.sql:26-28`) and `messages_delete_own` (`:31-32`) both correctly pin `sender_id = auth.uid()`, and the `delete_message_for_everyone()` RPC checks it too (`settings_and_delete.sql:47`) — the blanket UPDATE policy makes that check optional. Live `pg_policies` confirms; `authenticated` holds UPDATE on the table and no trigger guards it. The Flutter client never issues a direct UPDATE on `messages` (all mutation goes through RPCs), so this is a latent gap reachable by a crafted PostgREST call with a normal session — and the anon key ships in the APK. |
| Capsule seal is bypassable | `capsules.sql:47-48` | `capsules_update` grants unrestricted UPDATE on the `capsules` row; RLS `USING`/`WITH CHECK` cannot restrict columns. A client can `update capsules set unlocked_at = now()` and then read items that `capsule_items_select_unlocked` (`:59-62`) gates on `unlocked_at is not null`. `unlock_date` and `unlock_mode` are equally writable, so the `too_early` check in `unlock_capsule()` (`:91-95`) can also be satisfied legitimately by rewriting the date. Live DB confirms no column-level grants and no `BEFORE UPDATE` trigger. Separately, `unlock_mode='proximity'` has no server-side check at all — proximity is client-verified (`capsule_repository.dart:209`). And the `capsule-media` storage policies (`capsules.sql:115-117`) gate SELECT on `couple_id` alone with no `unlocked_at` check, so sealed photo/voice bytes are downloadable without touching the `capsules` row. |
| `call_invites` pins nothing but `couple_id` | `20260627_call_invites.sql:23-27` | A single `FOR ALL` policy with a `USING` clause and no `WITH CHECK`; `caller_id`/`callee_id` are not tied to `auth.uid()`. A member can insert an invite attributed to their partner, or UPDATE/DELETE any invite in the couple. |

Two lesser ones: `couples_insert_authed` (`schema.sql:137-139`) lets any authenticated user insert arbitrary `couples` rows with only `auth.uid() is not null` as the check — leftover, since creation is meant to go through the SECURITY DEFINER RPC (`schema.sql:130-132` says so). And `breath_events.user_id` / `reach_pulses.user_id` reference `auth.users(id)` rather than `public.profiles(id)` like every other user column, with insert policies that check only `couple_id` — so a member can write rows attributed to their partner.

### 5.4 Functions, triggers, RPCs

**22 database functions, every one `SECURITY DEFINER`, every one pinning `search_path`.**

| Group | Functions |
|---|---|
| RLS helpers | `current_user_couple_id()` `schema.sql:105`, `has_active_intimacy_signal()` `intimacy_signals.sql:39`, `my_intimacy_signaling_enabled()` `:47`, `has_vault_pin()` `private_vault.sql:75` |
| Pairing | `create_couple(text)` `schema.sql:295`, `join_couple_by_code(text)` `:334`, `create_pairing_invite(int)` `pairing_invites.sql:25`, `redeem_pairing_invite(text)` `:60`, `leave_couple()` (defined **three times**: `settings_and_delete.sql:8`, `20260627_leave_couple_fix.sql:7`, `20260628_leave_couple_privacy.sql:12`) |
| Capsules | `capsule_seal_summary(uuid)` `capsules.sql:70`, `unlock_capsule(uuid)` `:82` |
| Vault PIN | `set_vault_pin(text)` `private_vault.sql:37`, `verify_vault_pin(text)` `:52` |
| Messages | `hide_message(uuid)` `settings_and_delete.sql:35`, `delete_message_for_everyone(uuid)` `:44`, `clear_conversation()` `:52` (later dropped), `clear_conversation_everyone()` `clear_chat_everyone.sql:5` |
| Touch | `clear_body_photo(uuid)` `touch_photo_delete.sql:10` — lets either partner null the other's `presence.body_photo_path`, which normal self-write presence RLS forbids |
| Triggers | `handle_new_user()` `schema.sql:267`, `notify_reach()` `fcm_push.sql:16`, `sync_presence_couple_id()` + `init_presence_on_profile()` `20260628_presence_repair_trigger.sql:4,50` |

Grant hygiene is consistent for the 18 callable functions: `revoke execute … from public, anon; grant execute … to authenticated;`. Three trigger functions skip the revoke (`notify_reach`, `sync_presence_couple_id`, `init_presence_on_profile`); all return `trigger`, which limits exposure, but the inconsistency should be closed.

**Four triggers:**

| Trigger | On | Does |
|---|---|---|
| `on_auth_user_created` | AFTER INSERT `auth.users` | inserts a bare `profiles` row, timezone hardcoded `'UTC'`, `ON CONFLICT DO NOTHING` (`schema.sql:285-288`). This is why `Profile.isOnboarded` is `birthDate != null` (`models.dart:112`) — profile existence alone is not a signal. |
| `trg_init_presence` | AFTER INSERT `profiles` | upserts a `presence` row |
| `trg_sync_presence_couple_id` | AFTER UPDATE OF `couple_id` ON `profiles` | nulls presence fields on unlink, upserts on pairing |
| `reach_notify_on_insert` | AFTER INSERT `reach_events` | `pg_net` POST to the `reach-notify` edge function |

The interaction between `trg_sync_presence_couple_id` and `leave_couple()` is load-bearing and documented at `20260628_leave_couple_privacy.sql:5-11`: the sensitive-field wipe **must** run before the `profiles` UPDATE, because the trigger nulls `presence.couple_id` the moment `profiles.couple_id` changes, which would make the wipe's `WHERE couple_id = v_couple_id` match zero rows.

**Two live pairing flows, both still granted.** `create_couple` / `join_couple_by_code` use the permanent, never-expiring `couples.invite_code`. `create_pairing_invite` / `redeem_pairing_invite` use expiring single-use codes and were described at `pairing_invites.sql:3-4` as "replacing" the permanent code — nothing was removed. `create_pairing_invite` (`:37-42`) duplicates the code-generation logic inline and passes `primary_tz = null`, so couples created that way have no timezone. All four RPCs are called from `mobile/lib/core/supabase_repository.dart` (`:129,141,163,178`).

**Ordering hazard.** `clear_chat_everyone.sql:2` drops `clear_conversation()` and replaces it with `clear_conversation_everyone()`; `settings_and_delete.sql:52` still defines the old one. With no migrations table, re-running `settings_and_delete.sql` resurrects the dropped function. Nothing records which scripts have been applied.

### 5.5 Realtime

27 of the 35 tables are in the `supabase_realtime` publication, each preceded by `REPLICA IDENTITY FULL` (required so RLS-filtered UPDATE events carry the full row — `realtime.sql:6-9`) and guarded by a `pg_publication_tables` existence check. `closer_realtime.sql:9-23` additionally gates each `ALTER PUBLICATION` on `information_schema.tables`, so it is safe if the table is absent.

**Not published:** `capsule_items`, `couple_dissolutions`, `couples`, `pairing_invites`, `partner_keys`, `personal_vault_items`, `vault_pin`, `visit_memories`.

Not everything realtime goes through `postgres_changes`. Broadcast channels are used for ephemeral, high-frequency signals — `screen_presence:<coupleId>` (the "partner is here" badge), `mood_lamp:<coupleId>` (which bypasses the `mood_lamp` table entirely), `touch_trace:<coupleId>`, `cycle_events:<coupleId>`, chat emoji flings, and the Watch Together sync.

**Cleanup is inconsistent.** `pg_cron` is not created; both cleanup blocks are guarded by `if exists (select 1 from pg_extension where extname='pg_cron')`. Two jobs exist when it is present: `miles_breath_cleanup` (`0 3 * * *`, deletes `breath_events` older than 1 day) and `miles_reach_cleanup` (`*/30 * * * *`, `reach_pulses` older than 1 hour). `body_touches` (`expires_at now()+10s`) and `reach_events` (`expires_at now()+30s`) have **no cleanup job and no DELETE policy** — they grow without bound and no client can prune them, while both sit in the realtime publication with `REPLICA IDENTITY FULL`. Both `pg_cron` blocks also call `cron.unschedule()` unconditionally before `cron.schedule()` inside a plain `DO` block with no exception handler (`breath_events.sql:36-42`, `reach_pulses.sql:33-39`); the failure behaviour on first run was not executed against a live database, so treat the missing handler as the verified fact and the consequence as unverified.

### 5.6 Storage buckets

| Bucket | Public | Created in SQL | Policies |
|---|---|---|---|
| `capsule-media` | no | `capsules.sql:110` | 3 `storage.objects` policies, path-scoped: `(storage.foldername(name))[1] = current_user_couple_id()::text` (`:112-120`) |
| `couple_media` | **yes** | — | none in repo |
| `couple_intimate` | no | — | none in repo |
| `chat-bg` | **yes** | — | none in repo |

Bucket visibility was verified against the live project:

```
[{"id":"capsule-media","public":false},{"id":"chat-bg","public":true},
 {"id":"couple_intimate","public":false},{"id":"couple_media","public":true}]
```

`public: true` means unauthenticated. An anonymous request to `couple_media` resolves the bucket and performs the key lookup (`NoSuchKey` for a missing object), whereas the private buckets refuse to acknowledge the bucket at all (`NoSuchBucket`). An existing object in `couple_media` is served to anyone with the URL, forever. See §6.4 for what that means for chat media and the vault.

`TETHERED_FULL_DOCUMENTATION.md:426` says `couple_media` is public; `:535` lists it under "Storage buckets (private)". Line 535 is wrong.

### 5.7 Edge functions

Two functions exist in the repo, at `supabase/functions/`.

**`reach-notify`** — invoked by the `reach_events` INSERT trigger. Hand-signs an RS256 JWT from `FCM_SERVICE_ACCOUNT` via `crypto.subtle` to mint a Google OAuth2 token, then POSTs a **data-only** FCM HTTP v1 message to the other couple member's `profiles.fcm_token`. Data-only is deliberate (`index.ts:6-8`) so the app's own background handler builds the full-screen-intent notification. On `404`/`UNREGISTERED`/`NOT_FOUND` it nulls the stale token (`:181`). Returns HTTP 200 on every error path to avoid webhook retry storms. Uses the service-role key, so it bypasses RLS.

**`turn-credentials`** — reads `CF_TURN_KEY_ID` / `CF_TURN_API_TOKEN` from `public.app_secrets` with a service-role client, calls Cloudflare Realtime TURN `generate-ice-servers` with `ttl 86400`, and passes Cloudflare's `{iceServers:[…]}` straight through. CORS is `Access-Control-Allow-Origin: *`.

**A third function is deployed with no source in the repo.** The live `list_edge_functions` returns `call-notify` with `verify_jwt: false`, but `supabase/functions/` contains only `reach-notify` and `turn-credentials`. An unauthenticated function that cannot be code-reviewed is a strictly worse instance of the `reach-notify` problem below. (`care-notify` and `turn-credentials` are `verify_jwt: true`.)

`TETHERED_FULL_DOCUMENTATION.md:940` claims three functions — `reach-notify`, `care-notify`, `call-notify` — and omits `turn-credentials` entirely. It also lists `METERED_TURN_*` as "required for call media"; the code mints Cloudflare TURN and treats `METERED_*` only as a manual override appended if present (`call_controller.dart:131-185`).

---

## 6. Security and privacy model

The honest summary: this app has a **well-built concealment layer** and an **essentially absent cryptographic layer**. The disguise, the panic lock and the stealth scrim are real, working code that defeats a casual over-the-shoulder or hand-me-the-phone threat. Everything below the UI is protected by Supabase RLS plus possession of the session token, and nothing else.

### 6.1 What is genuinely protective

| Control | Implementation | Why it holds |
|---|---|---|
| **Row Level Security** | Enabled on all 35 repo tables; `current_user_couple_id()` idiom | The real, and only, confidentiality boundary. Verified live for `personal_vault_items` (`pvi_owner_only`, `owner_id = auth.uid()`) and `messages`. |
| **Vault PIN storage** | `set_vault_pin` / `verify_vault_pin`, `private_vault.sql:37-80` | Genuine bcrypt via `extensions.crypt(p_pin, gen_salt('bf'))`, `failed_attempts` counter, 15-minute `locked_until` after 5 failures, execute revoked from `public`/`anon`. The client never compares on-device (`vault_repository.dart:41-48`). This is done correctly. |
| **News cover** | `MilesApp.showRealApp` `main.dart:89`, cover at `:347-382` | A whole separate light-themed `MaterialApp(title: 'News', home: FakeNewsScreen)`, with a real RSS reader (BBC/Al Jazeera/NPR, `rss_service.dart:29-33`) and working external links. Forced false on `paused`/`hidden`/`detached` and on sign-out (`:334`). Both branches use title `'News'` so the recents switcher stays disguised. |
| **`FLAG_SECURE`** | `miles/secure_screen` MethodChannel, `MainActivity.kt:42-64` | Real screenshot/recording block, set in `initState` and cleared in `dispose`. Applied on chat, memory threads, Closer private vault, touch trace, touch map. |
| **Presence freshness model** | `presence_service.dart:106-204` | Three clocks with an enforced write split: `app_last_active_at` is stamped only by genuine app activity, never by GPS writes (`setLocation`, `setLiveLocation`, `:270-319`). `isOnlineFlag` is marked ADVISORY ONLY because a force-killed app never writes it false. GPS pings while the user sleeps cannot fake presence. |
| **Location minimisation** | `location_service.dart:63-66` | Three modes; city mode sends **only** a geocoded label, never coordinates. Foreground-only, no background service. |
| **Anti-stalkerware framing of background location** | `AndroidManifest.xml` comments | Background location is opt-in, mutual, and foreground-service-backed with a persistent notification. |
| **Capsule proximity** | `capsules.sql:5-6` | Proximity is checked client-side over ephemeral realtime broadcast; no coordinates are ever persisted. |
| **Local PIN storage for Memory Threads** | `memory_pin_gate.dart` | The one place `flutter_secure_storage` (hardware-backed) is actually used. |
| **Autofill and IME hardening** (shipped this session) | `MainActivity` `importantForAutofill="noExcludeDescendants"`; auth email fields set `enableSuggestions: false` + `enableIMEPersonalizedLearning: false` | Keeps the account email out of the keyboard's personalised dictionary and out of autofill surfaces. |

### 6.2 What is security theatre

**No encryption exists in the Closer module.** `mobile/lib/core/crypto_core.dart` states it in its own header: *"E2EE REMOVED (2026-06-25, at the owner's request) … `encrypt*`/`decrypt*` are now identity pass-throughs."* Lines 27-57:

```dart
static Future<EncryptedPayload> encryptString(String plaintext, {String? associatedData}) async =>
    EncryptedPayload(
      ciphertextB64: base64Encode(utf8.encode(plaintext)),
      nonceB64: base64Encode(Uint8List(24)),
      macB64: base64Encode(Uint8List(16)),
    );
```

`Uint8List(n)` is zero-initialised, so every stored nonce is `AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` and every MAC `AAAAAAAAAAAAAAAAAAAAAA==`. `deriveSharedKey` is `async {}`; `getMyPublicKeyB64()` returns the literal `'plaintext-v1'`, which `supabase_repository.dart:107-113` publishes into the `partner_keys.public_key` column as if it were an X25519 key. The `cryptography: ^2.7.0` dependency is declared at `pubspec.yaml:44` and **never imported** — grep for `package:cryptography` in `mobile/lib` returns nothing.

The schema is built to *look* encrypted. `closer_crypto.dart:8` still documents *"XChaCha20-Poly1305 always produces a 24-byte nonce and a 16-byte Poly1305 MAC"*, and `packMacAndCiphertext`/`packFull` (`:42-78`) still lay out `nonce || mac || ciphertext` into `bytea` columns. `intimacy_tables.sql:244` comments `vault_items` as *"ciphertext + nonce only; NEVER plaintext"*. The wire format is indistinguishable from real AEAD; only the values are inert. Everything in `afterglow_entries`, `body_map_pins`, `fantasy_jar_entries`, `memory_threads` and `vault_items` is recoverable with `base64 -d`.

Four further Closer features have no crypto call at all — `desire/`, `touch_trace/`, `mood_lamp/`, `pick_for_us/` — so their content is stored as plain columns without even the base64 wrapper. And `personal_vault_items` (`private_vault.sql:24-31`) has a bare `content text` column; `pgcrypto` is enabled in that file but used only for `gen_random_uuid()` and the PIN bcrypt, never to encrypt content.

The removal was a deliberate product decision, in one commit (`1fe99ae feat: remove E2EE from Closer; …`). Treating "RLS-scoped plaintext" as an acceptable tradeoff for a two-person private app is defensible. **What is not defensible is that the app still tells the user otherwise, in five places:**

| String | Location |
|---|---|
| "Yours alone. Encrypted on your phone — not even we can read it." | `private_vault_screen.dart:447` |
| "A private, end-to-end encrypted space. Nothing here is readable…" | `closer_screen.dart:315` |
| "Your end-to-end encryption key is set up." | `closer_screen.dart:187` |
| "It's encrypted end-to-end. Only you can read it" | `fantasy_jar/add_fantasy_screen.dart:96` |
| "Closer is end-to-end encrypted." / "Visible. End-to-end encrypted." | `settings_screen.dart:304`, `:481` |

Docs carrying the same false claim: `docs/INTIMACY_LAYER.md` (its entire §5, plus a compliance argument at §1.1/§1.6 resting on "cannot be exported by the developer"), `docs/BUILD_PLAN.md`, `TETHERED_FULL_DOCUMENTATION.md`, `supabase/partner_keys.sql`. **Every one of these strings must be removed or corrected before launch, whether or not encryption is restored.** They are a user-facing misrepresentation about intimate photo data, not a stale comment.

Precision on the threat model, so the claim is itself defensible: transport is still HTTPS, and RLS does scope rows to the couple. The exposed adversary is anyone with project-console access, a `service_role` key, a database backup, or any RLS bypass — plus Supabase as an infrastructure provider. That is exactly the class of adversary E2EE exists to exclude.

**Other theatre:**

| Control | Reality |
|---|---|
| **Vault PIN as a data guard** | The PIN is a client-side UI gate with nothing behind it. `VaultRepository.items()` (`vault_repository.dart:50-61`) is a plain `.from('personal_vault_items').select().eq('owner_id', uid)`, and the deployed `verify_vault_pin` issues no token, sets no GUC, calls no `set_config` — nothing server-side records that a PIN was entered. The gate does stop casual in-app browsing and auto-locks on background (`vault_gate_screen.dart:48-53`), and today no shipped code path reads the vault outside it. The exposure is that the boundary does not survive anything talking to PostgREST with the stored session. |
| **Vault biometric unlock** | `vault_gate_screen.dart:138-150` calls `local_auth` and does `setState(() => _unlocked = true)` with **no RPC**. The bcrypt hash, the 5-try counter and the 15-minute lockout are all sidestepped. There is no opt-in: `vault_pin.biometric_enabled` is declared at `private_vault.sql:15` and read by **zero** Dart code, and the button renders on `if (hasPin)` alone (`:247`). `authenticate()` is called without a `CryptoObject`, so no keystore key is bound with `setInvalidatedByBiometricEnrollment` — any currently-enrolled biometric opens the vault. On a shared handset with the partner's fingerprint enrolled, the subtitle "Your partner can never open this" (`:213`) is false against the partner too. |
| **App-lock PIN** | `_hash(pin) = sha256('miles-applock::$pin')` (`app_lock.dart:37-38`) stored in plaintext `SharedPreferences`, not `flutter_secure_storage`. Unsalted SHA-256 over 10,000 candidates; offline recovery from a rooted or backed-up device is instant. `LockScreen._onPin` (`lock_screen.dart:60-71`) has no attempt limit or backoff, and the enabled flag is a plain bool in the same file. |
| **The News cover as access control** | `fake_news_screen.dart:142-147`: `final enabled = await AppLock.isEnabled(); final passed = enabled ? await AppLock.authenticate() : true;` — if the user never enabled the app lock (**default false**, `app_lock.dart:27-28`), 5 taps on the logo opens the entire app with no authentication at all. The cover is then obfuscation, not access control. |
| **Panic lock** | `_emergencyLock` (`main.dart:161-164`) only sets `showRealApp = false`. Router, session, realtime channels and all in-memory data stay live underneath; whoever knows the trigger reverses it instantly. |
| **Stealth scrim** | `stealth_overlay.dart:4-49` draws inside the Flutter tree. Nothing about screenshots, screen recording, or the OS recents thumbnail. |
| **Session token storage** | `supabase_service.dart:12-16` calls `Supabase.initialize(url:, anonKey:, debug: false)` with no custom `localStorage`, so the session and refresh token persist in default unencrypted `SharedPreferences`. A device holder can lift the token and hit PostgREST directly — no app, no gate, no PIN. |
| **`FLAG_SECURE` coverage** | `mobile/lib/features/vault/*` never calls it. The personal vault, the PIN pad, the app `LockScreen` and the News cover all run without it. The cover swap on `paused` is a Flutter frame update and is not guaranteed to land before the OS captures the task snapshot — plausible recents leakage, unverified on device. |
| **`hmacTag`** | `crypto_core.dart:59-69` — 32-bit FNV-1a, keyless, and the file admits it: *"Deterministic, keyless … no secret required."* Fantasy-jar tags are trivially enumerable server-side. |

### 6.3 Unauthenticated push

`notify_reach()` (`supabase/fcm_push.sql:23-27`) POSTs to a hardcoded URL with **only** a `Content-Type` header:

```sql
perform net.http_post(
  url := 'https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify',
  body := to_jsonb(new),
  headers := jsonb_build_object('Content-Type', 'application/json')
);
```

`functions/reach-notify/index.ts:95-103` performs no auth check of its own — it parses `payload.record ?? payload` and acts on any body carrying `couple_id`. The `verify_jwt` setting is **not** unknown: `FCM_SETUP_REPORT.md:65` and `:142-145` document "deployed with `verify_jwt=false`", and the live API confirms `{"slug":"reach-notify","verify_jwt":false,"version":5,"status":"ACTIVE"}`. `FCM_SETUP_REPORT.md:142-145` already carries the accepted-risk note and the proposed fix (a shared secret header). Treat this as known-but-unremediated.

Two refinements: only a valid `couple_id` is needed, not a valid `from_user` — the lookup is `.eq("couple_id", coupleId).neq("id", fromUser)`, so any garbage UUID still selects the couple's other profile, with `display_name` falling back to `"Your partner"`. The sole barrier is guessing a 128-bit UUID. And the push is data-only and high-priority, but the full-screen intent fires only where the Android FSI permission was granted; otherwise it degrades to a max-priority heads-up (`FCM_SETUP_REPORT.md:94,128-130`).

`turn-credentials/index.ts:5-6` claims the function is *"JWT-gated: only signed-in couple members can call this"* — the handler contains no JWT parsing. It relies entirely on the platform setting (which the live API does report as `verify_jwt: true` for that function), while using the service-role key to read `app_secrets` and returning 24-hour Cloudflare TURN credentials with `Access-Control-Allow-Origin: *`.

### 6.4 Media exposure

`couple_media` is a genuinely public bucket, confirmed against the live project (§5.6). `ChatRepository.Message.imageUrl` (`chat_repository.dart:133-147`) derives a permanent public URL from `image_path`; `voiceUrl` does the same. **Chat media is therefore reachable-by-URL, unauthenticated and forever, from the moment it is sent.**

Saving to the vault does not make this worse and does not make it better. `vault_repository.dart:87` stores that public URL verbatim in `content` (`:76` comments it "never expires"), and `vault_screen.dart:84-88` opens it directly; only `intimate:<path>` items (private `couple_intimate` bucket) get a fresh 1-hour signed URL. The vault row itself *is* protected — RLS `pvi_owner_only` plus the bcrypt PIN — so the URL cannot be enumerated without the owner's session. **The defect is in the chat media architecture, not the vault.** Patching `vault_repository.dart` would fix nothing, because `ChatRepository` regenerates the same URL from the message row.

The remediation is to make `couple_media` private and serve signed URLs everywhere it is read — chat, home, settings, vault — exactly as `couple_intimate` already does. Note also that the only thing currently protecting this media is path unguessability, and the path uses a non-cryptographic PRNG (`chat_repository.dart:336-342`):

```dart
final rng = Random();
final hex = List.generate(12, (_) => rng.nextInt(16).toRadixString(16)).join();
```

`Random()`, not `Random.secure()`. 48 bits behind a UUID `couple_id` keeps brute force impractical today, so treat this as hardening rather than an active break — state-recovery exploitability is unverified.

### 6.5 Sign-out leaks the push token

Two divergent sign-out paths exist, and one of them keeps the device receiving the partner's pushes.

```dart
// settings_screen.dart:340-345 — correct
await FcmService.clearToken();
await ref.read(sessionProvider.notifier).signOut();

// app_drawer.dart:229-231 — leaks
await SupabaseRepository.signOut();
await ref.read(sessionProvider.notifier).signOut();  // calls signOut() again internally
```

`FcmService.clearToken` has exactly one call site repo-wide (`settings_screen.dart:342`). The drawer path clears neither `profiles.fcm_token` (written by `supabase_repository.dart:291-299`) nor the local Firebase registration, so the row stays populated, `reach-notify` keeps targeting the device (`index.ts:126,131,145`), and `firebaseMessagingBackgroundHandler` (`reach_notifications.dart:159-190`) gates only on `message.data['type']` with no auth or session check — it will render the notification, and for `type: call` build the full-screen-intent. `AppDrawer` is live code, used by `app_shell.dart:214` plus eight feature screens. The duplicated `SupabaseRepository.signOut()` is harmless noise; the missing `clearToken` is the defect.

### 6.6 Content and consent gates that are declared but not enforced

- `consent_state` (`intimacy_tables.sql:8`), described at `:243` as the dual-consent gate "shared by all intimacy features", has **zero** client references. Nothing reads or writes it.
- `couple_dissolutions` — the breakup-purge record — is never written.
- `dice_tier_consents` and `fantasy_jar_reveals` are likewise unreferenced.
- The adult gate that *is* enforced is `profiles.birth_date` with the `profiles_must_be_adult` CHECK (`intimacy_additions.sql:26`), plus the Closer tab being sliced off for non-adults at `app_shell.dart:192-198,203`, plus `couples.modest_mode` defaulting to `true`.

`docs/INTIMACY_LAYER.md`'s privacy guarantees — E2EE vault, "true E2EE means we have nothing to hand over", revenge-porn mitigation — are false against the shipped code and must not be relied on in any compliance argument.

---

## 7. Build, release and infrastructure

### 7.1 SDK levels and toolchain

| Setting | Value | Source |
|---|---|---|
| `compileSdk` | 36 | explicit, `mobile/android/app/build.gradle.kts:12` |
| `minSdk` | 24 | **inherited** — `flutter.minSdkVersion` |
| `targetSdk` | 36 | **inherited** — `flutter.targetSdkVersion` |
| AGP | 8.13.0 | `mobile/android/settings.gradle.kts` |
| Kotlin | 2.2.0 | same |
| `google-services` plugin | 4.4.4 | same |
| Java / JVM target | 17 | `build.gradle.kts` |
| Core library desugaring | on, `desugar_jdk_libs:2.1.4` | required by `flutter_local_notifications` 22.x |
| Flutter / Dart | 3.44.2 / 3.12.2 | operator-verified |
| App version | `0.1.0+1` | `pubspec.yaml` |

The comment beside `defaultConfig` claims minSdk 23 is *"Pinned explicitly"*. It is neither 23 nor pinned — `minSdk = flutter.minSdkVersion` resolves to 24 in the installed Flutter 3.44.2 (`FlutterExtension.kt`). The same applies to `targetSdk`: a Flutter SDK upgrade can silently move the target API level, and with it Play requirements and runtime behaviour changes, with no diff in this repo. **Pin both explicitly.**

`mobile/android/build.gradle.kts` force-patches every non-`:app` subproject to `compileSdkVersion(36)` in `afterEvaluate`, because older plugins (`:vibration` is cited) ship `compileSdkVersion 33` while their AndroidX deps need 34+. `gradle.properties` sets `-Xmx8G` / `MaxMetaspaceSize=4G` and `kotlin.incremental=false` — the latter is a documented Windows workaround: the project lives on `E:` while the pub cache is on `C:`, and Kotlin's incremental storage crashes on cross-drive relative paths.

### 7.2 Signing — blocker

```kotlin
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

That is the entire `buildTypes` block (`mobile/android/app/build.gradle.kts:32-36`). There is no `signingConfigs {}` block, no `key.properties` loader, and `mobile/android/key.properties` does not exist. There is also no `minifyEnabled`, no `shrinkResources`, and no ProGuard configuration, so release artifacts are unobfuscated and fully readable.

`mobile/android/.gitignore` does reserve `key.properties`, `**/*.keystore` and `**/*.jks` — the intent was real; it was never implemented. A debug-signed APK cannot be uploaded to Play, cannot upgrade over a production-signed install, and carries no authenticity guarantee (the debug key is a well-known shared secret). **The upload key can never be changed after first publish, so this must be fixed before any first release, not after.**

### 7.3 Permissions

21 `uses-permission` entries. No `<uses-feature>` elements are declared at all — notably none for `android.hardware.camera` despite `CAMERA` being requested.

| Permission | Feature it serves | Play consequence if submitted |
|---|---|---|
| `INTERNET` | Supabase API + Realtime | — |
| `VIBRATE` | Reach haptics, touch map | — |
| `USE_BIOMETRIC` | app lock, vault, Memory Threads gate | — |
| `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION` | capsule proximity unlock, location card | — |
| `ACCESS_BACKGROUND_LOCATION` | opt-in mutual live location | **Background location declaration + video demo — one of Play's hardest approvals** |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` | live-location foreground service | foreground-service-type declaration |
| `FOREGROUND_SERVICE_MICROPHONE` | keep a call alive when backgrounded | foreground-service-type declaration |
| `RECORD_AUDIO` | voice notes, capsule voice memos, video calls | — |
| `MODIFY_AUDIO_SETTINGS`, `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`, `BLUETOOTH` | WebRTC audio routing | — |
| `CAMERA` | rapid camera, heartbeat PPG, reaction camera | — |
| `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED` | gallery sharing | **Photo & Video Permissions declaration**; the manifest comment itself concedes "private app, not Play-bound" |
| `READ_EXTERNAL_STORAGE` (`maxSdkVersion=32`), `WRITE_EXTERNAL_STORAGE` (`maxSdkVersion=28`) | legacy save-to-gallery; 29+ uses MediaStore | — |
| `USE_FULL_SCREEN_INTENT` | Reach full-screen wake alert | **Restricted since Android 14 to calling/alarm apps** — arguable given the app has calling, but must be declared |
| `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED` | Reach wake path | no boot receiver is declared in this manifest; it may come from a plugin via manifest merge — unverified |
| `POST_NOTIFICATIONS` | Android 13+ runtime notifications | — |

`PermissionsBootstrap.requestAllOnce` (`permissions_bootstrap.dart:11-14`) writes its "already asked" flag **before** showing any prompt. If the app is killed during the 8-permission sequence — plausible, since it fires from a post-frame callback on first launch — the batch never runs again on that device and every permission falls back to per-feature prompting.

### 7.4 App identity — Play blocker, and a deliberate product decision

`AndroidManifest.xml:45` sets `android:label="News"` with a matching Google-News-style launcher icon (generated by `mobile/lib/tools/generate_icon.dart`). This is **intentional** and must not be reverted as if it were a bug — it is the outer layer of the concealment model in §6.

It is also flatly incompatible with Google Play's Deceptive Behavior policy. Combined with the background-location and media-permission declarations above, and the adult content in the Closer module, **Play distribution is not on the table for this build.** The blueprint should state that plainly so a new developer neither "fixes" the disguise nor plans a store submission.

Other manifest facts: package and namespace `com.miles.miles`; `MainActivity` is `exported`, `singleTop`, `taskAffinity=""`, `importantForAutofill="noExcludeDescendants"`; two intent filters (`MAIN`/`LAUNCHER`, and a `BROWSABLE` deep link `tethered://join?code=ABCDEF`); `flutterEmbedding = 2`; `com.yalantis.ucrop.UCropActivity` registered portrait-locked; a `<queries>` block for `VIEW` + `https` supporting Supabase Auth email confirmation and OAuth redirects.

**Impeller is force-disabled app-wide** — `io.flutter.embedding.android.EnableImpeller=false` (`:92-94`). The recorded reason is a segfault in `libflutter.so` when compositing the live camera-preview texture under the `BackdropFilter`/blend-mode stack in `rapid_camera_screen`. Skia is on a deprecation path for Android; this pin will eventually break or degrade, and the workaround is global rather than scoped to the one screen that triggers it.

The foreground service is declared once with `foregroundServiceType="location|microphone"` (`:120-124`), `exported=false`, `stopWithTask=true` — one service instance backing both calls and live location. The manifest warns not to rename it.

### 7.5 Key dependencies

| Area | Packages |
|---|---|
| Backend / state / routing | `supabase_flutter ^2.6.0`, `flutter_riverpod ^2.5.1`, `go_router ^14.2.7` |
| Realtime comms | `flutter_webrtc ^1.5.2`, `flutter_foreground_task ^9.2.2`, `record ^7.1.0`, `just_audio ^0.10.5` |
| Push | `firebase_core ^4.11.0`, `firebase_messaging ^16.4.1`, `flutter_local_notifications ^22.0.1`, `workmanager ^0.9.0+3` |
| Media / camera | `camera ^0.12.0+1`, `image_picker ^1.1.2`, `image_cropper ^12.2.1`, `video_player ^2.11.1`, `chewie ^1.13.1`, `image ^4.9.1`, `cached_network_image ^3.4.1`, `youtube_player_flutter 9.1.1` (the only exact pin), `webview_flutter ^4.14.0` |
| On-device ML | `google_mlkit_subject_segmentation ^0.0.3`, `google_mlkit_pose_detection ^0.14.1` |
| Location / maps | `geolocator ^14.0.2`, `geocoding ^4.0.0`, `flutter_map ^8.3.0`, `latlong2 ^0.9.1` |
| Security | `cryptography ^2.7.0` (**declared, never imported — see §6.2**), `flutter_secure_storage ^9.2.2` (used only by `memory_pin_gate.dart`), `local_auth ^2.3.0`, `permission_handler ^12.0.3` |
| Ads | `google_mobile_ads ^9.0.0` |
| Config | `flutter_dotenv ^5.1.0` |
| Lints | `flutter_lints ^4.0.0`, `very_good_analysis ^6.0.0` |

`publish_to: none`, `environment: sdk >=3.4.0 <4.0.0, flutter >=3.22.0`.

### 7.6 Ads — blocker if monetisation is intended

| Item | Current value |
|---|---|
| Manifest `APPLICATION_ID` | `ca-app-pub-3940256099942544~3347511713` — Google's public **test** App ID |
| `AdConfig.useTestAds` | `true` (`mobile/lib/core/ads/ad_config.dart:24`) |
| Test banner (Android) | `ca-app-pub-3940256099942544/6300978111` |
| Production banner / interstitial / rewarded | `'REPLACE_WITH_YOUR_BANNER_UNIT_ID'` etc. (`:40-44`) |

Flipping `useTestAds` to `false` today would request ads against those literal placeholder strings and every request would fail. Three changes must land together: the manifest App ID, the three `_prod*` constants, and the flag.

`AdService.init()` is called once from `main.dart:72`, guarded by `kIsWeb` and wrapped in a bare try/catch, so a failure (no Play Services) leaves the app fully functional with no banners. `banner_ad_slot.dart` is the only consumer; `interstitialUnitId` and `rewardedUnitId` have **no call sites** outside `lib/core/ads/` — dead configuration.

There is exactly one placement, and it is policy-driven: `app_shell.dart:210` reads `final showAd = selected == 3 && !isCloserTab;` — ads only on the Breath tab, enforcing the warning at `banner_ad_slot.dart:12-14` that AdMob policy prohibits ads adjacent to mature content.

`BannerAdSlot` has a latent bug: `onAdLoaded` calls `setState(() => _loaded = true)` (`:49-53`) but `_ad = ad` is assigned only after `await ad.load()` returns (`:63`) and is not inside `setState`. If the callback fires first, `build()` returns `SizedBox.shrink()` because `ad == null` and nothing triggers another rebuild — the banner stays invisible for the widget's lifetime.

Worth a product decision: `google_mobile_ads` is a leftover from the abandoned public-launch plan and currently ships AdMob inside a two-person private app.

### 7.7 Push / FCM

Configuration is complete and internally consistent — this is one of the better-wired parts of the build.

- `mobile/android/app/google-services.json` is present and committed: project `ldrc-120a2`, project number `188998306037`, app id `1:188998306037:android:32baecc398a397210dddbc`, `package_name com.miles.miles` (matches `applicationId`). Committing this file is normal for Firebase Android clients — the API key is restricted by package name + SHA — but that means security depends entirely on SHA-1/SHA-256 restrictions and backend rules configured in the console, neither verifiable from this repo.
- Manifest declares `com.google.firebase.messaging.default_notification_channel_id = "reach_channel"`, which is a real id (`reach_notifications.dart:9`), not a dangling reference.
- `FcmService.init()` initialises `flutter_local_notifications`, creates three channels (reach / care / call), and handles cold start via `getNotificationAppLaunchDetails` (`fcm_service.dart:55-59`).
- Every notification is disguised: title `'News update'`, body `'Tap to open'`, `visibility: NotificationVisibility.secret` (`reach_notifications.dart`).
- The `@pragma('vm:entry-point')` background handler (`:158-209`) reads the FSI permission from a `SharedPreferences` mirror (`fsi_can_use`, written by `fsi_permission.dart:39-44`) because it has no Activity.
- `registerToken()` (`fcm_service.dart:84-100`) retries `getToken()` up to 4× with 2s gaps and is re-run on **every** resume (`main.dart:277`) to self-heal tokens the notify function nulled server-side.
- No manual `FirebaseMessagingService` entry is needed — the plugin supplies it via manifest merge.

`mobile/lib/core/push/fcm_todo.dart` should be **deleted**. It opens *"FCM / background screen-wake for Reach — NOT YET CONFIGURED"* and lists five TODOs, all five of which have shipped (`firebase_core`/`firebase_messaging` in `pubspec.yaml:66-67`; `google-services.json` present; token persisted at `supabase_repository.dart:295`; the edge function at `functions/reach-notify/index.ts`; `flutter_local_notifications` at `pubspec.yaml:68`). Its class `FcmTodo` is never instantiated, and its only inbound reference is a doc comment at `reach_overlay_screen.dart:13` pointing readers at it — actively telling anyone reading the Reach flow that push is unimplemented. Deleting it removes 100% of the repo's TODO markers (5 TODOs, 0 FIXME, 0 HACK across 163 files / 40,317 lines).

### 7.8 Environment configuration

`mobile/.env` is loaded by `flutter_dotenv` at `main.dart:50-60`, after which a masked length check throws `StateError` if the Supabase URL or key is empty — deliberately failing fast rather than letting an empty URL raise a `FormatException` on every request.

`mobile/lib/core/config.dart` holds key **names** only: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `GOOGLE_MAPS_3D_KEY` (the `NEXT_PUBLIC_` prefix is a fossil of the abandoned Next.js app at the repo root, which targeted the same Supabase project). It also carries the 4-7-8 breath constants and a 17-entry timezone list.

`pubspec.yaml:99-100` declares `.env` as a bundled Flutter **asset**, so everything in it ships inside the APK and is trivially extractable — and with no code shrinking or obfuscation (§7.2), release artifacts are fully readable. The anon key is designed to be public, so this is acceptable for that key specifically; the exposure depends on whatever else `.env` contains. The file is blocked by permission settings and was not read, so its actual sensitivity is **unverified**. Genuine secrets are correctly kept out: Cloudflare TURN credentials live in the `app_secrets` table and are fetched through the `turn-credentials` edge function, never in the APK.

`mobile/android/local.properties` currently carries `flutter.buildMode=release`, `flutter.versionName=0.1.0`, `flutter.versionCode=1`, `sdk.dir=C:\Users\razaa\AppData\Local\Android\sdk`, `flutter.sdk=C:\flutter\flutter`.

### 7.9 Build and run

Always build from `E:\LDR\mobile`, never from `E:\LDR` — the latter fails with "No pubspec.yaml". `BRAIN.md:165` records this.

```
cd E:\LDR\mobile
flutter pub get
flutter analyze
flutter test
flutter run                    # debug on a connected device
flutter build apk --release    # debug-signed today — see §7.2
```

The root `build.gradle.kts` relocates the build directory to `../../build` (i.e. `E:/LDR/mobile/build`) for the root and every subproject.

**Measured today:**

| Check | Result |
|---|---|
| `flutter analyze` | 0 errors, ~1476 issues (10 warnings, 1466 info) |
| `flutter test` | 32 tests passing, 3 files, ~5s |
| `flutter build apk --release` | succeeds — 152.5 MB, 3 ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) |

The analyzer number overstates the debt: 1029 of 1476 issues are two pure-formatting rules (`require_trailing_commas` 776, `prefer_single_quotes` 253), both mechanically fixable. The signal that matters is buried under them — `unawaited_futures` (32, a real fire-and-forget risk in an app doing realtime and Supabase writes), `avoid_dynamic_calls` (29), and the 10 warnings, which include two unused imports, one unused element, three inference failures, one dead null-aware expression, and `app_shell.dart:76:45 invalid_use_of_internal_member` — the shell calls `realtime.connect()`, a package-internal member, which can break silently on a dependency bump. **Run the mechanical fixes so the remaining ~450 issues become readable.**

Test coverage is the largest quality gap. Three files, 32 tests, covering exactly three units out of 163 Dart files and 40,317 lines:

| File | Covers |
|---|---|
| `test/unit/json_utils_test.dart` | `core/utils/json_utils.dart` — 20 tests, labelled "Issue 3 regression tests" |
| `test/unit/love_notes_pool_test.dart` | `features/cycle/love_notes_pool.dart` — 7 tests, including a content-policy test asserting no real person is named |
| `test/widget/love_note_preview_sheet_test.dart` | `features/cycle/love_note_preview_sheet.dart` — 5 widget tests |

There is no `integration_test/` directory. No test imports the router, any screen, or any routed destination — the one widget under test is a modal sheet opened from `cycle_screen.dart:501`, not a route. Nothing covers auth, `supabase_repository.dart`, chat, calls/TURN, presence, the vault, or FCM. Most consequentially, the onboarding redirect funnel at `router.dart:54-100` — a single callback that gates all 43 routes through a five-stage auth → profile → couple → role sequence — is untested. That is an assessment of risk, not a measurement, but it is well supported by the fact that every route in the app passes through it.

Two of the 32 tests are brittle by construction: `love_notes_pool_test.dart:39` asserts `expect(withToken, 155)` and `:50` asserts `hasLength(250)` against the shipped note pool, so any edit to the content fails the suite for a non-defect reason.

### 7.10 Repo hygiene

| Issue | Detail |
|---|---|
| 16 loose APKs in the repo root | `Tethered-*.apk`, ~118–160 MB each (~2 GB total), dated 2026-06-28. Correctly gitignored (`*.apk`, `Tethered*.apk`) so they never entered history, but they bloat the working tree and any naive archive or backup of `E:/LDR`. |
| Dead Next.js scaffold | `E:/LDR/src` (19 files, 7 routes), `package.json`, `next.config.js`, `tailwind.config.ts` — a complete-but-abandoned Next.js 14.2.15 app wired to the same Supabase schema. Exactly 1 of the repo's 106 commits touches it (the initial commit, 2026-06-24); 104 touch `mobile/`. `node_modules/` is empty, there is no lockfile, no `.next/`, no `vercel.json`, and no git remote. It cannot be built or run without a fresh dependency resolve against 14 months of upstream drift. |
| 5 overlapping top-level docs | `README.md`, `BRAIN.md`, `ROADMAP.md`, `TETHERED_FULL_DOCUMENTATION.md`, `FIX_REPORT.md` — `README.md` still describes the Next.js/Vercel/Stripe/Resend web app and does not mention Flutter at all. |
| Naming drift | User-facing name "Tethered" (`main.dart:441`); Dart package `miles` (`pubspec.yaml:1`); Android `com.miles.miles`; launcher label "News"; design system "Emberlight"; `package.json` name "miles". |

### 7.11 Shipped on branch `fix-sprint` this session

| Change | Effect |
|---|---|
| `friendlyAuthError()` applied on the onboarding screens | network failures no longer dump a raw Dart exception into the UI |
| Auth email fields set `enableSuggestions: false` + `enableIMEPersonalizedLearning: false`; `MainActivity` sets `importantForAutofill="noExcludeDescendants"` | keeps the account email out of keyboard personalisation and autofill |
| News cover no longer force-drops on transient `inactive` during first-time setup — gated on a persisted `setupCompletedOnce` flag; sign-out now re-raises the cover | disconnecting a partner can no longer permanently disable the cover, and account creation is no longer made impossible by keyboard/dialog bounces |
| Cycle love-note pool: 169 hardcoded real names (`Zunaira` ×111, `"Mrs Raza"` ×58) replaced with a `{name}` placeholder filled from a required per-user prompt | removes personal data hardcoded into shipped app content |
| That feature hidden behind `FeatureFlags.pooledLoveNotes = false` (`core/feature_flags.dart`) | held back from launch: pet names still hardcoded, gendered husband → wife, no localisation |

## 8. Quality state

The build is green and the analyzer reports no errors, but neither number means much: coverage is three files, and the analyzer's headline count is ~70% formatting lint. The real debt is structural — untested control flow, hand-rolled realtime patterns duplicated nine times, and documentation that describes a product the code no longer is.

### 8.1 Measured today

| Check | Command | Result |
|---|---|---|
| Static analysis | `flutter analyze` (from `E:\LDR\mobile`) | 1476 issues — **0 errors**, 10 warnings, 1466 info (49.8s) |
| Tests | `flutter test` | `00:05 +32: All tests passed!` (exit 0) |
| Release build | `flutter build apk --release` | Succeeds. 152.5 MB, 3 ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) |

Builds must be run from `E:\LDR\mobile`; from `E:\LDR` they fail with "No pubspec.yaml".

### 8.2 Test coverage

Three files, 32 tests, covering three units out of 163 Dart files / 40,317 lines in `mobile/lib`.

| File | Tests | Unit under test |
|---|---|---|
| `mobile/test/unit/json_utils_test.dart` | 20 | `lib/core/utils/json_utils.dart` (labelled "Issue 3 regression tests") |
| `mobile/test/unit/love_notes_pool_test.dart` | 7 | `lib/features/cycle/love_notes_pool.dart` |
| `mobile/test/widget/love_note_preview_sheet_test.dart` | 5 | `lib/features/cycle/love_note_preview_sheet.dart` |

There is no `integration_test/` directory. `grep -rniE "router|gorouter|redirect" mobile/test/` returns nothing.

What is **not** covered: auth, the onboarding redirect funnel (`lib/core/router.dart:54-100`, the single gate in front of all 43 routes), `lib/core/supabase_repository.dart`, chat, WebRTC calls and TURN, presence, the vault and PIN flow, FCM registration, and every one of the 56 screen files. The one feature-UI test targets `LoveNotePreviewSheet`, a modal sheet with no route, opened from `cycle_screen.dart:501`.

Two assertions are brittle by construction: `love_notes_pool_test.dart:39` asserts `expect(withToken, 155)` and `:50` asserts `hasLength(250)` against the shipped note pool, so any edit to the pool fails the suite for a non-defect reason.

### 8.3 Analyzer breakdown

`mobile/analysis_options.yaml` uses `very_good_analysis` with `require_trailing_commas: true`, `avoid_print: true`, and `lines_longer_than_80_chars` / `public_member_api_docs` disabled.

| Rule | Count | Nature |
|---|---:|---|
| `require_trailing_commas` | 776 | formatting, mechanically fixable |
| `prefer_single_quotes` | 253 | formatting, mechanically fixable |
| `always_put_required_named_parameters_first` | 68 | style |
| `cascade_invocations` | 59 | style |
| `avoid_redundant_argument_values` | 51 | style |
| `unawaited_futures` | 32 | **substantive** — fire-and-forget Supabase/realtime writes |
| `avoid_dynamic_calls` | 29 | **substantive** |
| `avoid_escaping_inner_quotes` | 27 | formatting |

1029 of 1476 (~70%) are the top two formatting rules. Running `dart fix --apply` would collapse the number and make the remaining ~450 legible.

All 10 warnings:

| Location | Warning |
|---|---|
| `lib/core/utils/json_utils.dart:72:20` | `strict_raw_type` — `Map` without type args |
| `lib/features/chat/chat_screen.dart:1035:17` | `unused_element` — `_ago` never referenced |
| `lib/features/chat/chat_screen.dart:1585:3` | `strict_raw_type` — `StreamSubscription?` |
| `lib/features/chat/rapid_camera_screen.dart:3:8` | `unused_import` — `dart:typed_data` |
| `lib/features/chat/rapid_camera_screen.dart:248:15` | `inference_failure_on_instance_creation` — `Future.delayed` |
| `lib/features/closer/fantasy_jar/fantasy_jar_screen.dart:138:7` | `inference_failure_on_instance_creation` — `MaterialPageRoute` |
| `lib/features/closer/pick_for_us/pick_for_us_screen.dart:137:11` | `inference_failure_on_instance_creation` — `Future.delayed` |
| `lib/features/reach/reach_screen.dart:88:42` | `dead_null_aware_expression` |
| `lib/features/shell/app_shell.dart:76:45` | `invalid_use_of_internal_member` — `realtime.connect()` is package-internal |
| `lib/features/together/together_screen.dart:11:8` | `unused_import` — `supabase_flutter` |

`app_shell.dart:76` is the one worth acting on: it calls a `@internal` member of `supabase_flutter` inside the doze-recovery path, so a dependency bump can break realtime reconnection silently.

### 8.4 TODO / FIXME hotspots

`grep -rnE "TODO|FIXME|HACK" mobile/lib --include=*.dart` returns exactly **5 hits, 0 FIXME, 0 HACK** — all five in one file, `lib/core/push/fcm_todo.dart` (lines 8, 9, 11, 13, 18).

That file is entirely stale and actively misleading. It opens "FCM / background screen-wake for Reach — NOT YET CONFIGURED … there's no Firebase project yet". All five TODOs shipped:

| TODO | Shipped at |
|---|---|
| add `firebase_core` + `firebase_messaging` | `pubspec.yaml:66-67` |
| add `google-services.json` | `mobile/android/app/google-services.json` (project `ldrc-120a2`) |
| store + refresh FCM token | `lib/core/services/fcm_service.dart:89, :98`; `lib/core/supabase_repository.dart:295` |
| Edge Function on `reach_events` INSERT | `supabase/functions/reach-notify/index.ts` |
| `flutter_local_notifications` | `pubspec.yaml:68` |

The class `FcmTodo` is never instantiated. Its only inbound reference is a doc comment at `lib/features/reach/reach_overlay_screen.dart:13` pointing readers at it. Deleting the file removes 100% of the repo's TODO markers.

### 8.5 Dead and unreachable code

| Item | Status | Evidence |
|---|---|---|
| `lib/features/countdown/` (screen + `widgets/set_visit_sheet.dart`) | Dead — no route, no import | `grep -rn "CountdownScreen"` returns only its own 4 self-referential lines. Superseded by `lib/features/timeline/`, which owns `Visit` data |
| `lib/features/skybridge/sky_bridge_screen.dart` | Dead | `grep -rn "SkyBridgeScreen"` returns only its own 4 lines. Also carries an unresolved tzdata note |
| `lib/features/reach/reach_screen.dart` | Dead file inside a live module | `grep -rn "\bReachScreen\b"` returns only its own 4 lines. `reach_button.dart` / `reach_overlay_screen.dart` / `reach_repository.dart` are live |
| `/app/intimacy` (whole module: screen, prefs, controller, repository) | Routed but orphaned | Registered at `router.dart:162`; nothing anywhere pushes it. Only `/app/intimacy/prefs` is pushed, and only from inside `IntimacyScreen` itself. Deep-link-only |
| `RealtimeService.coupleStream` / `.broadcast` | Zero call sites | `coupleTable` has exactly one caller (`presence_service.dart:414`). The facade's own doc claims features go "through here"; 4 files call `client.channel()` directly and 15 use `ManagedSubscription` |
| `crypto_core.dart` | Identity pass-throughs since 2026-06-25 | `encryptString` returns `base64Encode(utf8.encode(plaintext))` with a zero-filled 24-byte nonce and 16-byte MAC |
| `lib/core/push/fcm_todo.dart` | Dead + misleading | See 8.4 |
| `AdConfig.interstitialUnitId` / `rewardedUnitId` | No call sites outside `lib/core/ads/` | Banner is the only format used |
| `signInWithGoogle` | `throw UnimplementedError('Google sign-in arrives in v1.1')` | `supabase_repository.dart:32-36` |
| 5 SQL tables | Provisioned, RLS'd, mostly realtime-published, zero client references | `consent_state`, `fantasy_jar_reveals`, `couple_dissolutions`, `visit_memories`, `mood_lamp`. `consent_state` is described in `intimacy_tables.sql:243` as the dual-consent gate "shared by all intimacy features" — that gate is enforced nowhere |

### 8.6 Structural debt: duplicated realtime subscription logic

The "remove old channel, then resubscribe" pattern is hand-rolled at **nine** sites. `ManagedSubscription` (`lib/core/realtime_service.dart:96-141`) already exists as the canonical primitive and documents why the naive form is broken (`:81-83`: "`unsubscribe()` only schedules an async leave … the app-wide subscription-health bug") — but none of the nine hand-rolled sites use it.

| Site | Awaits `removeChannel`? | Re-entrancy guard? |
|---|---|---|
| `lib/core/realtime_service.dart:112-128` (`ManagedSubscription`) | yes | yes |
| `lib/core/session_provider.dart:181-204` | yes | yes |
| `lib/core/services/presence_service.dart:398-429` | yes | yes |
| `lib/features/call/call_controller.dart:55-74` | yes | yes |
| `lib/features/chat/chat_screen.dart:300-318` | yes | yes |
| `lib/features/shell/app_shell.dart:83-98` | yes | **no** |
| `lib/core/widgets/partner_here_badge.dart:37-61` | **no** | **no** |
| `lib/features/closer/touch_trace/touch_trace_canvas.dart:87-91` | **never calls it** — `unsubscribe()` + immediate re-`channel()` | **no** |
| `lib/features/cycle/cycle_screen.dart:63-77` | **never calls it** | **no** |

`partner_here_badge.dart:42` carries a comment claiming the fix it does not perform. Its practical failure mode is degradation, not death — `:104` falls back to the DB presence value on a 15s poll — but `_subscribe()` never resets `state`, so a stale non-null broadcast value pins the `??` and blocks the fallback, leaving the badge tracking a screen the partner has left.

`BRAIN.md` records this as ISSUE-005, **IN PROGRESS** as of 2026-06-27, with Phase 2b (feature screens) outstanding. It is the largest known unfinished engineering item and exists in no plan document.

### 8.7 Debt reduced this session (branch `fix-sprint`)

| Change | Effect |
|---|---|
| `friendlyAuthError()` wired into the onboarding screens | Network failures no longer surface a raw Dart exception in the UI |
| Auth email fields set `enableSuggestions: false` + `enableIMEPersonalizedLearning: false`; `MainActivity` sets `android:importantForAutofill="noExcludeDescendants"` | Keyboard/autofill no longer learn or leak the pairing identity |
| Cover no longer force-drops on transient `inactive` during first-time setup; gated on a persisted `setupCompletedOnce` flag. Sign-out re-raises the cover | Disconnecting a partner mid-setup can no longer permanently disable the disguise |
| 169 hardcoded real names in the cycle love-note pool (`Zunaira` ×111, `"Mrs Raza"` ×58) replaced with a `{name}` placeholder filled from a required per-user prompt | Removes personal data from shipped source |
| That feature hidden behind `FeatureFlags.pooledLoveNotes = false` | Held back from launch: pet names still hardcoded, gendered husband→wife, no localisation |

---

## 9. Web presence

`E:\LDR` root holds a complete but abandoned Next.js 14.2.15 App Router project. It is **not** a marketing site placeholder — it is a working (if incomplete) authenticated web client for the same Supabase backend the Flutter app uses.

### 9.1 What it is

19 source files under `src/`, 7 routes:

| Route | File | What it does |
|---|---|---|
| `/` | `src/app/page.tsx` | Marketing landing page — hero "Feel close, even from here.", 3 feature cards, pricing copy "Together plan from $39/year" |
| `/login` | `src/app/login/` | Supabase sign-in |
| `/signup` | `src/app/signup/` | Sign-up |
| `/welcome` | `src/app/welcome/` | Onboarding + invite-code generation |
| `/couple` | `src/app/couple/` | Join by invite code |
| `/app` | `src/app/app/page.tsx` | Countdown dashboard (React Server Component) |
| `/auth/callback` | route handler | `exchangeCodeForSession` |

Business logic lives in `src/app/actions.ts` as Next server actions: `signOut`, `setNextVisit`, `completeOnboarding`, `joinCouple`.

Dependencies (`package.json`, name `miles`, version 0.1.0, private): `next 14.2.15`, `react ^18.3.1`, `@supabase/ssr ^0.5.2`, `@supabase/supabase-js ^2.45.4`; dev: `typescript ^5.6.2`, `tailwindcss ^3.4.13`, `eslint-config-next 14.2.15`. **No `stripe`, no `resend`** — `README.md:17-18` claims both are in the stack.

### 9.2 It targets the same Supabase project as the Flutter app

`src/types/database.ts` hand-types 7 tables (`couples`, `profiles`, `visits`, `daily_prompts`, `prompt_responses`, `rituals`, `visit_memories`) and its header states it "matches the schema in /supabase/schema.sql" — which it does. Both clients read `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`; the Flutter app inherits the Next.js-flavoured variable name verbatim at `mobile/lib/core/config.dart:6`.

Caveat: `.env.local` and `mobile/.env` are blocked by permission settings, so shared-project targeting is inferred from the shared schema and shared variable names, not directly observed.

### 9.3 It is not maintained and not deployed

| Signal | Value |
|---|---|
| Commits touching `src/`, `package.json`, `next.config.js`, `tsconfig.json` | **1** — `249f272`, 2026-06-24, the repo's first commit |
| Commits touching `mobile/` | 104 of 106; HEAD 2026-08-06 |
| `node_modules/` | Exists, **empty** (`ls -A` → 0 entries; `next/` and `@supabase/` absent) |
| Lockfile | None — no `package-lock.json`, `yarn.lock`, or `pnpm-lock.yaml` |
| Build output | No `.next/`, no `out/` |
| Deploy config | No `vercel.json`, no `.vercel/` |
| Git remote | `git remote -v` → empty. No remote at all |
| `README.md:23` | "Status: Phase 0 — Listening" |

The only surviving artefact of intent is `.claude/launch.json`, which defines a `web` config running `npm run dev` on port 3000.

### 9.4 Known defects if it is ever revived

| Defect | Location | Impact |
|---|---|---|
| Unhandled `TypeError` on `/app` | `src/app/app/page.tsx:14` dereferences `user!.couple!.id`; `src/lib/session.ts:33` returns `couple: null` when `profile.couple_id` is null. The middleware guard is explicitly skipped for `/app` (`src/lib/supabase/middleware.ts:58` gates the profile/couple check on `!isProtected`) | A signed-in user with no couple gets a crash instead of the onboarding redirect |
| 4 of 5 nav links 404 | `src/app/app/layout.tsx:21-27` links `/app/rituals`, `/app/prompt`, `/app/timeline`, `/app/settings`; `src/app/app/` contains only `layout.tsx` and `page.tsx` | The web app has never been navigable past the countdown screen |
| Cannot be built as-is | Empty `node_modules`, no lockfile | Reviving is a fresh dependency resolve against caret ranges with 14 months of upstream drift — treat as a new install, not a resume |

### 9.5 Recommendation

Decide explicitly (see §11.9). Leaving it in place is the worst option: `README.md` describes it as the product, so a new developer reading the repo top-down will build the wrong thing.

---

## 10. Launch readiness

Ordered by severity, then by whether the item blocks other decisions. **The first row is upstream of most of the rest** — the Play-vs-sideload decision determines whether rows 2, 3, 6, 7 and 21 are blockers or non-issues.

| # | Item | Severity | Why it blocks | Decision or work needed | Type |
|---:|---|---|---|---|---|
| 1 | **Distribution model unresolved: private sideload vs Play Store** | blocker | The repo documents two mutually exclusive products. `ROADMAP.md:1-30` plans a public freemium Play launch ("Miles", $100/mo MRR, $5/mo "Together" tier). `TETHERED_FULL_DOCUMENTATION.md:3-4` says "built for ONE couple … Not on any store — sideloaded APK." The code matches the latter. Nearly every other row's severity depends on this | Pick one, in writing, before anything else. Then delete or rewrite the losing document | **Product decision** |
| 2 | **Release APK signed with the debug keystore** | blocker | `mobile/android/app/build.gradle.kts:32-36` is `release { signingConfig = signingConfigs.getByName("debug") }`. No `signingConfigs {}` block; `mobile/android/key.properties` does not exist. Debug-signed APKs cannot be uploaded to Play, cannot upgrade over a production install, and carry no authenticity guarantee (the debug key is a shared public secret). **The upload key can never be changed after first publish** | Generate an upload keystore, add `key.properties` (already reserved in `android/.gitignore` alongside `**/*.keystore`, `**/*.jks`), wire a real `signingConfigs` block. Store the keystore off-repo with a documented recovery path | Engineering task |
| 3 | **`android:label="News"` + Google-News-style launcher icon** | blocker | `AndroidManifest.xml:45` ships a deliberate disguise. This is a direct conflict with Google Play's Deceptive Behavior policy (deceptive app identity) and would fail review. It is an intentional product feature, not a bug — see `lib/features/fake_news/` and the whole cover-swap in `main.dart:347-382` | If Play: the disguise must go, and with it the cover, the panic lock and the stealth scrim — i.e. the app's defining security feature. If sideload: keep it, and state plainly in the blueprint that Play distribution is off the table so no one "fixes" it | **Product decision** |
| 4 | **AdMob runs entirely on Google's test inventory** | blocker | Manifest `APPLICATION_ID` is `ca-app-pub-3940256099942544~3347511713` (Google's public test ID) and `lib/core/ads/ad_config.dart:24` has `useTestAds = true`. Production constants are literal `'REPLACE_WITH_YOUR_BANNER_UNIT_ID'` etc. Shipping test IDs violates AdMob policy; flipping the flag alone would request ads against placeholder strings and every request would fail | Three changes must land together: real manifest App ID, real unit IDs, `useTestAds = false`. **Or** remove `google_mobile_ads` entirely — see §11.4 | Both |
| 5 | **Supabase project is on the FREE plan and auto-pauses** | blocker | Project `sopictusdonlvuezmfep` (region `ap-south-1`, Postgres 17) auto-paused after ~7 days idle on 2026-08-06. Pausing withdraws the DNS record, so the app fails with `Failed host lookup … errno = 7` — a hard outage with no client-side recovery. Data survived (5 users, 5 profiles, 4 couples, 24 messages) and it was restored via the API, but **this will recur** | Move to a paid plan, or accept the outage and add (a) a keepalive that pings the project inside the idle window and (b) a client-side error state that says "service unavailable" rather than surfacing a DNS error | Both |
| 6 | **`E:\LDR\supabase` is not the schema of record — no environment can be rebuilt from it** | blocker | Four client-used tables have no DDL anywhere in the repo (`love_reasons`, `cycle_settings`, `cycle_events`, `care_nudges` — verified by mechanical diff of client `.from()` targets against every `create table`). Also missing: `profiles.gender`/`gender_set`, `profiles.chat_theme_id`/`chat_bg_image_url`, `messages.voice_path`/`video_path`/`reply_to_id`, `presence.chat_last_read`, `public.app_secrets`, and the `couple_media` / `couple_intimate` / `chat-bg` buckets. No `supabase/config.toml`, no `migrations/`, no seed. The RLS posture of those four tables and three buckets is unverifiable from source | Dump the live schema, commit it as a baseline migration, adopt `supabase/migrations/` + `config.toml`, and stop applying DDL out-of-band via MCP (`presence_status_v2.sql:3` records exactly that pattern) | Engineering task |
| 7 | **The app claims end-to-end encryption in its own UI; there is none** | blocker | `lib/core/crypto_core.dart` states "E2EE REMOVED (2026-06-25, at the owner's request)". `encryptString` returns `base64Encode(utf8.encode(plaintext))` with a zero-filled 24-byte nonce and 16-byte MAC; `getMyPublicKeyB64()` returns the literal `'plaintext-v1'`. The `cryptography ^2.7.0` dependency is never imported. Four more Closer features (`desire`, `touch_trace`, `mood_lamp`, `pick_for_us`) store plain columns with no wrapper at all. Meanwhile the shipped UI says: "Encrypted on your phone — not even we can read it" (`private_vault_screen.dart:447`), "A private, end-to-end encrypted space" (`closer_screen.dart:315`), "It's encrypted end-to-end. Only you can read it" (`add_fantasy_screen.dart:96`), plus `settings_screen.dart:304, :481` and `closer_screen.dart:187`. This is a user-facing misrepresentation about intimate photo and note data, not merely a stale doc | Either restore real encryption or delete every "end-to-end encrypted" string from the UI and from `docs/INTIMACY_LAYER.md`, `docs/BUILD_PLAN.md`, `TETHERED_FULL_DOCUMENTATION.md`, `supabase/partner_keys.sql`. "RLS-scoped plaintext" may be an acceptable deliberate tradeoff — the false claims are not | **Product decision**, then engineering |
| 8 | **`README.md` describes a product that does not exist** | high | It documents a Next.js/Tailwind/Stripe/Resend/Vercel web app, "Phase 0 — Listening", and never mentions Flutter. The dead scaffold is still physically present at `E:\LDR\src`. It is the first file any new developer opens | Replace or delete before this blueprint ships. Same pass should resolve `ROADMAP.md` (Play/freemium plan) and `docs/INTIMACY_LAYER.md` (whose Play-compliance defence rests on the deleted E2EE) | Engineering task |
| 9 | **`reach-notify` edge function is unauthenticated** | high | `supabase/fcm_push.sql:23-27` POSTs to a hardcoded URL with only a `Content-Type` header. `functions/reach-notify/index.ts:95-103` parses `payload.record ?? payload` and acts on any body with `from_user` + `couple_id`, with no auth check. Live API confirms `{"slug":"reach-notify","verify_jwt":false}`. Only a valid `couple_id` is needed — `from_user` can be garbage, since the lookup is `.eq("couple_id", …).neq("id", fromUser)` and `display_name` falls back to "Your partner". Anyone with the URL and a couple UUID can fire a high-priority push at the partner's phone. `FCM_SETUP_REPORT.md:142-145` already documents this and proposes the fix | Add a shared-secret header set by `notify_reach()` and verified in the function. Same for `call-notify`, which is also `verify_jwt:false` **and has no source committed anywhere under `supabase/functions/`** — an unauthenticated function that cannot be code-reviewed | Engineering task |
| 10 | **`couple_media` is a public bucket — all chat images, GIFs and voice notes are fetchable with no auth** | high | Verified live: `{"id":"couple_media","public":true}`, and an anonymous probe resolves the bucket and performs the key lookup. `ChatRepository.Message.imageUrl` (`chat_repository.dart:133-147`) regenerates the permanent public URL from any message row. Saving to the vault (`vault_repository.dart:87`) stores that URL verbatim, but **the vault is not the defect** — the media was reachable-by-URL from the moment it was sent. Path unguessability is the only protection and relies on `Random()`, not `Random.secure()` (`chat_repository.dart:336-342`) | Make `couple_media` private and serve signed URLs everywhere it is read (chat, home, settings, vault), as `couple_intimate` already does. Switch the path generator to `Random.secure()`. Also fix `TETHERED_FULL_DOCUMENTATION.md:535`, which wrongly lists this bucket as private (contradicting its own line 426) | Engineering task |
| 11 | **Capsule seal is bypassable by a direct UPDATE** | high | `capsules.sql:47-48` grants any couple member unrestricted UPDATE on the `capsules` row — RLS `USING`/`WITH CHECK` cannot restrict columns, and `information_schema.column_privileges` confirms `authenticated` holds UPDATE on `unlocked_at`, `unlock_date` and `unlock_mode`. No guard trigger exists (`pg_trigger` → empty). So `update capsules set unlocked_at = now()` defeats `capsule_items_select_unlocked`, making `unlock_capsule()`'s `too_early` check advisory. Worse: the `capsule-media` storage policies (`capsules.sql:115-117`) gate SELECT on `couple_id` only with no `unlocked_at` check, so sealed photo/voice bytes are downloadable without touching the row at all. `unlock_mode='proximity'` has no server-side check whatsoever | Restrict the UPDATE policy to non-seal columns (or revoke column UPDATE and route through an RPC), and add an `unlocked_at` predicate to the storage SELECT policy | Engineering task |
| 12 | **`messages` UPDATE policy is couple-scoped, not sender-scoped** | high | `settings_and_delete.sql:29-32` checks only `couple_id` in both `USING` and `WITH CHECK`. Confirmed live in `pg_policies`; `authenticated` holds UPDATE; no guard trigger. Either partner can rewrite the other's `body`, `kind`, `image_path`, flip `deleted_for_everyone`, **or reassign `sender_id`** (message forgery). Contrast `messages_insert_member` and `messages_delete_own` (`messages.sql:26-32`), which both pin `sender_id = auth.uid()`. The shipped Flutter client never issues a direct UPDATE — all mutation goes through RPCs — so this is latent, reachable via PostgREST with a normal session (and the anon key ships in the APK) | Add `sender_id = auth.uid()` to the policy, or drop the blanket UPDATE and route everything through the existing security-definer RPCs | Engineering task |
| 13 | **Drawer sign-out leaks the FCM token** | high | `app_drawer.dart:229-231` calls `SupabaseRepository.signOut()` then `sessionProvider.signOut()` (which calls it again at `session_provider.dart:221`) and never calls `FcmService.clearToken()`. `settings_screen.dart:340-345` does it correctly. `profiles.fcm_token` stays populated, and the background handler (`reach_notifications.dart:159-190`) gates only on `message.data['type']` with no session check — so a signed-out device keeps receiving the partner's Reach/care/call pushes, including the full-screen-intent call notification. The drawer is live code, used by `app_shell.dart:214` plus 8 feature screens | Extract one `signOut()` path and call it from both sites | Engineering task |
| 14 | **Cold-start network failure dumps a paired user into profile creation** | high | `session_provider.dart:172-176` catches and sets `loading: false` with `session` non-null and `profile` still null; its comment claims the router redirects to sign-in. It does not — `router.dart:65` sees `isAuthenticated == true` and falls through to `needsProfile` (`:72-78`) → `/welcome`. Any failure before `session_provider.dart:107` triggers it, including a timeout on the couples or partner query after the profile itself loaded. There is no auto-retry, so the user is stuck until they submit the form — **which overwrites their `display_name`, `timezone` and `birth_date`** — or a token refresh fires. Not affected: later reloads, since `copyWith` uses `profile ?? this.profile` | Distinguish "no profile" from "failed to load profile" in `SessionState`; show a retry state rather than routing to onboarding | Engineering task |
| 15 | **Three realtime subscriptions rejoin incorrectly after doze** | high | See §8.6. `partner_here_badge.dart:37-61` (unawaited `removeChannel`, no guard), `touch_trace_canvas.dart:87-91` and `cycle_screen.dart:63-77` (never call `removeChannel` at all — the exact anti-pattern `realtime_service.dart:81-83` names as "the app-wide subscription-health bug"). `app_shell.dart:83-98` awaits but has no re-entrancy guard. Tracked as `BRAIN.md` ISSUE-005, still open | Collapse all nine hand-rolled sites onto `ManagedSubscription`. Also clear `state` in `PartnerScreenNotifier._subscribe` so the DB fallback can engage | Engineering task |
| 16 | **`.env` ships inside the APK; release build has no shrinking or obfuscation** | high | `pubspec.yaml:99-100` declares `.env` as a bundled Flutter asset, so everything in it is trivially extractable. `buildTypes.release` sets no `minifyEnabled`, no `shrinkResources`, no ProGuard rules, so the release artifact is fully readable | Audit `.env` contents (not read during this survey). Anon key + URL are fine to ship; anything else is not. Enable R8 and `--obfuscate --split-debug-info` for release | Engineering task |
| 17 | **Vault protection is client-side only, and biometrics bypass the PIN entirely** | high | `vault_gate_screen.dart:138-150` unlocks on `local_auth` success alone — `setState(() => _unlocked = true)`, no RPC — sidestepping the server-side bcrypt hash, the 5-try counter and the 15-minute lockout in `private_vault.sql:52-71`. There is no biometric opt-in: `vault_pin.biometric_enabled` (`private_vault.sql:15`) is never read by any Dart code, so the button shows whenever a PIN exists. `authenticate()` is called with no `CryptoObject`, so a newly-enrolled fingerprint does not invalidate access. On a shared phone, the subtitle "Your partner can never open this" (`:213`) is false against the partner. Separately, `pvi_owner_only` is `(owner_id = auth.uid())` with no PIN dependency, and the Supabase session persists in unencrypted `SharedPreferences` (`supabase_service.dart:12-16` sets no custom localStorage), so a device holder can lift the token and hit PostgREST directly. No shipped in-app path bypasses the gate today | Route biometric unlock through the server (issue a short-lived unlock token from `verify_vault_pin`), honour `biometric_enabled`, and move the Supabase session to `flutter_secure_storage` — already a dependency, currently used only by `memory_pin_gate.dart` | Engineering task |
| 18 | **Zero tests on the router, the onboarding funnel, auth, or any screen** | high | `router.dart:54-100` is a five-stage funnel gating all 43 routes, with no test. Nothing covers auth, the repository layer, chat, calls, presence, the vault, or FCM. 32 tests over 40,317 lines, exercising 3 units | Agree a minimum bar (see §11.7). At the least: widget-test the redirect funnel across the six session states, and unit-test `SupabaseRepository` against a fake client | Engineering task |
| 19 | **Permissions requiring Play Console declarations** | high (if Play) / n/a (if sideload) | `ACCESS_BACKGROUND_LOCATION` (background-location declaration + video demo — one of Play's hardest approvals), `USE_FULL_SCREEN_INTENT` (restricted since Android 14; arguable given the calling feature, but must be declared), `READ_MEDIA_IMAGES`/`READ_MEDIA_VIDEO` (photo & video permissions declaration — the manifest comment itself concedes "private app, not Play-bound"), and the `location\|microphone` foreground-service types. 21 `uses-permission` entries, no `<uses-feature>` elements at all despite `CAMERA`. `RECEIVE_BOOT_COMPLETED` is requested with no boot receiver declared in this manifest | Gated on row 1. If Play: budget weeks for declarations and likely rejections. If sideload: no action, but document why they exist | Both |
| 20 | **Adult content in the Closer module vs store content rating** | high (if Play) / n/a | `intimacy_additions.sql:26` enforces an 18+ `CHECK` on `profiles.birth_date`, and the Closer tab is adult-gated at `app_shell.dart:192-198`. `banner_ad_slot.dart:12-14` carries a policy warning never to place ads in the Closer module, enforced by `app_shell.dart:210` (`selected == 3 && !isCloserTab`) | Gated on row 1. If Play: IARC rating, content declarations, and an AdMob policy review of the whole placement strategy | **Product decision** |
| 21 | **`minSdk` / `targetSdk` are not pinned and drift with the Flutter SDK** | medium | `defaultConfig` uses `flutter.minSdkVersion` / `flutter.targetSdkVersion`, which resolve to 24 / 36 in the installed Flutter 3.44.2 (`FlutterExtension.kt`). The adjacent comment claims minSdk 23 "Pinned explicitly" — it is neither 23 nor pinned. A Flutter upgrade can move the target SDK, and with it behaviour changes and Play requirements, with no diff in this repo | Pin both literally and fix the comment | Engineering task |
| 22 | **`leave_couple()` references a column the repo never creates** | medium | `20260628_leave_couple_privacy.sql:47` sets `presence.chat_last_read = NULL`; no `.sql` file in the repo or in git history ever creates that column (`presence_status_v2.sql:9` only asserts it "already exists"). plpgsql only syntax-checks bodies, so `CREATE FUNCTION` succeeds and the error surfaces at call time, aborting the whole transaction — the sensitive-presence wipe, the profiles unlink and the couples deactivation all roll back. The live DB has the column (added out-of-band), so **nothing is broken today**; the exposure is rebuild-from-repo | Subsumed by row 6 | Engineering task |
| 23 | **Two features named "Vault" with near-identical routes** | medium | `/app/vault` → `lib/features/vault/` (PIN/biometric personal notes, `personal_vault_items`) and `/app/closer/vault` → `lib/features/closer/private_vault/` (couple-scoped, `vault_items`). Both surfaced with a lock icon. Any document that does not disambiguate them will be wrong | Rename one in the UI and in code before the blueprint circulates | **Product decision** (naming), then engineering |
| 24 | **Deep-link crash surface on capsule routes** | medium | `router.dart:154` and `:159` force-unwrap `state.extra! as Capsule` for `/app/capsule/view` and `/app/capsule/fill`. Any deep link, restored route or external intent throws in the builder. The sibling routes `/app/rapid-camera` and `/app/location-map` default their extras safely — an inconsistency inside one file. `MainActivity` is `exported="true"` with a `BROWSABLE` `tethered://join` deep link carrying a pairing code; whether that code is validated server-side is not verifiable from the manifest | Take the capsule id as a path parameter and re-fetch, or degrade to the list screen | Engineering task |
| 25 | **Impeller force-disabled app-wide** | medium | `AndroidManifest.xml:92-94` sets `EnableImpeller=false` to work around a segfault in `libflutter.so` when compositing the live camera preview under the `BackdropFilter`/blend-mode stack in `rapid_camera_screen`. Skia is on a deprecation path for Android; the workaround is global rather than scoped to the one screen | Reproduce on current Flutter, file upstream if it persists, and scope or remove the flag | Engineering task |
| 26 | **Repo hygiene: ~2 GB of loose APKs and 5 overlapping top-level docs** | medium | 16 `Tethered-*.apk` files (118–160 MB each, dated ~2026-06-28) sit in the repo root. `.gitignore` lists `*.apk` and `Tethered*.apk`, so they should not be in history — confirm with `git log --all -- '*.apk'` before archiving. Alongside them: `README.md`, `BRAIN.md`, `ROADMAP.md`, `TETHERED_FULL_DOCUMENTATION.md`, `FIX_REPORT.md`, all describing overlapping and partly contradictory states | Delete the APKs, collapse to one current doc (`BRAIN.md` is the only one both current and honest about open work) plus this blueprint | Engineering task |
| 27 | **`RECEIVE_BOOT_COMPLETED`, dead ad formats, and other unused surface** | medium | `AdConfig.interstitialUnitId` / `rewardedUnitId` have no call sites; `signInWithGoogle` throws `UnimplementedError`; `lib/core/push/fcm_todo.dart` misinforms readers that push is unimplemented; three dead feature modules and one orphaned route (§8.5) | Delete. Each removal is independent and low-risk | Engineering task |

---

## 11. Open questions for the team

### 11.1 Is this a private two-person app or a Play Store product?

Everything else waits on this. The code, the disguise, the 18+ Closer module and the sideload workflow all say private; `README.md`, `ROADMAP.md` and `docs/INTIMACY_LAYER.md` all say public freemium.

**Trade-off:** Private means the "News" cover, the panic lock and the stealth scrim survive — they are the app's most distinctive engineering, and they are unshippable on Play. It also means the ads, the Stripe/Play Billing plans, the IARC rating work and most of §10 rows 19–20 evaporate. Public means removing the concealment layer wholesale, which removes the reason the app exists in its current form, and buying into a background-location declaration that is among the hardest approvals Google grants.

### 11.2 Restore encryption, or delete the claims?

The Closer module stores plaintext behind a schema and a wire format (`nonce || mac || ciphertext`) that still look like XChaCha20-Poly1305. E2EE was removed deliberately in commit `1fe99ae`, at the owner's request.

**Trade-off:** Restoring it means re-implementing key exchange, a key-loss recovery story, and the breakup-purge flow that `docs/INTIMACY_LAYER.md` §5 already designed — real work, and it makes debugging intimate-content bugs much harder. Not restoring it is defensible for a two-person app where the threat model is a partner or a snooping visitor, not the infrastructure provider — but then five UI strings and four documents are lying to the user about intimate photos, and that has to be fixed either way. The decision is whether to build the guarantee or withdraw the claim; keeping the claim without the guarantee is not an option.

### 11.3 Pay for Supabase, or engineer around the free tier?

The project auto-paused after ~7 days idle and took the app down with a DNS failure. Data survived.

**Trade-off:** A paid plan (~$25/mo) removes an entire class of outage and is trivial relative to the effort already sunk. A keepalive ping is free but adds a scheduled dependency that itself can fail silently, and it does not help against the other free-tier limits. Either way the client needs a real "backend unavailable" state — right now users see a raw `errno = 7`.

### 11.4 Should a two-person private app have ads at all?

`google_mobile_ads ^9.0.0` is a dependency, `AdService.init()` runs at boot, and one banner renders on the Breath tab.

**Trade-off:** It is inherited from the abandoned public-launch plan and currently earns nothing while adding an SDK, an init step, a policy constraint (no ads near the Closer module) and a latent bug (`banner_ad_slot.dart:44-75` can load an ad it never displays, because `_ad = ad` is assigned outside `setState`). Removing it is ~30 minutes and deletes §10 row 4 entirely. Keeping it only makes sense if row 1 resolves to a public launch.

### 11.5 What becomes the schema of record?

Today it is the live database. The 27 loose `.sql` files are a partial, unordered, partly-superseded record, and at least one script (`clear_chat_everyone.sql:2`) drops a function that another script (`settings_and_delete.sql:52`) would resurrect if re-run.

**Trade-off:** Adopting `supabase/migrations/` + `config.toml` means one disciplined day dumping the live schema as a baseline and then never applying DDL via the MCP again — which is slower for a solo developer than the current habit. Not adopting it means no staging environment, no reviewable RLS changes, and no way to answer "what protects `cycle_events`?" from source. Given how much of §10 is RLS-shaped, the current setup makes those defects unfixable-with-confidence.

### 11.6 Delete the dead modules, or wire them up?

`countdown`, `skybridge` and `reach_screen.dart` are unreachable; `/app/intimacy` is registered but has no entry point anywhere.

**Trade-off:** `countdown` is genuinely superseded by `timeline` — delete. `skybridge` needs real tzdata work before it could ship, so reviving it is a feature project, not a routing fix. `/app/intimacy` is the interesting one: it is a complete, thoughtfully-designed double-blind consent feature (with a matching double-blind RLS policy in `intimacy_signals.sql:56-60`) that either lost its entry point in a refactor or was never wired up. Deleting it discards real design work; wiring it up adds a surface nobody has tested. Someone needs to decide which.

### 11.7 What is the minimum acceptable test bar?

32 tests over 40,317 lines, none touching auth, routing, or the backend layer.

**Trade-off:** Chasing coverage across 56 screens is not a sensible use of a small team's time and would mostly produce brittle widget tests. But the redirect funnel gates every route and is exactly the kind of five-branch state machine that regresses silently — and §10 row 14 is a live example of it doing so. A defensible floor: the router funnel, `SupabaseRepository`, and the session lifecycle. Note also that the existing `love_notes_pool_test.dart` hard-codes pool sizes, so it fails on every content edit — that pattern should not be repeated.

### 11.8 What happens to the cycle love-note pool?

Shipped this session behind `FeatureFlags.pooledLoveNotes = false`. The 169 hardcoded real names are gone, but the pet names remain hardcoded, the feature is gendered husband→wife, and there is no localisation.

**Trade-off:** Generalising it (configurable pet names, gender-neutral, localised) is real work for a feature written in one couple's private Roman Urdu/Punjabi voice — the specificity is the point, and genericising it may destroy what made it good. Shipping it as-is means shipping someone's private register to any other user. Deleting it discards the only part of the codebase with meaningful test coverage. The honest options are "keep it flagged off indefinitely as personal content" or "delete it".

### 11.9 Delete the Next.js project, or revive it?

One commit, 14 months stale, no lockfile, empty `node_modules`, two known crashes, 4 of 5 nav links 404.

**Trade-off:** Deleting it removes the single most misleading artefact in the repo (`README.md` describes it as *the* product). Reviving it means a fresh dependency resolve against 14 months of drift, finishing four missing routes, and then maintaining a second client against a schema that is not under version control (§11.5) — while the Flutter app has 104 of the repo's 106 commits. If a web presence is wanted later, a static landing page is a different and much smaller project than this.

### 11.10 Which name is the real one, and when does it become permanent?

Four names are live: `Tethered` (UI, `main.dart:441`), `miles` (Dart package, theme classes, `package.json`), `com.miles.miles` (Android applicationId/namespace), and `News` (launcher label). The design system has a fifth, `Emberlight`.

**Trade-off:** Internally this is only friction. But the Android `applicationId` is permanent from the moment of first Play publish, and `ROADMAP.md:224` still lists "Final name + Play Store package ID" as an open question against a stale value (`com.miles.app`). If row 1 resolves to Play, this must be settled *before* the first upload; if it resolves to sideload, it is cosmetic and can be left alone — but the blueprint should say which name is canonical so documentation stops drifting.

### 11.11 Two features called "Vault" — merge, or rename?

`/app/vault` is owner-only personal notes behind a bcrypt PIN. `/app/closer/vault` is the couple-shared Closer vault. Both use a lock icon.

**Trade-off:** They serve genuinely different purposes (private-from-partner vs private-from-world), so merging them loses a real distinction. But the shared name has already produced one incorrect security claim in the UI, and it guarantees that any future security discussion starts with five minutes of disambiguation. Renaming one — "My Notes" vs "Our Vault", or similar — is cheap and permanent.

### 11.12 Mass-fix the analyzer, or relax the ruleset?

1029 of 1476 issues are `require_trailing_commas` and `prefer_single_quotes`.

**Trade-off:** `dart fix --apply` clears them in one commit but produces a diff touching most of the codebase, which destroys `git blame` usefulness for a while and makes any in-flight branch painful to rebase. Relaxing the two rules in `analysis_options.yaml` costs nothing and instantly exposes the ~450 substantive findings, at the price of inconsistent formatting. Doing neither is the current state, where 10 warnings and 32 `unawaited_futures` are invisible behind a four-digit number nobody reads.