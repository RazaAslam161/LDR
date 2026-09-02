#!/usr/bin/env bash
# Cut a release. Gates first, then the artifact, then the proof that the Dart
# inside it is the Dart just compiled.
#
#   bash tool/release.sh                  # PLAY APK for real testers
#   bash tool/release.sh --bump           # bump the build number first
#   bash tool/release.sh --play           # gates + play AAB for the Console
#   bash tool/release.sh --sideload       # the old debug-signed APK (rare)
#
# THE DEFAULT IS THE PLAY VARIANT, and that is the owner's standing ruling
# (2026-09-03): this app ships on Google Play, and an APK built here is the
# same build going to real testers for final feedback before production. It is
# not a different edition — same flavour, same R8, same upload key, same code.
# (Not literally the same flags: the APK adds -PmilesPlayApkArm64 and the
# Console bundle must never have it. See the ABI note further down.)
#
# That is not only policy, it is the only honest test. The play channel turns
# R8 and resource shrinking on (build.gradle.kts, beforeVariants) and the
# sideload channel does not, so every sideload APK a tester ever ran was code
# that had never been through the shrinker that ships. R8 is exactly what
# strips reflection and JNI entry points in WebRTC and ML Kit, and those fail
# only on a device.
#
# It also fixes an install that was impossible. The sideload channel is pinned
# to the DEBUG key unconditionally — not because the debug key is safer, but
# because it used to be `if (hasReleaseKey) release else debug`, so the
# afternoon someone created android/key.properties for Play, the SIDELOAD
# channel's signature changed as a side effect and build 45 met every handset
# with "App not installed as package conflicts with an existing package". A
# Play packaging decision must never be able to orphan the installed base
# (build.gradle.kts, the sideload signingConfig comment).
#
# The consequence for testers is the one that matters here: the handsets carry
# the UPLOAD key, so a debug-signed APK cannot update them. adb refuses it with
# INSTALL_FAILED_UPDATE_INCOMPATIBLE, and the only way past is an uninstall,
# which takes the X25519 seed with it. The play APK is signed with the upload
# key, so it installs straight over what is on the phone. BRAIN §262 addendum 2.
#
# One caveat, and it is not closed by any of this: once Play App Signing is on,
# Google re-signs with an app signing key IT holds, so a build delivered BY PLAY
# does not carry the upload certificate either. This APK is the same CODE that
# ships, not the same signature Play will ship. Moving a cable-installed tester
# onto Play still needs the escrow-then-uninstall ceremony in
# docs/guides/PLAY-RELEASE-RUNBOOK.md phase 3.
#
# Distribution is Play, or a cable. The in-app updater, the R2 upload and the
# app_release publish step were retired on 2026-09-02 (BRAIN §258).
set -euo pipefail

bump=false; play=false; sideload=false
for arg in "$@"; do
  case "$arg" in
    --bump) bump=true ;;
    --play) play=true ;;
    --sideload) sideload=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
if $play && $sideload; then
  echo "--play and --sideload are different artifacts; pick one" >&2; exit 1
fi

# ── The backend the APK will carry is decided by a GITIGNORED file. ─────────
# A sideload build pointing at staging shipped on 2026-08-28 (builds 53-55:
# .env was hand-recreated after the disk crash against the wrong project) and
# read as "the whole app is broken" — every feature failed against a drifted
# backend, and no gate in this script looked. This one does.
if ! grep -q "sopictusdonlvuezmfep" .env 2>/dev/null; then
  echo "REFUSING: mobile/.env does not point at the PRODUCTION project." >&2
  echo "A release that ships the wrong backend fails everywhere at once." >&2
  echo "Building against another project on purpose: MILES_ALLOW_NONPROD=1" >&2
  [ "${MILES_ALLOW_NONPROD:-0}" = "1" ] || exit 1
fi

if $sideload; then
  APK="build/app/outputs/flutter-apk/app-sideload-release.apk"
else
  APK="build/app/outputs/flutter-apk/app-play-release.apk"
fi
GATE="lib/core/app/release_gate.dart"

# ── What the play APK needs, checked BEFORE anything is spent. ──────────────
# The gates below run before the bump precisely so a failure never consumes a
# build number (see the comment at the top of section 0). The play APK path
# added two ways to fail that the old sideload default did not have — no upload
# keystore, and no apksigner to check the certificate with — and both were
# landing AFTER the bump, after build/ had been wiped, after a full analyze,
# test and R8 build. A build number spent on a machine that was never able to
# produce the artifact is the exact version-drift this script exists to stop.
# Both are knowable now, so both are checked now.
if ! $sideload && ! $play; then
  if [ ! -f android/key.properties ]; then
    echo "REFUSING: android/key.properties is missing, so the play channel has" >&2
    echo "no upload key and cannot produce an installable APK." >&2
    echo "Create the keystore and key.properties (docs/guides/PLAY-RELEASE-RUNBOOK.md" >&2
    echo "section 2.1), or build the debug-signed one with --sideload." >&2
    exit 1
  fi
  # Newest build-tools wins: every candidate that exists is printed, version
  # -sorted, and the last taken. Left to the loop's own order this was
  # last-line-wins, which happened to be right on one machine and would be
  # wrong the moment a preview build-tools directory or a new candidate line
  # appeared. .bat FIRST and under every SDK root, not just %LOCALAPPDATA%:
  # Windows ships only the .bat wrapper, so a machine with ANDROID_HOME set to
  # C:\Android\Sdk matched nothing and was told to set ANDROID_HOME.
  apksigner="$(
    for cand in \
        "$HOME"/AppData/Local/Android/Sdk/build-tools/*/apksigner.bat \
        "${ANDROID_HOME:-}"/build-tools/*/apksigner.bat \
        "${ANDROID_SDK_ROOT:-}"/build-tools/*/apksigner.bat \
        "$HOME"/AppData/Local/Android/Sdk/build-tools/*/apksigner \
        "${ANDROID_HOME:-}"/build-tools/*/apksigner \
        "${ANDROID_SDK_ROOT:-}"/build-tools/*/apksigner \
        "$HOME"/Android/Sdk/build-tools/*/apksigner; do
      # -e, NOT -x: the Windows apksigner.bat ships mode -rw-r--r--, so an
      # executable-bit test silently matches nothing and the certificate gate
      # then refuses every build on this machine. Measured 2026-09-03.
      #
      # A full if/fi, NOT `[ -e ] && printf`: the && form leaves the LOOP
      # exiting non-zero whenever the final candidate misses, pipefail carries
      # that out through the pipeline into the command substitution, and set -e
      # then kills the script on the assignment below — silently, before one
      # line of output. Measured 2026-09-03: exit 1, empty log, no clue.
      if [ -e "$cand" ]; then printf '%s\n' "$cand"; fi
    done | sort -V | tail -1
  )"
  if [ -z "$apksigner" ] && command -v apksigner >/dev/null 2>&1; then
    apksigner="$(command -v apksigner)"
  fi
  if [ -z "$apksigner" ]; then
    echo "REFUSING: apksigner not found, so the signing certificate of the APK" >&2
    echo "cannot be checked — and an APK signed by the wrong key cannot update" >&2
    echo "any handset in the field. Install Android SDK build-tools, or set" >&2
    echo "ANDROID_HOME / ANDROID_SDK_ROOT to the SDK that has them." >&2
    exit 1
  fi
  echo "apksigner: $apksigner"
fi

# ── 0. Gates ────────────────────────────────────────────────────────────────
# Before the bump, deliberately. Gating after it meant a red tree still spent a
# build number: pubspec.yaml and release_gate.dart were already written when the
# gate exited, so the retry produced N+2 and N+1 never existed as an artifact —
# the version-drift class the bump below exists to prevent, on a repo where
# several sessions edit pubspec.yaml at once.
#
# Nothing else mechanically stopped a red tree from becoming an APK: no CI, no
# git hook. On a sideloaded fleet with no update channel, whatever ships is what
# people keep.
#
# Errors and warnings only, never the exit code. `flutter analyze` exits 1 on
# `info` as well, and this tree carries hundreds of them; gating on the exit
# code would mean nobody could ever cut a release, which is how a gate gets
# deleted rather than obeyed.
# pub get FIRST, and it is not optional. `--no-pub` skips restoring packages,
# so on a tree that has just been cleaned there is no .dart_tool and every
# import in the project resolves to nothing: the gate reported 24,991 errors
# against a tree that analyzed 0/0 a minute earlier, and refused the build.
# The advice this script prints on failure is "flutter clean && release.sh",
# which walked straight into it. Restoring first costs a few seconds and is the
# difference between a gate and a tripwire.
echo "gate: flutter pub get"
flutter pub get >/dev/null 2>&1 || {
  echo "pub get failed — cannot analyze a tree with no packages" >&2; exit 1; }

echo "gate: flutter analyze"
# Retried once, because the FIRST analyze after a clean returns empty from a
# cold analysis server — no error, no issues, just nothing. The blindness check
# below then refuses the build on a tree that is perfectly green, which is
# exactly the clean-then-release path this script tells you to use. One retry
# costs seconds and turns a gate that blocks good trees into one that only
# blocks bad ones. It still fails closed if the second attempt is empty too.
# To a FILE, not a variable. An empty capture is what blocked build 39 for a
# day, and a shell variable keeps no evidence of why: by the time the gate said
# "blind" the output was gone. The file survives, and the failure path below
# prints it and says where it is.
alog="$(mktemp -t miles-analyze.XXXXXX)"
analyzed=false
for attempt in 1 2; do
  flutter analyze --no-pub >"$alog" 2>&1 || true
  # Proof that the ANALYZER ran, taken from the analyzer rather than from this
  # tree. It always ends in "N issues found." or "No issues found!".
  #
  # The previous liveness check required an `info - ` line to exist, which is a
  # fact about this repo today (477 of them) and not about the tool. Anybody who
  # cleaned those up would have made every future build fail with "this gate is
  # blind" on a perfectly green tree — a tripwire wearing a gate's clothes.
  if grep -qE 'issues? found' "$alog"; then analyzed=true; break; fi
  echo "  attempt $attempt produced no analyzer summary — retrying" >&2
done
if ! $analyzed; then
  # Everything the next person needs, in the failure itself. The last time this
  # fired, the only symptom recorded anywhere was the word "blind".
  echo "could not read analyzer output — this gate is blind, not green." >&2
  echo "  captured $(wc -c <"$alog") bytes over 2 attempts" >&2
  echo "  first lines of what came back:" >&2
  head -20 "$alog" >&2
  echo "  full capture kept at: $alog" >&2
  exit 1
fi
# Leading whitespace is optional on purpose. dart right-aligns the severity to
# width 7 — `warning - ` flush left, `  error - `, `   info - ` — so a flush-left
# anchor silently matches only one of the three. That exact mistake left
# repo_hygiene_test.dart unable to see an analyzer error for a whole session.
# `(-|•)`: the tool's field separator is `-` on Windows and `•` elsewhere, so a
# ` - ` pattern counts nothing on macOS or Linux (found 2026-09-02 on CI).
bad="$(grep -cE '^ *(error|warning) (-|•) ' "$alog" || true)"
if [ "$bad" -ne 0 ]; then
  grep -E '^ *(error|warning) (-|•) ' "$alog" >&2
  echo "$bad analyzer error(s)/warning(s) — not building." >&2
  echo "  full analyzer output: $alog" >&2
  exit 1
fi
rm -f "$alog"

echo "gate: flutter test"
if ! flutter test; then
  echo "tests are red — not building." >&2
  exit 1
fi

# ── 1. Build number ─────────────────────────────────────────────────────────
read_build() { sed -n 's/^version:.*+\([0-9][0-9]*\).*/\1/p' pubspec.yaml; }
read_gate()  { sed -n 's/.*buildNumber = \([0-9][0-9]*\).*/\1/p' "$GATE"; }

if $bump; then
  current="$(read_build)"
  [ -n "$current" ] || { echo "could not read the build number from pubspec.yaml" >&2; exit 1; }
  next=$(( current + 1 ))
  # Both, always, in one step. They drifted once by being bumped separately —
  # a versionCode-27 APK that reported itself as 26 — and the gate cannot name
  # a build it does not match.
  sed -i "s/^\(version: *[0-9.]*\)+${current}$/\1+${next}/" pubspec.yaml
  sed -i "s/buildNumber = ${current};/buildNumber = ${next};/" "$GATE"
  echo "bumped $current -> $next"

  # THROW AWAY EVERYTHING COMPILED BEFORE THIS BUMP.
  #
  # The gate above runs `flutter test`, which COMPILES the app — seeding
  # .dart_tool with a kernel built from the pre-bump source, where buildStamp
  # still reads the old number. The AOT build below then reuses that kernel, and
  # Gradle stamps the NEW versionCode onto an APK carrying the OLD Dart. Build 43
  # was produced exactly this way: pubspec 0.1.0+43, buildNumber = 43, and
  # `miles-build-42` inside libapp.so.
  #
  # Gating before the bump is right and stays — a red tree must not spend a build
  # number. What was missing is that the gate leaves a cache behind, and the bump
  # invalidates the source that cache was built from. So the cache goes with it.
  #
  # A FULL clean, and it is VERIFIED rather than trusted, because on Windows
  # `flutter clean` can fail and still exit 0.
  #
  # Two narrower fixes are recorded here because each looked right and was not.
  # Dropping only `.dart_tool/flutter_build` made Flutter recompile correctly —
  # build 44's jniLibs really did contain `miles-build-44` — and the APK still
  # shipped 43, because the stale copy was one layer further on, in GRADLE:
  #
  #   intermediates/flutter/sideloadRelease/jniLibs/…/libapp.so   miles-build-44
  #   intermediates/merged_jni_libs/sideloadRelease/…/libapp.so   miles-build-43
  #   app-sideload-release.apk                                    miles-build-43
  #
  # Adding `flutter clean` did not fix it either, and why it did not is the
  # whole reason this block exists: the Gradle daemon holds open handles under
  # build\, so the delete fails — and flutter prints "Failed to remove build"
  # and then EXITS 0. The script believed it had cleaned. Gradle found
  # mergeSideloadReleaseJniLibFolders up to date against its own earlier output
  # and packaged that instead of the fresh compile; the merge it reused was
  # eleven hours old. A clean that reports success without cleaning is worse
  # than no clean at all, because it is the thing everyone downstream trusts.
  #
  # So: stop the daemon to release the handles, clean, then PROVE build/ is gone.
  #
  # The cost is a full rebuild on every bumped release. That is the right price:
  # the alternative is shipping the wrong Dart under a fresh version number,
  # which this project has now done six times.
  echo "stopping the gradle daemon so build/ can actually be deleted"
  (cd android && ./gradlew --stop >/dev/null 2>&1) || true

  # RETRIED, because stopping the daemon and Windows releasing its handles are
  # not the same instant. The first version of this asserted after a single
  # attempt and failed the 46 build outright — then the identical `flutter clean`
  # run by hand seconds later succeeded. That is a race, not a stuck file, and
  # failing the release over it just moves the manual step somewhere else.
  #
  # The assert itself stays and is the point: it is what caught this, and what
  # catches the genuine case where an editor or an antivirus scanner really is
  # holding the directory.
  for attempt in 1 2 3 4 5; do
    flutter clean >/dev/null 2>&1 || true
    [ -e build ] || break
    echo "  build/ still held, waiting for handles to close (attempt $attempt/5)"
    sleep 3
  done

  if [ -e build ]; then
    echo "CLEAN FAILED: build/ still exists after 5 attempts over 15s." >&2
    echo "Something is genuinely holding a handle under it — an open editor, a" >&2
    echo "running emulator, an antivirus scan. Close it and re-run." >&2
    echo "Do NOT build on this tree: Gradle will package a stale merged_jni_libs" >&2
    echo "under the new version number, which is exactly how builds 39-44 went" >&2
    echo "out carrying older Dart." >&2
    exit 1
  fi
  echo "build/ is gone — every Gradle output below is recomputed, not reused"
  # pub get afterwards because clean takes package_config.json with it.
  flutter pub get >/dev/null

  # The snapshot guard further down stays as the backstop. It caught this three
  # times, and a release script that needs its own guard to notice a stale build
  # is one edit away from shipping one — but a guard that never fires is also
  # the one nobody maintains, so both remain.
fi

pubspec_build="$(read_build)"
gate_build="$(read_gate)"
version_name="$(sed -n 's/^version: *\([0-9][^+]*\)+.*/\1/p' pubspec.yaml)"

if [ -z "$pubspec_build" ] || [ -z "$gate_build" ]; then
  echo "could not read the build number from pubspec.yaml or $GATE" >&2
  exit 1
fi
if [ "$pubspec_build" != "$gate_build" ]; then
  echo "BUILD NUMBERS DISAGREE — pubspec.yaml is +$pubspec_build, ReleaseGate.buildNumber is $gate_build." >&2
  echo "Set both to the same number; the gate cannot name a build it does not match." >&2
  exit 1
fi
echo "build $pubspec_build (version $version_name)"

# ── 2. Build ────────────────────────────────────────────────────────────────
if $play; then
  # The Console artifact. Everything above this line — gates, bump + cache
  # purge, lockstep — is shared with the sideload path on purpose: play is the
  # channel where a stale snapshot costs days of review instead of minutes of
  # re-upload, and six releases shipped stale before the sideload guard
  # existed. No Miles.apk copy, no R2, no app_release row.
  AAB="build/app/outputs/bundle/playRelease/app-play-release.aab"
  echo "building play release AAB..."
  if ! flutter build appbundle --release --flavor play; then
    echo "build failed — stopping gradle daemons and retrying once" >&2
    (cd android && ./gradlew --stop >/dev/null 2>&1) || true
    flutter build appbundle --release --flavor play
  fi
  [ -f "$AAB" ] || { echo "expected an AAB at $AAB and found none" >&2; exit 1; }

  sha="$(sha256sum "$AAB" | cut -d' ' -f1)"
  bytes="$(wc -c < "$AAB" | tr -d ' ')"
  echo "sha256 $sha"
  echo "size   $(( bytes / 1048576 )) MB"

  # The stale-snapshot proof, on every libapp.so in the bundle — one ABI can
  # be stale alone. The buildStamp is what proves the Dart inside is the Dart
  # just compiled.
  python -c "
import sys, zipfile
z = zipfile.ZipFile('$AAB')
so = [n for n in z.namelist() if n.endswith('libapp.so')]
if not so:
    print('no libapp.so in the AAB'); sys.exit(1)
stamp = b'miles-build-' + b'$pubspec_build'
stale = [n for n in so if stamp not in z.read(n)]
if stale:
    print('STALE SNAPSHOT: no ' + stamp.decode() + ' in: ' + ', '.join(stale))
    sys.exit(1)
print('checked %d libapp.so, all stamped %s' % (len(so), stamp.decode()))
# Reach, asserted rather than trusted. -PmilesPlayApkArm64 strips non-arm64
# ABIs from the play VARIANT, and the variant feeds the bundle as well as the
# APK — a stray property in gradle.properties or ORG_GRADLE_PROJECT_* would
# upload an arm64-only bundle that Play accepts and that quietly serves nobody
# else. build.gradle.kts stops that at the task graph; this proves the artifact
# on disk, which is the thing actually being uploaded.
abis = sorted({n.split('/lib/')[1].split('/')[0] for n in z.namelist()
               if '/lib/' in n and n.endswith('.so')})
missing = sorted({'armeabi-v7a', 'arm64-v8a', 'x86_64'} - set(abis))
if missing:
    print('AAB IS MISSING ABIs: ' + ', '.join(missing) + ' - it carries ' + str(abis))
    sys.exit(1)
print('ABIs in the AAB: ' + str(abis))
" || {
    echo "REFUSING THIS ARTIFACT — the Dart inside is not build $pubspec_build," >&2
    echo "or it does not carry every architecture Play needs to split." >&2
    echo "Run: flutter clean && bash tool/release.sh --play" >&2
    exit 1
  }
  echo "play AAB is build $pubspec_build: $AAB"
  exit 0
fi

if ! $sideload; then
  # THE DEFAULT PATH: the Play variant, as an APK, for real testers.
  #
  # Signed with the upload key (build.gradle.kts gives the play flavour the
  # release signingConfig), so it installs over what is already on a handset
  # instead of being refused for a certificate mismatch.
  #
  # -PmilesPlayApkArm64 keeps ONE ABI in this APK and leaves the Console AAB
  # untouched — see the androidComponents block. An arm64 phone gets the same
  # libraries Play would have sent it; a 32-bit phone is told the app is not
  # compatible, instead of installing a shell with no engine in it (build 64).
  echo "building PLAY release APK (upload key, R8 on, arm64)..."
  if ! flutter build apk --release --flavor play -PmilesPlayApkArm64; then
    echo "build failed — stopping gradle daemons and retrying once" >&2
    (cd android && ./gradlew --stop >/dev/null 2>&1) || true
    flutter build apk --release --flavor play -PmilesPlayApkArm64
  fi
  [ -f "$APK" ] || { echo "expected an APK at $APK and found none" >&2; exit 1; }

  sha="$(sha256sum "$APK" | cut -d' ' -f1)"
  bytes="$(wc -c < "$APK" | tr -d ' ')"
  echo "sha256 $sha"
  echo "size   $(( bytes / 1048576 )) MB"

  python -c "
import sys, zipfile
z = zipfile.ZipFile('$APK')
sos = [n for n in z.namelist() if n.endswith('libapp.so')]
if not sos:
    print('no libapp.so in the APK'); sys.exit(1)
stamp = b'miles-build-' + b'$pubspec_build'
for n in sos:
    if stamp not in z.read(n):
        print('STALE SNAPSHOT: ' + n + ' has no ' + stamp.decode())
        sys.exit(1)
abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
if abis != ['arm64-v8a']:
    print('WRONG ABI SET: ' + str(abis) + ' — a partial APK installs and dies')
    sys.exit(1)
print('checked %d libapp.so, all stamped %s' % (len(sos), stamp.decode()))
print('ABIs in the APK: ' + str(abis))
" || {
    echo "REFUSING THIS ARTIFACT — the Dart inside is NOT build $pubspec_build," >&2
    echo "or it carries an ABI set that installs and then crashes." >&2
    echo "Run: flutter clean && bash tool/release.sh" >&2
    exit 1
  }
  echo "the snapshot really is build $pubspec_build"

  # The certificate a tester's phone checks against whatever it already has,
  # and the whole reason this path exists — so it is ASSERTED, not printed and
  # hoped over. hasReleaseKey in build.gradle.kts only tests that key.properties
  # names A keystore; repoint it at a different one and every gate above still
  # passes, Miles.apk is written, and the mismatch is discovered by a person
  # holding a phone that says INSTALL_FAILED_UPDATE_INCOMPATIBLE. That is
  # exactly how build 45 shipped (build.gradle.kts, the sideload signingConfig
  # comment), and a fingerprint nobody compares would not have caught it.
  #
  # The expected value is the upload certificate's public SHA-256 — an
  # identifier, not a secret. To read it off a handset, pull the APK and run
  # this same command on it; `dumpsys package` prints only a short signature
  # form, not this digest. Rotating the upload key is meant to stop this build
  # until the constant below is updated deliberately.
  EXPECT_CERT_SHA256="a37c59a5f3801b5a52ca1654ec088cc90d4ee4602ec7cdde50c58b515fbe9bb2"
  # $apksigner was resolved before the gates, so a machine without it never got
  # this far and never spent a build number.
  if ! certs="$("$apksigner" verify --print-certs "$APK" 2>&1)"; then
    echo "REFUSING THIS ARTIFACT — apksigner could not verify it, so its" >&2
    echo "certificate is unknown and it may not install anywhere." >&2
    printf '%s\n' "$certs" >&2
    echo "Nothing has been copied to Miles.apk." >&2
    exit 1
  fi
  got_dn="$(printf '%s\n' "$certs" | sed -n 's/^Signer #1 certificate DN: //p' | tr -d '\r')"
  got_sha="$(printf '%s\n' "$certs" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | tr -d '\r')"
  echo "Signer #1 certificate DN: $got_dn"
  echo "Signer #1 certificate SHA-256 digest: $got_sha"
  if [ "$got_sha" != "$EXPECT_CERT_SHA256" ]; then
    echo "WRONG SIGNING CERTIFICATE — this APK cannot update a handset." >&2
    echo "  expected $EXPECT_CERT_SHA256" >&2
    echo "  got      ${got_sha:-<none>}" >&2
    echo "Either android/key.properties points at the wrong keystore, or the" >&2
    echo "upload key was rotated — if it was rotated deliberately, update" >&2
    echo "EXPECT_CERT_SHA256 in tool/release.sh and say so in BRAIN." >&2
    echo "Nothing has been copied to Miles.apk." >&2
    if [ -f ../Miles.apk ]; then
      echo "WARNING: ../Miles.apk is left over from an EARLIER build. Do not" >&2
      echo "hand it to anyone believing it is this one." >&2
    fi
    exit 1
  fi
  echo "certificate matches the installed base — this APK updates in place"

  cp "$APK" ../Miles.apk
  echo "tester copy: Miles.apk is build $pubspec_build (play variant)"
  echo "install it with: adb install -r $APK"
  exit 0
fi

# ── The old sideload path, kept and explicit. ───────────────────────────────
# Debug-signed by design, so it CANNOT install over a handset carrying the
# upload key — which is every handset in the field. Use it only to debug the
# unshrunk build; anything a real person is going to use is the default above.
echo "WARNING: --sideload is DEBUG-SIGNED and unshrunk." >&2
echo "         It will not install over an upload-key build, and it is not" >&2
echo "         the code that ships. Testers get the default build." >&2
echo "building sideload release APK..."
# One retry after stopping the daemons. This machine loses builds to stale file
# locks — a dart process pinned .dart_tool and served stale sources for two
# releases, and Gradle's lint cache did the same to a third
# ("The process cannot access the file because it is being used by another
# process"). Both clear by stopping the daemon that holds them.
# --target-platform android-arm64, and it is the ONLY lever that works.
#
# Measured on build 47: an `ndk { abiFilters }` block in the sideload flavour
# changed nothing at all — the APK still carried all three architectures
# (x86_64 75.4MB, arm64-v8a 67.3MB, armeabi-v7a 50.8MB). AGP's abiFilters
# governs libraries IT builds via the NDK; Flutter's gradle plugin copies its
# own .so files straight into jniLibs and never consults it. The filter looked
# correct, compiled clean, and did nothing.
#
# lib/ was 192.8MB of a 243MB payload because every native library shipped three
# times. x86_64 is emulators only — no phone on earth — and armeabi-v7a is
# 32-bit hardware from roughly pre-2016. The .so files are STORED rather than
# deflated, so those are real download bytes.
#
# The Console AAB deliberately does NOT do this: Play splits per device, so
# filtering there would cost reach and save nobody a byte. The play APK above
# does filter, by -PmilesPlayApkArm64, because it is handed to a tester whole.
if ! flutter build apk --release --flavor sideload --target-platform android-arm64; then
  echo "build failed — stopping gradle daemons and retrying once" >&2
  (cd android && ./gradlew --stop >/dev/null 2>&1) || true
  flutter build apk --release --flavor sideload --target-platform android-arm64
fi
[ -f "$APK" ] || { echo "expected an APK at $APK and found none" >&2; exit 1; }

sha="$(sha256sum "$APK" | cut -d' ' -f1)"
bytes="$(wc -c < "$APK" | tr -d ' ')"
echo "sha256 $sha"
echo "size   $(( bytes / 1048576 )) MB"

# The stale-snapshot proof, on every libapp.so in the APK. Gradle re-stamps
# versionCode while Flutter can reuse a cached AOT snapshot, and releases went
# out that way carrying build-31 code under fresh version numbers. The literal
# comes from ReleaseGate.buildStamp; if the build used a stale snapshot, the
# number inside is the old one.
python -c "
import sys, zipfile
z = zipfile.ZipFile('$APK')
sos = [n for n in z.namelist() if n.endswith('libapp.so')]
if not sos:
    print('no libapp.so in the APK'); sys.exit(1)
stamp = b'miles-build-' + b'$pubspec_build'
# Every ABI, not sos[0]: a universal APK carries several snapshots and one
# can be stale alone.
for n in sos:
    if stamp not in z.read(n):
        print('STALE SNAPSHOT: ' + n + ' has no ' + stamp.decode())
        sys.exit(1)
print('checked %d libapp.so, all stamped %s' % (len(sos), stamp.decode()))
" || {
  echo "REFUSING THIS ARTIFACT — the Dart inside is NOT build $pubspec_build." >&2
  echo "Run: flutter clean && bash tool/release.sh ..." >&2
  exit 1
}
echo "the snapshot really is build $pubspec_build"

# The sideload copy. This script uploaded to R2 but never refreshed it, so
# Miles.apk at the repo root kept whatever was last copied by hand — a file named like the
# latest release and one build behind it. Build 39 went to R2 while Miles.apk
# still held 38, which is the shipped-artifact-is-not-the-claimed-artifact bug
# one layer out from the stale snapshot above. Copied only after the stamp check
# passes, so a refused artifact can never land here.
# A DIFFERENT filename on purpose: Miles.apk is the tester artifact and is the
# play variant. A debug-signed build landing there under the same name is the
# shipped-artifact-is-not-the-claimed-artifact bug wearing the other hat — it
# would not install on any handset that has the real one.
cp "$APK" ../Miles-sideload-debug.apk
echo "sideload copy: Miles-sideload-debug.apk is build $pubspec_build"
echo "install it with: adb install -r $APK"
