# Tethered — Complete Project Documentation

> **App:** *Tethered* — a private, invite-only **long-distance couples** app, built for ONE couple.
> **Disguise:** ships on-device as **“System Services”** (Android label) under package **`com.miles.miles`**. Not on any store — sideloaded APK.
> **Repo:** `E:\LDR`  ·  Flutter app: `E:\LDR\mobile`  ·  **145 Dart files**, **28 feature modules**.
> **Backend:** Supabase project ref **`sopictusdonlvuezmfep`**.

---

## Table of Contents
1. [Architecture & Core Foundation](#1-architecture--core-foundation)
2. [Data Model & Backend (Supabase)](#2-data-model--backend-supabase)
3. [Chat](#3-chat)
4. [Touch · Closer · Intimacy (Adult Modules)](#4-touch--closer--intimacy-adult-modules)
5. [Home · Location · Presence · Reach · Care · Cycle](#5-home--location--presence--reach--care--cycle)
6. [Social · Games · Keepsakes](#6-social--games--keepsakes)
7. [Calls · Ambient · Auth · Settings · Shell · Intro](#7-calls--ambient--auth--settings--shell--intro)
8. [Build, Run, Configure & Deploy](#8-build-run-configure--deploy)

---

## At a Glance

**What it is.** A two-person, sideloaded couples app for a long-distance relationship: real-time chat, mood sharing, live location + a free 3D map, voice/video calls, intimate “Touch” play, a menstrual-cycle tracker, synced games, and keepsakes — all scoped to ONE couple and hidden behind a “System Services” identity. Adult/intimate features are gated.

**Tech stack.**

| Layer | Technology |
|---|---|
| UI | Flutter (Dart) · Material · `google_fonts` (Fraunces display + Inter body) · “Velvet/Emberlight” theme (`MilesColors`) |
| State | Riverpod (`flutter_riverpod`) |
| Routing | `go_router` (auth/onboarding redirect funnel) |
| Backend | **Supabase** — Postgres, Auth, Realtime, Storage, Edge Functions (Deno/TS) |
| Realtime | Supabase Realtime — `postgres_changes` + ephemeral **broadcast** channels; socket-`onOpen` re-subscribe fan-out |
| Push | Firebase Cloud Messaging (HTTP v1 + service-account RS256 JWT) + `flutter_local_notifications` (full-screen intents) |
| Calls | `flutter_webrtc` (WebRTC) · signalling over Supabase broadcast · STUN + configurable TURN |
| Maps | `flutter_map` (2D dark) + MapLibre GL JS in `webview_flutter` (free 3D: Esri satellite + AWS terrain + OSM buildings) |
| Media | `image_picker`, `image_cropper`, `record`, `just_audio`, `video_player`/`chewie`, `camera` |
| Animation | `lottie` (Google Noto animated emoji), `flutter_animate` |
| Location | `geolocator`, `geocoding`, `workmanager` (periodic background), `flutter_foreground_task` |
| Security | `local_auth` (biometric app-lock), `flutter_secure_storage`, `cryptography`, Android `FLAG_SECURE` |
| Misc | `google_mobile_ads`, `app_links` (deep links), `cached_network_image`, `vibration` (haptics), `uuid`, `http` |

**Security & privacy posture.** Disguised launcher identity; optional **biometric/PIN app-lock**; **`FLAG_SECURE`** blocks screenshots/recording on intimate screens; all data is **couple-scoped via RLS**; intimate body photos live in a **private bucket** served by short-lived signed URLs; the adult **Closer/Intimacy** module is gated by an age flag + a couple-wide `modest_mode` toggle.

---

## 1. Architecture & Core Foundation

Tethered is a Flutter app for one private couple, disguised on-device as "System Services" (package `com.miles.miles`), backed by Supabase (project ref `sopictusdonlvuezmfep`). State is managed with Riverpod, navigation with `go_router`, and the visual language is the "Emberlight" design system (the code's internal name; the `MilesColors` palette). All source lives under `lib/`, with the foundation in `lib/core/`.

### App startup sequence

Entry point `lib/main.dart` → `main()` runs a fixed boot sequence before `runApp`:

1. `WidgetsFlutterBinding.ensureInitialized()`.
2. **Global error nets** — `FlutterError.onError` and `platformDispatcher.onError` are wired to log the full exception + stack and keep one bad async error from blanking a feature.
3. `dotenv.load()` then a **fail-fast env check**: it reads `MilesConfig.supabaseUrlKey` / `supabaseAnonKeyKey`, logs masked lengths, and throws a `StateError` if either is empty (so a bad `.env` gives a clear message, not a cryptic `FormatException`).
4. `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` (from `lib/firebase_options.dart`).
5. `FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler)` — registered before `runApp` so pushes wake a dedicated isolate when backgrounded/terminated.
6. `TzHelper.ensureInit()` (`lib/core/time/tz_helper.dart`) — timezone DB init.
7. `SupabaseService.init()` — creates the singleton `SupabaseClient`.
8. `initRealtimeAutoResume()` — hooks the realtime socket's `onOpen` (see Realtime architecture).
9. `AdService.init()` (`lib/core/ads/ad_service.dart`), `FcmService.init()`, and `FlutterForegroundTask.initCommunicationPort()` (lets the call's foreground service talk to the UI isolate).
10. `runApp(const ProviderScope(child: MilesApp()))`.

`MilesApp` (a `ConsumerStatefulWidget` with `WidgetsBindingObserver`) builds `MaterialApp.router` with `theme: milesDarkTheme()`, `routerConfig` from `routerProvider`, and a `builder` that stacks three things over every screen: the routed `child`, the minimised-call `CallPill` (`lib/features/call/call_pill.dart`), and a `ValueListenableBuilder` on `AppLock.locked` that overlays the `LockScreen` when locked.

In `initState`, two post-frame callbacks run: `PermissionsBootstrap.requestAllOnce()` and `AppLock.lockIfEnabled()`. It also wires **deep links** via `app_links`: `_handleLink` accepts `tethered://join?code=…`, upper-cases the code into `pendingInviteCodeProvider`, and routes to `/couple`.

### Auth + onboarding routing funnel

Routing lives in `lib/core/router.dart`. `buildRouter(Ref)` returns a `GoRouter` whose `refreshListenable` is `_SessionListenable`, a `ChangeNotifier` that calls `notifyListeners()` whenever `sessionProvider` changes — so redirects re-evaluate on every session mutation. Exposed as `routerProvider`.

The `redirect` callback reads `sessionProvider` and enforces this funnel:

- Path `/` (the intro video, `IntroVideoScreen`) is always allowed to render; it self-navigates to `/signin`.
- While `session.loading` is true, no redirect (don't bounce mid-resolve).
- **Not authenticated** → only `/signin` and `/signup` are reachable; everything else → `/signin`.
- **Authenticated** walks the funnel on *every* route (so a half-onboarded user can't slip into `/app`):
  - `needsProfile` = profile null **or** `!profile.isOnboarded` → force `/welcome`.
  - `needsCouple` = `couple == null` → force `/couple` (stays there while the invite code shows).
  - `needsRole` = `profile != null && !profile.genderSet` → force `/role-setup` (one-time gender pick that gates the cycle feature).
  - Fully set up → bounce away from auth/onboarding routes (`/signin`, `/signup`, `/welcome`, `/couple`, `/role-setup`, `/`) into `/app`.

Routes include the auth/onboarding pages plus the `AppShell` at `/app` and a large flat table of feature routes under `/app/...` (capsule, intimacy, vault, touch, together, reasons, care, watch, cycle, heartbeat, games, rituals, prompt, timeline, and the `closer/...` modules), plus `/call`. Game routes like `/app/games/would-you-rather` construct `SyncedCardGameScreen` with content pools from `lib/features/games/game_content.dart`.

### Session model

`lib/core/session_provider.dart` defines the "who am I + who is my partner" state.

- `SessionState` (immutable, `copyWith`): `loading`, `session` (Supabase `Session?`), `profile` (`Profile?`), `couple` (`Couple?`), `partner` (`Profile?`), `partnerOnline`, `error`. Derived getters: `isAuthenticated`, `hasProfile`, `isLinked`.
- `SessionNotifier extends StateNotifier<SessionState>`:
  - `init()` seeds from `SupabaseService.client.auth.currentSession`, then subscribes to `SupabaseService.authChanges`; on each auth event it updates the session and (if signed in) calls `loadProfile()`.
  - `loadProfile()` fetches the profile via `SupabaseRepository.fetchMyProfile()`, then — if `profile.coupleId != null` — loads the `couples` row and the partner via `SupabaseRepository.fetchPartner`. Every call is wrapped in a **10-second `.timeout`**; on timeout/error it sets `loading:false` + `error` so the router can fall back to sign-in rather than hang forever. On success with a couple it subscribes presence.
  - `_subscribePresence` / `reconnectPresence()` manage a `profile-sync:<coupleId>` realtime channel (via `SupabaseRepository.subscribeToPresence`) that pushes partner profile updates into state; `reconnectPresence` is called after a socket reset.
  - `signOut()` unsubscribes presence and calls `SupabaseRepository.signOut()`.

`sessionProvider` = `StateNotifierProvider<SessionNotifier, SessionState>` that calls `init()` on creation.

`lib/core/providers.dart` exposes narrow read-only views so features rebuild minimally: `authStateProvider`, `currentProfileProvider`, `currentCoupleProvider`, `partnerProfileProvider`, `isPairedProvider`, plus `pendingInviteCodeProvider` (deep-link invite) and `shellTabProvider` (selected bottom-nav index).

### Data layer (Supabase service + repository + models)

- `lib/core/supabase_service.dart` — `SupabaseService` singleton: `init()` (`Supabase.initialize` with the `.env` url/key), `client`, `currentUserId`, and `authChanges` (`onAuthStateChange`).
- `lib/core/supabase_repository.dart` — `SupabaseRepository`, the single chokepoint for queries. Auth (`signUp`/`signIn`/`signOut`; `signInWithGoogle` is `UnimplementedError`), profile reads/writes (`fetchMyProfile`, `fetchPartner` filtered by `couple_id` + `neq id`, `upsertProfile`, `updateMyProfile`, `setAvatarUrl`, `setGender`, `setChatTheme`/`getChatTheme`, `setFcmToken`, `updatePresence`), couple ops, visits, and `subscribeToPresence`. Notable security/architecture points:
  - **`create_couple`**, **`join_couple_by_code`**, **`create_pairing_invite`**, **`redeem_pairing_invite`**, and **`leave_couple`** are `SECURITY DEFINER` Postgres RPCs (`_c.rpc(...)`). They allocate the unique invite code, enforce the 2-member cap, validate expiry/single-use, and link profiles atomically server-side — the client never reads `couples` under RLS immediately after insert. `PostgrestException` messages (`invalid_code`, `couple_full`, `expired`, `already_used`, `already_paired`) are translated to friendly strings.
  - Pairing invites are **expiring + single-use** (default `ttlMinutes: 1440`), replacing a permanent code.
  - `setModestMode` flips the couple-wide `modest_mode` flag (hides the intimacy module for both).
  - `_singleRow` normalises a composite RPC result that may come back as an object or a one-element list.
- `lib/core/models.dart` — `Couple`, `Profile`, `Visit`, `Ritual`, `DailyPrompt`, `PromptResponse`, and enums `PresenceStatus` / `RitualType`. Field mapping uses `JsonUtils` (`lib/core/utils/json_utils.dart`). Key business logic on `Profile`: `isOnboarded` keys off `birthDate != null` (the signup trigger auto-creates a bare profile, so the DOB is the reliable onboarding signal), `isAdult` computes age ≥ 18 from `birthDate` (the 18+ gate for the Closer tab), and `isFemale`/`isMale` from `gender`.

### Realtime architecture

The realtime layer is built to survive Android doze, network drops, and backgrounding (sockets die silently with no close event, leaving channels "joined-but-dead").

- `lib/core/realtime_resume.dart` — the core mechanism. A module-level `ValueNotifier<int> realtimeResumed` ticks every time the socket **opens**. `initRealtimeAutoResume()` (called once in `main`) hooks `SupabaseService.client.realtime.onOpen(() => realtimeResumed.value++)`. The Supabase client reconnects the socket itself on heartbeat loss; this **fans that event out** to every subscription. The documented per-screen pattern: `initState → realtimeResumed.addListener(_subscribe)`; `_subscribe` unsubscribes the old channel and joins a fresh one; `dispose → removeListener`.
- `lib/core/realtime_service.dart` — `RealtimeService`, the standard way to subscribe so couple-scoping lives in one place. `coupleTable(...)` opens a named channel filtered by `couple_id = coupleId` on `onPostgresChanges`; `coupleStream(...)` wraps that in a broadcast `Stream` (channel created on first listen, torn down on last cancel); `broadcast(name)` returns an ephemeral channel for non-persisted signals (typing, pings). RLS still gates every delivery, so a subscriber only receives rows it may read.
- **Resume reconnect** (`lib/features/shell/app_shell.dart`): `AppShell` is a `WidgetsBindingObserver`. On `AppLifecycleState.resumed`, `_reconnectRealtime()` forces a clean socket via `realtime.disconnect()` then `realtime.connect()` (re-subscribing synchronously here raced the still-closing socket — the original bug). When the new socket opens, `realtimeResumed` ticks and `_rearmAlwaysOn()` runs: it re-subscribes the always-on Reach channel (`ReachRepository.subscribe`), calls `callControllerProvider.reconnect()`, and `sessionProvider.notifier.reconnectPresence()`. Per-screen channels rejoin off the same notifier.

### Presence

`lib/core/services/presence_service.dart` owns the couple's `presence` table.

- `Presence` model carries online/typing state (`is_online`, `is_typing`, `typing_in_chat`), mood (`current_mood`, `mood_color`), location (`location_sharing_mode` ∈ `off`/`city`/`precise`, `latitude`, `longitude`, `location_accuracy`, `location_updated_at`, `location_label`), `current_screen`, `body_photo_path`, `avatar_emoji`, `checkin_photo_url`/`checkin_photo_at`, and `chat_last_read`. Helpers: `isInChatNow` (read within ~18s) and `isSharingLive`.
- `PresenceService` is all `_upsert`-based (`user_id` + `couple_id` + `updated_at`), wrapped so presence is best-effort and never surfaces an error. Setters include `setOnline`, `setTyping`, `setTypingInChat`, `setChatLastRead`, `setMood`, `setScreen`, `setBodyPhoto`, `setAvatarEmoji`, `setSharingMode`, `setLocation`, `setLiveLocation`, `clearLiveLocation`, `setCheckinPhoto`. Reads: `fetchPartner` (filter `couple_id` + `neq user_id`) and `fetchMine`. RLS allows updating only your own row and reading your partner's.
- `PartnerPresenceNotifier` / `partnerPresenceProvider` (`StateNotifierProvider.autoDispose`) subscribe to the `presence:<coupleId>` couple-table channel via `RealtimeService` and re-fetch on any change; it registers on `realtimeResumed` so it rejoins + re-pulls current presence after a reconnect (avoiding a stale false-offline).
- App-lifecycle presence: `MilesApp.didChangeAppLifecycleState` calls `PresenceService.setOnline(couple.id, online: resumed)` on every lifecycle change.
- `lib/core/screen_presence.dart` — just `kTabScreens` (Home / Chat / Camera / Breath / Closer). The screen a user is in is published by `lib/core/presence_route_observer.dart`, a `NavigatorObserver` that sees every route; it is the only writer of `myScreenProvider`, and it pushes the name to the partner via `PresenceService.setScreen` plus a broadcast. Tab switches are a setState rather than a navigation, so `AppShell` calls `publishActiveTab()` for those.

### Biometric app-lock

`lib/core/services/app_lock.dart` (`AppLock`) + `lib/core/widgets/lock_screen.dart` + `lib/core/widgets/app_lock_pin_sheet.dart`. The lock state is a `ValueNotifier<bool> AppLock.locked`, overlaid by `MilesApp.build`.

- Storage is `SharedPreferences`: `app_lock_enabled` and a SHA-256 hash of a 4-digit PIN (`app_lock_pin_hash`, salted with `miles-applock::`). `local_auth`'s `LocalAuthentication` drives biometrics.
- `authenticate()` prompts with `localizedReason: 'Unlock Tethered'`, `biometricOnly: false` (allows device PIN/passcode as a system fallback), `stickyAuth: true`. On any failure it logs the real reason and returns false so the caller can fall back to the local PIN. A historical root-cause note in the file: `MainActivity` must extend `FlutterFragmentActivity` (not `FlutterActivity`) or `local_auth` throws `no_fragment_activity` and the prompt never shows.
- Lifecycle (`MilesApp`): `lockIfEnabled()` on launch and on `paused`; on `resumed`, if locked, re-`authenticate()`. `LockScreen` is non-dismissible (`PopScope(canPop:false)`), auto-prompts biometrics, and always offers the PIN fallback so the user can never get stuck.

### FCM push pipeline

`lib/core/services/fcm_service.dart` + `lib/core/services/reach_notifications.dart` + `lib/core/services/fsi_permission.dart`.

- **Three notification channels** (built in `reach_notifications.dart`): `reach_channel` (`Importance.max`, custom vibration, category `call`), `call_channel` (`Importance.max`, ongoing ring), `care_channel` (`Importance.high`). `FcmService.init()` creates all three, wires `flutter_local_notifications`, handles cold-start taps via `getNotificationAppLaunchDetails`, listens to `onMessage` / `onMessageOpenedApp` / `getInitialMessage`, and mirrors the FSI permission via `FsiPermission.refreshCache()`.
- **Message types** (`m.data['type']`): `reach`, `call`, `care`. Foreground/opened handlers translate these into the `ValueNotifier`s `pendingReach` (`ReachTap`) and `pendingCall` (`CallTap`), which `AppShell` consumes. Local-notification taps are routed via a pipe-delimited `payload` (`reachId|fromName`, `call|callId|fromName|video`, `care|nudgeId`).
- **Token lifecycle**: `registerToken()` requests permission and fetches the token with up to 4 retries (Google Play Services may not be ready), saves via `SupabaseRepository.setFcmToken` (writes `fcm_token` + `fcm_token_updated_at` on `profiles`), and subscribes to `onTokenRefresh`. It is re-called on **every app resume** in `MilesApp.didChangeAppLifecycleState` because the server-side notify functions null a recipient's token when FCM reports it `UNREGISTERED` — re-registering self-heals stale tokens. `clearToken()` nulls the token and deletes it on sign-out. `AppShell._onReady` also calls `registerToken()` once past login + pairing.
- **Background isolate**: `firebaseMessagingBackgroundHandler` (top-level, `@pragma('vm:entry-point')`) re-inits Firebase + the local-notifications plugin in its own isolate, re-creates the relevant channel, and shows the notification. Since the isolate has no Activity it cannot query the full-screen-intent permission live — it reads the cached `fsi_can_use` bool from `SharedPreferences`.
- **Full-screen-intent (Android 14+)**: `FsiPermission` uses a `MethodChannel('miles/fsi')` (`canUseFullScreenIntent`, `openSettings`). Tethered does not auto-qualify, so it *requests* the permission once (`promptIfNeeded`, called from `AppShell._onReady`) and otherwise **degrades gracefully** to a max-priority heads-up notification. `refreshCache()` mirrors the live value into `SharedPreferences` for the background isolate.

### Location & background location

- `lib/core/services/location_service.dart` (`LocationService`) — symmetric, opt-in, revocable sharing using `geolocator` + `geocoding`. Modes: `off`, `city` (sends only a "City, Country" label, **never coordinates**), `precise` (coords + finer label). `shareOnce`, `startLiveSharing` (foreground position stream, `distanceFilter: 10`, re-geocodes the label only after ~700 m of movement to avoid geocoding every tick), `stopLiveSharing` (clears coords so the partner never sees a stale pin as live), and `pauseStream` (stops streaming without changing mode; no-op when always-on is enabled). An "always-on" pref (`location_always_on`) and background permission helpers (`Allow all the time`) are tracked here.
- `lib/core/services/bg_location.dart` (`BgLocationService`) — periodic background updates via **`workmanager`** with **no persistent notification**. `bgLocationCallback` (`@pragma('vm:entry-point')`) re-inits dotenv + Supabase, fetches the profile/couple, and **only** pushes a fix when the user's `location_sharing_mode` is still `precise`; it never throws (to avoid WorkManager retry churn). `enable()` registers a periodic task (`tethered-bg-location` / `bgLocationUpdate`, ~15-min cadence, `NetworkType.connected`, `ExistingPeriodicWorkPolicy.keep`); `disable()` cancels it. Toggled from `lib/features/home/home_screen.dart` and `lib/features/settings/settings_screen.dart`. It is explicitly best-effort (OEM battery managers — OnePlus/Vivo/Xiaomi — may delay or skip runs).

### Permissions, photos, haptics, GIFs

- `lib/core/services/permissions_bootstrap.dart` — `PermissionsBootstrap.requestAllOnce()` (guarded by `perms_requested_v1`) requests location/camera/microphone/notification/photos/videos/storage in one batch on first launch.
- `lib/core/services/photo_picker_service.dart` — `PhotoPickerService`, the single pick → crop (`image_cropper`) → compress (≤1200px JPEG, q80) pipeline for avatar/check-in/chat photos, with an optional beauty pass (`FilterEditorScreen`). `pickFromSheet` shows a camera/gallery bottom sheet; `pickVideo` caps at 5 minutes.
- `lib/core/services/touch_haptics.dart` — `TouchHaptics.feel(type, heat)` plays distinct `vibration` patterns per touch type (kiss/hug/caress/grab/pinch/tongue/poke/spank/bite/glow), scaling amplitude with shared "warmth" when the device supports amplitude control, falling back to `HapticFeedback`.
- `lib/core/services/giphy_service.dart` — `GiphyService`, a thin GIPHY REST client (`trending`/`search`, `rating=r`). Needs `GIPHY_API_KEY` in `.env`; with no key it returns empty results and `isConfigured` is false.

### Mood model & crypto note

- `lib/core/mood.dart` — `MoodData` (key/emoji/label/hex/desc + `intimate` flag + a bundled Lottie at `assets/emoji/<key>.json`). `kMoods` splits into `kEverydayMoods` and `kIntimateMoods` (the adult moods like `horny`/`flirty`/`devilish`/`kissmark`). Rendered by `AnimatedMood` (`lib/core/widgets/animated_mood.dart`, falls back to the glyph if the Lottie fails).
- `lib/core/crypto_core.dart` — **E2EE was removed (2026-06-25, per the owner)**. `CryptoCore`'s `encrypt*`/`decrypt*` are now identity base64 pass-throughs (`EncryptedPayload` just holds base64 plaintext), `getMyPublicKeyB64()` returns the placeholder `'plaintext-v1'`, and key derivation is a no-op. The public API is preserved so the repositories compile unchanged; **RLS remains the sole privacy boundary** scoping every row to the couple. `hmacTag` is a keyless FNV-1a hash so Fantasy-Jar tag matching still produces the same value on both phones. Correspondingly, `SupabaseRepository.fetchPartnerPublicKey` always reports a key available and `publishMyPublicKey` upserts the placeholder into `partner_keys`.

### Design system ("Emberlight" / `MilesColors`)

`lib/core/theme.dart` defines a dark-mode-first, warm-plum/coral-ember palette ("a wine-dark room lit by one low flame"):

- `MilesColors` — surfaces (`night` `#120A0C`, `nightDeep`, `surface1`/`surface2`, `surfaceGlass`), warm text (`cream50`/`cream100`/`taupe`/`faint`), and accents (`ember`, `emberSoft`, `emberDeep`, `blush` for hearts/Reach, `gilt` hairlines, `star`/`starlight`, `sage` for in-sync). Back-compat aliases (`navy900`, `coral500`, `emerald400`, etc.) keep older screens compiling.
- `MilesGradients` — `cta`, `ambient` (candle glow), `halo`, `orb`.
- `milesDarkTheme()` — Material 3 dark theme: `Fraunces` for display/headline styles and `Inter` for body/labels (both via `google_fonts`, in `_buildTextTheme`), an italic ember `headlineSmall`, fully rounded inputs/buttons (radius 18–28), a glass `navigationBar` (`surfaceGlass`, gilt selected labels), gilt-hairline cards, and transparent app bars. `milesBlur([sigma])` is the shared frosted-glass filter.
- Core reusable widgets in `lib/core/widgets/`: `EmberBackground` (single-`CustomPainter` candle glow + drifting embers + starfield, behind content, in a `RepaintBoundary`), `GlassPanel` (`BackdropFilter` frosted card with a gilt hairline), `GlowButton` (gradient pill CTA with colored-glow halo, press-scale, light haptic), `BreathingGlow` (~4s breathing scale + glow pulse for focal moments), `LoveTextField` (themed input with a warm halo), `NetImage` (disk-cached `cached_network_image` for avatars/photos), `AnimatedMood`, `LockScreen`, and the app-lock PIN sheet.

### Config & .env keys

`lib/core/config.dart` — `MilesConfig` holds the `.env` key names: `NEXT_PUBLIC_SUPABASE_URL` (`supabaseUrlKey`), `NEXT_PUBLIC_SUPABASE_ANON_KEY` (`supabaseAnonKeyKey`), and `GOOGLE_MAPS_3D_KEY` (`mapsApiKeyKey`, for the photorealistic 3D map). It also defines `BreathPattern` (the 4-7-8 breath used by Breath Sync) and `commonTimezones`. Additional runtime `.env` keys referenced elsewhere in core: `GIPHY_API_KEY` (`giphy_service.dart`). Supabase tables/buckets touched by the core layer: `profiles`, `couples`, `partner_keys`, `presence`, `visits` (plus the `create_couple` / `join_couple_by_code` / `create_pairing_invite` / `redeem_pairing_invite` / `leave_couple` RPCs); realtime channels `profile-sync:<coupleId>`, `presence:<coupleId>`, and per-table `stream:<table>:<coupleId>:<event>` channels; presence stores `body_photo_path`/`checkin_photo_url` referencing private storage.

---

## 2. Data Model & Backend (Supabase)

Tethered's backend is a single Supabase project (ref `sopictusdonlvuezmfep`, base URL `https://sopictusdonlvuezmfep.supabase.co`) providing Postgres + Auth + Realtime + Storage + one Edge Function. The Postgres schema is version-controlled as a set of idempotent `.sql` migrations in `E:\LDR\supabase\*.sql` (the canonical data dictionary), applied in order starting with `schema.sql`. All client access flows through thin repository classes (`lib/core/supabase_repository.dart`, `lib/core/services/presence_service.dart`, `lib/features/*/.*_repository.dart`) that rely on RLS for authorization rather than enforcing it client-side.

### Core architectural principle: couple-scoping

There is **no `couple_members` table**. Two users are "linked" purely by sharing the same `profiles.couple_id`. Authorization across nearly every table is enforced by one SECURITY DEFINER helper (`schema.sql`):

```sql
create function public.current_user_couple_id() returns uuid
  language sql stable security definer set search_path = public
as $$ select couple_id from public.profiles where id = auth.uid(); $$;
```

The pervasive RLS pattern is `using (couple_id = public.current_user_couple_id())` for SELECT/INSERT/UPDATE/DELETE. Inlining the lookup into a `security definer` function avoids `42P17` recursive-policy errors that a self-referential SELECT on `couples` would otherwise trigger. The edge function and `reach-notify` recipient lookup mirror this: "the OTHER member of the couple" = `profiles where couple_id = X and id != fromUser`.

### Auth & profile bootstrap

- Email/password auth via Supabase Auth (`SupabaseRepository.signUp/signIn/signOut`). Google sign-in is stubbed (`UnimplementedError`, "arrives in v1.1").
- An `on_auth_user_created` trigger runs `handle_new_user()` (SECURITY DEFINER) on `auth.users` insert, creating a `public.profiles` row with `display_name` from `raw_user_meta_data->>'display_name'` (falling back to the email local-part) and `timezone='UTC'`.

### Postgres tables (data dictionary)

**`couples`** (`schema.sql`, extended by `intimacy_additions.sql`, `pairing_invites.sql`, `settings_and_delete.sql`)
- `id uuid pk`, `created_at timestamptz`, `invite_code text unique not null` (permanent 6-char code; superseded for joining by `pairing_invites`), `name text`, `primary_tz text`, `stripe_customer_id text`, `anniversary_date date`, `modest_mode boolean not null default true` (intimacy module hidden until *both* partners opt out), `active boolean not null default true` (set false on `leave_couple`).
- RLS: members read/update their own couple (`couples_select_member`, `couples_update_member`); any authed user may INSERT (used by RPCs). Realtime: not in publication.

**`profiles`** (`schema.sql`, extended by `intimacy_additions.sql`, `fcm_push.sql`, `settings_and_delete.sql`, plus runtime columns the app writes)
- `id uuid pk → auth.users(id) on delete cascade`, `couple_id uuid → couples(id) on delete set null`, `display_name text not null`, `avatar_url text`, `timezone text not null`, `wake_time time`, `sleep_time time`, `presence_status presence_status enum('asleep','awake','work','free','busy') default 'free'`, `birth_date date`, `status_message text`, `fcm_token text`, `fcm_token_updated_at timestamptz`, `created_at`.
- Additional columns written by the client (not all present in the committed SQL — `setGender`, `setChatTheme`): `gender` ('male'|'female'), `gender_set bool`, `chat_theme_id`, `chat_bg_image_url`.
- Constraint `profiles_must_be_adult`: `birth_date is null or birth_date <= current_date - interval '18 years'` (hard 18+ gate, defense in depth behind the client check).
- RLS: read self **or** partner (`couple_id = current_user_couple_id()`); insert/update self only (`id = auth.uid()`). **`REPLICA IDENTITY FULL`** + in `supabase_realtime` publication (`realtime.sql`) so RLS-filtered UPDATEs deliver the full row to the partner.

**`presence`** (`presence_and_mood.sql`) — one row per user, couple-scoped live state.
- `user_id uuid pk → profiles`, `couple_id uuid → couples`, `is_online bool`, `last_seen timestamptz`, `is_typing bool`, `typing_in_chat bool`, `current_mood text`, `mood_color text`, `mood_updated_at`, `latitude/longitude double precision`, `location_label text`, `location_sharing_mode text default 'off'` ('off'|'city'|'precise'), `location_accuracy double precision`, `location_updated_at`, `current_activity text`, `current_screen text` (which feature the partner is in), `body_photo_path text` (path into private `couple_intimate` bucket), `avatar_emoji text`, `checkin_photo_url text`, `checkin_photo_at`, `updated_at`.
- Written via `PresenceService._upsert` (best-effort, errors swallowed). RLS: `presence_select_couple` (read partner's row), insert/update self only. **`REPLICA IDENTITY FULL`** + realtime publication. The `Presence` model (`presence_service.dart`) derives `isInChatNow` (read within 18s) and `isSharingLive`.

**`messages`** (`messages.sql`, extended by `presence_and_mood.sql`, `settings_and_delete.sql`)
- `id uuid pk`, `couple_id → couples`, `sender_id → profiles`, `body text`, `image_path text`, `kind text default 'text'` (client uses 'text'|'image'|'video'|'voice'), `created_at`. Mood tint: `sender_mood`, `sender_mood_color`. Soft-delete: `deleted_for_sender bool`, `deleted_for_everyone bool`, `deleted_at`, `deleted_by uuid[]` (per-user "delete for me"). Client also writes `voice_path`, `video_path`, `reply_to_id` (not all in committed SQL).
- RLS: select/insert require couple membership + `sender_id = auth.uid()`; `messages_update_member` (couple-scoped, for the soft-delete RPCs); `messages_delete_own`. **`REPLICA IDENTITY FULL`** + realtime publication.
- RPCs (`settings_and_delete.sql`, all SECURITY DEFINER): `hide_message(uuid)` (appends `auth.uid()` to `deleted_by`), `delete_message_for_everyone(uuid)` (sender only), `clear_conversation()` (hides all for caller).

**`visits`** (`schema.sql`) — countdown / timeline. `id`, `couple_id`, `start_date timestamptz not null`, `end_date`, `location text`, `note text`, `is_upcoming bool default true`, `created_at`. Indexes on `couple_id` and `(couple_id, is_upcoming, start_date)`. Generic couple-scoped RLS + realtime (`realtime.sql`). Used by both `SupabaseRepository` (next-visit countdown) and `timeline_repository.dart`.

**`daily_prompts`** (`schema.sql`) — `id`, `prompt_text`, `scheduled_date date`, `couple_id`, `unique(couple_id, scheduled_date)`. Couple-scoped RLS + realtime.

**`prompt_responses`** (`schema.sql`) — `id`, `prompt_id → daily_prompts`, `user_id → profiles`, `response_text`, `responded_at`, `unique(prompt_id, user_id)`. **No `couple_id`** — RLS joins through `daily_prompts.couple_id` for SELECT/INSERT and gates UPDATE/DELETE to `user_id = auth.uid()`. The SELECT policy is what powers the "reveal both answers" flow. In realtime publication.

**`rituals`** (`schema.sql`) — `id`, `couple_id`, `type ritual_type enum('goodnight','goodmorning','weekly_highlow','custom')`, `cron text`, `message text`, `deliver_at timestamptz`, `delivered bool`. Generic couple-scoped RLS + realtime.

**`visit_memories`** (`schema.sql`) — `id`, `visit_id → visits`, `photo_url`, `caption`, `created_at`. No `couple_id`; RLS joins through `visits`.

**`partner_keys`** (`partner_keys.sql`) — legacy E2EE key exchange. `user_id pk`, `public_key text` (X25519, base64), `updated_at`. RLS: read any key in your couple, write own. Note: E2EE was removed (`fetchPartnerPublicKey` now returns the constant `'plaintext-v1'`), so this table is effectively dormant.

**`pairing_invites`** (`pairing_invites.sql`) — expiring, single-use 6-char join codes. `code text pk`, `couple_id`, `created_by`, `created_at`, `expires_at`, `consumed_at`, `consumed_by`. RLS: members read invites for their couple. Created/redeemed via RPCs.

**`reach_events`** (`reach_events.sql`) — the "Reach" full-screen alert. `id`, `couple_id`, `from_user → profiles`, `created_at`, `acknowledged_at`, `expires_at timestamptz default now()+30s`. RLS: couple-scoped select/update; insert requires `from_user = auth.uid()`. **`REPLICA IDENTITY FULL`** + realtime. INSERT triggers the push pipeline (below).

**`reach_pulses`** (`reach_pulses.sql`) — ephemeral haptic "heartbeats". `id`, `couple_id`, `user_id → auth.users`, `sent_at bigint` (ms epoch), `created_at`. Couple-scoped RLS. `pg_cron` job `miles_reach_cleanup` deletes rows >1h old every 30 min.

**`breath_events`** (`breath_events.sql`) — Breath Sync. `id`, `couple_id`, `user_id → auth.users`, `started_at bigint`, `created_at`. Couple-scoped RLS. In realtime publication (`realtime.sql`). `pg_cron` job `miles_breath_cleanup` purges nightly (>1 day).

**`body_touches`** (`body_touches.sql`) — ephemeral Touch glows. `id`, `couple_id`, `from_user`, `body_zone text` (silhouette zone or 'free' for photo mode), `touch_type text default 'glow'` ('glow'|'kiss'|'hug'), `intensity real`, `pos_x/pos_y real` (normalized 0..1 for photo mode), `created_at`, `expires_at default now()+10s`. RLS: couple select, insert requires `from_user = auth.uid()`. **`REPLICA IDENTITY FULL`** + realtime. Client never reads old rows — only listens for live inserts.

**`call_invites`** (referenced in `call_controller.dart`; **no committed SQL file**) — durable WebRTC offer so a closed app can still ring. Columns written: `couple_id`, `caller_id`, `callee_id`, `offer_sdp text`, `video bool`. The comment says its INSERT trigger fires `call-notify` (FCM ring), mirroring the reach pipeline.

**`care_nudges`** (referenced in `care_repository.dart`; **no committed SQL file**) — Care "thinking of you" nudges. Columns: `id`, `couple_id`, `from_user`, `kind text`, `message text`, `created_at`, `acknowledged_at`. Couple-scoped realtime via channel `care_nudges:<coupleId>`. A `care-notify` edge function is implied by the area brief but not present in the repo.

**`love_reasons`** (referenced in `reasons_repository.dart`; **no committed SQL file**) — `id`, `couple_id`, `author`, `text`, `created_at`. Couple-scoped realtime.

**Cycle tracking** (`cycle_repository.dart`; **no committed SQL files**):
- **`cycle_settings`** — `user_id`, `couple_id`, `avg_cycle_length int`, `avg_period_length int`, `share_with_partner bool`, `tracking_enabled bool`, `on_period_now bool` (live mirror of latest event), `updated_at`. Sensitive health data; partner sees it only if `share_with_partner` (RLS-gated).
- **`cycle_events`** — `id`, `user_id`, `couple_id`, `type text` ('period_start'|'period_end'), `event_date date`, `created_at`. Predictions (phase, next period) are computed entirely client-side in `CyclePrediction.compute`.

#### Intimacy / "Closer" module (`intimacy_tables.sql`, `intimacy_additions.sql`, `intimacy_signals.sql`, `private_vault.sql`, `capsules.sql`)

All are couple-scoped with the standard RLS loop, enabled for realtime via `closer_realtime.sql` (`REPLICA IDENTITY FULL` + publication).

- **`consent_state`** — per-feature dual-consent gate. PK `(couple_id, feature, user_id)`, `granted bool`, `granted_at`, `revoked_at`.
- **`desire_temps`** — daily 1–10 score. PK `(couple_id, on_date, user_id)`, `score int check 1..10`.
- **`mood_lamp`** — last color per partner. PK `(couple_id, user_id)`, `color_rgb int check 0..16777215`, `updated_at`.
- **`fantasy_jar_entries`** — E2EE. `id`, `couple_id`, `author`, `ciphertext bytea`, `nonce bytea`, `tag_hashes text[]`, `created_at`. Plus **`fantasy_jar_reveals`** PK `(couple_id, entry_pair, user_id)`.
- **`afterglow_entries`** — `id`, `couple_id`, `happened_at`, per-partner `gratitude_a/b bytea`, `nonce_a/b`, `photo_a/b bytea`, `retention text default 'ephemeral'`, `sealed_at`, `created_at`.
- **`vault_items`** (Closer couple vault, E2EE) — `id`, `couple_id`, `kind text` ('photo'|'note'|'voice'|'trace'), `ciphertext bytea`, `nonce bytea`, `ad text` (associated data), `created_by`, `retention text default 'keep'`, `reconfirm_due timestamptz` (90 days for ephemeral), and a mutual-delete workflow: `delete_requested bool`, `delete_requested_by`, `delete_requested_at`, `deleted bool`, `deleted_by`, `deleted_at`. The client (`private_vault_repository.dart`) only ever writes `ciphertext`/`nonce` (via `CryptoCore`) — **never plaintext** (table comment enforces this contractually). Delete is a soft-delete (mutual confirm, or requester escape hatch after 14 days).
- **`body_map_pins`** — `id`, `couple_id`, `author`, `x/y real check 0..1`, `note_cipher bytea`, `note_nonce bytea`, `created_at`.
- **`dice_rolls`** — "Pick for us". `id`, `couple_id`, `rolled_at`, `tier text`, `result_tags text[]`. Plus **`dice_tier_consents`** PK `(couple_id, tier, user_id)`, `granted bool`.
- **`memory_threads`** — encrypted milestones. `id`, `couple_id`, `proposer`, `title_cipher/nonce`, `happened_on date`, `photo_cipher/nonce`, `note_cipher/nonce`, `state text default 'proposed'`, `accepted_by`, `accepted_at`, `archived_at`. Plus **`memory_revisits`** PK `memory_id → memory_threads` (RLS joins through `memory_threads`).
- **`couple_dissolutions`** — breakup purge. PK `couple_id`, `initiated_by`, `initiated_at`, `purge_at`, `cancelled_at`.
- **`intimacy_prefs`** (`intimacy_signals.sql`) — `user_id pk`, `receiving_enabled bool`, `signaling_enabled bool`, `updated_at`. RLS: self-only.
- **`intimacy_signals`** ("In the Mood") — `id`, `couple_id`, `user_id`, `state text`, `created_at`, `window_expires_at`. **Double-blind privacy**: the SELECT policy requires `user_id = auth.uid() OR has_active_intimacy_signal()` — you only see your partner's signal if you *also* have an active one. INSERT requires `my_intimacy_signaling_enabled()`. Both gates are SECURITY DEFINER helpers (`has_active_intimacy_signal`, `my_intimacy_signaling_enabled`) so the policy never self-references the table (avoids `42P17`). `REPLICA IDENTITY FULL` + realtime.
- **`capsules`** / **`capsule_items`** (`capsules.sql`) — Time Capsules. `capsules`: `id`, `couple_id`, `title`, `unlock_mode capsule_unlock_mode enum('proximity','date','both')`, `unlock_date`, `unlocked_at`, `created_by`. `capsule_items`: `id`, `capsule_id`, `author_id`, `type capsule_item_type enum('note','photo','voice')`, `content_text`, `media_url`, `created_at`. **Sealed-until-unlock**: `capsule_items_select_unlocked` only reads items when the parent `capsules.unlocked_at is not null`. RPCs `unlock_capsule(uuid)` (enforces date gate server-side: raises `too_early`), `capsule_seal_summary(uuid)`. Proximity is checked **client-side** via ephemeral realtime broadcast — coordinates are never persisted. `REPLICA IDENTITY FULL` + realtime.

**`personal_vault`** (`private_vault.sql`) — strictly owner-private (not couple-shared):
- **`vault_pin`** — `user_id pk`, `pin_hash text` (bcrypt via `extensions.crypt`/`gen_salt('bf')`), `biometric_enabled bool`, `failed_attempts int`, `locked_until timestamptz`. RLS: self-only. RPCs `set_vault_pin`, `verify_vault_pin` (5-try / 15-min lockout, returns 'ok'|'wrong'|'locked'|'no_pin'), `has_vault_pin`. The functions deliberately set `search_path = public, extensions` because `crypt`/`gen_salt` live in the `extensions` schema on Supabase.
- **`personal_vault_items`** — `id`, `owner_id`, `type text default 'note'`, `content`, `media_url`, `created_at`. RLS `pvi_owner_only` (`owner_id = auth.uid()`).

### SECURITY DEFINER RPCs (server-side business logic)

Pairing and lifecycle operations run as definer functions (granted to `authenticated`, revoked from `public`/`anon`) so logic stays server-side and avoids the recursive-RLS trap of "insert couple then SELECT it":
- `create_couple(p_timezone)` — idempotent; allocates a unique 6-char code (retries on `unique_violation`), inserts the couple, links the creator's profile atomically. Returns the `couples` row.
- `join_couple_by_code(p_code)` — validates code, enforces 2-member cap (`couple_full`), links profile. Raises `invalid_code`/`couple_full` (translated to friendly UI errors).
- `create_pairing_invite(p_ttl_minutes default 1440)` / `redeem_pairing_invite(p_code)` — short-lived single-use codes; redeem validates `invalid_code`/`expired`/`already_used`/`couple_full`/`already_paired`.
- `leave_couple()` — nulls `couple_id` for both partners and sets `couples.active = false` (data preserved on the inactive couple).
- Message RPCs: `hide_message`, `delete_message_for_everyone`, `clear_conversation`.

### Storage buckets

- **`couple_media`** — **public** bucket for chat images, GIFs/stickers, and voice notes; served via `getPublicUrl`. Paths are `<coupleId>/<rand>.<ext>`. Also used for avatars/check-in photos by `home_screen`, `settings_screen`.
- **`couple_intimate`** — **private** bucket for intimate content: chat videos (`kind='video'`) and Touch body photos (`<coupleId>/body/<uid>_<ts>.jpg`). Served only via short-lived **signed URLs** (1h, `createSignedUrl(path, 3600)` in `chat_repository.dart` and `touch_map_repository.dart`).
- **`capsule-media`** — **private** (`capsules.sql`). Storage RLS restricts insert/select/delete to objects whose first path folder equals `current_user_couple_id()::text` (`(storage.foldername(name))[1]`). Served via 1h signed URLs.
- **`chat-bg`** — chat background images for the custom per-user chat theme (`chat_theme_picker.dart`, `getPublicUrl`).

### Realtime channels (app-wide)

Two flavors: Postgres-changes channels (filtered by `couple_id`, gated again by RLS on delivery — a subscriber only receives rows it may read) and ephemeral broadcast channels (no table). The shared helper `RealtimeService.coupleTable/coupleStream/broadcast` (`lib/core/realtime_service.dart`) centralizes the pattern; many features still hand-roll their own. Channel names observed (all suffixed with `<coupleId>` unless noted):

- Postgres-changes: `profile-sync` (profiles, in `SupabaseRepository.subscribeToPresence`), `presence`, `messages`, `reach_events`, `body_touches`, `care_nudges`, `love_reasons`, `capsules`, `cycle_events`, `home_cycle`, `desire_temps`, `mood_lamp`, `intimacy` (intimacy_signals).
- Broadcast / ephemeral: `call:<coupleId>` (WebRTC signalling: offer/answer/ice/hangup, event `'signal'`), `touch:<id>`, `touch_trace:<coupleId>`, `capsule_proximity:<coupleId>` (proximity, no coords persisted), `breath:<coupleId>`, `mood_burst:<id>`, `together:<coupleId>`, `heartbeat:<coupleId>`, `watch:<coupleId>`, `reach:<coupleId>`, and game channels `game_td:<cid>`, `gcard:<gameKey>:<cid>`, `gchat:<gameKey>:<coupleId>`.

Note: Supabase Realtime delivers nothing unless the table is added to the `supabase_realtime` publication — `realtime.sql` and the per-feature SQL files do this, and apply `REPLICA IDENTITY FULL` so RLS-filtered UPDATE events carry the full row to subscribers. Channels are re-subscribed on socket reconnect (`realtimeResumed` listener in `PartnerPresenceNotifier`; `CallController.reconnect`).

### Edge Functions & push pipeline (FCM HTTP v1)

Only **`reach-notify`** exists in the repo (`E:\LDR\supabase\functions\reach-notify\index.ts`). **`care-notify`** and **`call-notify`** are referenced by intent (the `call-notify` FCM ring is mentioned in `call_controller.dart` comments) but are not committed here.

`reach-notify` flow:
1. `fcm_push.sql` installs the `pg_net` extension and a SECURITY DEFINER trigger `notify_reach()` that fires `after insert on reach_events`, doing `net.http_post` to `https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify` with the new row as JSON body (implemented as a pg_net trigger rather than a dashboard Database Webhook so it's version-controlled).
2. The function mints an OAuth2 access token from the service-account JSON: builds an RS256 JWT (`{alg:RS256}`, scope `firebase.messaging`, aud `oauth2.googleapis.com/token`), signs it with `crypto.subtle` (`RSASSA-PKCS1-v1_5`/SHA-256) using the PKCS8 key, and exchanges it at the Google token endpoint. The legacy `fcm/send` API is dead.
3. Recipient = the other couple member (`profiles where couple_id = X and id != from_user`, limit 1). It sends a **data-only** FCM v1 message (`type:'reach'`, `from_name`, `couple_id`, `reach_id`; android `priority:high, ttl:30s`; apns high priority + `content-available`) so the Android background handler can build the full-screen-intent notification (notification-only messages won't reliably wake the screen).
4. On 404/`UNREGISTERED`/`NOT_FOUND` it clears the stale `profiles.fcm_token` (null). Always returns 200 to prevent webhook retry-storms.

Device tokens live on `profiles.fcm_token`/`fcm_token_updated_at`, written by `SupabaseRepository.setFcmToken` (nulled on sign-out). RLS for token writes reuses `profiles_update_self`.

### Config / environment keys

- **`.env`** (loaded via `flutter_dotenv`, see `.env.example`): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`. WebRTC TURN (optional, `call_controller.dart`): `METERED_TURN_HOST`, `METERED_TURN_USERNAME`, `METERED_TURN_CREDENTIAL` (falls back to the public openrelay relay if unset).
- **Supabase Function secrets** (set via `supabase secrets set`, never committed): `FCM_SERVICE_ACCOUNT` (full service-account JSON, one line), `FCM_PROJECT_ID`. Auto-injected by the platform: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (the function uses the service-role client `admin` to bypass RLS for recipient lookup and token cleanup).

### Security notes

- RLS is the sole authorization layer; the client never enforces couple boundaries itself. Every couple-scoped table has explicit `select/insert/update/delete` policies keyed on `current_user_couple_id()`.
- The 18+ gate is enforced both client-side and by the `profiles_must_be_adult` CHECK constraint.
- E2EE intimacy tables (`vault_items`, `fantasy_jar_entries`, `memory_threads`, `afterglow_entries`, `body_map_pins`) store only `ciphertext`/`nonce` `bytea` — plaintext never reaches Postgres. (The older `partner_keys` X25519 exchange is now bypassed; `fetchPartnerPublicKey` returns a constant placeholder.)
- The "In the Mood" double-blind and per-feature `consent_state` gate intimate visibility on mutual opt-in; `couples.modest_mode` defaults TRUE so the entire intimacy module is hidden until both partners disable it.
- Personal vault PINs are bcrypt-hashed server-side with a 5-attempt / 15-minute lockout; verification is a SECURITY DEFINER RPC so the hash never leaves the database.
- All helper/RPC functions are `revoke execute ... from public, anon` and `grant ... to authenticated`, keeping them off the anonymous REST surface.

---

## 3. Chat

The chat is the heart of Tethered: a private, two-person, real-time conversation between the linked partners. It is engineered for *instant* feel — every send shows on your own screen immediately, lands on your partner's screen in milliseconds over a broadcast fast-path, and is durably persisted to Postgres, with all three carrying the same client UUID so the slower DB echo de-dupes cleanly. It supports text, images/GIFs, voice notes, and private intimate video, plus playful "flings" (animated mood emoji and GIFs that rise on both phones), per-partner chat themes, typing indicators, read receipts, an "is here" presence avatar, and slide-to-reply.

### User flow

You open the chat from the app drawer (the screen lives in the shell and is kept alive while viewing). The AppBar shows the partner's name, their live mood (an animated Lottie emoji next to the name), and a presence-aware subtitle (`typing…` with bouncing dots / `Online` with a green dot / `Last seen 5m ago`). You type in the bottom input bar; the send button morphs between a mic (hold to record a voice note) and a send arrow (✈) the moment text becomes non-empty. The `+` button opens an attach sheet (GIF, camera, gallery, record video, video from gallery). Long-press a bubble for Reply / Delete-for-me / Delete-for-everyone; swipe a bubble left-to-right to quick-reply. The overflow menu offers Set your mood, Fling a GIF, Chat theme, and Clear conversation. Voice/video call buttons start an in-app WebRTC call.

### Key files

- `lib/features/chat/chat_screen.dart` — the whole screen (`ChatScreen` / `_ChatScreenState`), realtime wiring, optimistic send, fling animations, bubbles, read-receipt logic, voice/video players. Largest file (~1645 lines).
- `lib/features/chat/chat_repository.dart` — the `Message` model + `SendStatus` enum and all data access (`ChatRepository`).
- `lib/features/chat/chat_input_bar.dart` — `ChatInputBar`: text field, attach sheet, hold-to-record voice, keyboard-GIF insertion, reply bar.
- `lib/features/chat/chat_theme.dart` — `ChatTheme` model + the six built-in themes + `customChatTheme` + `chatThemeById`.
- `lib/features/chat/chat_theme_controller.dart` — `ChatThemeController` / `chatThemeProvider` (local cache + server sync of the per-user theme).
- `lib/features/chat/chat_theme_picker.dart` — `showChatThemePicker` bottom sheet (swatches + custom photo background upload).
- `lib/features/chat/giphy_picker.dart` — `showGiphyPicker` GIPHY search/trending sheet.
- `lib/core/services/giphy_service.dart` — `GiphyService` REST client + `GiphyGif` model.
- `lib/features/chat/media_viewer.dart` — `MediaViewer` full-screen pinch-zoom image viewer.
- `lib/features/chat/mood_selector.dart` — `showMoodSelector` bottom sheet of mood chips.
- `lib/features/chat/typing_indicator.dart` — `TypingIndicator` three bouncing dots.
- Supporting core: `lib/core/mood.dart` (`MoodData`, `kMoods`, `moodByKey`), `lib/core/widgets/animated_mood.dart` (`AnimatedMood` Lottie renderer), `lib/core/widgets/net_image.dart` (`NetImage` disk-cached image), `lib/core/services/presence_service.dart` (typing/read/mood/"is here"), `lib/core/realtime_resume.dart` (`realtimeResumed` resubscribe notifier).

### Message model + kinds

`Message` (in `chat_repository.dart`) has `kind` ∈ `'text' | 'image' | 'voice' | 'video'`:
- **text** — `body` holds the message.
- **image** — `imagePath` is a storage path in the public `couple_media` bucket; `imageUrl` getter derives the public URL.
- **voice** — `voicePath` in `couple_media`; `voiceUrl` getter; played back in-bubble by `_VoicePlayer` (just_audio) with a pseudo-waveform.
- **video** — `videoPath` in the **private** `couple_intimate` bucket; played via a short-lived signed URL.

Other fields: `id`, `senderId`, `createdAt`, `replyToId`, `deletedForEveryone`, `deletedBy` (list of uids that chose "delete for me"). Two transient (never-from-DB) fields drive optimistic UI: `localPath` (the local file rendered instantly while it uploads) and `sendStatus` (`SendStatus.sent | sending | failed`). `previewText()` gives quote-reply previews ("📷 Photo", "🎙️ Voice note", "🎬 Video", or truncated body). `isMine(uid)`, `isHiddenFor(uid)`. `Message.fromJson` parses snake_case DB rows via `JsonUtils`.

### RAPID realtime design

This is the core of the chat. There are two realtime channels:
- **Postgres-changes channel** `messages:<coupleId>` (`ChatRepository.subscribe`) — listens for INSERTs on `public.messages` filtered by `couple_id`. This is the durable/authoritative path; its callback flags `fromDb: true`.
- **Broadcast channel** `mood_burst:<coupleId>` (subscribed in `_init`/`_resubscribe`) — carries three ephemeral events: `'msg'` (text fast-path), `'typing'`, and `'mood'` (flings).

**Optimistic send + broadcast + persist sharing one UUID** (`_sendTextFast`): a v4 UUID is generated client-side; the message is (1) inserted into local state immediately via `_onIncoming` (optimistic, appears instantly on the sender), (2) pushed to the partner over the `'msg'` broadcast (arrives in ~ms), and (3) persisted with `ChatRepository.sendText(..., id: id)`. Because all three carry the same `id`, the Postgres echo and the broadcast dedupe against the `_ids` set. The DB insert is fire-and-forget (`try/catch` swallows errors — "it's already on screen").

**Broadcast receive** (`_onMsgBroadcast`): the partner's `'msg'` event renders the message instantly; the later Postgres echo (same id) is deduped.

**Reconcile-on-DB-echo for ordering** (`_onIncoming`): if an id is already present and the message now arrives `fromDb`, `Message.reconcileWith(server)` adopts the authoritative server `created_at` (fixes cross-device ordering), canonical paths, and deletions, while *keeping* the transient `localPath` so an optimistic image keeps showing without a re-download — then `_sortMessages()` re-sorts (descending by `createdAt`, with `id` as a stable same-second tiebreaker). The list is `reverse: true` so newest sits at the visual bottom; if the user is scrolled up reading history, a "New message" chip (`_NewMessageChip`) appears instead of yanking them down.

**Resubscribe on resume/reconnect** (`_resubscribe`): the screen listens to the global `realtimeResumed` `ValueNotifier` (ticked by `initRealtimeAutoResume` on every realtime socket open) and to `AppLifecycleState.resumed` (with a 300ms delay). On either, it tears down and re-creates both the Postgres-changes and broadcast channels, then refreshes `setChatLastRead`, so messages and flings keep arriving across Android doze / network drops / backgrounding.

### Optimistic image / GIF send

`_sendImageFast` mirrors text: a UUID is created, the local file is shown immediately as a bubble with `sendStatus = sending` (rendered in `_Content` via `Image.file`, with a dark overlay + spinner), then `ChatRepository.sendImage(..., id: id)` uploads to `couple_media/<coupleId>/<rand>.<ext>` and inserts the row. On success the status flips to `sent` (`_updateStatus`); on failure to `failed` (a red error icon overlays the bubble). The DB echo (same id) dedupes; the partner (no `localPath`) gets the network image.

### Typing (broadcast)

`_onTyping` fires as the user types: it sets `PresenceService.setTyping` (DB, durable) *and* immediately sends a `'typing'` broadcast for a ~ms-latency indicator on the partner. A 1500ms timer clears it. The receiver (`_onTypingBroadcast`) sets `_partnerTyping` (auto-cleared after 4s) which, with the persisted `presence.is_typing`/`typing_in_chat`, drives the `typing…` subtitle + `TypingIndicator` dots.

### Read receipts + "is here" avatar

While the chat is open, a 5-second `Timer` calls `PresenceService.setChatLastRead` (writes `presence.chat_last_read`) and rebuilds. The sender's bubble shows a `_StatusTick`: `_statusFor` computes sent (single check) / delivered (double check, partner online or `last_seen` past the message) / **seen** (sage double-check, partner's `chat_last_read` not before the message). When `presence.isInChatNow` (read within ~18s), the `_PartnerHere` widget shows a small avatar (cached via `NetImage`) with a green dot and "{name} is here" above the input.

### Reply / slide-to-reply

`_startReply` sets `_replyingTo`; the input shows a `_ReplyBar`. Each bubble is wrapped in a `Dismissible` (start-to-end, 0.22 threshold) whose `confirmDismiss` triggers `_startReply` and snaps back (never actually dismisses). On send, `_takeReplyId()` attaches `reply_to_id`. Replies render a `_ReplyPreview` (quoted bar with a gilt left border) at the top of the bubble, resolved via `_byId`.

### Full-screen media

Image bubbles tap into `MediaViewer.open` (a `Hero`-tagged, `InteractiveViewer` pinch-zoom/pan full-screen viewer). Video bubbles (`_VideoBubble`) fetch a signed URL on tap and push `_FullScreenVideo` (Chewie/video_player) which calls `SecureScreen.setSecure()` so intimate video can't be screenshotted/recorded/shown in recents.

### Chat themes (per-user)

`ChatTheme` defines a background (1 colour = solid, 2+ = gradient), `myBubble`, `partnerBubble`, `text`, `subtext`. Six built-ins on-brand with Velvet Aurora: `velvet` (Midnight Boudoir, default), `ember` (Candlelit), `aurora`, `rose` (Blush), `midnight` (Starlit), `dawn`. Plus `customChatTheme` (`id: 'custom'`) which pairs with a user-uploaded background photo (dark scrim for legibility, drawn by `_ChatBg`). `ChatThemeController` loads instantly from `SharedPreferences` (`chat_theme_id`, `chat_bg_url`) then reconciles from the server. **Each partner has their own theme** — it never touches the other person. The picker (`chat_theme_picker.dart`) uploads custom backgrounds to the `chat-bg` storage bucket at `<uid>/bg_<ts>.jpg` and saves the public URL.

### Mood set / fling (animated emoji)

`MoodData` (`lib/core/mood.dart`) is emoji + label + signature hex colour + a bundled animated Noto-emoji Lottie at `assets/emoji/<key>.json` (rendered by `AnimatedMood`, falling back to the plain glyph). `kMoods` includes everyday moods (joyful, loving, missing_you, etc.) and **bold/intimate** ones flagged `intimate: true` (horny/"Turned on", flirty, devilish, kiss, kissmark) — split via `kEverydayMoods` / `kIntimateMoods` (never child imagery). "Set your mood" opens `showMoodSelector` and writes `PresenceService.setMood` (persisted to `presence.current_mood` / `mood_color`); the partner sees it live next to the name. A mood **fling** is sent over the `'mood'` broadcast and animated by `_BurstAnimation` — a big glowing emoji that rises up the chat and fades on both phones.

### Fling-a-GIF + keyboard GIF + GIPHY

Three GIF paths:
- **Fling a GIF** (overflow menu / `_pickGifBurst`) — pick from `showGiphyPicker`, then `_sendGifBurst` broadcasts the URL on the `'mood'` channel; `_BurstAnimation` makes the GIF drift up and linger (~5.2s) on both phones. Ephemeral — no message row.
- **Keyboard GIF** (`contentInsertionConfiguration` on the TextField → `_onKeyboardContent`) — a Gboard GIF/sticker is saved to a temp file and `onFlingGif` → `_flingGifFile` uploads it via `ChatRepository.uploadGif` (to `couple_media`, returning a public URL, no message row) so the partner can load it, then flings it.
- **Attach a GIF into the chat** (`_attachGif`) — pick from GIPHY, download the bytes, save a temp `.gif`, then `_sendImageFast` sends it as a real `image` message (reliable, doesn't depend on the keyboard; GIFs stay animated because `sendImage` uploads the raw file without recompressing).

`GiphyService` (`lib/core/services/giphy_service.dart`) is a thin REST client over `api.giphy.com/v1/gifs/{trending,search}` with `rating=r&bundle=messaging_non_clips`. `GiphyGif` exposes `previewUrl` (grid) and `fullUrl` (sent/flung). The picker debounces search (400ms), shows "Powered by GIPHY" attribution, and shows a friendly "add your key" note when unconfigured.

### Cached avatars (NetImage)

`NetImage` (`lib/core/widgets/net_image.dart`) wraps `cached_network_image` for disk-cached avatars/photos (used in `_PartnerHere`, etc.) so they don't re-download every render or on restart. Note: chat photos, GIF flings, and the themed background use plain `Image.network` deliberately, because GIFs don't animate under some cache configs.

### Deletion

`ChatRepository` calls Postgres RPCs: `hide_message` (delete for me — appends the uid to `deleted_by`, filtered client-side by `isHiddenFor`), `delete_message_for_everyone` (sender-only; both see a "This message was deleted" placeholder), and `clear_conversation` (clears the whole thread for the current user only). After a delete, the screen calls `_reload`.

### Supabase resources

- **Tables**: `public.messages` (couple-scoped via `couple_id`; columns include `id`, `sender_id`, `couple_id`, `body`, `image_path`, `voice_path`, `video_path`, `reply_to_id`, `kind`, `created_at`, `deleted_for_everyone`, `deleted_by`); `public.presence` (typing, mood, `chat_last_read`, online/last_seen — read partner / write self); `public.profiles` (`chat_theme_id`, `chat_bg_image_url`).
- **Realtime channels**: `messages:<coupleId>` (Postgres-changes INSERT), `mood_burst:<coupleId>` (broadcast: `msg` / `typing` / `mood`), `presence:<coupleId>` (partner presence, via `RealtimeService.coupleTable`).
- **Storage buckets**: `couple_media` (public — images, voice notes, flung/keyboard GIFs), `couple_intimate` (private — videos, served via 1-hour signed URLs from `signedVideoUrl`), `chat-bg` (custom theme backgrounds, public URL).
- **RPCs**: `hide_message`, `delete_message_for_everyone`, `clear_conversation`.

### RLS / security notes

`messages` and `presence` are couple-scoped by RLS (you can read/write only your couple's rows; presence lets you update only your own row and read your partner's). The chat fetch limits to the latest 300 messages (`order created_at desc, limit 300`). Intimate video lives in the private `couple_intimate` bucket (signed URLs only, never public) and the full-screen player sets `FLAG_SECURE` to block screenshots/recording/recents preview. Per-user theme writes are scoped to the current uid's `profiles` row.

### Config / .env keys

- `GIPHY_API_KEY` (read via `dotenv.maybeGet`) — required for GIF search/trending; empty key disables GIFs gracefully with a "get a free key at developers.giphy.com" note. Present in `E:\LDR\mobile\.env`.
- Supabase project ref `sopictusdonlvuezmfep` (URL/anon key in the app's Supabase init, not in this feature).
- `SharedPreferences` keys (local theme cache): `chat_theme_id`, `chat_bg_url`.
- Bundled assets: `assets/emoji/<moodKey>.json` (animated Noto-emoji Lottie files).

---

## 4. Touch · Closer · Intimacy (Adult Modules)

These are the app's consent-gated, adults-only intimacy features. They are split across three feature areas: the synced **Touch** screen (`lib/features/touch_map/`), the encrypted **Closer** module hub and its sub-features (`lib/features/closer/`), and the **In the Mood** mutual-consent signal layer (`lib/features/intimacy/`). All three are explicitly opt-in, off by default, and designed so that nothing intimate becomes visible to one partner until the other has reciprocated.

> **Adult / consent nature:** Every feature here is mutual-gated. Touch needs a linked couple with both photos; Closer is hard-gated behind couple-wide "Modest Mode" plus an E2EE-key handshake both partners must complete; In the Mood reveals a signal only when both partners have an active signal in the same window (enforced by RLS, not just UI); Pick-for-Us escalates tiers only when *both* partners tap to unlock. Intimate screens set Android `FLAG_SECURE` to block screenshots/recordings. Copy is deliberately tasteful (the In-the-Mood states are non-graphic).

---

### Touch (synced body-photo touch screen)

**What it does / user flow.** `TouchMapScreen` (`lib/features/touch_map/touch_map_screen.dart`) puts **both partners' full-body photos on one shared screen, rendered identically on both phones**. Each partner taps/drags on the *other's* body; the touch lands at that spot on both screens in real time, and the person being touched feels a haptic. Both can touch simultaneously. The user picks a **touch type** from a horizontal selector — `caress 🫳, glow 💫, kiss 💋, hug 🤗, grab ✊, pinch 🤏, lick 👅 (key 'tongue'), poke 👉, spank 🖐️, bite 🫦` (the `_types` list / `_TouchType` class). A shared **warmth meter** (`_heat`, 0..1) rises on every interaction (`_bumpHeat`) and decays ~0.03/s via `_heatTimer`; the haptic strength scales with `_heat`.

**Deterministic sync.** In `build`, the two UIDs are sorted (`[me, partner]..sort()`) so left/right body columns render in the same order on both devices. Each `_ActiveTouch` glow is keyed to **whose body** it landed on (`owner`), not screen pixels, so positions stay in sync regardless of device size. Touches are stored as normalized `(x, y)` in 0..1.

**Key sub-behaviors (all in `touch_map_screen.dart`):**
- **Real-time touch broadcast** — `_touch()` shows the glow locally (`_spawn` → animated `_Glow`), buzzes a light tick for the toucher (`TouchHaptics.touchTick`), and broadcasts `event: 'touch'` with `{from, target, x, y, type}`. `_onTouchMsg` ignores its own echo (`from == _myUid`); if `target == _myUid` it fires the per-type haptic (`_haptic` → `TouchHaptics.feel`).
- **Live synced pan/zoom framing** — the `_Frame` class (scale/dx/dy) per body. Tapping the crop toggle (`_adjusting`) enters adjust mode; pinch/drag updates the frame (`_onFrameUpdate`, clamped scale 1–4, offset ±0.7) and broadcasts `event: 'frame'`. `_onFrameMsg` applies the partner's framing so both phones show the same crop of a photo live.
- **Neon "hot lines"** — toggled by the `gesture` AppBar icon (`_drawing`). Dragging draws glowing comet-tail strokes (`_NP` points, `_NeonPainter`, color `0xFFFF4D8D`) that fade after ~1.3s; each point broadcasts `event: 'neon'` (`_onNeonMsg` re-draws on the partner). Strokes are keyed so separate strokes aren't bridged.
- **Quick-snap** — camera icon → `_quickSnap()` takes a photo straight from the camera (no crop/confirm) and sends it to chat via `ChatRepository.sendImage` (uploads to `couple_media` bucket, inserts a `messages` row).
- **Whisper chat** — a `GameChatPanel(coupleId, gameKey: 'touch')` strip (`lib/features/games/game_chat_panel.dart`) lets partners text live without leaving Touch. It is **ephemeral broadcast only** (channel `gchat:touch:<coupleId>`, `event: 'msg'`), not saved to the DB.
- **Live photo reload** — setting your photo (`_setMyPhoto`) broadcasts `event: 'photo'`; `_onPhotoMsg` calls `_loadPhotos()` so the partner sees the new photo without leaving/returning.
- **Silhouette fallback** — `_SilhouettePainter` draws a gender-neutral figure until a real photo is set (also the `Image.network` error builder).

**Realtime channel.** All Touch sync is on **one ephemeral broadcast channel** `touch:<coupleId>` (`_subscribe`), carrying events `touch`, `frame`, `photo`, `neon`. No DB writes for the live sync. It re-subscribes on app resume via `realtimeResumed.addListener(_subscribe)`.

**Data / repository.** `TouchMapRepository` (`lib/features/touch_map/touch_map_repository.dart`):
- `uploadBodyPhoto(coupleId, file)` → uploads to **private Storage bucket `couple_intimate`** at path `<coupleId>/body/<uid>_<ts>.jpg` (upsert), returns the path.
- `signedBodyUrl(path)` → `createSignedUrl(path, 3600)` on `couple_intimate` (1-hour signed URL; bucket is private).
- The path is stored on the user's `presence` row via `PresenceService.setBodyPhoto` (column `body_photo_path`); `_loadPhotos` reads it back with `PresenceService.fetchMine` / `fetchPartner` (table `presence`).
- The file also defines a legacy `BodyTouch` model + `sendTouch`/`subscribe` against a `body_touches` Postgres table (insert + postgres-changes on channel `body_touches:<coupleId>`). **The live screen does NOT use this path** — it uses broadcast — but `body_touches` exists as an "ephemeral touch glows" table (rows auto-expire via `expires_at`).

**Haptics.** `TouchHaptics` (`lib/core/services/touch_haptics.dart`) uses the `vibration` package. `feel(type, heat)` maps each touch type to a distinct vibration pattern (e.g. `kiss` = quick double peck, `hug` = long 460ms envelope, `spank` = hard 70ms smack at amp 255, `bite`/`tongue` = multi-pulse patterns), with amplitude raised by `heat` when the device supports amplitude control. Falls back to `HapticFeedback.mediumImpact()`. Honest caveat in-code: it's the whole-device motor, can't target a body part.

**Security.** `initState` calls `SecureScreen.setSecure()` (FLAG_SECURE) and `dispose` clears it. Routed at `/app/touch` (`router.dart`).

---

### SecureScreen (FLAG_SECURE helper)

`lib/features/closer/secure_screen.dart` — `SecureScreen.setSecure()` / `clearSecure()` toggle Android's `FLAG_SECURE` via `MethodChannel('miles/secure_screen')`, blocking screenshots, screen recording, and the recent-apps preview. Used by Touch, Touch Trace, and (per spec) Private Vault / Memory Threads. iOS / pre-wired native is a no-op (swallows `MissingPluginException` / `PlatformException`) so a missing native hook never crashes a release build.

---

### Closer module (hub + gating)

**What it does.** `CloserScreen` (`lib/features/closer/closer_screen.dart`) is the entry hub for the end-to-end-encrypted intimacy module. Its `_ModuleEnabled` grid links to nine sub-features: **Touch Trace, Mood Lamp, Desire, Fantasy Jar, Afterglow, Private Vault, Body Map, Pick for us, Memory Threads** (routes under `/app/closer/...` in `router.dart`).

**Adults-only / consent gating (two layers):**
1. **Modest Mode (couple-wide).** The `couple.modestMode` flag (`models.dart`, column `modest_mode`, default treated as `true` when unknown) hides everything: when on, `CloserScreen` shows `_ModestModeOn` ("a space for adult couples… stays off until both of you turn it on in Settings") with only an *Open Settings* button. It's toggled via `SupabaseRepository` `update({'modest_mode': enabled})` on `couples`, and the same flag gates Closer's visibility in `app_shell.dart` and `settings_screen.dart`.
2. **E2EE key handshake.** With Modest Mode off, `_prepareKey()` calls `ensureSharedKey(session)` (`closer_crypto.dart`), which publishes the user's own X25519 public key (`SupabaseRepository.publishMyPublicKey`, idempotent upsert) and derives the couple-shared symmetric key from the partner's published key (`CryptoCore.deriveSharedKey`). If the partner hasn't opened Closer yet (no published key), the screen shows `_WaitingForPartner` ("Ask your partner to open the Closer tab once") with a retry; other failures show `_KeyError`. So **both partners must enable Modest-off and each open Closer once** before any sub-feature works.

**Crypto plumbing.** `closer_crypto.dart` provides byte-packing helpers used by the encrypted sub-features (Vault, Memory Threads, Afterglow): XChaCha20-Poly1305 with a 24-byte nonce + 16-byte MAC, packed as `mac||ciphertext` (`packMacAndCiphertext`, nonce in its own column) or `nonce||mac||ciphertext` (`packFull`, single `bytea` column, e.g. `afterglow_entries.photo_a`). `byteaToBytes` / `bytesToBytea` handle Postgres `bytea` hex-literal (`\x…`) round-tripping over PostgREST (the file notes this hex bug previously silently dropped every Closer row). The "nothing is readable by anyone but the two of you — not even us" promise comes from this E2EE: ciphertext is stored server-side, keys never leave the devices.

---

### Touch Trace (shared drawing canvas)

**What it does / flow.** `TouchTraceScreen` (`lib/features/closer/touch_trace/touch_trace_screen.dart`) is a full-screen shared canvas: whatever one partner draws appears live on the other's screen. Requires a linked couple with both partners (else a "Link your partner to draw together" guard). Sets `FLAG_SECURE` on enter, clears on dispose.

**Data flow (`touch_trace_canvas.dart`).** Drawing is **ephemeral broadcast only** on channel `touch_trace:<coupleId>` — no DB writes. A `_TraceStroke` = a color + list of normalized `_TracePoint`s (`x,y` in 0..1, `t` ms since stroke start). On pan, points stream to the partner throttled to ~33ms (`_throttledSend`) via `event: 'stroke_point'` `{from, stroke, point}`; `event: 'stroke_end'` and `event: 'clear'` finalize/clear. Incoming events ignore own echoes (`from == userId`). A 6-color picker + clear button sit on top; `_TracePainter` renders a glow pass + bright core, with your own strokes slightly thinner than the partner's. Re-subscribes on resume (`realtimeResumed`). Routed at `/app/closer/touch-trace`.

---

### Pick for Us (consensual dice, tiered escalation)

**What it does / flow.** `PickForUsScreen` (`lib/features/closer/pick_for_us/pick_for_us_screen.dart`) is a "roll for spontaneous connection" die. Three tiers (`DiceTier` enum in `pick_for_us_repository.dart`): **Warm** (`warm`, always on), **Warm + Hot** (`warm_hot`), **Hot** (`hot`) — each with a fixed pool of non-graphic tags (e.g. warm: slow/morning/whispered/tender/playful). Rolling picks one random tag from each *enabled* tier (`rollTags`) and animates a spinning die, then shows the combo.

**Consent gating.** A higher tier unlocks only when **both** partners have granted consent. Each partner taps "Let's go hotter" → `setMyConsent` upserts their row; the UI shows "Waiting on them" until the partner matches, then "Unlocked" (`_tierUnlocked` = both `granted`). Warm is always enabled.

**Data flow.** `PickForUsRepository`:
- `dice_tier_consents` table — rows `{couple_id, tier, user_id, granted, granted_at}`, upserted per user; `fetchConsents` returns `{tier → {userId → granted}}`.
- `dice_rolls` table — `saveRoll` inserts `{couple_id, tier, result_tags}`; `fetchRecent` reads the last 12 ordered by `rolled_at` for the "Recent rolls" history.

There is no realtime here; state refreshes via `_load()` (pull). Routed at `/app/closer/pick-for-us`. (Tag pools are entirely client-side constants in the `DiceTier` enum.)

---

### In the Mood / Intimacy (mutual-consent signal layer)

**What it does / flow.** `IntimacyScreen` (`lib/features/intimacy/intimacy_screen.dart`, route `/app/intimacy`) is a tender, opt-in way to signal closeness across distance — deliberately **never explicit**. Off by default; `_OptIn` turns it on for both directions. The user picks a non-graphic mood (`moodStates`: *Thinking of you 💭, Feeling close 🤍, Missing your touch 🌙, Feeling a little flirty ✨, Wishing you were here 💫*). After signaling you see `_Waiting`; if the partner also has an active signal you both see the `_MutualMoment` reveal (`💞`, both moods shown). "Comfort & consent" (`IntimacyPrefsScreen`, `/app/intimacy/prefs`) has per-direction switches (receive / send) and a one-tap **Mute the whole layer** that also clears any signal — with the explicit promise that the partner is never notified of any change.

**State / controller.** `IntimacyController` (`intimacy_controller.dart`, `intimacyControllerProvider`) holds prefs + `mine`/`partner` signals; `mutual = mine != null && partner != null`, `waiting = mine != null && partner == null`. `signal()`, `notTonight()` (clears, no trace), `muteAll()`.

**Data flow & RLS (the security crux).** `IntimacyRepository`:
- `intimacy_prefs` table — `{user_id, receiving_enabled, signaling_enabled}` (upsert / `maybeSingle`).
- `intimacy_signals` table — `sendSignal` first `clearMine()` then inserts `{couple_id, user_id, state, window_expires_at}` (default 6-hour window). `activeSignals` selects rows for the couple with `window_expires_at > now`. **The mutual gate is enforced server-side by RLS**, not the client: as the controller comment states, RLS guarantees you only see your partner's signal if *you* also have an active one. `clearMine` deletes your own signal ("not tonight" — frictionless, no trace).
- Realtime: channel `intimacy:<coupleId>` listens to all postgres-changes on `intimacy_signals` for the couple and calls `refresh()` so the mutual reveal appears live.

---

### Supabase resources used (summary for this area)

- **Tables:** `presence` (`body_photo_path` for Touch photos, `current_screen`), `body_touches` (legacy/ephemeral touch glows, `expires_at`), `dice_rolls`, `dice_tier_consents`, `intimacy_prefs`, `intimacy_signals`, `couples` (`modest_mode`), `messages` (quick-snap), and the E2EE public-key / encrypted Closer tables referenced by `closer_crypto.dart` (e.g. `vault_items`, `memory_threads`, `afterglow_entries`).
- **Storage buckets (private):** `couple_intimate` (body photos, 1h signed URLs), `couple_media` (quick-snap chat images).
- **Realtime channels:** broadcast-only `touch:<coupleId>` (events `touch`/`frame`/`photo`/`neon`), `touch_trace:<coupleId>` (`stroke_point`/`stroke_end`/`clear`), `gchat:touch:<coupleId>` (whisper chat `msg`); postgres-changes `intimacy:<coupleId>` and legacy `body_touches:<coupleId>`. All broadcast channels re-arm on resume via `realtimeResumed`.
- **Security:** Android `FLAG_SECURE` on Touch & Touch Trace; couple-wide `modest_mode` gate + per-user E2EE public-key handshake for Closer; RLS-enforced mutual visibility for `intimacy_signals` and dual-consent unlock for `dice_tier_consents`; private buckets with short-lived signed URLs for intimate photos.
- **Config / .env:** none specific to these modules beyond the shared Supabase project (ref `sopictusdonlvuezmfep`); no feature-specific env keys were found in these files.

---

## 5. Home · Location · Presence · Reach · Care · Cycle

This area covers the app's landing dashboard ("Tethered" Home), live/coarse location sharing, the presence layer that backs almost every couple-aware widget, the **Reach** touch-from-afar feature, **Care** reminders, the gender-gated menstrual **Cycle** tracker, and the post-capture **photo filter** editor.

### Home dashboard

**What it does / user flow.** `HomeScreen` (`lib/features/home/home_screen.dart`) is the first tab. It greets the user with the "Tethered" title + a drawer button (`rootScaffoldKey`), then renders, in order: a **partner status card**, a **live location card**, an optional **live-sharing banner**, the **partner cycle card** (male partner only), a big **Reach button**, and a **quick-actions** row (Messages, Capsule, Touch, Vault). If there's no couple it shows "Link with your partner to begin."; if the partner row hasn't materialized yet it shows "Waiting for your partner to join…".

**Key widgets (all in `home_screen.dart` unless noted):**
- `_PartnerStatusCard` — partner avatar (their latest check-in snap via `NetImage`/`Hero`, tappable into `MediaViewer`), display name + animated mood (`AnimatedMood` keyed by `moodByKey`), online dot / "Last seen h:mm a", their local time (`TzHelper.nowIn(partner.timezone)`), location label, "Feeling X", "In <screen>" (their `currentScreen`), and a **Share a snap** button. Wrapped in a `GlassPanel` with a `BreathingGlow` (sage when online, blush when offline).
- `PartnerLocationCard` (`lib/features/home/partner_location_card.dart`) — see below.
- `_LiveSharingBanner` — privacy indicator "Sharing live location with <name>" + a one-tap **Turn off**, shown only while the local user's own mode is `precise`.
- `PartnerCycleCard` (`lib/features/cycle/partner_cycle_card.dart`) — see Cycle.
- `ReachButton` (`lib/features/reach/reach_button.dart`) — see Reach.
- `_QuickActions` — Messages switches the shell tab via `shellTabProvider`; the rest `context.push` to `/app/capsule`, `/app/touch`, `/app/vault`.

**Share a snap (`_shareSnap`).** Picks an image via `PhotoPickerService.pickFromSheet`, uploads to Storage bucket **`couple_media`** at path `<coupleId>/checkins/<uid>_<millis>.jpg`, then writes the public URL to presence via `PresenceService.setCheckinPhoto`. The partner's status-card avatar then becomes that snap.

**Providers consumed:** `currentCoupleProvider`, `partnerProfileProvider`, `partnerPresenceProvider`, `shellTabProvider` (from `core/providers.dart`).

### Presence layer

`lib/core/services/presence_service.dart` is the shared backbone for Home (and chat read-receipts, mood, "in chat", body photo, avatar emoji, location). 

- **Table:** `presence` (one row per user, keyed by `user_id`, carries `couple_id`). All writes go through `PresenceService._upsert`, which always stamps `user_id`, `couple_id`, `updated_at` and is **best-effort** (errors are swallowed — presence never surfaces an error to the user).
- **`Presence` model** parses: `is_online`, `last_seen`, `is_typing`, `typing_in_chat`, `current_mood`/`mood_color`, `location_label`, `location_sharing_mode` (`off`|`city`|`precise`), `latitude`/`longitude`/`location_accuracy`/`location_updated_at`, `current_activity`, `current_screen`, `body_photo_path`, `avatar_emoji`, `checkin_photo_url`/`checkin_photo_at`, `chat_last_read`. Helpers: `isInChatNow` (read within ~18s), `isSharingLive` (`precise` + coords present).
- **Writers:** `setOnline`, `setTyping`, `setTypingInChat`, `setChatLastRead`, `setMood`, `setScreen`, `setBodyPhoto`, `setAvatarEmoji`, `setSharingMode`, `setLocation`, `setLiveLocation`, `setCheckinPhoto`, plus `clearLiveLocation`.
- **Readers:** `fetchPartner(coupleId)` (the row in this couple that is **not** mine — `.neq('user_id', uid)`), `fetchMine(coupleId)`.
- **Realtime:** `PartnerPresenceNotifier` / `partnerPresenceProvider` (autoDispose `StateNotifier<Presence?>`) subscribes via `RealtimeService.coupleTable` on channel **`presence:<coupleId>`**, refetches the partner row on any change, re-subscribes + refetches on `realtimeResumed` (socket reconnect) so a stale false-"offline" is corrected.
- **Security note (in code comment):** RLS lets you update only your own row and read your partner's.

### Live location sharing

**Modes (`lib/core/services/location_service.dart`):** symmetric, opt-in, revocable. `off` (nothing shared), `city` (only a "City, Country" label — **no coordinates persisted**), `precise` (coords + accuracy + a finer reverse-geocoded label). Each user picks for their own account; either partner can turn it off any time. Foreground streaming has **no persistent notification** (the Android sticky-notification foreground-service was deliberately avoided).

**Flow on Home (`_initLocation`):**
1. Reads the user's stored mode from presence (`PresenceService.fetchMine`).
2. **Auto-enable on first install:** if `SharedPreferences` key `location_auto_init` is unset, it sets mode to `precise` and writes it (`PresenceService.setSharingMode`). Stays on until the user taps "Turn off".
3. If `precise`: `LocationService.startLiveSharing(couple.id)` + `BgLocationService.enable()`. If `city`: `LocationService.shareOnce`.
4. `_refreshMyCoords` uses `Geolocator.getLastKnownPosition()` for an instant, prompt-free "you are here" used in the distance readout.

**`LocationService` internals:**
- `ensurePermission` / `blocked` wrap `Geolocator.checkPermission`/`requestPermission`. Background ("Allow all the time") is tracked separately: `hasBackgroundPermission()` checks `LocationPermission.always`; an `location_always_on` SharedPreferences flag (`isAlwaysOn`/`setAlwaysOnPref`) records the user's opt-in. Android 11+ won't grant "always" in the normal flow, so the caller routes to `openAppSettings`.
- `shareOnce` (city/precise one-shot) reverse-geocodes a label via `geocoding`'s `placemarkFromCoordinates`. In `city` mode it sends **only** the label (`PresenceService.setLocation(mode:'city', label:…)`), never coordinates.
- `startLiveSharing` pushes one immediate high-accuracy fix, then streams `Geolocator.getPositionStream` with `distanceFilter: 10`, upserting each tick via `setLiveLocation`. Labels are re-geocoded only on first fix or after a ~700 m move (`_labelIfMoved`) to avoid geocoding every 10 m.
- `stopLiveSharing` cancels the stream and `clearLiveLocation` (wipes coords, sets mode `off`) so the partner sees "paused", never a stale pin. `pauseStream` cancels the stream without changing the mode (used when Home is backgrounded / left).

**Lifecycle wiring in `HomeScreen`:** `didChangeAppLifecycleState` restarts `startLiveSharing` on resume and `pauseStream` on background (only when mode is `precise`); `dispose` pauses the stream (mode persists).

**Background updates (`lib/core/services/bg_location.dart`):** `BgLocationService` uses **WorkManager** (`workmanager`) — `registerPeriodicTask` at ~15-min cadence (`bgLocationUpdate` / unique name `tethered-bg-location`, `NetworkType.connected`, `ExistingPeriodicWorkPolicy.keep`). The `@pragma('vm:entry-point') bgLocationCallback` re-inits dotenv + Supabase, fetches the user's profile/couple, **respects the live mode** (bails unless `locationSharingMode == 'precise'`), grabs a high-accuracy fix and writes it via `setLiveLocation`. Best-effort: aggressive OEM battery managers (OnePlus/Vivo/Xiaomi) may delay/skip runs; the callback never throws (to avoid WorkManager retry churn).

**Presence fields used:** `location_sharing_mode`, `latitude`, `longitude`, `location_accuracy`, `location_updated_at`, `location_label`.

**`.env` keys:** the background isolate calls `dotenv.load()` + `SupabaseService.init()`, so the standard Supabase URL/anon-key env keys are required there too.

### Partner location card (2D map) & FREE 3D map

**`PartnerLocationCard` (`lib/features/home/partner_location_card.dart`).** When the partner is sharing live (`isSharingLive`), shows a 210 px `flutter_map` (`FlutterMap`/`MapController`) with:
- a **CARTO dark** raster basemap (`https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png`, no API key), `userAgentPackageName: 'com.miles.miles'`;
- a `_CuteMarker` (bobbing blush avatar with a pulsing "live" halo + ground shadow) at the partner's point, plus an optional `_MyDot` (sage) at the user's coords and a blush `PolylineLayer` connecting the two;
- header "partner · <ago>" (`_agoText` off `locationUpdatedAt`), a **3D** button (`Icons.threed_rotation`) and a **recenter** button;
- a "X km / m apart" readout (`_distanceText` via `latlong2` `Distance`).

Interaction is limited to `pinchZoom | drag`. New fixes glide the camera between positions via an `AnimationController` (`_glideTo`/`_onMoveTick`). When the partner stops sharing it renders a "<name> isn't sharing location right now" placeholder (never a stale pin).

**`Map3DScreen` (`lib/features/home/map_3d_screen.dart`)** — the **free, no-API-key** full-screen photorealistic 3D view. It loads an inline HTML string into a `webview_flutter` `WebViewController` (`JavaScriptMode.unrestricted`) running **MapLibre GL JS 4.7.1** (from unpkg). The style stitches together free sources:
- **`sat`** — Esri World Imagery raster tiles (`server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}`);
- **`terrain`** — AWS terrarium elevation DEM (`s3.amazonaws.com/elevation-tiles-prod/terrarium/...`), `setTerrain` with exaggeration 1.4;
- **`osm`** — OpenFreeMap vector tiles (`tiles.openfreemap.org/planet`) rendered as a `fill-extrusion` **3D buildings** layer (`source-layer: building`).

The camera starts pitched (`pitch:58`, `bearing:28`, `zoom:18.4`) with a gentle auto-orbit (`setInterval` nudging bearing). A blush marker is dropped at the partner's lat/lon. **Gesture note:** the `WebViewWidget` registers an `EagerGestureRecognizer` so all touches (including 2-finger pinch) go to the native WebView — otherwise Flutter's gesture arena eats the pinch and the map won't zoom/rotate. Comments call this "Google photorealistic 3D," but the actual implementation is the Esri+AWS+OSM/MapLibre stack above.

### Reach (touch-from-afar)

There are two distinct mechanisms in `lib/features/reach/`:

**1. Active feature — full-screen-intent "reaching for you":**
- **`ReachButton`** (on Home) — a 132 px hold-to-reach button (gradient `MilesGradients.cta`). `onLongPress` (~0.5 s, prevents accidental taps) fires `ReachRepository.reach`, gives `HapticFeedback.mediumImpact`, shows "Reaching for <name>… 💕", then enforces a **30 s cooldown** ("Wait Ns").
- **`ReachRepository`** (`reach_repository.dart`) — `reach(coupleId)` inserts into table **`reach_events`** (`couple_id`, `from_user`); `acknowledge(id)` stamps `acknowledged_at`; `subscribe(coupleId, onReach)` listens on realtime channel **`reach_events:<coupleId>`** for INSERTs filtered by `couple_id`. `ReachEvent` has `isMine(uid)` and `isActive` (`expires_at` in the future) — so the DB sets `expires_at`.
- **`ReachOverlayScreen`** (`reach_overlay_screen.dart`) — full-screen "<partner> is reaching for you 💕" alert with `EmberBackground`, breathing 💗, a strong vibration pattern, and **"I'm here 💕"** (calls `acknowledge`) / Dismiss buttons.
- **Wiring (`lib/features/shell/app_shell.dart`):** the shell subscribes via `ReachRepository.subscribe(couple.id, _onReach)` on ready and re-arms it on socket reconnect (`_rearmAlwaysOn`, driven by `realtimeResumed`). `_onReach` ignores your own / expired events and calls `_showReach`, which is **de-duped by reach id** (`_shownReach` set) so the realtime and push paths never double-show the same Reach; it pushes the overlay on the root navigator. It also drains `pendingReach` (a tapped/foreground push) via `_onPendingReach`.
- **Background wake — NOT YET CONFIGURED:** `lib/core/push/fcm_todo.dart` documents that waking the screen when backgrounded needs FCM (firebase_core/messaging, `google-services.json`, a `device_tokens` table, and a **Supabase Edge Function on INSERT to `reach_events`** that sends an FCM v1 message with `fullScreenIntent: true` / `PRIORITY_MAX`). The Android manifest already declares `USE_FULL_SCREEN_INTENT` + `WAKE_LOCK`; `FsiPermission.promptIfNeeded` prompts for the Android 14+ full-screen-alert permission. The **foreground** path is fully working today.

**2. `ReachScreen` (`reach_screen.dart`) — defined but not routed.** A separate heartbeat experiment: hold the heart to insert rows into table **`reach_pulses`** (`couple_id`, `user_id`, `sent_at`) once/second; the partner's device subscribes on channel **`reach:<coupleId>`** and plays a 60-BPM-style haptic (`vibration` package, pattern `[0,100,150,100,700]`) per pulse, counting "They reached for you · N×". No route references `ReachScreen` or `reach_pulses`, so it is currently inactive code (the live Reach is mechanism #1).

### Care reminders

**What it does / user flow.** `CareScreen` (`lib/features/care/care_screen.dart`, route `/app/care`) lets you send your partner a gentle nudge ("Did you have lunch yet?", "Take your medicine 💊", "Drink some water 💧", etc.). Presets are defined as `_Preset(kind, emoji, label, message)` for kinds `eat`/`medicine`/`water`/`sleep`/`break`/`move`, plus a **Custom** dialog (kind `custom`). Sent nudges list below; **the recipient (not the sender)** taps **Done ✅** to acknowledge, and the sender then sees "They did it ✓".

**Data flow (`care_repository.dart`).** 
- **Table:** `care_nudges` (`couple_id`, `from_user`, `kind`, `message`, `created_at`, `acknowledged_at`). 
- `send` inserts; `acknowledge(id)` stamps `acknowledged_at`; `list(coupleId)` pulls the latest 50 ordered by `created_at desc`. 
- **Realtime channel:** `care_nudges:<coupleId>` (all events, filtered by `couple_id`) re-runs `_load`.
- `CareScreen` needs no presence code of its own: `PresenceRouteObserver` derives `Care` from `/app/care`.

### Cycle tracker (gender-gated)

**Gating.** Each user sets their **own** gender once after pairing. `Profile` (`lib/core/models.dart`) exposes `gender`, `genderSet`, `isFemale`, `isMale`. The router (`lib/core/router.dart`) redirects paired users with `genderSet == false` to `/role-setup` (`role_setup_screen.dart` → `SupabaseRepository.setGender`, which sets `gender` + `gender_set`). The Cycle UI branches on `isFemale`/`isMale`.

**Female tracker (`CycleScreen._femaleTracker`, route `/app/cycle`).**
- A big **"I'm on my period"** toggle. `_toggle(on)` calls `CycleRepository.setOnPeriod`, which **both** inserts a `cycle_events` row (`type: 'period_start'|'period_end'`, `event_date`) **and** upserts the live `on_period_now` flag on `cycle_settings` so the partner's card updates instantly.
- A prediction card (`CyclePrediction.compute` from logged start dates + settings): phase (`menstrual`/`follicular`/`fertile`/`luteal`), day-of-cycle, "Next period in ~N days" — every figure labeled **(estimate)**.
- A month `_CycleCalendar` (logged period days filled in red `0xFFE0564B`, predicted window ringed in gilt).
- An averages card (avg cycle / avg period / cycles logged), a **Settings** card (Share-with-partner switch, average-cycle and average-period steppers), and a medical-use **disclaimer** ("not for medical, fertility, or contraception decisions").

**Male partner view (`CycleScreen._partnerView`).** Reads the partner's `cycle_settings`; if `share_with_partner` is false it shows "<name> keeps her cycle private right now." Otherwise it reverse-derives her state from her (RLS-gated) `cycle_events` + `on_period_now` and shows a gentle, **detail-free** card ("<name> started her period", or "Next period in ~N days") with a phase-appropriate `partnerNote`, plus a **Send a care note** button that posts a fixed sweet message into chat (`ChatRepository.sendText`).

**Home card (`PartnerCycleCard`, `lib/features/cycle/partner_cycle_card.dart`).** Renders **only for the male partner** (`s.profile?.isMale`), and only when there's "something gentle to say" (she's on her period or a next-period estimate exists). Tapping it pushes `/app/cycle`. Subscribes on channel **`home_cycle:<coupleId>`** to `cycle_events`.

**Repository (`cycle_repository.dart`).**
- **Tables:** `cycle_settings` (per-user: `avg_cycle_length` (def 28), `avg_period_length` (def 5), `share_with_partner` (def true), `tracking_enabled`, `on_period_now`, `updated_at`) and `cycle_events` (`user_id`, `couple_id`, `type`, `event_date`, `created_at`).
- **Realtime channel:** `cycle_events:<coupleId>` (in `CycleScreen`), re-armed on `realtimeResumed`.
- **Derivations:** `onPeriod` (latest event is a start), `startDates`, `spans` (pair start→end for calendar shading), `avgPeriodLength`/`avgCycleLength` (from closed spans / start-to-start gaps, filtering gaps to 10–90 days), and `CyclePrediction.compute` (uses average gap when ≥2 cycles, derives a coarse phase with ovulation ≈ cycleLen − 14).
- **Security note (in code comments):** sensitive health data, RLS-locked to the couple; the partner can read `cycle_events` **only if** the owner's `share_with_partner` is true (the male view explicitly checks `ps.shareWithPartner` before fetching her events).

### Photo filter / enhance editor

`FilterEditorScreen` (`lib/features/photo/filter_editor_screen.dart`) is a post-capture **beauty/enhance** editor reusable across the app (`FilterEditorScreen.edit(context, file)` returns the processed `File` or null). Presets: Original, Smooth (gaussian blur + lift), Glow (stronger blur + bloom), Warm, Cool, B&W (grayscale), Vintage (sepia + vignette), implemented with the `image` package. Filtering runs in a background isolate via `compute(_processBytes, _FilterArgs)` so the UI never janks; preview is downscaled (maxWidth 700, q85) while the final confirm re-renders at full size (q88) and writes a `.f.jpg` sibling file. No Supabase/network — it's a pure local image transform consumed by upstream pickers (e.g. snap/check-in flows).

### Tables, channels, buckets & config (this area)

- **Supabase tables:** `presence`, `reach_events`, `reach_pulses` (inactive), `care_nudges`, `cycle_settings`, `cycle_events`; `profiles` (read for `gender`/`gender_set`, `timezone`).
- **Realtime channels:** `presence:<coupleId>`, `reach_events:<coupleId>`, `reach:<coupleId>` (inactive), `care_nudges:<coupleId>`, `cycle_events:<coupleId>`, `home_cycle:<coupleId>`.
- **Storage bucket:** `couple_media` (check-in snaps at `<coupleId>/checkins/…`).
- **SharedPreferences keys:** `location_auto_init` (first-install auto-enable of precise sharing), `location_always_on` (background-sharing opt-in).
- **Background work:** WorkManager periodic task `bgLocationUpdate` / unique `tethered-bg-location` (~15 min).
- **External (key-less) map services:** CARTO dark basemap (2D), Esri World Imagery + AWS terrarium DEM + OpenFreeMap vector tiles via MapLibre GL JS 4.7.1 (3D); reverse geocoding via the `geocoding` plugin.
- **RLS / security:** own-row-only writes + partner-read on `presence`; couple-scoped RLS on `reach_events`/`care_nudges`/`cycle_*`; cycle data additionally gated by the owner's `share_with_partner` flag. FCM background-wake for Reach is **stubbed/not configured** (`fcm_todo.dart`); only the foreground Reach overlay is live.

---

## 6. Social · Games · Keepsakes

This section documents the couple-facing "things to do together" surface of Tethered: synced mini-games, the shared affection space, daily/relationship rituals, and the keepsake features (time capsules, private vault, reasons jar, visit timeline). Almost every feature is **couple-scoped** (rows carry a `couple_id`, fetched from `sessionProvider.couple`) and the synced/live ones ride Supabase Realtime **broadcast** channels (ephemeral pub/sub, nothing persisted) rather than Postgres-change streams.

### Games (synced couple arcade)

**What it does / user flow.** `GamesScreen` (`lib/features/games/games_screen.dart`, route `/app/games`) is a hub listing three mini-games as gradient cards: **Truth or Dare** (badged `LIVE` / synced), **Would You Rather**, and **Never Have I Ever**. All content is hand-written in natural Roman Urdu. The two synced card games and Truth-or-Dare keep both phones in lockstep over a realtime broadcast channel, and each embeds a live answer strip.

**Key files**
- `lib/features/games/games_screen.dart` — the hub/menu (`_Game` records define title/route/accent/`synced`).
- `lib/features/games/truth_dare_screen.dart` — `TruthDareScreen`, the synced turn-based Truth-or-Dare.
- `lib/features/games/truth_dare_deck.dart` — `TDType`/`TDTier` enums, `TDCard` (with `toJson`/`fromJson`), and `truthDareDeck` (a fixed hand-written deck). `drawCard()` filters by type+tier.
- `lib/features/games/game_content.dart` — the **content engine**: opener × core combinatorics that multiplies a few dozen hand-written cores into hundreds of variations per tier. Exposes `drawTD()`, `markTDSeen()`, plus `wyrPool` (Would You Rather) and `nhiePool` (Never Have I Ever) lists. This is what the live TD screen actually draws from (not the small static `truthDareDeck`).
- `lib/features/games/synced_card_game_screen.dart` — `SyncedCardGameScreen`, a generic "same card on both phones" screen reused for WYR and NHIE.
- `lib/features/games/no_repeat_bag.dart` — `NoRepeatBag`, the persistent shuffle-bag.
- `lib/features/games/game_chat_panel.dart` — `GameChatPanel`, the embedded live answer strip.
- Routes wired in `lib/core/router.dart`: `/app/games/truth-dare`, `/app/games/would-you-rather` (builds `SyncedCardGameScreen` with `cards: wyrPool`, `gameKey: 'wyr'`), `/app/games/never-have-i-ever` (`cards: nhiePool`, `gameKey: 'nhie'`).

**Truth or Dare (synced turn-based).** On a player's turn they pick **Truth** or **Dare**; `drawTD(type, tier)` pulls the next card at the chosen heat tier and both phones show the identical card. State held locally: `_turn`, `_round`, `_tier`, `_card`. The turn-holder confirms ("Ho gaya — ab <partner> ki baari") to pass the turn (`_next` flips `_turn` to `_partnerUid`, clears the card, increments round), or re-draws ("naya card do"). `_myTurn` gates interaction; the other phone shows a wait/loading view.
- Three **heat tiers** (`TDTier`): `cute` (🌸 wholesome), `flirty` (😏 teasing), `spicy` (🔥 intimate/adult). Tier is chosen via `ChoiceChip`s and broadcast so both pick from the same level. Spicy photo/voice dares deliberately bake in consent (every such dare says "jitna comfortable ho" / "jitna chaho").
- **Realtime:** channel `game_td:<coupleId>` with two broadcast events:
  - `state` — full snapshot `{from, turn, tier, round, card}` sent on every change (`_broadcast`). Receiver ignores its own echo (`payload['from'] == _myUid`), rebuilds `TDCard.fromJson`, and calls `markTDSeen` so the no-repeat stays shared across phones.
  - `sync` — on (re)subscribe, after a 900 ms timer the screen sends `{from}`; any peer already in a started game responds by re-broadcasting `state`, so a phone that joins/reconnects mid-game catches up.

**Would You Rather / Never Have I Ever (synced shuffle-cards).** `SyncedCardGameScreen` shows one shared card; **either** partner can hit "Agla card (dono ke liye)" which draws from the bag and pushes it to the other phone. No turn ownership.
- **Realtime:** channel `gcard:<gameKey>:<coupleId>` (`gameKey` = `wyr` or `nhie`) with events `card` (`{from, text}`) and `sync` (same resubscribe-and-rebroadcast pattern as TD). On receiving a `card`, the peer marks it seen in its bag so the no-repeat is shared.

**No-repeat bag.** `NoRepeatBag` (`no_repeat_bag.dart`) is a persistent shuffle bag in **SharedPreferences** under key `nrb_<key>`. `draw(key, pool)` deals each prompt once before any repeat, then clears and reshuffles when exhausted. `markSeen(key, item)` is called when the *partner* draws so the same prompt won't reappear on this device either — the no-repeat is effectively shared across both phones. Per-pool keys: TD uses `td_<type>_<tier>`; the card games use `card_wyr` / `card_nhie`.

**Game chat panel.** `GameChatPanel` is an in-game **live answer strip** embedded under every game. Channel `gchat:<gameKey>:<coupleId>`, event `msg` (`{from, name, text}`). It is **ephemeral** — messages live only in memory (`_msgs`), are not persisted, and are explicitly described as in-game banter, not saved chat.

**Resume handling.** TD and the synced card screens add `realtimeResumed.addListener(_subscribe)` (from `core/realtime_resume.dart`) so the channel is torn down and re-subscribed after the app returns from background; the post-subscribe `sync` ping then re-pulls current state. Presence needs no code in the games: `PresenceRouteObserver` derives the room from the route.

**DB/security.** Games persist nothing server-side — all content is bundled client constants, all sync is transient broadcast, and the bag is local SharedPreferences. No tables, buckets, or RLS involved.

### Together (shared affection space)

**What it does / flow.** `TogetherScreen` (`lib/features/together/together_screen.dart`, route `/app/together`) is a shared avatar space. Each partner picks an emoji avatar; tapping a gesture (`cuddle 🫂`, `kiss 💋`, `hug 🤗`, `hold hands 🤝`, `head pat ✋`, `boop 👉`) animates the gesture on **both** screens — the two avatars lean together (`AnimatedAlign`) and the action emoji blooms with drifting hearts (`_MomentBurst`).

**Data flow / realtime.** Channel `together:<coupleId>`, broadcast event `moment` (`{action}`). Sender plays locally and broadcasts; receiver plays the same action. Avatars are loaded/saved via `PresenceService` (`lib/core/services/presence_service.dart`): `fetchMine`/`fetchPartner` read the **`presence`** table and `setAvatarEmoji` upserts the `avatar_emoji` column — so the chosen avatar persists per user and the partner sees it. No gesture history is stored (the burst list is in-memory only).

### Watch Together

**What it does / flow.** `WatchTogetherScreen` (`lib/features/watch/watch_together_screen.dart`, route `/app/watch`) lets a couple paste a YouTube link (movie/music video/playlist) and watch in loose sync via `youtube_player_flutter`. Whoever touches the controls drives; the other follows. Paste support is robust (clipboard button + `YoutubePlayer.convertUrlToId`).

**Realtime/sync.** Channel `watch:<coupleId>`, broadcast event `watch` (`{from, videoId, playing, pos}`). A 2.5 s heartbeat timer re-broadcasts state; local play/pause toggles push immediately (`_onControllerChange`). On receiving, `_applyingRemote` guards against feedback loops, it loads the video if `videoId` differs, **re-seeks only when drift > 2500 ms**, and matches the play/pause state. No persistence.

### Heartbeat ("Feel My Heartbeat")

**What it does / flow.** `HeartbeatScreen` (`lib/features/heartbeat/heartbeat_screen.dart`, route `/app/heartbeat`) reads your pulse via the back camera + torch (fingertip over lens) and makes your partner's phone throb with your real heartbeat in real time, including a haptic tap on each of their beats.

**Key files.** `lib/features/heartbeat/ppg_detector.dart` — `PpgDetector`, a photoplethysmography detector: it's fed average luma-plane brightness per frame (`_onFrame` samples every 16th byte of `image.planes[0]`), keeps a ~10 s rolling window, finds beats as local maxima above the mean with a refractory gap (≤180 BPM), and estimates BPM from the average of the last beats (clamped 40–200). The camera runs at `ResolutionPreset.low`, `yuv420`, with `FlashMode.torch` (gracefully tolerated if torch is blocked).

**Realtime.** Channel `heartbeat:<coupleId>`, broadcast event `hb` with three payload shapes: `{from, bpm}` (number to show), `{from, beat: true}` (triggers the partner's pulse animation + `HapticFeedback.lightImpact`), and `{from, stopped: true}`. No persistence — purely live.

### Daily Question (daily prompt)

**What it does / flow.** `DailyPromptScreen` (`lib/features/daily_prompt/daily_prompt_screen.dart`) shows one LDR-flavoured question per couple per day; you write your answer, and **both** answers are revealed only once both partners have responded (otherwise a "waiting on <partner>" / locked card).

**Key files & data flow.** `lib/features/daily_prompt/daily_prompt_repository.dart`:
- `promptPool` is a curated English question list; `promptForDay(date)` is **deterministic** (`promptPool[dayOfYear % length]`) so both partners get the same question without coordinating.
- `ensureToday()` idempotently creates/fetches a row in **`daily_prompts`** (`couple_id`, `prompt_text`, `scheduled_date`) — the first partner to open it inserts.
- `responsesFor(promptId)` reads **`prompt_responses`**; `upsertMyResponse()` upserts `{prompt_id, user_id, response_text, responded_at}`. The reveal gate (`bothAnswered`) is computed client-side. No realtime — refresh/`RefreshIndicator` re-pulls.

### Rituals

**What it does / flow.** `RitualsScreen` (`lib/features/rituals/rituals_screen.dart`, route `/app/rituals`) lists scheduled rituals (goodnight, good morning, weekly highs-&-lows, custom) and a `CreateRitualSheet` (`create_ritual_screen.dart`) to add one with a type, a delivery time picked in the user's local timezone (stored as UTC), and a message. Swipe-to-delete via `Dismissible`.

**Data flow.** `lib/features/rituals/ritual_repository.dart` is CRUD over the **`rituals`** table (`couple_id`, `type`, `message`, `deliver_at`, `delivered`), ordered by `deliver_at`. **Important caveat noted in code:** this is a **v1 preview — actual scheduled delivery / push is NOT implemented yet**; the screen only persists and displays the chosen time (a cron/edge-function worker is planned). The list deliberately orders by `deliver_at` because the table has no `created_at`.

### Reasons I Love You (the jar)

**What it does / flow.** `ReasonsScreen` (`lib/features/reasons/reasons_screen.dart`, route `/app/reasons`) is a shared jar of "reasons I love you" notes both partners add. One is **featured each day** (`_featured` = `_reasons[dayOfYear % length]`, stable for the day). Your own notes show 💗 and are deletable; the partner's show 💛.

**Data flow / realtime.** `lib/features/reasons/reasons_repository.dart` over the **`love_reasons`** table (`couple_id`, `author`, `text`, `created_at`). Unlike most keepsakes, this one uses a **Postgres-changes** subscription (`subscribe()` → channel `love_reasons:<coupleId>`, `PostgresChangeEvent.all` filtered by `couple_id`) so new reasons from the partner appear live.

### Timeline (visit history & countdown)

**What it does / flow.** `TimelineScreen` (`lib/features/timeline/timeline_screen.dart`, route `/app/timeline`) shows the couple's visit history; a bottom sheet adds a past visit. `lib/features/timeline/timeline_repository.dart` reads/writes the **`visits`** table (`couple_id`, `start_date`, `end_date`, `location`, `is_upcoming`) ordered by `start_date`; `addPastVisit()` always sets `is_upcoming = false` so a back-dated visit doesn't hijack the next-reunion countdown. Models via `core/models.dart` (`Visit`).

### Time Capsule

**What it does / flow.** A "seal little surprises now, open them together later" feature. `CapsuleCreateScreen` (`/app/capsule/new`) names a capsule and chooses an unlock mode: **proximity** ("when we're together" 🧲), **date** 📅, or **both** ✨. `CapsuleFillScreen` (`/app/capsule/fill`) adds **notes, photos, and voice memos** — and you genuinely **cannot read items back** while sealed (you only see blurred locked silhouettes + a count). `CapsuleDetailScreen` (`/app/capsule/view`) shows the sealed state, runs the unlock check, plays an opening "ceremony" animation, then reveals all items at once.

**Key files**
- `lib/features/capsule/capsule_repository.dart` — `Capsule` / `CapsuleItem` models, `CapsuleUnlockMode` (proximity/date/both), `CapsuleItemType` (note/photo/voice), and all data access.
- `lib/features/capsule/proximity_service.dart` — `ProximityService`, the privacy-preserving "are we together?" check.
- `capsule_create_screen.dart`, `capsule_fill_screen.dart`, `capsule_detail_screen.dart`, `capsule_list_screen.dart`.

**Data flow / DB.**
- **Tables:** `capsules` (`couple_id`, `title`, `unlock_mode`, `unlock_date`, `unlocked_at`, `created_by`) and `capsule_items` (`capsule_id`, `author_id`, `type`, `content_text`, `media_url`).
- **Storage bucket:** `capsule-media` (constant `_bucket`); media uploaded to path `<coupleId>/<capsuleId>/<type>_<rand>.<ext>`. Playback/photo display uses **1-hour signed URLs** (`signedUrl`, `createSignedUrl(path, 3600)`).
- **RPCs (server-enforced):** `capsule_seal_summary(p_capsule_id)` returns only per-type counts (no content) to power the blurred silhouettes; `unlock_capsule(p_capsule_id)` performs the server-side unlock (returns `too_early` for date/both if not yet due); the repo comment notes full items are **un-SELECTable via RLS until `unlocked_at` is set**.
- **Realtime:** `subscribe()` → channel `capsules:<coupleId>` (Postgres-changes on `capsules` filtered by `couple_id`), so when one partner opens a capsule the unlock flips live on both phones (`CapsuleDetailScreen._reload` then auto-runs the reveal ceremony).

**Proximity unlock (privacy-preserving).** `ProximityService` **never persists coordinates server-side**. Each partner fetches their own **coarse** location (`geolocator`, `LocationAccuracy.low`) and broadcasts it every 4 s over the **ephemeral** channel `capsule_proximity:<coupleId>` (event `loc`, `{uid, lat, lon}`). Each device computes the **Haversine** distance locally; `withinRange` when ≤ `thresholdMeters` (default 100 m). Coordinates exist only in memory on the two phones, only while both have the screen open. For proximity/both modes the client verifies "we're together" first, then calls the server `unlock_capsule` RPC. Permission/location-services blocks are surfaced with a settings shortcut (`Geolocator.openAppSettings`).

**Media libs used:** `image_picker` (photos), `record` (voice memos, `.m4a`/`audio/mp4`), `just_audio` + `path_provider`, `geolocator`; ceremony/reveal animations via `flutter_animate`.

### Private Vault

**What it does / flow.** `VaultGateScreen` (`lib/features/vault/vault_gate_screen.dart`, route `/app/vault`) guards a **personal, owner-only** vault behind a **4-digit PIN** (with optional biometric unlock via `local_auth`). First use sets+confirms a PIN; thereafter it asks every time and **auto-locks the moment the app leaves the foreground** (`didChangeAppLifecycleState`). After unlock, `VaultScreen` lists private notes (add via FAB; long-press to delete; explicit lock button).

**Key files & security.** `lib/features/vault/vault_repository.dart`, `vault_gate_screen.dart`, `vault_screen.dart`, `pin_pad.dart` (`PinPad`).
- **Table:** `personal_vault_items` (`owner_id`, `type`, `content`, `media_url`, `created_at`) — items are fetched filtered by `owner_id == currentUserId`; this is the **personal** vault, explicitly **not couple-scoped** ("Your partner can never open this").
- **PIN is server-side, never compared on-device.** RPCs: `has_vault_pin`, `set_vault_pin(p_pin)`, and `verify_vault_pin(p_pin)` which returns one of `ok | wrong | locked | no_pin`. Hashing/verification + lockout run server-side (bcrypt via pgcrypto per the repo comment), with a **15-minute lockout** after too many wrong tries. The gate maps server errors (`invalid_pin`, `not_authenticated`, `gen_salt`/missing function) to friendly messages.

### Cross-cutting notes

- **Session source:** every screen reads `coupleId`/`myUid`/`partner` from `sessionProvider` (`core/session_provider.dart`).
- **Realtime patterns:** the *live/social* features (Games, Together, Watch, Heartbeat, capsule proximity) use **broadcast** channels (no DB writes); the *persisted-but-live* features (Reasons, Capsule unlock) use **Postgres-changes** subscriptions; Daily Prompt, Rituals, Timeline, Vault are pull/refresh only.
- **Buckets:** only the Time Capsule uses Storage (`capsule-media`, signed URLs). Avatars (Together) are stored as an emoji string in the `presence` table, not a bucket.
- **No `.env` keys** are specific to these features beyond the app's shared Supabase config; the Watch feature depends on `youtube_player_flutter`, Heartbeat/Capsule on device permissions (camera, microphone, coarse location).

---

## 7. Calls · Ambient · Auth · Settings · Shell · Intro

This section covers the launch intro video, the authentication + couple-pairing onboarding funnel, the bottom-nav app shell and side drawer, the settings surface, the three "ambient presence" features (SkyBridge, Breath Sync, Countdown), and the full 1:1 WebRTC call stack with its push-to-ring pipeline.

### Launch intro video

- **Files:** `lib/features/intro/intro_video_screen.dart`, route `/` in `lib/core/router.dart`.
- **What it does:** `IntroVideoScreen` plays the bundled `assets/videos/intro.mp4` full-screen on app launch via `video_player` (`VideoPlayerController.asset`, non-looping, volume 0.6). A top-right "Skip" button and a tap anywhere (`GestureDetector` + `HitTestBehavior.opaque`) call `_advance()`; the video also auto-advances when `position >= duration`. Both paths call `context.go('/signin')`. Branding overlay shows "Tethered" in the Fraunces font with the tagline "together, even from here".
- **Routing note:** `/` is special-cased in the router `redirect` (returns `null`) so the intro renders without being bounced by auth gating; after `_advance()` navigates to `/signin`, the redirect logic takes over and sends already-authenticated users on to `/app`. (The screen's doc comment mentions a SharedPreferences "play once" flag, but the implemented version always renders at `/` and relies on the redirect to move signed-in users past it.)

### Auth + onboarding funnel

The router (`lib/core/router.dart`, `buildRouter`) drives a strict funnel using `sessionProvider` state, re-evaluated on every navigation via a `_SessionListenable` bridged to `refreshListenable`:

1. Not authenticated → only `/signin` and `/signup` are reachable (else redirect to `/signin`).
2. Authenticated but `profile == null || !profile.isOnboarded` (where `isOnboarded` = `birthDate != null`) → `/welcome`.
3. Onboarded but `couple == null` → `/couple`.
4. Paired but `!profile.genderSet` → `/role-setup`.
5. Fully set up → kept out of auth/onboarding routes; everything funnels to `/app`.

**Key screens / files:**
- `welcome_page.dart` (`/welcome`) — step 1: collects display name, timezone (auto-detected from `DateTime.now().timeZoneName` against `commonTimezones`), and date of birth. Enforces **18+** (`_isUnderage`, `_age`); `lastDate` of the date picker is `now.year - 13`. Writes via `SupabaseRepository.upsertProfile(...)` (formats DOB to `YYYY-MM-DD`), reloads the session, then `context.go('/couple')`.
- `sign_in_page.dart` / `sign_up_page.dart` (`/signin`, `/signup`) — email+password via `SupabaseRepository.signIn` (`auth.signInWithPassword`) and `signUp` (`auth.signUp`). Sign-up shows an email-confirmation notice. Errors run through `friendlyAuthError` (`auth_errors.dart`), which maps raw Supabase/`AuthRetryableFetchException`/socket strings to actionable copy (network, invalid credentials, unconfirmed email, already-registered, weak password). `SignInPage` honors a `?redirect=` query param.
- `couple_page.dart` (`/couple`) — step 2, partner linking. **Create:** `SupabaseRepository.createPairingInvite()` (RPC `create_pairing_invite`, default `p_ttl_minutes: 1440`) returns a fresh code + expiry; `_InviteReveal` displays the code, copy-code / copy-link buttons, and expiry. **Join:** `SupabaseRepository.redeemPairingInvite(code)` (RPC `redeem_pairing_invite`) validates expiry / single-use / capacity server-side, mapping `invalid_code`, `expired`, `already_used`, `couple_full`, `already_paired` to friendly `StateError`s. Code input is forced uppercase + `[A-Z0-9]` (`UpperCaseTextFormatter`).
- **Deep link / invite link:** `inviteLinkFor(code)` builds `tethered://join?code=$code`. `main.dart` `_initDeepLinks` / `_handleLink` (using `app_links`, both `getInitialLink` and `uriLinkStream`) parses `tethered://join`, stores the uppercased code in `pendingInviteCodeProvider` (`lib/core/providers.dart`), and routes to `/couple`. `CouplePage` reads/listens that provider to pre-fill the code field.
- `role_setup_screen.dart` (`/role-setup`) — one-time per-user gender pick (male/female) via `SupabaseRepository.setGender` (writes `profiles.gender` + `gender_set = true`); gates the Cycle feature. Reloading the profile flips `genderSet` and the router moves the user to `/app`.
- **Shared widgets:** `auth/widgets/alert_banner.dart` (`AlertBanner`, error/info tones), `auth/widgets/labeled_field.dart` (`LabeledField`). `couple_page` and `role_setup` use the "Velvet Aurora" components (`EmberBackground`, `GlassPanel`, `GlowButton`, `LoveTextField`).

**Tables/RPCs:** `profiles` (upsert + targeted updates), `couples`, plus SECURITY-DEFINER RPCs `create_pairing_invite`, `redeem_pairing_invite`, `create_couple`, `join_couple_by_code`, `leave_couple`. Server-side RPCs handle invite-code generation/uniqueness and the 2-member cap (the client never reads `couples` under RLS immediately post-insert).

### App shell + drawer

- **Files:** `lib/features/shell/app_shell.dart` (`AppShell`), `lib/features/shell/app_drawer.dart` (`AppDrawer`), route `/app`.
- **Bottom nav:** A `NavigationBar` over six screens (`HomeScreen`, `ChatScreen`, `CountdownScreen` labeled "Reunion", `SkyBridgeScreen` labeled "Sky", `BreathSyncScreen` labeled "Breath", `CloserScreen`). The **Closer** tab is only shown when `profile.isAdult` (`showCloser = isAdult`); its icon reflects `couple.modestMode` (locked vs. open). Selected tab index lives in `shellTabProvider`; the shell rebuilds only on `select`-scoped reads of `isAdult` / `modestMode` / tab index to avoid rebuilding on every presence/typing tick. A `BannerAdSlot` is shown only on the secondary tabs (Countdown/Sky/Breath, `selected >= 2 && !isCloserTab`).
- **Drawer** (`AppDrawer`, opened via `rootScaffoldKey`): shows partner presence (`_PresenceDot` colored from `partner.presenceStatus`: asleep/busy/online) and timezone, plus push-route tiles to Capsule, Vault, Touch, Together, Reasons I Love You, Care Reminders, Watch Together, Cycle, Feel My Heartbeat, Games, Rituals, Daily Question, Timeline, and Settings, and a Sign-out button (`SupabaseRepository.signOut` + `sessionProvider.signOut`).
- **Always-on realtime orchestration (the shell is the hub for Reach + Calls):**
  - Subscribes the **Reach** channel via `ReachRepository.subscribe(couple.id, _onReach)` and registers FCM (`FcmService.registerToken()`) once ready; also prompts the one-time full-screen-intent permission (`FsiPermission.promptIfNeeded`, Android 14+).
  - On `AppLifecycleState.resumed`, `_reconnectRealtime()` force-cycles the realtime socket (`realtime.disconnect()` → `connect()`) because Android doze kills sockets silently. When the socket reopens, `realtimeResumed` fires `_rearmAlwaysOn()`, which re-subscribes Reach, calls `callControllerProvider.reconnect()`, and `sessionProvider.reconnectPresence()`.
  - `pendingReach` / `pendingCall` (`ValueNotifier`s from `FcmService`) are listened to; `_onPendingCall` hands an incoming push to `CallController.handlePendingCall(callId, fromName, video)`.
  - A `ref.listen(callControllerProvider)` detects the idle→active transition (tracking `_lastCallState` manually since the `ChangeNotifierProvider` instance is stable) and pushes `/call` to surface the call screen on an incoming ring or outgoing call.

### Settings

- **File:** `lib/features/settings/settings_screen.dart` (`SettingsScreen`), route `/app/settings`.
- **Profile:** tappable avatar (`PhotoPickerService` → uploads to the `couple_media` storage bucket at `<coupleId>/avatars/<uid>_<ts>.jpg`, then `SupabaseRepository.setAvatarUrl`), display name + status (`updateMyProfile` → `profiles`), and gender (`setGender`).
- **Timezone:** searchable picker over `commonTimezones` (`updateMyProfile(timezone:)`).
- **Location sharing:** modal with `off` / `city` / `precise`. Reads current mode from `PresenceService.fetchMine(couple.id)`; `off` → `PresenceService.setSharingMode(..., 'off')` + `BgLocationService.disable()`; otherwise `LocationService.shareOnce(couple.id, mode)` and, for `precise`, `BgLocationService.enable()`.
- **Reach alerts:** opens system full-screen-intent settings (`FsiPermission.openSettings`).
- **Privacy — Closer toggle:** a `SwitchListTile` bound to `!couple.modestMode`. Enabling shows a confirm dialog, then `SupabaseRepository.setModestMode(coupleId, enabled: !newValue)` (updates `couples.modest_mode`) and best-effort `publishMyPublicKey()` (upserts to `partner_keys`; note E2EE is now a documented no-op — `fetchPartnerPublicKey` returns `'plaintext-v1'`).
- **Security — biometric app lock:** `SwitchListTile` driven by `AppLock` (`lib/core/services/app_lock.dart`). Enabling requires a 4-digit PIN fallback (`showAppLockPinSetup`) so there's always a way in even without biometrics; disabling requires PIN verify (`showAppLockPinVerify`). Lock is enforced in `main.dart` lifecycle (`AppLock.lockIfEnabled` on background, re-prompt on resume).
- **Partner:** "Remove partner" → confirm dialog → `SupabaseRepository.leaveCouple()` (RPC `leave_couple`, data preserved) → `/couple`.
- **Account — sign out:** `FcmService.clearToken()` (drops this device's push token while still authed) → `sessionProvider.signOut()` → `/signin`. Version footer reads "Tethered · v0.1.0".

### SkyBridge (shared sky)

- **File:** `lib/features/skybridge/sky_bridge_screen.dart` (`SkyBridgeScreen`), Sky tab.
- **What it does:** A purely client-side, no-backend ambient view. Takes the single shared instant `DateTime.now().toUtc()` and renders two `_SkyCard`s — yours and your partner's — each converting that instant into the respective wall-clock via `TzHelper.inZone(utcMoment, timezone)` and bucketing the local hour into seven gradient/emoji/poetic bands (`_describeSky`: deep night, dawn, morning, midday, golden hour, dusk, night). A `_TimeDifferenceCard` shows the offset using `TzHelper.offsetHours(tzA, tzB)`. Shows a "Waiting for your partner to join…" empty state until both profiles exist. No tables/channels/storage.

### Breath Sync

- **File:** `lib/features/breath/breath_sync_screen.dart` (`BreathSyncScreen`), Breath tab.
- **What it does:** A shared 4-7-8 breathing pacer (`BreathPattern` constants from `core/config.dart`). Tapping **Begin** calls `_beginCycle`, which records `_cycleStart` (ms since epoch) and `_broadcastStart`.
- **Data flow:** `_broadcastStart` **inserts** a row into the `breath_events` table (`couple_id`, `user_id`, `started_at` ms). The screen subscribes to realtime channel `breath:<coupleId>` via `onPostgresChanges` (INSERT on `public.breath_events`, filtered `couple_id == coupleId`). When a partner's insert arrives (`user_id != currentUserId`), `_onPartnerStartedCycle` marks `_partnerActive` and, if the event is within one cycle of "now" (stale-event guard), starts the local animation at the correct offset (`_beginCycleFromOffset`) so both phones pulse in unison. The animated `_BreathOrb` scales with the `AnimationController` through inhale → hold → exhale.
- **Backend:** table `breath_events`; realtime postgres-changes channel `breath:<coupleId>`. No storage.

### Countdown ("Reunion")

- **Files:** `lib/features/countdown/countdown_screen.dart` (`CountdownScreen`), `lib/features/countdown/widgets/set_visit_sheet.dart` (`SetVisitSheet`), Reunion tab.
- **What it does:** Loads the next visit via `SupabaseRepository.fetchNextVisit(couple.id)`; a 1-second `Timer.periodic` ticks down days/hours/minutes/seconds to the visit's `startDate` (UTC). Shows the target in the **partner's** timezone (`TzHelper.inZone`), a `_TogetherState` ("You're together") once the date passes, and an `_EmptyState` prompting to set a date. `SetVisitSheet` picks a date (default +30 days, max +3 years) and optional location, saving via `SupabaseRepository.setNextVisit(coupleId, startDate, location)`.
- **Backend:** the couple "visits" table (read via `fetchNextVisit`, write via `setNextVisit`); timezone from each `profiles.timezone`.

### WebRTC 1:1 voice/video calls

- **Files:** `lib/features/call/call_controller.dart` (`CallController`, exposed as `callControllerProvider`), `lib/features/call/call_screen.dart` (`CallScreen`, route `/call`), `lib/features/call/call_pill.dart` (`CallPill`), `lib/features/call/call_foreground.dart` (`CallForegroundService`). Uses `flutter_webrtc`.
- **Signalling — Supabase realtime broadcast:** All SDP/ICE/hangup signalling rides a single broadcast channel `call:<coupleId>` (`SupabaseService.client.channel('call:$id').onBroadcast(event: 'signal', ...)`). Messages are `{from: <uid>, type: <offer|answer|ice|hangup>, data: {...}}`; the controller ignores its own echo (`payload['from'] == _myUid`). `init()` subscribes on provider creation; `reconnect()` re-subscribes after a socket reset (called by the shell's `_rearmAlwaysOn`).
- **Call states:** `CallState { idle, calling, ringing, connected, ended }`. `startCall({video})` opens media (`getUserMedia`), creates the peer connection, sends an `offer` broadcast, **and** persists the offer (see below). `accept()` sets the remote offer, flushes queued ICE, creates/sends an `answer`. `decline()` / `hangup()` send `hangup` and tear down. `_teardown` disposes the stream/PC, resets flags, and settles back to `idle` after 300 ms.
- **ICE / STUN / TURN config (`_rtcConfig`):** Always includes Google STUN (`stun.l.google.com:19302/1/2`) plus Cloudflare STUN. TURN is **configurable via `.env`**: if `METERED_TURN_HOST` / `METERED_TURN_USERNAME` / `METERED_TURN_CREDENTIAL` are all set, it adds that relay over UDP:80, TCP:80, UDP:443, and **TURN-over-TLS/TCP on 443** (`turns:$host:443?transport=tcp`) for networks that block UDP; otherwise it falls back to the public openrelay TURN (often down). `sdpSemantics: unified-plan`. The comment notes symmetric mobile-carrier NATs require a working TURN relay.
- **Resilience for closed/backgrounded callees (ICE re-send, reconnect, timeout):**
  - `_localCandidates` are retained and **re-sent** when the answer arrives (`_applyAnswer`), because a previously-closed callee misses the first ICE trickle.
  - Incoming ICE before the remote description is set is queued in `_pendingRemote` and flushed via `_flushPending`.
  - `_startConnectTimeout` (35 s) ends the call cleanly if it never reaches `connected`, so it doesn't hang on "Calling…/Connecting…".
- **FCM call-push so a closed app rings:** On `startCall`, `_insertInvite` writes a durable row to the **`call_invites`** table (`couple_id`, `caller_id`, `callee_id`, `offer_sdp`, `video`). A backend insert trigger / `call-notify` push fires the FCM ring. `FcmService` (`lib/core/services/fcm_service.dart`) handles `type == 'call'` data messages (foreground, opened-app, and cold-start tapped notification via the `call|callId|fromName|video` payload), populating the `pendingCall` `ValueNotifier` with a `CallTap`. The shell's `_onPendingCall` calls `CallController.handlePendingCall(callId, fromName, video)`, which calls `reconnect()`, fetches the stored offer from `call_invites` by id, and presents it as `ringing`. The dedicated `call_service`/call notification channel is created in `FcmService.init` (`buildCallChannel()`).
- **In-call foreground service:** `CallForegroundService` (`call_foreground.dart`) starts an Android foreground service of type `microphone` (via `flutter_foreground_task`, `serviceId: 512`, channel `call_service`, "On call with <peer>" notification) so call audio survives backgrounding / screen-off. Started in `startCall`/`accept`, stopped in `_teardown`. The task handler is intentionally minimal — WebRTC audio runs in the main isolate; the service just keeps the process alive (best-effort, never breaks the call).
- **UI:** `CallScreen` is a `Stack` showing full-screen remote video (video calls, when connected), a voice/pre-connect centerpiece (avatar + name + status), a local PIP preview, mic/cam/flip/end controls (`switchCamera` via `Helper.switchCamera`), and accept/decline buttons while ringing. Backing out **minimizes** rather than ends (`PopScope` → `setMinimized(true)`); the screen auto-pops when state returns to `idle`. `CallPill` is an app-wide floating "tap to return to call" pill shown while a call is active and `minimized` (over any screen), with a quick hang-up button; tapping it clears minimized and pushes `/call`.
- **Backend touchpoints:** realtime broadcast channel `call:<coupleId>`; table `call_invites`; FCM `call-notify` push (backend edge function — not present in this repo); `.env` keys `METERED_TURN_HOST` / `METERED_TURN_USERNAME` / `METERED_TURN_CREDENTIAL` (currently blank in `.env`, so the openrelay fallback is in effect).

### Config / .env keys referenced by this area

- `NEXT_PUBLIC_SUPABASE_URL` = `https://sopictusdonlvuezmfep.supabase.co`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (Supabase client init).
- `METERED_TURN_HOST`, `METERED_TURN_USERNAME`, `METERED_TURN_CREDENTIAL` (optional TURN relay for calls; loaded via `flutter_dotenv` `dotenv.maybeGet`).
- Asset: `assets/videos/intro.mp4` (launch intro). Deep-link scheme: `tethered://join?code=…`.

### Security / RLS notes

- Pairing and couple lifecycle go through SECURITY-DEFINER RPCs (`create_pairing_invite`, `redeem_pairing_invite`, `create_couple`, `join_couple_by_code`, `leave_couple`), which enforce invite expiry, single-use, and the 2-member cap server-side rather than trusting the client; the client deliberately avoids reading `couples` under RLS right after insert.
- Age gate (18+) is enforced client-side at `/welcome` and DOB is stored on `profiles` ("never shared" per UI copy).
- Location sharing is opt-in per-user (`off`/`city`/`precise`) with the UI asserting "Only your partner can ever see this"; `precise` additionally enables a background-location service.
- App lock always requires a PIN fallback alongside biometrics so the user can never be locked out.
- The "Closer" intimacy module is gated behind both `profile.isAdult` (tab visibility) and the per-couple `modest_mode` flag; the in-app copy still claims end-to-end encryption, though `SupabaseRepository.fetchPartnerPublicKey` documents E2EE as removed (returns `'plaintext-v1'`, key derivation is a no-op).
- FCM tokens are cleared from `profiles` on sign-out so a signed-out device stops receiving Reach/call pushes; tokens self-heal by re-registering on every resume (notify functions null stale `UNREGISTERED` tokens server-side).

---

## 8. Build, Run, Configure & Deploy

### Project layout
| Path | What |
|---|---|
| `E:\LDR\mobile` | The Flutter app — **always build from here** |
| `E:\LDR\mobile\lib` | Dart source (`core/` foundation, `features/<module>/`) |
| `E:\LDR\mobilessets` | `.env`, `emoji/` (Noto Lottie), `videos/intro.mp4` |
| `E:\LDR\supabaseunctions` | Edge functions (Deno/TypeScript) |

### Prerequisites
- Flutter SDK (this machine: `C:lutterlutter`), Android SDK + `adb`.
- `mobile/.env` populated (keys below).
- `mobile/android/app/google-services.json` (Firebase project for FCM).

### `.env` keys (`mobile/.env`, bundled as a Flutter asset)
| Key | Purpose |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL |
| *(anon key — see `MilesConfig.supabaseAnonKeyKey`)* | Supabase anon/public key |
| `GIPHY_API_KEY` | GIF picker / fling (free key at developers.giphy.com → Create App → API) |
| `METERED_TURN_HOST` · `METERED_TURN_USERNAME` · `METERED_TURN_CREDENTIAL` | WebRTC **TURN** relay for calls (free metered.ca account) — required for call media on mobile NATs |
| `GOOGLE_MAPS_3D_KEY` | Legacy (the 3D map is now keyless MapLibre — kept for the title bar only) |

### Build & install
```bash
cd /e/LDR/mobile                 # ALWAYS — building from E:\LDR fails with "No pubspec.yaml"
flutter pub get
flutter build apk --debug        # test build → build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release      # send-ready (~119 MB; bundles intro.mp4)
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am force-stop com.miles.miles
adb shell am start -n com.miles.miles/.MainActivity
```

### Supabase edge functions
Three Deno functions deployed to project `sopictusdonlvuezmfep`: **`reach-notify`**, **`care-notify`**, **`call-notify`**. Each builds a Google OAuth token from a service account (RS256 JWT) and sends an FCM HTTP v1 **data** message; the app's background isolate renders the notification (full-screen intent for Reach/Calls). Required function secrets: `FCM_SERVICE_ACCOUNT` (service-account JSON) + `FCM_PROJECT_ID`. They are invoked by **Postgres triggers** that `net.http_post` (pg_net) the inserted row from `reach_events`, the care-nudge table, and `call_invites` respectively.

### Operational notes & gotchas
- **Build dir:** only from `E:\LDR\mobile`; the shell CWD drifts to `E:\LDR` and the build then fails with *“No pubspec.yaml.”*
- **APKs are built on request only** — never auto-built.
- **Calls** need: a real TURN (`METERED_TURN_*`), **both phones on the same build**, and an FCM token registered (open the app + sign in once). A *closed* app rings only via the FCM call-push.
- **Cross-device sync:** the realtime/sync fixes only work when **both** partners are on the updated build.
- **Background location & background call-ring** are best-effort — OEMs (OnePlus/Vivo/Xiaomi) need the app **exempted from battery optimisation**.
- **Test devices:** IN2015 (OnePlus), Vivo, OnePlus 7.

---

*End of documentation.*
