# Miles — Build Plan

_Long-distance-relationship app · Flutter + Supabase · canonical engineering plan_

**Decision:** Build **on top of** the existing codebase. We are **not** rewriting from scratch. The code is sound; the work ahead is finishing, proving, and shipping.

**Goal, in order:** (1) prove every existing feature works on two real phones, (2) add 5 new features, (3) monetize with AdMob, (4) publish to the Google Play Store.

---

## 1. Where things stand

The codebase is in good shape: a proper auth/onboarding state machine, correct Supabase table/column names everywhere, and Row-Level-Security (RLS) that correctly scopes every couple's data to that couple. Two recent fixes are the reason most features now have a path to working: the **couples RLS recursion** fix (the policy no longer references itself in an infinite loop, so partner/profile reads succeed) and **realtime enablement** in `supabase/realtime.sql`. That unlocked the live presence dot, Reach haptics, and Breath Sync.

### ✅ Already completed this session (2026-06-24)
- **Couples RLS recursion** fixed (RPCs `create_couple` / `join_couple_by_code`).
- **Onboarding funnel** fixed (router enforces sign-in → profile → Create/Join → app; couple screen now offers both Create and Join).
- **Realtime enabled** for `profiles`, `breath_events`, `reach_pulses` **and** `visits`, `rituals`, `daily_prompts`, `prompt_responses` (publication + `replica identity full`).
- **Daily Prompt** — missing `prompt_responses` SELECT policy **added** (HIGH bug #1 below: DONE).
- **Breath Sync** — `_partnerActive` now updates from incoming partner events (bug #6 below: DONE).
- **AdMob** banner integration (test IDs, SFW tabs only).
- App built + installed on both test phones (IN2015 / GM1900).

**Remaining = (a) the code-side bugs below and (b) adding the in-code realtime *subscriptions* in the countdown / timeline / rituals / daily-prompt repositories (the DB tables are now published, but the screens don't yet subscribe).**

---

## 2. Existing features — status & bug-fix list

### Status table

| Feature | Works on 2 phones? | Top issues to fix |
|---|---|---|
| **Auth & Onboarding** | ✅ Yes | Error detection uses substring matching, not error codes (medium) |
| **Reach** (haptic pulse) | ✅ Yes | None found — verify on hardware only |
| **Countdown** (next visit) | ⚠️ Has bugs | Null-crash on no-visit; `visits` has no realtime |
| **Sky Bridge** (timezone sky) | ⚠️ Broken | Offset math always returns 0; sky uses device hour not partner's TZ |
| **Breath Sync** (shared pacer) | ⚠️ Has bugs | "Partner is here" never shows; no null/error guards |
| **Rituals** (scheduled msgs) | ⚠️ Has bugs | `rituals` has no realtime; silent spinner when not linked |
| **Daily Prompt** (reveal Q&A) | ⚠️ Broken | **Missing SELECT RLS policy** on `prompt_responses`; no realtime |
| **Timeline** (visit history) | ⚠️ Has bugs | `visits` has no realtime; Add-visit form drops the note field |

### Bug-fix list, ordered by severity

**HIGH — these block a feature from working correctly:**

1. **Daily Prompt — missing SELECT RLS policy on `prompt_responses`.** The generic policy loop in `supabase/schema.sql` (~lines 154–186) builds a `prompt_responses_select_member` policy that filters on `couple_id`, but `prompt_responses` **has no `couple_id` column** (it links via `prompt_id`). Reads fail or silently return zero rows, so `daily_prompt_repository.dart` (lines 84–93) can never load answers. Add an explicit SELECT policy gated through the parent prompt's couple, e.g. `using (exists (select 1 from daily_prompts p where p.id = prompt_id and p.couple_id = current_user_couple_id()))`.
2. **Sky Bridge — timezone offset always 0.** `lib/features/skybridge/sky_bridge_screen.dart` `_offsetDifference` (~lines 209–224) builds both times with `now.toLocal()` and returns 0. Add the `timezone` (`dart-lang/timezone`) package and compute the real difference via `tz.getLocation()` / `tz.TZDateTime.from()`.
3. **Sky Bridge — sky gradient uses device hour, not partner's TZ.** Same file (~lines 253–256) uses `DateTime.now().hour`. Change `_describeSky` to take a timezone and convert the UTC moment into that zone before picking the gradient.
4. ~~**Countdown — null crash when there is no visit.**~~ **FALSE POSITIVE (verified).** `visit?.startDate.toIso8601String()` does NOT crash: Dart null-shorting makes the whole expression evaluate to `null` when `visit` is null (the `?.` shorts the rest of the chain), and `startDate` is non-nullable otherwise. No fix needed. _The real Countdown issue is the partner-timezone "their time" line using device tz instead of the partner's — folded into the Sky Bridge timezone fix._
5. **Realtime not enabled for `visits`, `rituals`, `daily_prompts`, `prompt_responses`.** Per `supabase/realtime.sql` (line 15) only `profiles`, `breath_events`, `reach_pulses` are published. Add these four tables to the publication array (with `replica identity full`) and add postgres-changes subscriptions in `lib/features/countdown/countdown_screen.dart`, `lib/features/timeline/timeline_repository.dart`, `lib/features/rituals/ritual_repository.dart`, and `lib/features/daily_prompt/daily_prompt_repository.dart`, following the presence pattern in `lib/core/supabase_repository.dart` (`subscribeToPresence`, ~lines 209–232).
6. **Breath Sync — "Your partner is here" never appears.** `lib/features/breath/breath_sync_screen.dart` never updates `_partnerActive`. Drive it from `ref.watch(sessionProvider).partner` in `build()`.
7. **Breath Sync — silent insert failure if `currentUserId` is null.** Same file: guard `_beginCycle()` with a null check on `SupabaseService.currentUserId` and wrap `_broadcastStart` in try/catch with a snackbar.

**MEDIUM:**

8. **Auth — structured error codes.** `lib/core/supabase_repository.dart`: replace `e.message.contains('invalid_code')` with a check on the exception `code`/name field.
9. **Countdown — validate `coupleId` before save.** `lib/features/countdown/widgets/set_visit_sheet.dart`: in `_save()`, if `session.couple?.id != widget.coupleId`, block and show an error.
10. **Breath Sync — guard `_attachChannel` and subscription errors.** Same file: return early when `coupleId.isEmpty`; add an error callback on the realtime subscription.
11. **Timeline — Add-visit form is missing the note field.** `lib/features/timeline/timeline_screen.dart` (`_AddPastVisitSheet`, ~lines 438–570) renders `visit.note` but never lets users enter one. Add a note controller + `TextField`, pass it to `TimelineRepository.addPastVisit(...)`.
12. **Rituals — silent infinite spinner when not linked.** `lib/features/rituals/rituals_screen.dart` (lines 30–31): set an error state ("No couple linked") instead of returning into a permanent spinner. Same pattern needed in Timeline (`timeline_screen.dart` line 28–29).
13. **Sky Bridge — null-coalesce partner timezone.** `sky_bridge_screen.dart` line 71: `partner.timezone ?? 'UTC'`.
14. **Rituals — timezone correctness.** `lib/features/rituals/create_ritual_screen.dart` (lines 38–45) builds delivery time from device local time. Convert to UTC explicitly so the partner gets it at the intended wall-clock time.

**LOW:** profile-fetch timeout tuning and partner-name null-guards in `lib/core/session_provider.dart`; add `created_at` to the `Ritual` model (`lib/core/models.dart` ~163–195) and `order('created_at', ...)`; UTC year-bucketing in Timeline stats; "link with partner first" hint on Breath's disabled Begin button.

---

## 3. New features (5)

Each adds value to an LDR app and reuses existing conventions (per-feature idempotent SQL in `supabase/`, `current_user_couple_id()` RLS helper, static-method repositories, models in `lib/core/models.dart`, dark-coral theme, `go_router` routes under `/app`).

### 3.1 Push Notifications (foundational — build first)
**Behavior:** When the app is closed, the partner still gets notified — a Reach pulse, a Breath invite, a love note, or a morning/night greeting. A one-time soft-ask sheet precedes the OS permission prompt; declining still leaves realtime working in-app. On grant (and every cold start / token refresh) the app saves the device's FCM token. Foreground stays unchanged — realtime drives haptics/animation and the duplicate push is suppressed. A Settings → Notifications section toggles categories (Reach / Breath / Notes) plus a global mute. Sign-out and uninstall remove the token so an ex-partner's old phone goes quiet.
**SQL / infra:** new `supabase/device_tokens.sql` (couple-scoped, self-only RLS), `supabase/push_triggers.sql` (a `notify_push()` trigger on `reach_pulses` / `breath_events` / `notes` calling one `send-push` Edge Function via `pg_net`), and a `push_throttle` table — **mandatory** because Reach writes ~1 row/second while held; without a ~60s debounce it floods the partner and violates Play's notification-spam policy. Edge Function `supabase/functions/send-push/index.ts` looks up the **partner's** tokens with the service-role key (bypasses RLS so raw tokens never reach the client), sends a data-only FCM v1 message, and prunes `UNREGISTERED` tokens.
**Packages:** `firebase_core`, `firebase_messaging`, `flutter_local_notifications`. Needs `google-services.json` (Android) + the Gradle google-services plugin — the app's first Firebase dependency.
**Effort: L.**

### 3.2 Love Notes & Reactions
**Behavior:** A simple notes thread — either partner writes a short note; it lands on the other phone (live in-app via realtime, and as a push when closed). Add lightweight reactions (tap a heart/emoji on a note). Scheduled morning/night greetings reuse the same `notes` table via a `pg_cron` insert at `deliver_at`, which then fans out through the same push trigger. Routed at `/app/notes` with a drawer entry.
**SQL / packages:** `supabase/notes.sql` (the `notes` table is defined alongside the push design — couple-scoped RLS, `kind` = `note`/`goodmorning`/`goodnight`) plus a small `note_reactions` table (couple-scoped). Add `notes` to the realtime publication. New `lib/features/notes/notes_screen.dart` + `notes_repository.dart` (mirrors `lib/features/rituals/ritual_repository.dart`). No new Flutter packages.
**Effort: M** (S without scheduled greetings).

### 3.3 Shared Photo Memories
**Behavior:** A shared couple photo wall — either partner uploads a photo with an optional caption; both see the grid update live; tap for full-screen. This is the app's first use of **Supabase Storage** (today all media is `bytea` in Postgres, which doesn't scale to photos).
**SQL / storage / packages:** new `supabase/memories.sql` — a `memories` table (`couple_id`, `created_by`, `storage_path`, `caption`, `created_at`) with couple-scoped RLS, plus a **private** Storage bucket `memories` whose `storage.objects` policies gate read/write on `current_user_couple_id()` (object path convention `<couple_id>/<memory_id>`). Add `memories` to the realtime publication. Reuse the already-present `image_picker` package; add `cached_network_image` for the grid. New `lib/features/memories/memories_screen.dart` + `memories_repository.dart`.
**Effort: M** (storage + bucket RLS is new ground for the team).

### 3.4 Listen / Watch Together
**Behavior:** A lightweight "together" session — one partner starts a session with a link (a song/playlist or video URL) and a synced play position; the other joins and sees the same now-playing card with play/pause/seek mirrored in near-real-time. v1 is a **synced shared queue + "now playing" card with a deep link out** to the media app (not an embedded DRM player — embedding Spotify/YouTube playback is a licensing and review minefield we deliberately avoid for launch).
**SQL / packages:** new `supabase/sessions.sql` — a `watch_sessions` table (`couple_id`, `host_id`, `media_url`, `title`, `position_ms`, `is_playing`, `updated_at`) with couple-scoped RLS; add it to the realtime publication so position/state changes propagate live (this is exactly the realtime-broadcast pattern already used by Breath/Reach, so it's low-risk infra). Optional `url_launcher` for the deep-link-out. New `lib/features/together/together_screen.dart` + `together_repository.dart`.
**Effort: M.**

### 3.5 Time Capsule
**Behavior:** One partner records/writes a text (v1), voice, or video message sealed until a chosen future date, then it unlocks for the other partner with a notification. The sender sees their sealed capsules and a countdown; the recipient sees only a cleartext teaser while locked. The **unlock gate is enforced in Postgres RLS**, not just the UI — a recipient must not be able to read the payload early via the REST API.
**SQL / storage / packages:** new `supabase/time_capsules.sql` — `time_capsules` table with the key SELECT policy `using (couple_id = current_user_couple_id() and (created_by = auth.uid() or (recipient_id = auth.uid() and unlock_at <= now())))`; mirror that `now()` gate on `storage.objects` for the private `time-capsules` bucket so voice/video can't leak early. Optional E2EE reuses the existing Closer `CryptoCore`. Packages for voice/video (`record`, `just_audio`, `video_player`, `path_provider`, `permission_handler`) — **v1 ships text-only** to avoid the Storage + media + exact-alarm + Play-disclosure overhead; voice/video is a fast-follow. New files under `lib/features/closer/time_capsule/` (screen, seal screen, detail screen, repository), routed under `/app/closer/time-capsule`.
**Effort: L** (text-only v1 is M; voice/video pushes it to L).

---

## 4. Phased roadmap

> Each box is a checklist item. "Verify on 2 phones" means two real devices, two accounts, linked into one couple via the `create_couple` / `join_couple_by_code` RPCs.

### Phase 1 — Stabilize (fix every audit bug, then prove each feature on two phones)
Fix bugs in severity order, then verify. **No new features until this phase is green.**

- [ ] **DB:** Add SELECT RLS policy for `prompt_responses` in `supabase/schema.sql` (gate via parent prompt's `couple_id`).
- [ ] **DB:** Add `visits`, `rituals`, `daily_prompts`, `prompt_responses` to the publication array in `supabase/realtime.sql` (+ `replica identity full`).
- [ ] **Code:** Fix Countdown null crash (`countdown_screen.dart` line 63).
- [ ] **Code:** Fix Sky Bridge offset math + sky-by-timezone; add `timezone` package; null-coalesce `partner.timezone`.
- [ ] **Code:** Add realtime subscriptions in countdown / timeline / rituals / daily-prompt repositories.
- [ ] **Code:** Fix Breath Sync `_partnerActive`, null/error guards, subscription error callback.
- [ ] **Code:** Auth structured error codes; Countdown `coupleId` pre-save check; Timeline note field; not-linked error states (Rituals + Timeline); Rituals TZ→UTC conversion.
- [ ] **Code (low):** session timeouts/null-guards, `Ritual.created_at` + ordering, Timeline UTC year bucket, Breath disabled-button hint.
- [ ] **Verify on 2 phones — Auth:** Phone A creates couple, Phone B joins by code, both reach `/app`; dashboard shows identical `couple_id`; invalid code → "We could not find that code."; under-18 DOB blocked; session persists across app restart.
- [ ] **Verify on 2 phones — Reach:** A long-presses heart → B gets haptics + counter; release resets text; both directions.
- [ ] **Verify on 2 phones — Countdown:** B sets a visit → A's countdown auto-updates without refresh; partner-TZ "their time" line correct; deleting the visit row does not crash A.
- [ ] **Verify on 2 phones — Sky Bridge:** two different timezones show correct local time + correct sky gradient each; offset card shows the real hour difference (not 0).
- [ ] **Verify on 2 phones — Breath Sync:** A taps Begin → B receives event and syncs within ~1s; "Your partner is here" appears; stale (>19s) events ignored; channel unsubscribed on dispose.
- [ ] **Verify on 2 phones — Rituals:** A creates a ritual → B sees it appear live (after realtime fix); delete syncs; not-linked shows a message, not a spinner.
- [ ] **Verify on 2 phones — Daily Prompt:** both answer → both reveal after the second answer; partner's answer appears live; no RLS permission error on read.
- [ ] **Verify on 2 phones — Timeline:** A adds a past visit (with note) → B sees it live; delete syncs; empty/not-linked states show correctly; duration math correct.
- [ ] **Sign-off:** capture a short screen recording of each feature working across both phones; check into `docs/verification/`.

### Phase 2 — Push Notifications (foundational; everything else leans on it)
- [ ] Create the Firebase project; add `google-services.json`; wire the Gradle google-services plugin; add `firebase_core` / `firebase_messaging` / `flutter_local_notifications`.
- [ ] Run `supabase/device_tokens.sql` and `supabase/notes.sql`.
- [ ] Build `lib/core/push/push_service.dart`, `push_repository.dart`, `push_providers.dart`; soft-ask sheet before the OS prompt; token upsert on grant + `onTokenRefresh`; delete token on sign-out.
- [ ] Deploy `supabase/functions/send-push/index.ts`; store the service-role key + FCM v1 service-account in Edge Function secrets / Vault (never in client or repo).
- [ ] Run `supabase/push_triggers.sql` incl. the **`push_throttle` ~60s debounce** for Reach/Breath; verify the function targets only the **partner** (`user_id != sender_id`).
- [ ] Settings → Notifications section (category toggles + global mute) writing via `PushRepository.updatePrefs`.
- [ ] Lockscreen privacy: generic "New note from X" preview, full body only in-app. Never route Closer/intimacy content through FCM.
- [ ] **Verify on 2 phones:** close B's app; A sends Reach → exactly one notification (no flood); tap deep-links to the Reach tab; note + breath invites likewise; foreground push suppressed when realtime already fired.

### Phase 3 — The other four new features (in this order)
Ordered to climb the difficulty curve and reuse Phase 2's push pipeline immediately.

- [ ] **Love Notes & Reactions** (M) — `supabase/notes.sql` already live from Phase 2; add `note_reactions`, build `lib/features/notes/`, wire push + realtime + drawer entry. _First because it directly exercises the push pipeline and is the lowest-risk new surface._
- [ ] **Listen / Watch Together** (M) — `supabase/sessions.sql`, realtime sync of now-playing/position, `lib/features/together/`, deep-link-out. _Pure realtime, no new storage; safe second._
- [ ] **Shared Photo Memories** (M) — introduces Supabase Storage: `supabase/memories.sql` + private `memories` bucket with object-level RLS; `lib/features/memories/`. _Third because Storage + bucket RLS is new ground and is a prerequisite for Time Capsule's media._
- [ ] **Time Capsule** (L; text-only v1) — `supabase/time_capsules.sql` with the RLS unlock gate; `lib/features/closer/time_capsule/`; local-scheduled reminders + realtime unlock flip; push at unlock via the Phase 2 path. _Last; voice/video deferred to a fast-follow._
- [ ] **Verify each on 2 phones** as it lands (live propagation, RLS scoping, push fallback, unlock gate cannot be bypassed via REST).

### Phase 4 — Polish (make it feel like a real product)
- [ ] Final **app name + app icon** + adaptive icon + splash screen.
- [ ] First-run **onboarding polish**: soft-ask copy, empty states, loading/error states consistent across screens.
- [ ] Pass over copy, haptics, dark-coral theme consistency, and drawer ordering.
- [ ] Crash/error reporting (e.g. Sentry or Firebase Crashlytics) so post-launch issues are visible.
- [ ] Performance check: cold-start time, image/grid memory, realtime channel teardown on `dispose()` (no leaks).

### Phase 5 — Monetize + Publish
**Monetize (AdMob):** scaffolding already exists in `lib/core/ads/` (`ad_config.dart`, `ad_service.dart`, `banner_ad_slot.dart`) and `google_mobile_ads: ^9.0.0` is in `pubspec.yaml`.
- [ ] Create the real AdMob account/app; replace test ad-unit IDs in `lib/core/ads/ad_config.dart` with **real** IDs; keep test IDs for debug builds.
- [ ] Place banner slots on **non-intimate, low-friction** screens only (e.g. Timeline, Countdown). **No ads** on Closer/intimacy UGC screens or on screens presenting a partner's private content — this is both Play policy and good taste.
- [ ] Add the AdMob App ID to `AndroidManifest.xml`; confirm consent/UMP flow for EU users.

**Publish (Play Store):**
- [ ] Generate a **release signing keystore**; store it and its passwords securely (offline backup — losing it means you can never update the app); configure `key.properties` + `build.gradle` signing config.
- [ ] **Hide the adult Closer module for the first public launch.** Gate it behind a feature flag (off in the published build) to reduce content-review risk and speed approval. Ship Closer in a later update once the base app is live and stable. _This is a deliberate launch-de-risking call._
- [ ] **Content rating:** complete the IARC questionnaire. With Closer hidden, the base app rates lower; **if/when Closer ships, the rating becomes Mature 17+** — plan the re-rating with that update.
- [ ] **Privacy policy** (required): host a public URL covering Supabase data, FCM tokens, photos/Storage, and AdMob's advertising ID; link it in the Play listing and in-app.
- [ ] **Data safety form:** declare data collected (auth email, profile, photos, device token, ad ID) and how it's used/shared.
- [ ] **Store listing:** title, short + full description, feature graphic, phone screenshots (use the Phase 1 recordings), category (Lifestyle/Social).
- [ ] **Closed testing:** Google now requires **12 testers opted-in for 14 continuous days** before a personal developer account can promote to production — recruit testers early (ideally start during Phase 4) so the 14-day clock isn't on the critical path.
- [ ] Build the **app bundle (.aab)**, upload, pass pre-launch report, then promote closed → production.

---

## 5. Next 3 actions

1. **Fix the two highest-leverage DB issues first** — add the missing `prompt_responses` SELECT policy in `supabase/schema.sql`, and add `visits` / `rituals` / `daily_prompts` / `prompt_responses` to the publication in `supabase/realtime.sql`. These two changes alone fix Daily Prompt and unblock live updates for half the app.
2. **Fix the Phase 1 HIGH code bugs** — Countdown null crash (`countdown_screen.dart:63`), Sky Bridge timezone math (`sky_bridge_screen.dart`), and Breath Sync `_partnerActive` — then add the realtime subscriptions in the four repositories.
3. **Borrow two phones and run the Phase 1 verification checklist end-to-end**, recording each feature working across both devices. That recording is both the proof the owner asked for and the raw material for Play Store screenshots in Phase 5.
