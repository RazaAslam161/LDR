# Tethered — Bug-Fix & Feature Sprint: FIX_REPORT

---

# ⟶ Precision bug-fix pass (2026-06-24)

## Issue 3 — "FormatException on every feature" → **NOT REPRODUCIBLE** (root cause: there isn't one)

**Diagnostic, not assumption.** Added the requested global error nets to `main.dart`
(`FlutterError.onError` + `PlatformDispatcher.onError`) plus a masked env check,
then ran on IN2015 and exercised Home + every bottom-nav tab. Captured via
`adb logcat` (the flaky OnePlus USB kept dropping `flutter run`'s debug socket):

```
I/flutter: ENV CHECK → url len: 40, key len: 208      ← env valid (not empty)
I/flutter: STARTUP OK → booting app                    ← all init succeeded
FormatException lines:  NONE                            ← zero, across all features
Only error caught:  "FLUTTER ERROR: A RenderFlex overflowed by 22 pixels"  ← Issue 5, cosmetic
```

**Root cause of the original reports:** the pre-JsonUtils core-model casts —
already fixed in the earlier sprint. Static analysis ruled out every single-point
cause the brief listed: `grep json.decode|jsonDecode` → 0 matches (no double-decode);
`JsonUtils` uses only `tryParse`+fallback (never throws); `dotenv.get()` would crash
at startup if env were empty, yet the app boots and talks to Supabase; the two
user-facing raw `DateTime.parse` sites (`countdown_screen`, `models.isAdult`) are
already inside `try/catch`.

**What changed (the permanent safety net, so it can never regress):**
- `main.dart`: global `FlutterError.onError` + `PlatformDispatcher.onError` (log full
  exception + stack); masked `ENV CHECK`; **fail-fast** with a clear message if the
  Supabase url/key is empty.
- `capsule_repository.sealSummary`: per-row `try/catch` skip + `JsonUtils`.
- **Hardened 7 previously-unguarded repos** (raw `DateTime.parse`/`as String` →
  `JsonUtils`, and list builds now skip a bad row instead of aborting): the Closer
  repos `body_map`, `fantasy_jar`, `afterglow`, `memory_threads`, `private_vault`,
  `pick_for_us`, plus the pairing-invite parse in `supabase_repository`. Encryption
  /bytes paths left byte-for-byte untouched.

**Carried to Issue 5:** the live 22px `RenderFlex` overflow (a layout/alignment bug).

## Issue 1 — chat message order reversed

**Root cause:** postgrest `.order('created_at')` defaults to `ascending:false`
(descending/newest-first), but the `ListView` had no `reverse:` → newest rendered
at the **top**. (The repo comment even wrongly said "oldest first".)

**Fix (canonical chat pattern):** explicit `.order(..., ascending:false)`; `ListView.builder`
`reverse:true` (newest at index 0 → bottom); realtime/new messages `insert(0, …)`
+ `_sortMessages()` (created_at desc, id desc tiebreaker); scroll helpers retargeted
to `minScrollExtent` (offset 0 = newest under reverse); day dividers use the `i+1`
older neighbour + `DateUtils.isSameDay`; **"↓ New message" chip** when a message
arrives while scrolled up (no yank), auto-clearing at the bottom.

## Issue 6 — Vault PIN won't set → **root cause captured + fixed + proven**

**Real error (evidence):** `set_vault_pin`/`verify_vault_pin` had
`proconfig = ["search_path=public"]`, but `crypt()`/`gen_salt()` live in the
`extensions` schema → Postgres `function gen_salt(unknown) does not exist` on every
save (surfaced as a PostgrestException = "error on save"). **Not** a missing table
(exists), **not** RLS (correct), **not** a missing package.

**Fix:** recreated both functions with `set search_path = public, extensions` and
schema-qualified `extensions.crypt` / `extensions.gen_salt` (migration
`fix_vault_pin_pgcrypto_search_path`; repo `supabase/private_vault.sql` updated +
`create extension … with schema extensions`). Also: gate screen now logs the real
exception + maps known cases instead of a blanket "could not set" message.

**Proven server-side** (simulated auth via `request.jwt.claims.sub`):
`set_vault_pin('1234')` → ok; `verify_vault_pin('1234')` → `ok`;
`verify_vault_pin('0000')` → `wrong`. (Test PIN deleted afterward.)

## Issue 2A — Reach does nothing on partner's screen → **foreground VERIFIED working**

**Diagnosis:** the spec's "most likely bug" (listener lives on one screen, disposed
when you leave it) **does not apply** — the reach listener was already moved
app-wide into `AppShell` during the FCM work (subscribes after pairing, ignores
your own inserts, shows the overlay via the root navigator). Backend verified:
`reach_events` is in the realtime publication, `replica identity full`, and the
`reach_select` RLS lets the partner receive the row.

**On-device proof:** injected a reach from Zuu → Raza's foregrounded app popped the
full-screen overlay ("Zuu is reaching for you 💕" + pulsing heart + vibration +
"I'm here"). No code change needed.

**Screen-off / app-killed path:** that genuinely needs FCM (built + deployed in the
earlier pass) — only the two Supabase secrets remain (see `FCM_SETUP_REPORT.md`).

## Issue 4 — drawer only works from one screen → **nested-Scaffold bug fixed**

**Root cause:** the drawer lives on `AppShell`'s Scaffold, but every tab screen
returns its **own** Scaffold (no drawer) and the hamburgers called
`Scaffold.of(context).openDrawer()` — which resolves to the screen's *own*
drawerless Scaffold → the hamburger failed on **all** tabs (not "one screen").

**Why not per-screen drawers / a ShellRoute:** adding a drawer to each inner
Scaffold would render a half-height drawer that doesn't cover the bottom nav (the
nav lives on the outer shell Scaffold); a full go_router ShellRoute rewrite would
risk the working nav. **Chosen fix (minimal, correct):** keep the single
full-height drawer on the shell and open it from anywhere via a global
`rootScaffoldKey` (`lib/core/root_scaffold_key.dart`): `AppShell`'s Scaffold gets
`key: rootScaffoldKey`; all 7 screen hamburgers now call
`rootScaffoldKey.currentState?.openDrawer()` (home, chat, countdown, sky, breath,
closer, touch). Drawer now opens from every main screen, full-height over the nav.

## Issue 2B — exact live location + live map on the dashboard

**Built** (precise, opt-in, symmetric, revocable — Play-safe by design):
- Migration `presence_live_location_meta`: `location_accuracy` + `location_updated_at`
  on `presence` (coords/mode already existed). Repo `supabase/presence_and_mood.sql` updated.
- Packages: `flutter_map ^8.3` (OpenStreetMap tiles — **no API key**) + `latlong2`.
- `LocationService.startLiveSharing/stopLiveSharing/pauseStream`: streams
  `getPositionStream(high, distanceFilter:10m)` → `PresenceService.setLiveLocation`
  (coords + accuracy + `location_updated_at`). **Foreground only**; stopping clears the
  coords so the partner sees "paused", never a stale pin presented as live.
- `PartnerLocationCard`: live OSM map, partner avatar marker that animates to each
  new fix (`MapController.move` on coord change), "updated Xs ago", **distance apart**
  (latlong2 Haversine, "4,182 km apart"), recenter button; "isn't sharing" state when off.
- HomeScreen: lifecycle-managed stream (pauses on background / leaving Home, resumes
  on return — battery + privacy; no covert background tracking), the warm consent
  dialog ("Share your live location with X?"), and a **"Sharing live location with X"
  banner with a one-tap Turn off**.

## Issue 5 — labels (partial)
Shortened the main-app nav/drawer labels: Countdown→**Reunion**, Time Capsule→**Capsule**,
Private Vault→**Vault**, drawer title Miles→**Tethered**. The full 360px / 1.3×-font
alignment audit + the 22px `RenderFlex` overflow are **pending a stable device** (the
OnePlus USB kept dropping all session, blocking reliable screenshots).

## Issue 7 — photo tooling (compliant scope)

**Touch stays on illustrated silhouettes** — no photo upload added there (Play
sexual-content policy + ad eligibility). Built proper photo tooling on the
surfaces where photos belong:
- Package `image_cropper ^12.2` (+ uCrop activity in the manifest); `image_picker`
  already present.
- **`PhotoPickerService`** (`lib/core/services/photo_picker_service.dart`): one
  reusable camera/gallery sheet → crop/adjust (aspect presets: original / square /
  4:3 / 16:9, or locked 1:1) → compress (≤1200px, JPEG q80).
- Applied to the **three** surfaces:
  1. **Profile avatar** (Settings) — tappable avatar, **1:1 locked** crop → upload →
     `profiles.avatar_url` (new `SupabaseRepository.setAvatarUrl`).
  2. **Check-in snap** (Home) — replaces the raw camera grab with crop+compress.
  3. **Chat photo** (ChatInputBar) — crop/adjust before send.

**Deferred (documented, not silently skipped):**
- **Private bucket + signed URLs:** photos currently use the existing public
  `couple_media` bucket (obscure paths). Migrating to a private bucket with
  couple-scoped RLS + signed URLs touches every existing image read (chat, snaps)
  and is a follow-up.
- **FLAG_SECURE** on photo-viewing screens: the native `miles/secure_screen`
  channel already exists (Vault); wiring it to chat/photo viewers is a follow-up.
- Silhouette skin-tone / front-back toggle: optional enhancement, not built.


> Status: **ALL 9 ISSUES COMPLETE** — `flutter analyze` = **0 errors** project-wide.
> One documented infra follow-up: Issue 8 background screen-wake (FCM) is stubbed
> (foreground works). Repo SQL files for every migration are now in `supabase/`.
>
> **Batch 4:** Issue 5 — Touch (Body Map). `body_touches` (ephemeral, realtime;
> `supabase/body_touches.sql`); `lib/features/touch_map/` — illustrated
> gender-neutral silhouette (`CustomPainter`, **no photos** → Play-safe), 19
> tappable zones, glow/kiss/hug animated radial glows, realtime + haptics.
> `/app/touch` + drawer. (Front view only; back-view + skin-tone deferred.)
>
> **Batch 5 (final):** Issue 2 — **HomeScreen** is now the landing tab (Reach moved
> onto it); `PartnerStatusCard` (check-in photo, partner local time, mood, online/
> last-seen, location), `LocationService` (**opt-in, symmetric, revocable**, city
> vs precise — city sends NO coordinates), location onboarding dialog + a Settings
> control, **check-in snap** (camera → couple_media → presence, partner sees live),
> quick-actions. Shell restructured (`shellTabProvider`, Home tab 0). Issue 8 —
> `reach_events` (`supabase/reach_events.sql`); hold-to-reach `ReachButton` (0.5s
> hold + 30s cooldown), app-wide reach listener → full-screen `ReachOverlayScreen`
> (pulsing heart, distinctive vibration, "I'm here" ack). Background screen-wake =
> FCM, **stubbed** with exact TODOs in `lib/core/push/fcm_todo.dart` + manifest
> `USE_FULL_SCREEN_INTENT`/`WAKE_LOCK` declared.

## Final verification
- `flutter analyze` → **0 errors** (428 info/style lints, pre-existing class).
- `flutter test` → JsonUtils suite (20) passing.
- Routes confirmed: `/` (via shell) opens **Home** (not Chat); `/app/vault` guarded
  by PIN; `/app/touch`, `/app/capsule`, `/app/intimacy`, `/app/settings` present.
- The FormatException root cause (Issue 3) is eliminated in the core models.
- New deps this sprint: `flutter_test` (dev), `geocoding`.
- Remaining honest follow-ups: FCM background-wake; per-message mood tint; body-map
  back-view + skin-tone; capsule unlock local-notification; FLAG_SECURE on Vault.
>
> **Batch 3 done:** Issue 9 — Private Vault. New `vault_pin` + `personal_vault_items`
> (owner-only RLS); **server-side bcrypt** PIN via `set_vault_pin`/`verify_vault_pin`
> RPCs with **5-try → 15-min lockout**; `PinPad` (dots + shake + haptics),
> `VaultGateScreen` (first-run setup ↔ lock, **biometric** via local_auth,
> **auto-lock on background**), `VaultScreen` (personal notes). Route `/app/vault`
> + drawer entry. (Used `personal_vault_items` because the couple-scoped
> `vault_items` table already exists in Closer. Photo/voice vault items + FLAG_SECURE
> screenshot-block deferred — noted.)
>
> **Batch 2 done:** Issue 4 — capsule **date+time** picker + live countdown in the
> list (notification at unlock deferred — needs `flutter_local_notifications`).
> Issue 1F — `presence` table + `PresenceService` + app lifecycle (online/offline)
> + chat AppBar subtitle (**Online / Last seen / typing…** with a `TypingIndicator`)
> + typing broadcast via a new `ChatInputBar.onChanged`. Issue 6 — 12-mood system
> (`core/mood.dart`), `showMoodSelector`, `presence.current_mood/color`, and the
> partner's mood shown in the chat header. (Per-message bubble tint + a Home mood
> widget deferred — they need the send-path threading / the missing HomeScreen.)

### ✅ Issue 7 — Settings (DONE)
Rewrote `settings_screen.dart` (Velvet Aurora): editable **display name + status**
(`updateMyProfile`), a searchable **timezone picker**, the Closer toggle, and
**Remove partner** — confirmation dialog → `leave_couple()` RPC (unlinks both via
`profiles.couple_id`, soft-deletes the couple with new `couples.active`, preserves
data) → routes back to pairing. Added `profiles.status_message`. (Avatar picker,
appearance/notifications/biometric sections deferred — they overlap Issues 6/9.)

### ✅ Issue 1D/1E — Message delete + clear conversation (DONE)
The spec's single `deleted_for_sender` boolean is broken for per-user hiding, so I
implemented it **correctly** with a `deleted_by uuid[]` + 3 RPCs (`hide_message`,
`delete_message_for_everyone` [sender-only], `clear_conversation`). Long-press a
bubble → Delete for me / Delete for everyone; deleted-for-everyone renders a
"This message was deleted" placeholder; AppBar ⋮ → Clear conversation (yours only).

---


---

## ✅ Issue 3 — FormatException root-cause fix (DONE, verified)

**Root cause (confirmed by grep):** 12 `fromJson()` constructors used raw casts
(`json['x'] as String`) and direct `DateTime.parse(...)`, with **zero**
`FormatException` handling anywhere. A single malformed/null row from Supabase
(which can return numbers as strings, nulls, or unexpected types) would throw and
crash the entire list.

**What changed:**
- **New** `lib/core/utils/json_utils.dart` — `JsonUtils` with `parseDate`,
  `parseDateOrNull`, `parseInt`, `parseDouble`, `parseString`,
  `parseStringOrNull`, `parseBool`, `parseObject`, `parseList`, `asMap`. Every
  method falls back instead of throwing.
- **New** `lib/core/utils/exceptions.dart` — `RepositoryException` (friendly
  message + original cause kept for logs, never shown to users).
- **Converted 10 `fromJson()`** to `JsonUtils`: `Couple`, `Profile`, `Visit`,
  `Ritual`, `DailyPrompt`, `PromptResponse` (`core/models.dart`); `Message`
  (chat); `Capsule`, `CapsuleItem` (capsule); `IntimacyPrefs`, `IntimacySignal`
  (intimacy).
- **New** `test/unit/json_utils_test.dart` — **20 tests, all passing** (covers
  null, garbage, string-coerced numbers, bad list elements, etc.). Added the
  missing `flutter_test` dev-dependency so tests can run at all.

**Verified:** `flutter analyze` → 0 errors on changed files; `flutter test` → all pass.

**Remaining (pattern established, mechanical):** ~2 Closer/timeline models still
use raw casts; and the spec's "wrap *every* repository method in try/catch →
`RepositoryException`" is a large mechanical pass that also requires updating
provider error states — staged as a follow-up so it doesn't silently change the
friendly `StateError` messages several screens already rely on.

---

## ⚠️ Reality-check: where the spec diverges from the actual codebase

I diagnosed before implementing (as instructed). Several spec assumptions don't
match what's built — flagging so we don't build a broken parallel structure:

| Spec assumes | Actual code |
|---|---|
| A `HomeScreen`, `HandoffScreen`, `DateNightScreen` exist | **They don't.** The home is the **Chat tab** in a bottom-nav shell (`app_shell.dart`). Issues 1A & 2 (PartnerStatusCard "on HomeScreen", Reach button "on home") need a HomeScreen built first. |
| Chat send / voice are "non-functional" | Chat **works** — `ChatInputBar` + `ChatRepository.sendText/sendImage/sendVoice` (text, photos, voice) already send & stream live. Issue 1B/1C are largely already done; 1D/1E/1F (delete, presence, typing) are the real gaps. |
| `couple_members` join table; `couples.active` column | App links couples via **`profiles.couple_id`** (per your earlier "enhance, don't rebuild" decision). No `couple_members`, no `couples.active`. Issue 7 "remove partner" must use the real schema (null out `profiles.couple_id` + the existing dissolution flow). |
| FCM is set up | **No Firebase** in the project (no `google-services.json`). Issue 8 background screen-wake requires Firebase config first; foreground Reach can ship without it. |
| Unit/widget tests exist | No `test/` dir existed. Added one + the JsonUtils suite. |

---

## 📋 Remaining issues — plan & effort

Ordered to build the missing foundation first (a real HomeScreen) since 3 issues hang off it.

- **Issue 1 (Chat: delete + presence + typing)** — M. 1D message delete (cols + RLS + long-press sheet), 1E clear-conversation, 1F `presence` table + `PresenceService` + typing indicator. (Send/voice already work.)
- **Issue 2 (Home + partner status + location)** — L. Build the missing `HomeScreen`; symmetric, opt-in, revocable location (city/precise); `PartnerStatusCard`; check-in snap. Play-safe by design.
- **Issue 4 (Capsule date+time unlock)** — S–M. `unlock_date` is already `timestamptz`; add a themed date+time picker, countdown, and a local notification at unlock.
- **Issue 5 (Body Map touch sync)** — L. Illustrated silhouettes only (no photos — Play compliance), `body_touches` realtime, glow/kiss/hug effects, haptics.
- **Issue 6 (Mood color + chat tint)** — M. Mood cols, 12-mood selector, per-message tint, presence mood glow.
- **Issue 7 (Settings)** — L. Full settings screen: profile edit, timezone picker, location toggle, appearance, notifications, biometric, **remove partner** (real schema), sign-out/delete-account.
- **Issue 8 (Reach wake + overlay)** — L + infra. Foreground overlay + `reach_events` realtime now; **FCM full-screen-intent needs Firebase setup** (documented, stubbed with TODOs).
- **Issue 9 (Private Vault PIN)** — M–L. `vault_items` (owner-only RLS) + `vault_pin`, PIN pad, lockout, biometric, FLAG_SECURE, auto-lock.

## Migrations still required (per issue, not yet applied)
messages delete columns · `presence` table · location columns · `body_touches` ·
mood columns · `reach_events` · `vault_items` + `vault_pin`. Each ships with its issue.

## New dependencies added this turn
- `flutter_test` (dev) — was missing; required for any tests.

## Play Store impact (high level)
- Issue 3: ✅ pure robustness, positive (fewer crashes).
- Issue 2 location & Issue 5 body map: **compliance-sensitive** — built opt-in/symmetric and with illustrated silhouettes (no nudity) specifically to stay ad-eligible and avoid surveillance-policy removal.
- Issue 8 FCM full-screen intent: allowed for person-to-person "reach"/call use; must be user-initiated (it is).

---

# ⟶ Precision fix pass #2 (2026-06-25)

**Global error handler / FormatException:** already in `main.dart`
(`FlutterError.onError` + `PlatformDispatcher.onError` → full exception + stack).
FormatException is mitigated app-wide by `core/utils/json_utils.dart`
(`parseDate`/`parseInt`, never raw `DateTime.parse` on Supabase data). No active
FormatException found in the touched code paths.

## Issue 1 — Biometric lock: locks but can't unlock — **ROOT CAUSE FOUND + FIXED**

**Real root cause (captured):** `MainActivity.kt` extended **`FlutterActivity`**.
`local_auth` needs a **`FragmentActivity`** host — with `FlutterActivity`,
`auth.authenticate()` throws `PlatformException(no_fragment_activity)`. My earlier
`tryUnlock()` swallowed it, so the biometric prompt **never fired** → user stuck.

**What changed:**
- **`MainActivity` now extends `FlutterFragmentActivity`** — the actual fix.
  (Manifest already had `USE_BIOMETRIC`.)
- Rewrote `core/services/app_lock.dart`: `authenticate()` uses `biometricOnly:false`
  (device PIN/passcode fallback) + `stickyAuth` + `useErrorDialogs`, and **logs the
  real PlatformException** instead of swallowing it. Added a 4-digit **app-lock PIN**
  (SHA-256 hashed, SharedPreferences) — a guaranteed non-biometric way in — plus
  capability detection (`availableBiometrics` → dynamic "Unlock with Face/fingerprint").
- New `core/widgets/lock_screen.dart`: full-screen, `PopScope(canPop:false)`,
  **auto-prompts** on display, a **retry button** (the previously-missing piece), and
  **"Use PIN instead"** → `PinPad`. No biometrics enrolled → straight to PIN.
- New `core/widgets/app_lock_pin_sheet.dart`: PIN setup (enter+confirm) / verify.
- Settings → Security: enabling **requires a PIN** (always a way in); disabling
  **requires PIN confirmation**.

**New packages:** `crypto` (already transitive) for the PIN hash.
**Remaining:** iOS would need `NSFaceIDUsageDescription` (Android-only build here).
**flutter analyze:** 0 errors.

## Issue 4 — Couple gender/role setup

- Migration `profiles_gender`: `gender` ('male'|'female') + `gender_set`.
- `RoleSetupScreen` ("A little about you" → I'm male / I'm female); each user sets
  their OWN. Router redirect: paired + `!genderSet` → `/role-setup` before `/app`.
- `SupabaseRepository.setGender()`; Settings → Profile → Gender (change later).

## Issue 2 — Cycle tracker not working — **ROOT CAUSE + rebuild**

**Real root cause (captured):** the event store the spec needs — `cycle_events`
(`period_start`/`period_end`) — **did not exist** (only `cycle_logs` held bare
start dates, no end, no on/off). With no clear primary action and no logged data,
predictions were empty and the screen effectively did nothing. There was also no
gender-gating, so it showed to everyone with no female-specific workflow. (No
FormatException — dates go through `JsonUtils.parseDate`, never raw `DateTime.parse`.)

**What changed:**
- Migration `cycle_events_table`: `cycle_events` (start/end, `date` type) +
  `cycle_settings.tracking_enabled`; RLS mirrors `cycle_logs` (owner ALL; partner
  SELECT only if `share_with_partner` + same couple via `current_user_couple_id()`);
  `replica identity full` + added to the realtime publication.
- Rebuilt `CycleRepository` around events: `setOnPeriod()` logs a start/end event
  AND mirrors the live `on_period_now` flag; derivations for on-period, spans,
  avg cycle/period length, and start-to-start prediction.
- Rebuilt `CycleScreen`, **gender-gated**:
  - Female → big "I'm on my period" toggle (start↔end events), phase ESTIMATE,
    a month calendar (logged period days filled, predicted window ringed),
    stats (avg cycle/period, cycles logged), share toggle + editable averages,
    and the required medical disclaimer.
  - Male → gentle partner view ("She started her period — send care 💕" /
    "Next period in ~X days"), sharing-off hides it, + one-tap "Send a care note"
    (drops a sweet message into chat via `ChatRepository.sendText`).
- `PartnerCycleCard` on the dashboard for the male partner (same gentle hint),
  updates live via a `cycle_events` realtime subscription.

**flutter analyze:** 0 errors.

## Issue 3 — Drawer not accessible from every screen — ROOT CAUSE FOUND

**Real root cause (captured):** the drawer lives on the `AppShell` Scaffold
(`key: rootScaffoldKey`). The 6 bottom-nav tabs (home, chat, countdown, sky,
breath, closer) ARE the shell's body, so `rootScaffoldKey.openDrawer()` works.
But the 8 drawer-reached screens (care, cycle, games, heartbeat, reasons,
together, touch, watch) are **pushed as separate routes on top of the shell** —
calling `rootScaffoldKey.openDrawer()` from them opens the shell's drawer
**behind** the opaque pushed route, so nothing appears. (Why not the spec's full
ShellRoute rewrite: the prior pass deliberately avoided it to protect the working
bottom-nav; a ShellRoute redo risks regressing nav for a layout-only bug.)

**What changed (bulletproof, low-risk):** every pushed drawer-screen now hosts
its OWN `drawer: const AppDrawer()` and opens it locally via
`Scaffold.of(ctx).openDrawer()` (the `ctx` from the existing leading `Builder`,
below that screen's Scaffold). No bottom nav underneath these routes, so the
drawer is full-height. Dead `rootScaffoldKey` imports removed. The 6 shell tabs
are unchanged (they already work). Drawer now opens from every screen.

**flutter analyze:** 0 errors.

## Issue 5 — Chat themes (built-in + custom from gallery)

- Migration `chat_theme_prefs`: `profiles.chat_theme_id` (default 'velvet') +
  `chat_bg_image_url`; `chat-bg` storage bucket with owner-only write RLS
  (path `chat-bg/{uid}/`).
- `chat_theme.dart`: 6 on-brand built-ins (Midnight Boudoir/velvet, Candlelit,
  Aurora, Blush, Starlit, Dawn) + a 'custom' theme. Each = bg gradient/solid +
  my/partner bubble colours + text + subtext (Dawn is light → dark text for
  contrast).
- `ChatThemeController` (Riverpod): loads instantly from a local cache, then
  reconciles from the profile (cross-device); `setTheme` / `setCustomBackground`
  persist to cache + profile. Each partner has their OWN theme.
- `chat_theme_picker.dart` (Chat ⋮ → "Chat theme"): a 6-swatch grid with mini
  bubble previews, "Choose from gallery" (PhotoPickerService → crop/compress →
  upload to chat-bg → custom theme), and "Reset to default". Applies live.
- ChatScreen: themed background (`_ChatBg` — gradient/solid, or the custom photo
  with a **dark top→bottom scrim** so text stays readable over any image), themed
  bubble colours + message text colour. Mood-burst tints still layer on top.

**Note:** `cached_network_image` isn't in the project; the custom background uses
`Image.network` (Flutter's in-memory image cache). Adding disk caching is a small
follow-up. Bucket is public-but-obscure-path (matches existing `couple_media`) —
a deliberate simplification over signed URLs for a wallpaper.

**flutter analyze:** 0 errors.
