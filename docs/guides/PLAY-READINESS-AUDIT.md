# Play Store readiness audit — 2026-08-16

Six-dimension audit of build 40, every finding adversarially verified against the tree.
65 confirmed (7 blocker / 22 high / 36 medium), 8 refuted. Source: 53-agent workflow.

## 1. Verdict

- **No. It cannot ship, and it cannot even be uploaded.**
- **Single biggest obstacle: the Play artifact does not exist and never has.** `ls mobile/android/key.properties` → *No such file or directory*; `find . -name "*.aab"` → empty. The gradle gate hard-fails `packagePlayReleaseBundle`, so R8, resource shrinking, dexing and the play manifest merge have never once run together. Every behavioural claim about the app that will actually ship is unverified.
- **Biggest calendar obstacle (start it today, it cannot be compressed): Play Console access.** A personal developer account must run a closed test with 12+ opted-in testers for 14 continuous days before it can apply for production. That clock cannot start until a signed AAB exists. *(Thresholds change — confirm current numbers in Console; org accounts with a D-U-N-S number are exempt.)*
- Current state: build 40, `version: 0.1.0+40`, `buildNumber = 40`.

## 2. Blockers — ordered

**B1. No upload keystore → nothing uploadable can be built**
- Play requires an AAB; the `play` variant refuses to package without `android/key.properties`.
- Fix (human, minutes): `keytool -genkeypair -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 10000` (not JKS — keytool warns), write `key.properties`, `./gradlew :app:signingReport`, enrol in Play App Signing at upload so the .jks is only an upload key. Back it up off this machine. Runbook §2.1–2.4 already has the steps; only §2.1's `-storetype JKS` needs changing.

**B2. First AAB has never been built — R8 runs only on the play flavor**
- Directly downstream of B1. `isMinifyEnabled`/`shrinkResources` are true for play only, so the shipping artifact is the one configuration never compiled or executed.
- Fix (hours–days): `flutter build appbundle --release --flavor play`, then `bundletool build-apks --mode=universal` and install on a real device. Do NOT resolve this by turning minify off. Keep rules exist for WebRTC/ML Kit/Firebase and Mapbox/InAppWebView ship consumer rules, so the risk is smaller than feared — but unproven.

**B3. Child Safety Standards / CSAE declaration is absent — Play blocks publishing for Social UGC apps**
- Repo-wide grep for `csae|child safety|ncmec` returns exactly one hit: in-app text in `terms_text.dart:115`. No public URL, no Console self-certification. The policy has **five** requirements, not four; the standards doc must include the operational commitment to act on CSAM.
- Fix (hours): write the CSAE standards doc, host at a public HTTPS URL, name a **child-safety point of contact with a role and a name** (today the only published contact is a bare personal Gmail), complete Console → App content → Child safety standards. The in-app CSAM reporting mechanism is already built (`report_service.dart:16`) — 1 of 5 done.

**B4. Every hosted legal URL except the privacy policy is dead, and the privacy policy is an unfinished draft**
- Measured just now against the live bucket: `privacy-policy.html → 200`, `delete-account.html → 404`, `terms.html → 404`, `csae.html → 404`, `faq.html → 404`. The live privacy policy still renders the author's "Before publishing…" TODO box (grep on the fetched body → 1 match), and its own deletion link points at `functions/v1/delete-account`, which 404s — the real slug is `account-delete`.
- Fix (hours): register a real domain or Cloudflare Pages site (r2.dev is a rate-limited dev host Cloudflare tells you not to depend on), strip the TODO box, correct the deletion link to the hosted page, publish privacy-policy + delete-account + faq + csae, re-curl all for 200, then paste into Data safety. Fix `docs/legal/privacy-policy.md:8,231` too or the markdown source stays wrong.

**B5. No store listing assets exist anywhere in the repo**
- No fastlane dir, no screenshots, no descriptions. The only repo PNGs are stock Flutter web template icons.
- Fix (days): 512×512 32-bit icon (must be rendered from the `ic_launcher_play` vectors — `generate_icon.dart` has no play spec), 1024×500 feature graphic, 4–8 phone screenshots, ≤80-char short description, ≤4000-char full description. **Keep Touch Map and Closer out of every screenshot and the promo video.**

**B6. Play Console prerequisites (non-code, start immediately)**
- $25 account, identity + address verification, phone/email verification, decide personal vs organisation, then the closed-testing gate.

**High — will not stop the upload, but will sink or delay the review**
- Play build opens the nine-cover disguise picker at first run (`app_shell.dart:249-253`, `DISGUISE_ENABLED=true` on play). See §3.
- `USE_FULL_SCREEN_INTENT`: Reach is tagged `AndroidNotificationCategory.call` + `fullScreenIntent` (`reach_notifications.dart:65,67`) — a partner nudge is not a call, and it undermines the declaration you need for real calls. Fix is a pure deletion of both lines plus the dead `fullScreen` param.
- FGS declarations: microphone + mediaProjection need descriptions and demo videos. `FOREGROUND_SERVICE_CAMERA` + the `camera` type are declared but never requested at runtime — either delete them (removes an unrecordable video), or wire `ForegroundServiceTypes.camera` for video calls only and film it.
- Closer UI claims blanket end-to-end encryption at three sites (`closer_screen.dart:377`, `settings_screen.dart:375,697`) while `desire_temps`, `dice_rolls`, `body_touches`, `intimacy_signals` are plaintext columns. The app's own FAQ contradicts it in the same binary. That is a false security representation.
- Runbook contradicts the manifest it gates (§0.1 says play strips the aliases and sets `DISGUISE_ENABLED=false`; both false). Following it as written files an incorrect Console declaration.

## 3. The owner's decision

**A. Adult / intimacy content — nothing needs to be cut.**
- The explicit tier is already gone; what remains is suggestive, `modest_mode` defaults true, Truth-or-Dare rides the same gate plus an 18+ check, Giphy is pinned to pg-13, Touch Map vocabulary was softened.
- Ship it as: category **Social** (not Dating), IARC **Mature 17+**, target audience **18+ only**, ads none, IAP none.
- Cost of that honest answer: the CSAE declaration becomes mandatory (B3), and the listing draws human policy review.
- The only content rule that is non-negotiable: intimacy features never appear in listing assets. A screenshot of Touch Map is indefensible; the feature itself, as private UGC, is defensible.

**B. The disguise — you must choose one, and "leave it" is not on the list.**

*Option 1 — cut covers from the Play channel (recommended for v1).* Add a `COVERS_OFFERED` buildConfigField (false on play, true on sideload), gate `app_shell.dart:250` on it, and drop the `/app/disguise` route on play. Leave the nine disabled aliases in the manifest — they upload fine and a test pins them. **Cost: hours.** Buys: no Behavior Transparency exposure, no listing-disclosure obligation, no risk of a reviewer enabling a cover and locking themselves out.

*Option 2 — keep covers, disclose everything.* Requires all of: kill the first-open prompt, describe the cover feature in the full description, show the picker in at least one screenshot, a confirmation dialog before applying a cover (`_apply()` has none today), a visible unlock affordance on every cover screen, and the exact gesture plus a test account in Console → App access. **Cost: days**, and it makes an app-hider the public face of the listing. Enforcement in this category is account-level once published, not a resubmit.

*Option 3 — ship as-is.* A fresh Play install offers nine fake app identities, unprompted, undisclosed, on run one. This is the single most likely path to an account strike. Reject it.

**Minimum regardless of choice:** `_offerCoverAtFirstOpen()` must not fire on the play channel. The code's own contract 200 lines away already forbids it.

**C. Two smaller owner calls:** whether `Razaaslam3210@gmail.com` + "Pakistan" with no postal address is the public privacy/child-safety contact you want (it is thin for GDPR and named nowhere as a child-safety role), and whether the sideload channel keeps `com.miles.miles` or takes an `applicationIdSuffix` so both builds can coexist during migration.

## 4. Already done — do not spend time here

- **Policy:** explicit spicy tier removed; full UGC stack live in prod (content_reports, submit_report, mute/unmute, contact pause, ToS gate failing closed, three report entry points); 18+ age gate + versioned Terms; Giphy pinned pg-13; intimacy opt-in by default; not a dating app (no discovery surface, invite-code pairing only).
- **Release:** 16 KB page size — all 11 arm64 libs compliant; targetSdk/compileSdk 36, minSdk 24; play flavor configures cleanly and hard-fails rather than emitting a debug-signed AAB; self-updater excluded at manifest, BuildConfig and Dart layers (`REQUEST_INSTALL_PACKAGES` count in merged play manifest = 0); 219 MB is a sideload artifact — the real arm64 split is ~93 MB, far under Play's limit.
- **Permissions:** no QUERY_ALL_PACKAGES / SYSTEM_ALERT_WINDOW / MANAGE_EXTERNAL_STORAGE / background location / READ_MEDIA_IMAGES / contacts — four Console declaration forms avoided outright; exported flags, backup rules and cleartext posture all correct.
- **Privacy:** in-app account deletion is real and cascades; no analytics SDK; crash reports strip exception messages on-device; retention cron jobs all active. **No longer true as of BRAIN §81 (2026-08-24):** `google_mobile_ads` is now in the tree for one Touch-tab banner, it merges `com.google.android.gms.permission.AD_ID` into the manifest, and the Data Safety declaration must say so before the next Play upload. Ads are off by default (`app_release.ads_enabled`), which does not make the declaration optional.
- **Security:** RLS on 63/63 tables, verified with a live anon-key negative test; no service-role key, TURN credential or private key in the artifact; vault PIN lockout not bypassable; storage buckets private and couple-scoped.
- **Stability:** `flutter analyze` 0 errors / 0 warnings, `flutter test` 754 passing; launcher icons complete at every density; global error nets + ANR-safe isolate offloading in place; the fresh-account funnel is gated on every route.

## 5. Sequence to launch

**Phase 0 — start today, runs in parallel with everything (non-code, ~1–2 days of your time, 2–3 weeks of waiting)**
- Create the Play Console account ($25), complete identity + address verification.
- Decide personal vs organisation account — an org (D-U-N-S) skips the 12-tester/14-day gate; a personal account does not.
- Buy a domain and stand up static hosting. Everything in Phase 2 depends on it.

**Phase 1 — owner decisions (hours)**
- Covers: Option 1 or 2. Content: confirm Social / Mature 17+ / 18+. Public contact identity. Sideload applicationId suffix, yes or no.

**Phase 2 — legal hosting (hours)**
- Write the CSAE standards doc; name a child-safety contact.
- Strip the TODO box, fix the deletion link, publish privacy-policy + delete-account + faq + csae on the new domain; curl all for 200. Update `terms_text.dart:18` and `docs/legal/privacy-policy.md`.

**Phase 3 — code before the first build (1–2 days)**
- Covers decision implemented (`COVERS_OFFERED`).
- Reach FSI + `category.call` deleted; camera FGS resolved.
- Three blanket-E2EE strings narrowed.
- Not-medical disclaimer under the BPM readout.
- Delete `GIPHY_API_KEY` from `.env` and rotate it (it is live, shipped, and read by nothing).
- `debugPrint` no-op in release (one line, 99 sites).
- Escrow write path → `kdfArgon2idV2` (gate met: `min_build 39`), plus a test.
- `uses-feature required="false"` opt-outs (with `tools:replace` for camera.any and Mapbox's glEsVersion).
- Gradle 8.14.x + Kotlin 2.2.20 — before the first R8 run, not after. Do not go to Gradle 9.
- Fix the runbook (§0.1, §4 manifest block, §4 build number, §5.6 rationale, new §5.7 CSAE, new listing-disclosure step) and the five inverted doc comments in `disguise_service.dart`, `disguise_profile.dart`, `main/AndroidManifest.xml`, `build.gradle.kts:91`.
- Optional size win: exclude `pose-detection-accurate` — 6.14 MB, one gradle line, zero behaviour change.

**Phase 4 — keystore + first AAB (hours, then a real debugging pass)**
- Keystore → key.properties → `flutter build appbundle --release --flavor play`.
- Verify the merged bundle manifest has no `REQUEST_INSTALL_PACKAGES` and no FileProvider.
- Add a `--play` mode to `tool/release.sh` or accept the manual path.

**Phase 5 — device verification (2–3 days)**
- `bundletool build-apks --mode=universal`, install, exercise: WebRTC audio+video both directions, screen share, Mapbox world map, Google Maps location, ML Kit touch-map, image_cropper, voice notes, video playback, watch-together, FCM push, foreground-service call notification.
- **Prove key-escrow recovery**: uninstall a debug-signed build, install the Play-signed one, recover with the escrow password, confirm old encrypted content decrypts. Runbook Phase 3 says stop the release if this fails; it has never been run.
- Fresh-account funnel on a brand-new account against the wiped prod DB.
- Rotate the Maps API key (it is public in git history — restricting is not enough, create a new one and delete the old), then restrict to `com.miles.miles` + the **Play App Signing** SHA-1, Maps SDK for Android only. Add the same SHA-1/SHA-256 to Firebase or FCM stops delivering to Play installs.

**Phase 6 — listing assets (2–3 days)**
- Icon, feature graphic, screenshots, descriptions. Cover-feature disclosure text and screenshot if you chose Option 2.

**Phase 7 — Console forms (1 day)**
- Data safety (answer sharing deliberately: Giphy gets search terms, Mapbox gets viewport/approximate location; do not tick a blanket E2EE claim), Child safety standards, IARC questionnaire, FGS declarations + demo videos, full-screen-intent declaration, target audience 18+, ads none, news app no, account-deletion URL, App access notes with a test account and pairing instructions.

**Phase 8 — closed testing → production (14+ days wall clock)**
- Recruit 12+ testers, keep them opted in for 14 continuous days, then apply for production access.

**Realistic total: ~6–9 working days of engineering, 3–4 weeks of calendar** — dominated by Phase 0 verification and Phase 8's testing clock, both of which start before any code is written.

---
**VERIFY** (self-checking loop): Grounding 9/10 — every blocker re-checked live this session (keystore absent, no AAB, build 40, four of five legal URLs 404, TODO box present in the fetched body); the 12-tester/14-day threshold is from training knowledge and is flagged unverified. Completeness 9/10 — all 5 requested sections, blockers separated from review-gating highs, non-code chores included. Correctness 9/10 — adopted every verifier correction (covers are `enabled="false"`, camera FGS is dead, ML Kit saving is pose-only, r2.dev is the wrong permanent host). Brevity 8/10 — long, but the ask was five sections including a full launch plan. **FINAL.** The prompt supplied by the calling agent already carried role/context/format/constraints, so it stands as the expanded prompt rather than a re-authored one.