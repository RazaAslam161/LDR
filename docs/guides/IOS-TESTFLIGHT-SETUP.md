# Getting Miles onto an iPhone that is not in the room

The development Mac cannot build Miles for iOS — see `IOS-PORT-STATE.md` for why, and do not
retry it. `.github/workflows/ios-testflight.yml` builds and ships instead. This is the setup
that workflow needs, once.

**Why TestFlight and not a cable.** The partner this app is for is remote, which is the entire
premise. Free provisioning needs the phone physically connected to a Mac running Xcode, expires
every **7 days**, and cannot have the Push Notifications capability at all — so Reach, message
delivery and a ringing call would all be dead. TestFlight installs over the internet, builds
last **90 days**, and push works. It requires the **paid Apple Developer Program, $99/yr**.
There is no third option.

Test on your own iPad first, then invite the partner. TestFlight installs on iPad as well as
iPhone, and nothing in this port has ever run anywhere — the first launch will find things.

---

## 1. Enrol

<https://developer.apple.com/programs/enroll/> — $99/yr. Individual is fine.

## 2. Team ID

<https://developer.apple.com/account> -> **Membership details**. A 10-character string like
`ABCDE12345`.

Save as the repository secret **`APPLE_TEAM_ID`**.

## 3. App Store Connect API key

This replaces an Apple ID password, which Apple no longer accepts for automation. It is also
what lets `xcodebuild -allowProvisioningUpdates` create the signing certificate and the
provisioning profile by itself — which is why there is no `.p12` to export and no fastlane
`match` repo to maintain.

<https://appstoreconnect.apple.com/access/integrations/api> -> **Team Keys** -> **+**

- Name: anything, e.g. `miles-ci`
- Access: **App Manager**

On generating it you get three things, and the `.p8` **downloads exactly once**:

| From the page | Secret name |
|---|---|
| Issuer ID (a UUID at the top of the page) | **`APP_STORE_CONNECT_ISSUER_ID`** |
| Key ID (the 10-char string in the row) | **`APP_STORE_CONNECT_KEY_ID`** |
| The `AuthKey_XXXXXXXXXX.p8` file | **`APP_STORE_CONNECT_PRIVATE_KEY`**, base64 |

Encode the `.p8` — the workflow expects base64, not the raw file:

```bash
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

## 4. The app record

<https://appstoreconnect.apple.com/apps> -> **+** -> **New App**

- Platform: **iOS**
- Bundle ID: **`com.miles.miles`** — must match exactly. It is the Android `applicationId`, the
  `CFBundleIdentifier` the CI already asserts, and what the Firebase iOS app is registered
  against. A different one is a different app to Apple and to Firebase both.
- SKU: anything, e.g. `miles`

You are **not** submitting for review. TestFlight distribution to people you invite needs no
App Review for internal testers.

While there: note the app's **numeric Apple ID** from the App Information page and put it in
`kAppStoreAppId` in `lib/core/app/release_gate.dart`. It is empty today, and the iOS block
screen has no exit button until it is filled — an iOS app can open its own listing only by
numeric id. **Fill it before ever raising `app_release.min_build_play`.**

## 5. The `.env`

The workflow writes `mobile/.env` from a secret, because the file is gitignored and
`main.dart:99` throws a `StateError` before the first frame when either key is empty. A
TestFlight build that dies on launch is worse than no build.

```bash
base64 -i mobile/.env | pbcopy
```

Save as **`MILES_ENV`**.

Both values already ship in plaintext inside every APK as a pubspec asset, and THREAT-MODEL.md
§(g) treats them as public by design — the anon key is refused by RLS on every table but
`app_release`. Putting them in a repository secret is not a new exposure.

## 6. APNs, or push does not arrive

The `.p8` above is for App Store Connect. Push needs a **second, different** key.

<https://developer.apple.com/account/resources/authkeys/list> -> **+** -> tick **Apple Push
Notifications service (APNs)** -> download that `.p8`.

Then Firebase Console -> project **`ldrc-120a2`** -> Project settings -> **Cloud Messaging** ->
the iOS app -> **APNs Authentication Key** -> upload it with its Key ID and your Team ID.

Without this the app installs and runs and no push ever arrives.

---

## Adding the secrets

`https://github.com/RazaAslam161/LDR/settings/secrets/actions` -> **New repository secret**, five times:

    APPLE_TEAM_ID
    APP_STORE_CONNECT_ISSUER_ID
    APP_STORE_CONNECT_KEY_ID
    APP_STORE_CONNECT_PRIVATE_KEY     (base64 of the .p8)
    MILES_ENV                         (base64 of mobile/.env)

The workflow checks all five in its first step and fails immediately if one is missing, rather
than 40 minutes later at the upload with an auth error.

## Shipping a build

    Actions -> "ios testflight" -> Run workflow -> pick the branch

Roughly 20-30 minutes. Then 5-15 minutes of processing on App Store Connect before it appears.

**The build number is not auto-incremented, deliberately.** CLAUDE.md requires `pubspec.yaml`
and `ReleaseGate.buildNumber` to move together, and `version_lockstep_test.dart` enforces it.
Injecting a number in CI would ship an artifact whose `ReleaseGate.buildNumber` disagrees with
its `CFBundleVersion`, so the release gate would check a build that does not exist. App Store
Connect refuses a duplicate build number, and that refusal is correct: bump the pair in a commit,
as with any other release.

## Adding testers

App Store Connect -> your app -> **TestFlight** -> **Internal Testing** -> add by Apple ID email.
Internal testers need no App Review and get the build as soon as processing finishes. They
install the **TestFlight** app from the App Store and the build appears there.

Add yourself first. Install on the iPad, confirm it launches, then invite the partner.

## What the first run will and will not tell you

Nothing in this port has ever executed. The first launch is the first evidence.

| | |
|---|---|
| Does it launch, or die before the first frame | the biggest unknown |
| Does it open as **Miles**, not the News cover | today's fix, never observed |
| Do the AAC cues play | the fix nothing has confirmed |
| Auth, pairing, chat, navigation, settings | yes |
| Push / Reach / a message arriving closed | yes, once §6 is done |
| A call **ringing** a locked phone | **no** — needs CallKit + PushKit, not built (60-100h) |
| Touch haptics on iPad | ten patterns collapse to one buzz. No Taptic Engine. Not a bug. |
| Screenshot blocking on the intimate screens | **no** — `FLAG_SECURE` has no iOS equivalent, ever |
