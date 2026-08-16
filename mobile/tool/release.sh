#!/usr/bin/env bash
# Cut a sideload release. With --ship it is the whole thing in one command:
# bump the build number, build, upload to R2, prove the hosted bytes are the
# built bytes, and publish the row that makes every phone offer the update.
#
#   bash tool/release.sh                  # build + hash only
#   bash tool/release.sh --ship           # bump, build, upload, verify, publish
#   bash tool/release.sh --upload --verify --publish   # ...without bumping
#
# Uploads with curl's built-in SigV4 against R2's S3 API and publishes through
# PostgREST — no aws CLI, no rclone, no psql. Never put a key in this file;
# credentials come from the environment. See
# docs/guides/SIDELOAD-UPDATE-RUNBOOK.md.
set -euo pipefail

bump=false; upload=false; verify=false; publish=false
for arg in "$@"; do
  case "$arg" in
    --ship) bump=true; upload=true; verify=true; publish=true ;;
    --bump) bump=true ;;
    --upload) upload=true ;;
    --verify) verify=true ;;
    --publish) publish=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

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
echo "gate: flutter analyze"
analysis="$(flutter analyze --no-pub 2>&1 || true)"
# Leading whitespace is optional on purpose. dart right-aligns the severity to
# width 7 — `warning - ` flush left, `  error - `, `   info - ` — so a flush-left
# anchor silently matches only one of the three. That exact mistake left
# repo_hygiene_test.dart unable to see an analyzer error for a whole session.
bad="$(printf '%s\n' "$analysis" | grep -cE '^ *(error|warning) - ' || true)"
if [ "$bad" -ne 0 ]; then
  printf '%s\n' "$analysis" | grep -E '^ *(error|warning) - ' >&2
  echo "$bad analyzer error(s)/warning(s) — not building." >&2
  exit 1
fi
# Proves the output was actually parsed rather than empty: `info` lines always
# exist in this tree, so zero of them means analyze did not run and the count
# above is noise. A gate that cannot fail is worse than none, because it is
# trusted.
if ! printf '%s\n' "$analysis" | grep -qE '^ *info - '; then
  echo "could not read analyzer output — this gate is blind, not green." >&2
  exit 1
fi

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
so = [n for n in z.namelist() if n.endswith('libapp.so')]
if not so:
    print('no libapp.so in the APK'); sys.exit(1)
blob = z.read(so[0])
stamp = b'miles-build-' + b'$pubspec_build'
if stamp not in blob:
    print('STALE SNAPSHOT: libapp.so has no ' + stamp.decode())
    sys.exit(1)
sys.exit(0 if b'Update available' in blob else 1)
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
