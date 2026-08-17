#!/usr/bin/env bash
# Cut a sideload release. With --ship it is the whole thing in one command:
# bump the build number, build, upload to R2, prove the hosted bytes are the
# built bytes, and publish the row that makes every phone offer the update.
#
#   bash tool/release.sh                  # build + hash only
#   bash tool/release.sh --ship           # bump, build, upload, verify, publish
#   bash tool/release.sh --upload --verify --publish   # ...without bumping
#   bash tool/release.sh --play           # gates + play AAB for the Console
#
# Uploads with curl's built-in SigV4 against R2's S3 API and publishes through
# PostgREST — no aws CLI, no rclone, no psql. Never put a key in this file;
# credentials come from the environment. See
# docs/guides/SIDELOAD-UPDATE-RUNBOOK.md.
set -euo pipefail

bump=false; upload=false; verify=false; publish=false; play=false
for arg in "$@"; do
  case "$arg" in
    --ship) bump=true; upload=true; verify=true; publish=true ;;
    --bump) bump=true ;;
    --upload) upload=true ;;
    --verify) verify=true ;;
    --publish) publish=true ;;
    --play) play=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# The play artifact goes to the Console by hand; R2 and app_release are the
# sideload channel. Mixing them would upload an .aab no phone can install.
if $play && { $upload || $verify || $publish; }; then
  echo "--play cannot combine with --upload/--verify/--publish (sideload only)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."   # mobile/

# Credentials, if they are kept in a file rather than exported by hand.
# tool/.release-env is gitignored and holds the MILES_* exports. It exists
# because a non-interactive shell never sources ~/.bashrc, so an agent or a
# cron running this would otherwise see none of them and stop at the first
# check. Anything already in the environment wins.
if [ -f tool/.release-env ]; then
  set -a
  # shellcheck disable=SC1091
  . tool/.release-env
  set +a
fi

APK="build/app/outputs/flutter-apk/app-sideload-release.apk"
GATE="lib/core/app/release_gate.dart"

# The object name is derived from the published URL rather than configured
# separately. Setting them apart is how the first release broke: the script
# uploaded news.apk while app_release pointed at Miles.apk, and every phone
# would have been sent to a 404. One source of truth, so they cannot drift.
if [ -n "${MILES_APK_URL:-}" ]; then
  object="${MILES_APK_URL##*/}"
else
  object="${MILES_R2_OBJECT:-news.apk}"
fi

# ── Environment, checked BEFORE the ten-minute build ────────────────────────
if $upload; then
  for v in MILES_R2_ACCOUNT_ID MILES_R2_BUCKET MILES_R2_KEY MILES_R2_SECRET; do
    [ -n "${!v:-}" ] || { echo "--upload needs $v set (see the runbook)" >&2; exit 1; }
  done
fi
if { $verify || $publish; } && [ -z "${MILES_APK_URL:-}" ]; then
  echo "--verify/--publish need MILES_APK_URL set to the public URL" >&2
  exit 1
fi
if $publish; then
  for v in MILES_SUPABASE_URL MILES_SUPABASE_SERVICE_KEY; do
    [ -n "${!v:-}" ] || { echo "--publish needs $v set (see the runbook)" >&2; exit 1; }
  done
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
bad="$(grep -cE '^ *(error|warning) - ' "$alog" || true)"
if [ "$bad" -ne 0 ]; then
  grep -E '^ *(error|warning) - ' "$alog" >&2
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
  # be stale alone. No updater-copy assertion here: self-update is
  # deliberately absent from the play flavor, and the buildStamp is the part
  # that proves the Dart inside is the Dart just compiled.
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
" || {
    echo "REFUSING THIS ARTIFACT — the Dart inside is not build $pubspec_build." >&2
    echo "Run: flutter clean && bash tool/release.sh --play" >&2
    exit 1
  }
  echo "play AAB is build $pubspec_build: $AAB"
  exit 0
fi

# --flavor sideload is mandatory: a bare release build enters the play graph and
# stops on the missing upload key, deliberately.
echo "building sideload release APK..."
# One retry after stopping the daemons. This machine loses builds to stale file
# locks — a dart process pinned .dart_tool and served stale sources for two
# releases, and Gradle's lint cache did the same to a third
# ("The process cannot access the file because it is being used by another
# process"). Both clear by stopping the daemon that holds them.
if ! flutter build apk --release --flavor sideload; then
  echo "build failed — stopping gradle daemons and retrying once" >&2
  (cd android && ./gradlew --stop >/dev/null 2>&1) || true
  flutter build apk --release --flavor sideload
fi
[ -f "$APK" ] || { echo "expected an APK at $APK and found none" >&2; exit 1; }

sha="$(sha256sum "$APK" | cut -d' ' -f1)"
bytes="$(wc -c < "$APK" | tr -d ' ')"
echo "sha256 $sha"
echo "size   $(( bytes / 1048576 )) MB"

# Prove the updater is actually IN the artifact. A build once shipped without it
# — the code was in the tree, reachable from three call sites, and simply not in
# the APK — so both phones sat on a release that could never offer another one,
# and nothing anywhere said so. The string is a literal in update_sheet.dart; if
# Dart tree-shook the file away or the build used a stale snapshot, it is absent.
python -c "
import sys, zipfile
z = zipfile.ZipFile('$APK')
sos = [n for n in z.namelist() if n.endswith('libapp.so')]
if not sos:
    print('no libapp.so in the APK'); sys.exit(1)
stamp = b'miles-build-' + b'$pubspec_build'
# Every ABI, not sos[0]: the universal APK carries three snapshots and one
# can be stale alone.
for n in sos:
    blob = z.read(n)
    if stamp not in blob:
        print('STALE SNAPSHOT: ' + n + ' has no ' + stamp.decode())
        sys.exit(1)
    if b'Update available' not in blob:
        print('UPDATER MISSING from ' + n + '. The literal comes from')
        print('update_sheet.dart; if that copy was reworded, update this')
        print('gate in the same change - it is load-bearing, not decorative.')
        sys.exit(1)
print('checked %d libapp.so: stamped %s, updater present' % (len(sos), stamp.decode()))
" || {
  echo "REFUSING TO SHIP THIS ARTIFACT." >&2
  echo "Either update_sheet.dart is missing from libapp.so, or the Dart in it" >&2
  echo "is NOT the Dart just compiled. Gradle re-stamps versionCode while" >&2
  echo "Flutter can reuse a cached AOT snapshot, and releases went out that" >&2
  echo "way carrying build-31 code under fresh version numbers." >&2
  echo "Run: flutter clean && bash tool/release.sh ..." >&2
  exit 1
}
echo "self-updater present, and the snapshot really is build $pubspec_build"

# The sideload copy. This script uploaded to R2 but never refreshed it, so
# E:\LDR\Miles.apk kept whatever was last copied by hand — a file named like the
# latest release and one build behind it. Build 39 went to R2 while Miles.apk
# still held 38, which is the shipped-artifact-is-not-the-claimed-artifact bug
# one layer out from the stale snapshot above. Copied only after the stamp check
# passes, so a refused artifact can never land here.
cp "$APK" ../Miles.apk
echo "sideload copy: Miles.apk is build $pubspec_build"

# ── 3. Upload ───────────────────────────────────────────────────────────────
if $upload; then
  endpoint="https://${MILES_R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${MILES_R2_BUCKET}/${object}"
  echo "uploading to r2://${MILES_R2_BUCKET}/${object} ..."
  # -f so an HTTP error is a failure rather than an error page written over the
  # release.
  curl -fsS --aws-sigv4 "aws:amz:auto:s3" \
    --user "${MILES_R2_KEY}:${MILES_R2_SECRET}" \
    -H "Content-Type: application/vnd.android.package-archive" \
    -T "$APK" "$endpoint"
  echo "uploaded"
fi

# ── 4. Prove what is actually being served ──────────────────────────────────
# The check that stops a fleet-brick. A blocked phone's only way back is this
# URL, so truncated, stale or wrong bytes there strand it with no second door.
if $verify; then
  echo "verifying $MILES_APK_URL ..."
  served="$(curl -fsSL "$MILES_APK_URL" | sha256sum | cut -d' ' -f1)"
  if [ "$served" != "$sha" ]; then
    echo "MISMATCH — that URL is serving $served, this build is $sha." >&2
    echo "Not publishing. Do not raise min_build." >&2
    exit 1
  fi
  echo "verified: the hosted bytes are this build"
fi

# ── 5. Publish ──────────────────────────────────────────────────────────────
# Only latest_build moves, which makes this an OPTIONAL update. min_build is the
# hard gate and is never touched here: raising it strands every older phone on
# the block screen, and that is a decision to take deliberately, after watching
# a real phone update itself.
if $publish; then
  echo "publishing to app_release ..."
  curl -fsS -X PATCH "${MILES_SUPABASE_URL%/}/rest/v1/app_release?id=eq.true" \
    -H "apikey: ${MILES_SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${MILES_SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "{\"latest_build\":${pubspec_build},\"latest_version_name\":\"${version_name}\",\"apk_url\":\"${MILES_APK_URL}\",\"apk_sha256\":\"${sha}\"}" \
    > /dev/null
  echo "published build $pubspec_build — phones will offer it on their next cold start"
else
  cat <<SQL

Publish it by running this against production:

  update public.app_release set
    latest_build        = $pubspec_build,
    latest_version_name = '$version_name',
    apk_url             = '${MILES_APK_URL:-<the public URL of $object>}',
    apk_sha256          = '$sha'
  where id = true;

SQL
fi
