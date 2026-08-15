#!/usr/bin/env bash
# Cut a sideload release: verify, build, hash, upload to R2, and print the one
# SQL statement that publishes it to every phone.
#
#   bash tool/release.sh             # build + hash + print SQL
#   bash tool/release.sh --upload    # also upload to R2
#   bash tool/release.sh --upload --verify
#                                    # ...then re-download the public URL and
#                                    #    prove the bytes match before publishing
#
# Uploads with curl's built-in SigV4 against R2's S3 API — no aws CLI, no rclone,
# no new dependency. Never put a key in this file; credentials come from the
# environment. See docs/guides/SIDELOAD-UPDATE-RUNBOOK.md.
set -euo pipefail

upload=false
verify=false
for arg in "$@"; do
  case "$arg" in
    --upload) upload=true ;;
    --verify) verify=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Check the environment BEFORE the build, not at the point of use: the build is
# ten minutes, and discovering a missing key after it is ten minutes wasted.
if $upload; then
  for v in MILES_R2_ACCOUNT_ID MILES_R2_BUCKET MILES_R2_KEY MILES_R2_SECRET; do
    if [ -z "${!v:-}" ]; then
      echo "--upload needs $v set (see the runbook)" >&2
      exit 1
    fi
  done
fi
if $verify && [ -z "${MILES_APK_URL:-}" ]; then
  echo "--verify needs MILES_APK_URL set to the public URL" >&2
  exit 1
fi

cd "$(dirname "$0")/.."   # mobile/

APK="build/app/outputs/flutter-apk/app-sideload-release.apk"
GATE="lib/core/app/release_gate.dart"

# ── 1. The two build numbers must agree ──────────────────────────────────────
# They have drifted before: pubspec went 25->27 while the gate went 25->26, so a
# versionCode-27 APK reported itself as 26. Raising min_build then locks out the
# very build it was meant to admit. Cheapest possible place to catch it.
pubspec_build="$(sed -n 's/^version:.*+\([0-9][0-9]*\).*/\1/p' pubspec.yaml)"
gate_build="$(sed -n 's/.*buildNumber = \([0-9][0-9]*\).*/\1/p' "$GATE")"
version_name="$(sed -n 's/^version: *\([0-9][^+]*\)+.*/\1/p' pubspec.yaml)"

if [ -z "$pubspec_build" ] || [ -z "$gate_build" ]; then
  echo "could not read the build number from pubspec.yaml or $GATE" >&2
  exit 1
fi
if [ "$pubspec_build" != "$gate_build" ]; then
  echo "BUILD NUMBERS DISAGREE — pubspec.yaml is +$pubspec_build, ReleaseGate.buildNumber is $gate_build." >&2
  echo "Set both to the same number before releasing; the gate cannot name a build it does not match." >&2
  exit 1
fi
echo "build $pubspec_build (version $version_name)"

# ── 2. Build ────────────────────────────────────────────────────────────────
# --flavor sideload is mandatory: a bare release build enters the play graph and
# fails on the missing upload key, which is deliberate.
echo "building sideload release APK..."
flutter build apk --release --flavor sideload

[ -f "$APK" ] || { echo "expected an APK at $APK and found none" >&2; exit 1; }

# ── 3. Hash and size ────────────────────────────────────────────────────────
sha="$(sha256sum "$APK" | cut -d' ' -f1)"
bytes="$(wc -c < "$APK" | tr -d ' ')"
mb="$(( bytes / 1048576 ))"
echo "sha256 $sha"
echo "size   ${mb} MB"

# ── 4. Upload ───────────────────────────────────────────────────────────────
# Always the SAME object name, so the URL stored in app_release never changes and
# a release is one overwrite. R2's region is literally "auto".
object="${MILES_R2_OBJECT:-news.apk}"

if $upload; then
  endpoint="https://${MILES_R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${MILES_R2_BUCKET}/${object}"
  echo "uploading ${mb} MB to r2://${MILES_R2_BUCKET}/${object} ..."
  # --aws-sigv4 is curl's own S3 signing, so this needs no CLI beyond curl.
  # -f matters: without it an HTTP error body is written as a "successful"
  # upload, silently replacing the release with an error page.
  curl -fsS --aws-sigv4 "aws:amz:auto:s3" \
    --user "${MILES_R2_KEY}:${MILES_R2_SECRET}" \
    -H "Content-Type: application/vnd.android.package-archive" \
    -T "$APK" "$endpoint"
  echo "uploaded"
else
  echo "(no upload: pass --upload)"
fi

# ── 4b. Prove what is actually being served ─────────────────────────────────
# The one check that stops a fleet-bricking release. A blocked client's only way
# back is this URL, so if the hosted bytes are truncated, stale, or the wrong
# file, every gated phone loops forever with no other escape. Costs a full
# download; cheap next to that.
if $verify; then
  echo "verifying $MILES_APK_URL ..."
  served="$(curl -fsSL "$MILES_APK_URL" | sha256sum | cut -d' ' -f1)"
  if [ "$served" != "$sha" ]; then
    echo "MISMATCH — that URL is serving $served, this build is $sha." >&2
    echo "Do not publish it, and do not raise min_build." >&2
    exit 1
  fi
  echo "verified: the hosted bytes are this build"
fi

# ── 5. Publish ──────────────────────────────────────────────────────────────
# Printed rather than executed: it needs a privileged connection, and a release
# is worth reading once before it reaches every phone. latest_build alone is an
# OPTIONAL update; min_build is the hard gate and is deliberately not touched
# here — raise it separately, and only after this APK is proven to install.
cat <<SQL

Publish it by running this against production:

  update public.app_release set
    latest_build        = $pubspec_build,
    latest_version_name = '$version_name',
    apk_url             = '${MILES_APK_URL:-<the public URL of $object>}',
    apk_sha256          = '$sha'
  where id = true;

SQL
