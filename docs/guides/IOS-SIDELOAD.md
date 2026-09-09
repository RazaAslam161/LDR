# Putting Miles on an iPhone, for free

This is the no-Apple-account route. It costs nothing. It also means **no notifications** and a
**reinstall every 7 days** — both are Apple restrictions on free accounts, not something the app
can work around. Read "What she loses" before starting, so nothing is a surprise.

The alternative, for the record: the $99/yr Apple Developer Programme gives TestFlight —
one-tap install, 90-day builds, and push that works. Ruled out here deliberately.

---

## Part 1 — you: get the file

1. Go to **Actions** on the repo → **"ios ipa (unsigned)"** → **Run workflow** → pick `ios-port`.
2. Wait ~25 minutes.
3. Open the finished run → scroll to **Artifacts** → download **`miles-ios-unsigned-ipa`**.
4. Unzip it. Inside is `Miles-0.1.0-build80-unsigned.ipa`.
5. Send that file to her — WhatsApp, Drive, email, anything. It is ~100-250 MB.

The build is **unsigned on purpose**. It will not install by itself; she signs it with her own
free Apple ID in Part 2. Nothing here needs an Apple account of yours.

## Part 2 — her: install it

She needs a **Windows PC or a Mac**, once, and a cable.

**Sideloadly** is the simplest. <https://sideloadly.io>

1. Install Sideloadly on the computer. On Windows it will also install iTunes/iCloud drivers if
   they are missing — let it.
2. Plug the iPhone in. Unlock it. Tap **Trust** if asked.
3. Open Sideloadly. Drag `Miles-...-unsigned.ipa` onto the window.
4. Enter her **Apple ID** and password. This is Apple's own sign-in — Sideloadly uses it to ask
   Apple for a free 7-day signing certificate in her name. If she has two-factor on, it will ask
   for an **app-specific password**: <https://appleid.apple.com> → Sign-In and Security →
   App-Specific Passwords.
5. Click **Start**. A few minutes.
6. On the iPhone: **Settings → General → VPN & Device Management** → tap her Apple ID → **Trust**.
   The app will not open until this is done.
7. Miles is on the home screen.

**AltStore / SideStore** are the alternative. Harder to set up, but SideStore can re-sign over
WiFi so the weekly step does not need the cable again. <https://altstore.io> / <https://sidestore.io>

## Part 3 — every 7 days

Apple's free certificates last **seven days**. On day 8 Miles stops opening — it does not warn,
it just refuses.

To fix: repeat Part 2 with the same file. It keeps her data; it is a re-sign, not a fresh install.

If the weekly cable step is annoying, SideStore does it automatically over WiFi.

---

## What she loses, honestly

| | |
|---|---|
| Chat, photos, the vault, settings, covers — with the app open | ✅ works |
| **A message arriving while Miles is closed** | ❌ nothing. No banner, no badge, no sound. |
| **Reach** | ❌ silent |
| **A call ringing** | ❌ nothing rings. A call only connects if she already has the app open. |
| Screenshot blocking on the private screens | ❌ iOS has no equivalent of the Android protection |
| Touch haptics | ⚠️ weaker than Android — different hardware |
| Lasts | ⚠️ 7 days, then re-sign |

**A free Apple ID cannot have the Push Notifications capability.** That is the whole reason for
the second and third rows, and no change to Miles can restore them. Practically: Miles becomes an
app you both have to remember to open, rather than one that reaches you. For a long-distance app
that is a real loss and worth being clear-eyed about.

The app itself survives fine — `main.dart:202` calls `FcmService.init()` unawaited, so push
failing cannot block startup. It simply never receives anything.

## If something goes wrong

**"Unable to install"** — the 7-day certificate expired, or she already has 3 sideloaded apps
(free accounts are capped at 3). Remove one and retry.

**Opens and closes instantly** — Part 2 step 6 was skipped. Trust the developer in Settings.

**Opens to a blank or stuck screen** — most likely the build shipped without a real `.env`.
The workflow checks for that and fails early, so it should not happen; if it does, say so, because
it means the check has a hole.

**"Miles" is not on the home screen** — look for a folder, or search. The app installs under its
own name; the launcher covers are opt-in from Settings and off by default.
