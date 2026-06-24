# Tethered — FCM "Reach" Push Setup Report

Goal: when partner A presses **Reach**, partner B's phone wakes/alerts — even
backgrounded, closed, or screen-off. FCM **HTTP v1 + service account only**
(legacy `fcm/send` is dead). Built in staged phases with on-device checkpoints.

> **Live status:** Phase 1 (packages + gradle) in progress. Everything past the
> `flutterfire configure` gate is blocked until you run it (see "Manual steps").

---

## ⛔ Manual steps only YOU can do (in order)

These need your Google/Firebase login or a physical device — I can't do them.

1. **FlutterFire CLI + configure** (Phase 1.2 — *do this first*):
   ```bash
   dart pub global activate flutterfire_cli
   cd E:\LDR\mobile
   flutterfire configure
   ```
   - Select or create the Firebase project (e.g. `tethered-ldr`).
   - Enable the **Android** app (applicationId `com.miles.miles`); iOS if building it.
   - This generates `lib/firebase_options.dart` and drops
     `android/app/google-services.json` in place.
   - ✅ Confirm `lib/firebase_options.dart` exists, then tell me — I'll wire the
     google-services Gradle plugin + `Firebase.initializeApp()` and we verify the
     token (Checkpoint 1).

2. **Service account key** (Phase 5.1): Firebase Console → Project settings →
   Service accounts → **Generate new private key** → download JSON. Also confirm
   **Cloud Messaging API (V1)** is *enabled* (Cloud Messaging tab).

3. **Supabase secrets** (Phase 5.1): never commit the key.
   ```bash
   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
   supabase secrets set FCM_PROJECT_ID="<your-firebase-project-id>"
   ```

4. **Deploy the Edge Function** (Phase 5.3): `supabase functions deploy reach-notify`.

5. **Database Webhook** (Phase 5.3): Supabase Dashboard → Database → Webhooks →
   on `reach_events` INSERT → call the `reach-notify` function URL.

6. **Play Console — full-screen-intent declaration**: when you submit, declare
   the `USE_FULL_SCREEN_INTENT` permission (Tethered uses it for person-to-person
   "reach" alerts). Android 14+ does **not** auto-grant it — users toggle it on,
   and the app falls back to heads-up notifications when they don't (handled in
   Phase 3.3 / 4.2).

7. **(iOS only)** APNs `.p8` auth key → Firebase Console → Cloud Messaging →
   Apple app config; enable Push + Background Modes capabilities in Xcode.

---

## Phase 1 — Firebase project wiring

**1.1 Packages added** (`pubspec.yaml`):
| Package | Version |
|---|---|
| `firebase_core` | ^4.11.0 |
| `firebase_messaging` | ^16.4.1 |
| `flutter_local_notifications` | ^22.0.1 |
| `vibration` | ^2.0.0 (already present) |

**1.3 Gradle wiring** (`android/app/build.gradle.kts`):
- `minSdk` pinned to **23** (was `flutter.minSdkVersion`) — firebase_messaging 16.x
  requires it (FCM itself needs ≥ 21).
- **Core-library desugaring enabled** + `desugar_jdk_libs:2.1.4` — required by
  flutter_local_notifications 22.x, or the Android build fails.
- _Pending the gate:_ the `com.google.gms.google-services` plugin (declared in
  `settings.gradle.kts` + applied in `app/build.gradle.kts`) — held until
  `google-services.json` exists, because the plugin errors without it.

**1.4 `Firebase.initializeApp()` in `main()`** — _pending the gate_ (needs
`firebase_options.dart`).

### ✅ Checkpoint 1 (after you run `flutterfire configure`)
App launches with Firebase initialized, no crash; `FirebaseMessaging.instance
.getToken()` prints a token to the console.

---

## Phases 2–6 — queued (will fill in as each lands)
- **2** Token storage: `profiles.fcm_token` + `FcmService` (save on login, refresh,
  clear on sign-out). Migration SQL drafted below.
- **3** `reach_channel` (Importance.max) + Android-14 full-screen-intent permission
  flow with graceful heads-up fallback.
- **4** Receive handlers: foreground / background / terminated + tap routing →
  `ReachOverlayScreen` (already exists).
- **5** Supabase Edge Function `reach-notify` (HTTP v1, service-account OAuth2) +
  DB webhook on `reach_events` INSERT.
- **6** iOS notes + the lock-screen-wake limitation (needs Apple critical-alert
  entitlement — future).

### Phase 2.1 migration (ready to apply when we reach Phase 2)
```sql
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS fcm_token text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS fcm_token_updated_at timestamptz;
-- RLS: profiles already has a "user updates only their own row" policy (verify).
```

---

## What's verified vs. pending
- ✅ Packages resolve; Android tree builds with the new deps + desugaring (Phase 1.1/1.3).
- ⏳ Everything else is **blocked on `flutterfire configure`** (the manual gate) and,
  later, on two-device testing (Checkpoint 5).
