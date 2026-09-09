# iOS bring-up

Written 2026-09-08 from an audit of the tree at build 80. Every claim below was
checked against a file in this repo or a podspec in the pub cache; where it was
not, it says so.

Read section 0 before running a single command. Three of the four blockers there
cannot be discovered by `flutter build ios` — two of them let the build succeed
and fail on the handset instead.

---

## 0. What is actually true today

**There is no `mobile/ios/`.** It has never existed. `mobile/.metadata` lists
exactly two platforms:

```
  platforms:
    - platform: root
    - platform: android
```

So this is a platform bring-up, not a build. Four blockers, in the order they
will bite:

### Blocker 1 — Firebase kills the app on launch, first run, every time

`mobile/lib/firebase_options.dart` was generated for android + web only:

```dart
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for ios - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
```

and `mobile/lib/main.dart:109` awaits it inside a `Future.wait`:

```dart
  await Future.wait([
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
```

Nothing catches `UnsupportedError` there. The app dies before first frame until
an iOS app is registered in Firebase project `ldrc-120a2`. Fixed in §4b.

### Blocker 2 — calling does not exist on iOS

`mobile/pubspec.yaml` overrides the whole package:

```yaml
dependency_overrides:
  flutter_webrtc:
    path: third_party/flutter_webrtc
```

and that fork declares one platform:

```yaml
flutter:
  plugin:
    platforms:
      android:
        package: com.cloudwebrtc.webrtc
        pluginClass: FlutterWebRTCPlugin
```

Upstream 1.6.0 declares `android, ios, macos, windows, linux, elinux`. The fork
was vendored by copying `android/` and `lib/` only — `ios/`, `common/`,
`macos/`, `assets/` and the package's own `third_party/` are all absent.

So on iOS: no video call, no voice call, no screen share. Fixed in §4a, and the
fix is mechanical — `lib/` is byte-identical to upstream (`diff -rq` returns
nothing), so nothing Dart-side is at risk.

### Blocker 3 — ten MethodChannels with no iOS host

`MainActivity.kt` is 866 lines and hosts ten channels; `beauty/` is another
2,676 lines of Kotlin (GL renderer, ML Kit face tracking, NV21 conversion):

| channel | Dart caller | iOS status |
|---|---|---|
| `miles/beauty` | `features/chat/camera/beauty/beauty_engine.dart` | dead — 2,676 LOC Kotlin, needs a Metal/Core Image port |
| `miles/disguise` | `features/disguise/disguise_service.dart` | **cannot be built as designed** — see §12 |
| `miles/volume_keys` | `main.dart:323` | dead — no public API on iOS |
| `miles/secure_screen` | `features/closer/secure_screen.dart` | dead — iOS cannot block screenshots |
| `miles/fsi` | `core/services/fsi_permission.dart` | dead — Android 14 concept; CallKit is the iOS answer |
| `miles/pip` | `features/call/pip_mode.dart` | partial — iOS PiP is AVPlayer-only, not arbitrary UI |
| `miles/updater` | `release_gate.dart`, `exit_reasons.dart`, `notification_channel_settings.dart` | dead — all three are Android concepts |
| `miles/export` | `core/services/data_export_service.dart` | needs port — share sheet instead of SAF |
| `miles/device_stats` | `features/disguise/covers/device_info_cover.dart` | needs port — small |
| `miles/share_intent` | `features/reels/share_intake.dart` | needs port — a Share Extension target |

Good news: 14 `MissingPluginException` handlers already exist across
`pip_mode`, `beauty_engine` (7), `secure_screen`, `disguise_service` and
`share_intake`, so most of these degrade rather than crash. `secure_screen.dart`
even says so in its own doc comment:

```dart
/// - There is no iOS equivalent, so there the channel has no host and the call
///   is a no-op.
```

**Not verified:** whether every one of the ten is guarded. `miles/export`,
`miles/fsi`, `miles/device_stats` and `miles/volume_keys` have no
`MissingPluginException` catch in the grep. Walk those four before shipping.

### Blocker 4 — the deployment target floor is 15.5, set by ML Kit

Read from the podspecs in the pub cache, not from memory:

```
mapbox_maps_flutter-2.30.0            -> platform = :ios, '14.0'
google_mlkit_subject_segmentation-0.0.3 -> platform = :ios, '15.5'
google_mlkit_commons-0.11.1           -> platform = :ios, '15.5'
flutter_webrtc-1.6.0                  -> ios.deployment_target = '13.0'
camera_avfoundation-0.10.3            -> platform = :ios, '13.0'
local_auth_darwin-1.6.1               -> ios.deployment_target = '13.0'
just_audio-0.10.6                     -> ios.deployment_target = '12.0'
image_cropper-12.2.1                  -> ios.deployment_target = '12.0'
flutter_inappwebview_ios-1.1.2        -> platform = :ios, '12.0'
```

**ML Kit binds at 15.5.** That is the floor for the whole app. iPhone 6s and SE
1st-gen top out at iOS 15.8, so they stay in — but set it consciously (§6).

---

## 1. Apple side — start here, it has queue time

1. Apple ID with 2FA on, on the MacBook.
2. Enrol in the **Apple Developer Program** (paid, annual). Individual is fine
   for one owner; Organization needs a D-U-N-S number and takes weeks. Approval
   is usually 24–48h but can be longer.
   *Fee not verified in this session — read it on the enrolment page.*
3. Once approved, at <https://developer.apple.com/account>:
   - **Certificates, Identifiers & Profiles → Identifiers → +** → App IDs → App.
   - Bundle ID: `com.miles.miles` (match Android's `applicationId`, from
     `mobile/android/app/build.gradle.kts:33`).
   - Tick capabilities now: **Push Notifications**, **Associated Domains** (only
     if you do universal links, §7), **App Groups** (needed later for screen
     share and any Share Extension).
4. **APNs key** — Keys → + → tick *Apple Push Notifications service (APNs)* →
   download the `.p8`. **It downloads exactly once.** Note the Key ID and your
   Team ID. This goes into Firebase in §4b.
5. App Store Connect → **My Apps → +** → new iOS app, same bundle ID.

---

## 2. Mac toolchain

```bash
xcode-select --install
```

Then Xcode itself from the App Store (latest stable), and:

```bash
sudo xcodebuild -runFirstLaunch && sudo xcodebuild -license accept
```

Homebrew, if the Air is fresh:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

CocoaPods via Homebrew, not the system Ruby gem:

```bash
brew install cocoapods
```

Flutter — **pin to the same version this repo builds with**, `3.38.1` per
`mobile/pubspec.yaml` (`flutter: ">=3.38.1"`); the Windows box runs 3.44.2:

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
```

Add `export PATH="$HOME/flutter/bin:$PATH"` to `~/.zshrc`, then:

```bash
flutter doctor -v
```

Everything under "Xcode" and "CocoaPods" must be green before going on. Ignore
the Android toolchain lines unless you also want to build Android on the Mac.

---

## 3. Get the repo onto the Mac

```bash
git clone https://github.com/RazaAslam161/LDR.git ~/Miles
```

Branch is `fix-sprint`, not `main`:

```bash
cd ~/Miles && git checkout fix-sprint
```

`mobile/.env` is **gitignored and will not arrive**. Copy it across by hand from
`D:\Miles\mobile\.env` (AirDrop, USB, anything but a public paste). Without it
the Supabase URL and anon key are missing and the app cannot reach the backend.

```bash
cd ~/Miles/mobile && cp .env.example .env   # then paste the real values in
```

Confirm the tree is what you think:

```bash
cd ~/Miles/mobile && flutter pub get && flutter analyze
```

---

## 4. Fix the blockers BEFORE creating `ios/`

Order matters — `flutter create` reads the plugin list to decide what to wire.

### 4a. Re-vendor `flutter_webrtc` with its iOS side

The fork is missing every non-Android platform. Restore them from the exact same
upstream version it was cut from (1.6.0), keeping the Android patches.

On the Mac, after `flutter pub get`, upstream 1.6.0 sits in
`~/.pub-cache/hosted/pub.dev/flutter_webrtc-1.6.0/`. Copy in only what is
missing — never overwrite `android/` or `lib/`:

```bash
SRC=~/.pub-cache/hosted/pub.dev/flutter_webrtc-1.6.0
DST=~/Miles/mobile/third_party/flutter_webrtc
for d in ios macos common assets third_party windows linux elinux Documentation; do
  [ -d "$SRC/$d" ] && cp -R "$SRC/$d" "$DST/$d"
done
ls "$DST"
```

Then restore the platform declarations in
`mobile/third_party/flutter_webrtc/pubspec.yaml` so they match upstream:

```yaml
flutter:
  plugin:
    platforms:
      android:
        package: com.cloudwebrtc.webrtc
        pluginClass: FlutterWebRTCPlugin
      ios:
        pluginClass: FlutterWebRTCPlugin
      macos:
        pluginClass: FlutterWebRTCPlugin
```

**Why this is safe:** `diff -rq` between the fork's `lib/` and upstream's `lib/`
returns nothing — the Dart is untouched. The Miles changes are confined to
Android Java:

```
GetUserMediaImpl.java              modified
MethodCallHandlerImpl.java         modified
OrientationAwareScreenCapturer.java modified
video/LocalVideoTrack.java         modified
MilesVideoProcessorHook.java       added
audio/PlaybackAudioMixer.java      added
```

**Correction to the tree while you are in there:** `mobile/pubspec.yaml`
describes this fork as "~20 lines in ONE file — `GetUserMediaImpl.java`". It is
four modified files and two new ones. The comment is stale; the code is what it
is. Worth a one-line amend when someone next touches that block.

The copied `ios/` is self-contained — its podspec's only outward reference is
`{ :file => '../LICENSE' }`, which the fork already has, and its sources sit
entirely under `ios/flutter_webrtc/Sources/`. It pulls the binary
`WebRTC-SDK 144.7559.09` pod. `common/` and `macos/` are in the copy list for
completeness, not because iOS needs them.

Verify after the copy:

```bash
cd ~/Miles/mobile && flutter pub get && flutter pub deps | grep -A2 flutter_webrtc
```

### 4b. Register the iOS app in Firebase and stop the launch crash

Install the CLIs:

```bash
brew install firebase-cli && dart pub global activate flutterfire_cli
```

Then, from `~/Miles/mobile`:

```bash
firebase login && flutterfire configure --project=ldrc-120a2 --platforms=android,ios,web
```

This does four things at once: creates the iOS app under project `ldrc-120a2`,
writes `ios/Runner/GoogleService-Info.plist`, and rewrites
`lib/firebase_options.dart` with an `ios` branch replacing the `throw`, and
updates `firebase.json`.

**Check the diff before you accept it.** It rewrites the android block too, and
the android `appId` must still read
`1:188998306037:android:32baecc398a397210dddbc`:

```bash
cd ~/Miles && git diff mobile/lib/firebase_options.dart mobile/firebase.json
```

Then upload the APNs `.p8` from §1.4: Firebase Console → Project settings →
Cloud Messaging → *Apple app configuration* → APNs Authentication Key. Push is
dead on iOS without this, silently — FCM will accept the token and drop the
message.

### 4c. Decide the bundle ID once

Android ships `com.miles.miles`. Use the same on iOS. Note this is **not** the
Firebase project id (`ldrc-120a2`) and not the old `com.miles.app` that some
notes still mention.

---

## 5. Create the iOS platform

```bash
cd ~/Miles/mobile && flutter create --platforms=ios --org com.miles .
```

This adds `ios/` and appends an `ios` entry to `.metadata`. It touches nothing
else — but check:

```bash
cd ~/Miles && git status --short mobile/
```

Confirm the bundle id landed:

```bash
grep -r PRODUCT_BUNDLE_IDENTIFIER ~/Miles/mobile/ios/Runner.xcodeproj/project.pbxproj | head -3
```

If it says anything but `com.miles.miles`, set it in Xcode → Runner → Signing &
Capabilities → Bundle Identifier, for all three configurations.

Note: `.metadata` already carries `ios/Runner.xcodeproj/project.pbxproj` under
`unmanaged_files`, so `flutter migrate` will leave it alone afterwards.

---

## 6. Podfile — set the floor to 15.5

Edit `mobile/ios/Podfile`, first line:

```ruby
platform :ios, '15.5'
```

And in Xcode → Runner → Build Settings → **iOS Deployment Target → 15.5**.

Then:

```bash
cd ~/Miles/mobile/ios && pod install --repo-update
```

Expect this to take a long time on a first run — Mapbox 11.30.0, WebRTC and ML
Kit are large binary pods.

**Mapbox needs no secret token.** As of plugin 2.4.0: *"Configuring Mapbox's
secret token is no longer required when installing our SDKs"*
(`CHANGELOG.md`, and this repo resolves 2.30.0). The `~/.netrc` step in the
plugin's `DEVELOPING.md` is for plugin contributors. The runtime public token is
already handled — `core/media/map_token.dart:36` fetches it from the `map-token`
edge function, same as Android.

From here on, open `ios/Runner.xcworkspace` — **never** `Runner.xcodeproj`.

---

## 7. `Info.plist` — the strings Apple will read out loud

Derived from the 19 permissions in
`mobile/android/app/src/main/AndroidManifest.xml`. iOS shows these sentences to
the user verbatim, and App Review rejects vague ones. Add to
`ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Miles uses the camera for video calls and for photos you send in chat.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Miles uses the microphone for calls and voice notes.</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>Miles needs your photo library so you can share pictures and videos with your partner.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>Miles saves photos and videos you choose to keep to your library.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>Miles shows your partner where you are on the map while you have the app open.</string>

<key>NSFaceIDUsageDescription</key>
<string>Miles uses Face ID to unlock your private space.</string>

<key>NSMotionUsageDescription</key>
<string>Miles uses motion to tilt artwork and to detect the gesture that locks the app.</string>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>Miles uses Bluetooth to route call audio to headphones and speakers.</string>
```

Notes on each, so nobody adds a key the app cannot justify:

- **Location is foreground only.** The Android manifest says so explicitly at
  line 13 — *"No ACCESS_BACKGROUND_LOCATION / FOREGROUND_SERVICE_LOCATION"* —
  and `core/services/location_service.dart` never opens a background stream. Do
  **not** add `NSLocationAlwaysAndWhenInUseUsageDescription`; asking for Always
  without using it is a rejection.
- **Motion** covers `sensors_plus`, used by `emergency_lock_service.dart`,
  `tilt_parallax.dart` and `level_cover.dart`.
- **Bluetooth** mirrors the Android `BLUETOOTH_CONNECT` used for call audio
  routing. Drop it if the first build shows nothing requests it.
- `vibration` and `screen_brightness` need no key on iOS.

Background modes — Xcode → Signing & Capabilities → **+ Background Modes**:

- **Audio, AirPlay, and Picture in Picture** — voice notes and call audio.
- **Voice over IP** — only if you adopt CallKit/PushKit (§10). Do not tick it
  otherwise; an unused VoIP mode is a rejection.
- **Remote notifications** — FCM.

Deep links — `tethered://join` and `tethered://auth-callback`, from
`AndroidManifest.xml:170,183` and `main.dart:827`. Register the scheme:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.miles.miles</string>
    <key>CFBundleURLSchemes</key>
    <array><string>tethered</string></array>
  </dict>
</array>
```

`supabase_repository.dart:148` already notes that auth confirmation goes through
an `https://` page that forwards to `tethered://auth-callback`, so a custom
scheme is enough — universal links and Associated Domains are optional.

---

## 8. Signing and first run on a device

In Xcode, open `ios/Runner.xcworkspace` → Runner target → Signing &
Capabilities:

- Team: your developer account.
- **Automatically manage signing**: on, for now.
- Repeat for the `RunnerTests` target or the build will fail on it.

Plug in an iPhone, trust the Mac, then:

```bash
cd ~/Miles/mobile && flutter devices
```

```bash
cd ~/Miles/mobile && flutter run --release -d <device-id>
```

Use `--release` for the first run. A debug build on iOS is slow enough that you
will misdiagnose performance, and JIT is disallowed on device anyway for
profiling comparisons.

---

## 9. The triage list — what to check on that first run, in order

1. **App launches at all.** If it dies instantly, §4b did not take —
   `flutter logs` will show the `UnsupportedError` from `firebase_options.dart`.
2. **Supabase reachable.** If not, `.env` did not travel (§3).
3. **Push token arrives.** No token = APNs key not uploaded to Firebase.
4. **A call connects.** If `MissingPluginException` on WebRTC, §4a did not take.
5. The four unguarded channels from §0 — `miles/export`, `miles/fsi`,
   `miles/device_stats`, `miles/volume_keys`. Exercise each screen and watch for
   an unhandled `MissingPluginException`.
6. **The X25519 seed.** iOS stores `flutter_secure_storage` in the Keychain,
   which is a **separate identity from the Android keystore** — an iOS install
   is a new device to the E2EE layer, not a migration. Pair it as a new device
   and confirm history decrypts. Do not assume the Android pairing carries over.

---

## 10. Things this app needs on iOS that have no Android counterpart

- **CallKit + PushKit** for incoming calls. On Android, `miles/fsi` +
  full-screen intent wakes the call UI. iOS will not let a silent push open a
  call screen; without CallKit an incoming call is a notification the user has
  to tap. This is real work and it is the biggest functional gap after WebRTC.
- **Broadcast Upload Extension** for screen share. `screen_share_session.dart`
  and `call_controller.dart` drive it; on Android it is MediaProjection. On iOS
  it is a **separate app target** plus an App Group plus the fork's iOS code
  from §4a. Budget for it separately.
- **Share Extension** for `miles/share_intent` (`features/reels/share_intake.dart`).
  Another separate target.

---

## 11. TestFlight

Bump the pair together — `pubspec.yaml` version and `ReleaseGate.buildNumber`;
a test and `tool/release.sh` both enforce it on Android and the same pair feeds
`CFBundleShortVersionString` / `CFBundleVersion`.

```bash
cd ~/Miles/mobile && flutter build ipa --release
```

Then either open `build/ios/archive/Runner.xcarchive` in Xcode → Distribute App,
or:

```bash
xcrun altool --upload-app --type ios -f build/ios/ipa/*.ipa --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

App Store Connect → TestFlight. Internal testers (up to 100, your own Apple IDs)
need no review. External testers need a Beta App Review, usually a day.

`tool/release.sh` is Android-only — it builds the play APK/AAB and asserts ABIs.
It does not know about iOS. Do not try to make it dual-platform in the same
change.

---

## 12. Parity: what survives the crossing

**Works with no extra effort** — Supabase, Riverpod, go_router, chat, E2EE
(`cryptography`, `crypto`), secure storage (Keychain), local notifications,
image picker, cropper, video player, Mapbox, geolocation, geocoding, haptics,
audio session, InAppWebView, YouTube player, Lottie, fonts, `flutter_animate`.

**Degrades quietly, already guarded** — beauty filters (no-op), PiP (no-op),
secure screen (no-op), share intake (no-op).

**Needs a port** — data export, device stats cover, share intent, PiP proper,
CallKit, screen share.

**Cannot be built as designed** — the disguise. `disguise_service.dart` switches
`<activity-alias>` components to change the launcher name *and* icon across nine
covers. iOS has `setAlternateIconName`, and it is a different thing: a fixed
list of icons declared in `Info.plist` at build time, icon only — **the app name
cannot change** — and iOS shows a system alert *"You have changed the icon for
Miles"* the user cannot suppress. Also note `CLAUDE.md` already records the
covers as disabled on both Android flavors (`.AliasMiles` is the only alias with
`android:enabled="true"`), so this may be moot; it is flagged here so nobody
promises it in iOS copy. This one needs an owner decision, not a port.

---

## 13. What this document does not do

- No cost or timeline estimate for the CallKit, screen-share and Share Extension
  targets in §10. They are each a project.
- `record` 7.1.1's iOS implementation lives in a federated `record_darwin`
  package that is not in this machine's pub cache (Windows never fetched it), so
  its iOS support is **unverified here**. `pod install` on the Mac settles it.
- Nothing here has been run. There is no Mac in this session. Every command is
  written from the audited tree, not from an executed build.
