# The iOS port: what is done, what is not, and what it is waiting on

Written 2026-09-09 on branch `ios-port`. Read this before touching iOS.
BRAIN §303 and its addenda carry the narrative; this file is the map.

## The one thing to know first

**The iOS app builds and is CI-verified. It has never run. Not once.**

Not "runs with bugs" — never launched, on any device or simulator, by anyone.
Every iOS behaviour here was reasoned from source and pinned by host-VM tests where
that was possible. Treat all of it as unproven until something actually starts.

## The hardware ceiling, and why it is not worth retrying

The development machine is a 2020 **Intel** MacBook Air on **macOS 15.7.9**. It cannot run
Miles on iOS, and this is not a configuration problem:

| Link in the chain | State |
|---|---|
| Mapbox `MapboxCommon`/`MapboxCoreMaps` ship **precompiled** XCFrameworks stamped Swift **6.2.4** | verified down to `mapbox_maps_flutter` **2.28.1**, this pubspec's floor |
| A Swift binary framework cannot be consumed by an older compiler | so **Xcode 26 is mandatory** — 16.4 is Swift 6.1.2 and fails to build |
| Xcode 26.0–26.3 need macOS 15.6; **26.4+ need macOS Tahoe 26** | 26.3 is the ceiling here, and is installed at `/Applications/Xcode-26.3.app` |
| Xcode 26.3 needs an **iOS 26 simulator runtime** for ANY destination — device builds too | none present |
| iOS 26 runtimes require **macOS 26** | `softwareupdate --list-full-installers` offers **nothing above Sequoia 15.7.9** for this Mac |

Three separate attempts failed, ~24 GB spent, and the failures are consistent rather than flaky:

- `xcodebuild -downloadPlatform iOS` downloads all 10.47 GB then dies:
  `Download failed due to not having an extractor` (AppleArchive, `MobileAssetError.Download` code 16).
- Fetching the asset by hand off `updates.cdn-apple.com` (public, no auth) and decrypting it with the
  `ArchiveDecryptionKey` the failure logged **does decrypt** — but the payload is an asset PATCH
  descriptor (`YOP=manifest`, `YOP=extract`, `YOP=dst-fixup`), not a file tree. Applying it needs the
  extractor that is missing. The error is literal.
- `xcodes runtimes install` delegates to `xcodebuild` for iOS 26 and gets
  `iOS 23C54 is not available for download` — Apple refusing to offer, not failing to unpack.

**Do not spend another afternoon or another 10 GB on this.** The only local fixes are an Apple
Silicon Mac or a Mac that can run macOS 26; this one is neither.

## What CI does instead

`.github/workflows/ios-build.yml`, **workflow_dispatch only** — macOS runners bill at 10x against a
private repo's metered minutes, which is the fate `gates.yml`'s header warns about.
`gates.yml` runs on ubuntu and is structurally incapable of failing on anything iOS: no Xcode, no pod
is ever linked, and `flutter test` forces `defaultTargetPlatform` to android, so every iOS branch in
`lib/` is invisible to it. It stayed green through this entire port while the iOS build was, at
times, completely broken.

Last green run: compiles and links against the iOS 26 SDK, `Runner.app` 255 MB, `WebRTC.framework`
bundled, `GoogleService-Info.plist` in the bundle, 15 `.m4a` cues and zero `.ogg`, plus every
`NSUsageDescription`, the background modes, and the bundle id asserted from the BUILT plist.

## Done, and why each mattered

Six bugs, none of which would have surfaced as a build failure:

| Fix | The failure it prevents |
|---|---|
| **Audio → 48kHz AAC** | AVFoundation has no Ogg Vorbis decoder. All 15 cues and the bed were **silent on iOS**, and the load error is one the sound layer already swallows. |
| **`DarwinInitializationSettings` ×3** | `flutter_local_notifications` **throws `ArgumentError`** on iOS when `settings.iOS` is null. Every notification path was dead. |
| **WebRTC `ios/` restored into the vendored fork** | The fork declared `platforms: android` only. As a global `dependency_overrides` that is not a build error — the Dart layer compiles and calls a channel with nothing behind it. Every call would have died with `MissingPluginException`. |
| **Firebase iOS registered** | `firebase_options.dart` threw `UnsupportedError` for iOS inside `main()`'s first `Future.wait`. The app could not reach its first frame. |
| **Disguise: iOS opens as itself** | `miles/disguise` has no iOS host, the catch swallowed it, and both defaults stood — so the app opened wearing the **fake News reader**, with the two-finger hold as the only way in. The inverse of the Play posture, and an App Store 2.3.1 hazard. |
| **Release channel `appstore`** | iOS was classed `sideload`, so `applyRow` read `min_build` — the floor raised to push testers onto a hand-built APK. Raising it would have **blocked the entire iOS fleet** with an instruction no store install can act on. |

### The rule that made two of those findable

`defaultTargetPlatform`, never `Platform.isIOS`. `dart:io` reports the **host** under `flutter test`
(macOS), so a `dart:io` branch is one **no test in this repo can reach** — which is exactly how the
disguise defaults survived unnoticed. `debugDefaultTargetPlatformOverride` drives the former.
There are three iOS branches in `lib/` and all three now have tests that were confirmed to go **red
without the fix**, not merely green with it.

Also fixed while writing those: `ReleaseGate._channelKnown` is a process-wide static that
`_loadChannel()` early-returns on, so the first test to resolve a channel silently decided the answer
for every test after it — a green suite asserting nothing. `forgetChannelForTest()` exists for that.

## Not done

Nothing below is started. Each says what it is actually waiting on.

| Item | Needs | Rough |
|---|---|---|
| **Beauty/retouch pipeline** | Owner decided **not** to port for v1. 3,542 lines of Kotlin/GLES + ML Kit Face Mesh; iOS means Metal + Vision. | 250–450h |
| **CallKit + PushKit** | Paid Apple account (VoIP push entitlement). The only way a call rings a locked iPhone; iOS has no full-screen-intent equivalent. | 60–100h |
| **Push actually arriving** | Paid account for the APNs `.p8`, **and** a server change: `reach-notify` sends data-only payloads with no `alert` block, which iOS will not display. | 60–100h |
| **Screen share** | A ReplayKit Broadcast Upload Extension — a second target, and an **App Group**, which free accounts cannot have. | 40–70h |
| **PiP** | `AVPictureInPictureController` takes an `AVSampleBufferDisplayLayer`, not a Flutter view. Not a port of the Android mechanism. | 30–60h |
| **Data export** | `UIDocumentPicker` + security-scoped bookmarks. The Android side is a bespoke SAF chunked-write protocol in `MainActivity.kt`; this is a different protocol, not a translation. Currently fails honestly with a message. | 12–24h |
| **Reels share intake** | An iOS Share Extension target + App Group. | 12–24h |
| **Disguise launcher icons** | `setAlternateIconName`. Note two hard limits: the app **name** is fixed at build time, and every swap shows an unsuppressable system alert. The cover screens, picker, entry gesture and persisted choice already work on iOS. | 16–30h |
| **App icons** | `tool/generate_icon.dart` emits Android densities only. The bundle still carries Flutter's placeholder. | 6–12h |

### Impossible on iOS, not merely unbuilt

- **`FLAG_SECURE`** — no iOS API blocks screenshots. Eight intimate screens lose that guarantee
  silently. A product decision, not an engineering one.
- **Volume-key panic lock** — no public API for hardware volume capture. Half the emergency gesture.
- **`ApplicationExitInfo`** — MetricKit is push-shaped and daily-ish, not a synchronous pull.

### Open correctness item, deliberately not attempted

**iOS Keychain items survive app deletion.** "A reinstall wipes the key" is true on Android and false
on iOS, and `web/privacy-policy.html:233` states it as fact. Needs a first-run wipe keyed off an
NSUserDefaults marker (which IS deleted with the app) plus a correction to the published copy. Not
done in passing because getting it wrong destroys the user's X25519 seed.

**`kAppStoreAppId` in `release_gate.dart` is empty.** An iOS app can open its own store listing only
by numeric id, and that id does not exist until an App Store Connect record does. **Fill it before
ever raising `min_build_play`**, or the first block strands the iOS fleet on a screen with no exit.

## Traps that cost real time here

- `flutter config --no-enable-swift-package-manager` is **per-machine** state in `~/.config/flutter`.
  It never travels. A fresh clone hits `image_cropper 12.2.1 -> tocropviewcontroller 3.1.2..<4.0.0`
  against `DKImagePickerController -> 2.6.0..<3.0.0` and cannot resolve. The CI job sets it explicitly.
- **A runtime is not a destination.** `Unable to find a destination matching { generic:1, platform:iOS
  Simulator }` can mean zero instantiated devices, not a missing SDK. Check `simctl list devices`.
- iOS assets live at `Runner.app/Frameworks/App.framework/flutter_assets/`, not the bundle root.
- `mobile/pubspec.lock` **is gitignored** (`mobile/.gitignore:12`; `gates.yml:63-67` documents the
  consequence). Any "the lockfile is unchanged" check is vacuous. Pins belong in `pubspec.yaml`.
- `google_mlkit_subject_segmentation` does **nothing** on iOS — its entire iOS plugin is 16 lines
  returning `FlutterMethodNotImplemented`. For that it sets the **iOS 15.5 floor** (its podspec is the
  only thing that does), drags in MLKitVision/MLKitCommon/MLImage, and has **no arm64-simulator
  slice**, which forces `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` into the Pods config. Used in
  one place: `touch_map/reaction_segment_service.dart`. A strong removal candidate.
