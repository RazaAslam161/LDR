# What build 52 had that the tree does not

Recovered 2026-08-28 from the owner's surviving `Miles.apk` (build 52, arm64,
98.5MB, sha256 `f191dcab…`), after the E: drive failure took the Dart source
for builds 49–52.

**Method.** `libapp.so` is an AOT snapshot — there is no decompiler that returns
readable Dart — but every string LITERAL survives in it. `tool/release.sh:368`
already relies on this to prove `Update available` is in a build. Extracting the
literals from build 52 and from build 53 and diffing gives the exact set of UI
copy that existed in the lost work and does not exist now.

    build 52 UI strings: 1763
    build 53 UI strings: 1754
    LOST  (in 52, missing from 53): 92

**What this is and is not.** It is an inventory of WHAT to rebuild and the exact
copy to use. It is NOT the layout, spacing, widget structure or ordering — that
is gone as code and has to be rebuilt by eye. Screenshots from a device running
52 would recover the rest; see the note at the bottom.

---

## 1. Settings — the redesign's information architecture

Section headings and their subtitles, which is most of what an IA redesign IS:

| String | Reads as |
|---|---|
| `Your profile` | section |
| `About you` | row / section |
| `Account & data` | section |
| `Email, export, sign out, delete` | its subtitle |
| `Privacy & security` | section |
| `App lock` | row |
| `Sound & vibrate` | section |
| `Silent delivery, ongoing calls, timers` | its subtitle |
| `Help & FAQ` | section |
| `Your data` | section |
| `Recovery backup`, `Backup on`, `Backup off` | row + state |
| `The icon and name shown on your phone` | disguise subtitle |

Notification-permission handling, which the current build words differently:

- `Alerts are off for this app, so nothing below can reach you.`
- `Your phone didn't say how these are set. The rows still open the right pages.`
- `This phone has no full-screen alert setting.`
- `Let a call light up your screen while the phone is locked`
- `Go to settings` · `Some blocked` · `New chat messages`

Pairing / unlinking:

- `Not linked yet` · `Not paired yet` · `Paired with ` · `Disconnect from `
- `Pair with your partner to share this app`
- `Unlink your accounts` · `Yes, disconnect` · `Could not disconnect. Try again.`

Safety-code verification:

- `A code you both compare to verify your encryption`
- `Compared with your partner` · `Not compared` · `Read it aloud together once`

## 2. Message editing — AN ENTIRE FEATURE, absent from the tree

Nine strings, including conflict handling and rate limiting. This is not copy
polish; it is a feature with a designed failure surface:

- `Editing message`
- `Only text messages can be edited.`
- `Finish or cancel the edit first.`
- `That message changed while you were editing it. Have another look.`
- `That message is no longer there.`
- `That message was deleted.`
- `That message belongs to a conversation you have left.`
- `You've edited a lot of messages this hour. Try again later.`
- `Couldn't save that edit. Check your connection and try again.`

## 3. A daily check-in / closeness feature — also entirely absent

- `Change today's` · `Locked in for today.`
- `Your partner has checked in for today.`
- `Slide to set yours.` · `Pick a number between 1 and 10.`
- `If you both landed at 7 or higher, you'll both be told.`
- `They put ` · `Everyone sees the change`
- `Couldn't reach Closeness. Check your connection.`
- `Sign in again to check in.`

## 4. Smaller losses

- `Name your capsule`
- `Search emoji` · `No emoji for that`
- `Forecast updated` (weather cover)
- `Check again` · `This is taking too long. Try again.` ·
  `Couldn't reach this one. Try again.`

---

## What is NOT the cause of the login regression

The owner reported that the email confirmation link opens
"localhost refused to connect" instead of the app. **Build 52 sends Supabase the
identical redirect:**

    https://miles-legal.vercel.app/auth-callback.html

byte-for-byte the same constant as `supabase_repository.dart:104` in the tree,
and that page returns HTTP 200. So this is NOT a build-53 regression — the
client half is unchanged. "localhost refused to connect" is Supabase's
signature behaviour when the requested `redirectTo` is not in the project's
allowed Redirect URLs: it falls back to Site URL, whose default is
`http://localhost:3000`. The suspect is the PRODUCTION project's auth
configuration, which would fail for build 52 today as well.

## Recovering the visual design too

Strings give the inventory; they do not give layout. The remaining route is to
run build 52 and photograph it. It cannot be installed over build 53 — 52 is
signed with the key that died with the E: drive — so it needs a device where
Miles is uninstalled first, and it must not be an uninstall that costs anything.

**Preserve `Miles.apk` (build 52).** A backup is at the session scratchpad as
`recovery/old_build.apk`; the repo root copy is the path `tool/release.sh`
overwrites on every build, so it WILL be destroyed by the next release run.
