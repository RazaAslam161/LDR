# Build 52 vs the tree — complete audit

Done 2026-08-28 from the owner's surviving `Miles.apk` (build 52, sha256
`f191dcab…`) against build 53 (`f22be830…`, built from the current tree).

**Why a second pass.** The first diff (§151) filtered to "Capitalised, contains
a space, no punctuation" and found 92 strings. That discarded routes, RPC
names, table names, asset paths and preference keys — i.e. most of the evidence
about which FEATURES existed. This pass compares each dimension separately.

    ROUTES  in 52, missing from 53:  3 real (rest is binary noise)
    ASSETS  referenced, missing:     0
    ASSET FILES packaged, missing:   0
    snake_case identifiers missing: 45
    UI copy strings missing:       496

---

## The decisive evidence: routes

    /app/settings/profile
    /app/settings/notifications
    /app/settings/account          (extracted as "/app/settings/accounte")

The tree has only `/app/settings` and `/app/settings/export`. So build 52's
settings subpages were **routed, not pushed** — this is how 14 flat sections
became 5 groups.

## The decisive evidence: RPCs — AND THE BACKEND IS ALREADY LIVE

45 snake_case identifiers are in 52 and not in 53. Cross-checked against
PRODUCTION `pg_proc`, every RPC the lost features need **already exists in the
live database**. Only the Dart client is missing:

| RPC (live in prod) | Signature | Called by tree? |
|---|---|---|
| `edit_message` | `p_message_id uuid, p_body text, p_cipher bytea, p_nonce bytea` | **NO** |
| `get_closeness` | `()` | **NO** |
| `set_closeness` | `p_score integer` | **NO** |
| `closeness_revealed` | `p_date date` | **NO** |
| `notify_closeness` | `()` | **NO** |
| `hide_message` | `p_message_id uuid` | yes |
| `delete_message_for_everyone` | `p_message_id uuid` | yes |
| `submit_report` | … | yes |
| `mute_partner` | `p_kind text, p_minutes integer` | yes |

`messages.edited_at` exists in production. The tree never selects it —
`grep -rl edited_at lib/` returns nothing.

The error codes carried in 52's binary name the server rules exactly:
`not_text`, `too_late`, `too_many`, `not_found` (edit); `bad_score`,
`too_soon`, `partner_checked_in` (closeness); `no_couple_key`, `no_key`,
`derive_failed`, `partner_key_missing`, `sent_unsealed`, `wrong_couple`,
`pin_mismatch` (crypto).

---

## THE MERGE LIST — three items, in priority order

### 1. Settings redesign — UI only, no backend

Every handler already exists in `settings_screen.dart`. This is regrouping.

- Profile hero card -> `/app/settings/profile` (moves the inline avatar +
  display name + status + gender editor off the main screen)
- **[unlabelled]** Notifications (`On`) -> `/app/settings/notifications` ·
  Content language (EN|UR pill) · Timezone (`Asia/Karachi`)
- **APPEARANCE** Chat theme (`Midnight Boudoir`) · How this app looks (`Miles`)
- **PRIVACY & SECURITY** App lock (switch) · Security code ·
  Location sharing (`Precise location`) · Closer (switch)
- **SUPPORT** Help & FAQ · Report a problem
- **ACCOUNT** Account & data (`Backup on`) -> `/app/settings/account` ·
  About (`0.1.0 (53)`)

`Chat theme` is genuinely NEW — it is not reachable from Settings anywhere in
the tree. The Notifications subpage holds `Sound & vibrate`
("Silent delivery, ongoing calls, timers"), full-screen alerts, the channel
rows and Pause notifications. The Account subpage holds Recovery backup,
Export, Change email, Sign out of other devices, Sign out, Delete account.

Widgets for this already built (§152): `_SettingsGroup`, `_SettingsRow`,
`_ProfileCard`.

### 2. Message editing — entirely absent from the client

Backend live. Needs: `ChatRepository.editMessage()` calling `edit_message`,
`edited_at` selected and surfaced, an edit affordance in the message actions,
and the composer's editing state.

Copy, recovered verbatim:

- `Editing message`
- `Only text messages can be edited.` (`not_text`)
- `Finish or cancel the edit first.`
- `That message changed while you were editing it. Have another look.`
- `That message is no longer there.` (`not_found`)
- `That message was deleted.`
- `That message belongs to a conversation you have left.` (`wrong_couple`)
- `You've edited a lot of messages this hour. Try again later.` (`too_many`)
- `Couldn't save that edit. Check your connection and try again.`

### 3. Closeness — exists as "Warmth Meter", but on the WRONG data path

`warmth_meter_screen.dart` writes `desire_temps` DIRECTLY:

    .from('desire_temps').upsert({...})
    .from('desire_temps').select('user_id, score')

Build 52 moved this onto `set_closeness` / `get_closeness` /
`closeness_revealed`, which enforce the rules SERVER-side (`bad_score`,
`too_soon`, `partner_checked_in`) and fire `notify_closeness`. A client-side
upsert cannot enforce once-per-day, cannot validate the range against anything
a modified client must respect, and cannot push to the partner.

Copy, recovered verbatim:

- `Slide to set yours.` · `Pick a number between 1 and 10.`
- `Locked in for today.` · `Change today's`
- `Your partner has checked in for today.` · `They put `
- `If you both landed at 7 or higher, you'll both be told.`
- `Read it aloud together once` · `Everyone sees the change`
- `Couldn't reach Closeness. Check your connection.`
- `Sign in again to check in.`

---

## Explicitly NOT a regression

The email-confirmation link opening "localhost refused to connect" is NOT
caused by building from the old baseline. Build 52's auth redirect literal is
byte-identical to `supabase_repository.dart:104`
(`https://miles-legal.vercel.app/auth-callback.html`) and that page returns
HTTP 200. This is Supabase falling back to Site URL because the redirect is not
in the project's allowed Redirect URLs — a production auth-config setting, and
it would fail for build 52 today too.

## Also confirmed intact

- 0 packaged asset files lost, 0 asset references lost.
- `message_reactions` is already wired (`chat_reactions.dart`).
- Build 52 was arm64-only as well, so §145's ABI observation is not new.
