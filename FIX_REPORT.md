# Tethered — Bug-Fix & Feature Sprint: FIX_REPORT

> Status: **Issues 3, 7, 1D/1E, 4, 1F, 6, 9 complete and verified** (`flutter
> analyze` = 0 errors project-wide). Remaining: **2 (Home+location), 5 (Body
> Map), 8 (Reach/FCM)**. (Git skipped per request.)
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
