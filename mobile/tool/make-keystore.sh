#!/usr/bin/env bash
# Creates the Play UPLOAD key and the key.properties that build.gradle.kts reads.
#
# Run this yourself: the password is read interactively and never appears in an
# agent transcript, a shell history line, or a log. Nothing here is committable
# — .gitignore already covers *.jks, *.keystore and key.properties in all three
# gitignores, verified before this script was written.
#
#   bash tool/make-keystore.sh
#
# WHAT THIS KEY IS. With Play App Signing (opt in at first upload, and you
# should) Google holds the real app-signing key and this is only the UPLOAD key
# — the one that proves a bundle came from you. If you ever lose it, Google can
# reset it and you keep publishing. WITHOUT Play App Signing, losing this file
# means you can never update the app again under this package name. Back up the
# .jks and its password somewhere off this machine either way.
set -euo pipefail
cd "$(dirname "$0")/../android"

KEYSTORE="miles-upload.jks"
ALIAS="miles-upload"

# Refuse rather than overwrite. Regenerating over a key that has already signed
# an uploaded bundle locks you out of your own listing.
if [ -f "$KEYSTORE" ]; then
  echo "refusing: android/$KEYSTORE already exists." >&2
  echo "If you meant to replace it, move it aside first — and do not do that" >&2
  echo "if it has already signed anything you uploaded to Play." >&2
  exit 1
fi
if [ -f key.properties ]; then
  echo "refusing: android/key.properties already exists." >&2
  exit 1
fi

# keytool ships with the JDK and is not on PATH on this machine. Look where it
# actually is before asking the user to fix their environment.
if ! command -v keytool >/dev/null; then
  for candidate in \
    "/c/Program Files/Java/jdk-17/bin" \
    "/c/Program Files/Android/Android Studio/jbr/bin" \
    "/c/Program Files/Eclipse Adoptium"/*/bin
  do
    if [ -x "$candidate/keytool.exe" ] || [ -x "$candidate/keytool" ]; then
      PATH="$candidate:$PATH"
      break
    fi
  done
fi
command -v keytool >/dev/null || {
  echo "keytool not found. It ships with the JDK — add its bin/ to PATH:" >&2
  echo '  export PATH="/c/Program Files/Java/jdk-17/bin:$PATH"' >&2
  exit 1
}

echo "Certificate identity — this is baked into the key permanently."
echo "Press enter to accept the default shown in brackets."
read -r -p "  Organisation [R&D Dev]: " ORG;      ORG="${ORG:-R&D Dev}"
read -r -p "  Country code [PK]: "     COUNTRY;  COUNTRY="${COUNTRY:-PK}"

# -s: no echo. Read twice, because a typo here is only discovered later, at the
# one moment you cannot afford it.
read -r -s -p "  New keystore password: " PW; echo
read -r -s -p "  Repeat it: " PW2; echo
[ "$PW" = "$PW2" ] || { echo "passwords differ — nothing created." >&2; exit 1; }
[ "${#PW}" -ge 8 ] || { echo "use at least 8 characters — nothing created." >&2; exit 1; }

# PKCS12, not JKS: keytool warns that JKS is proprietary and tells you to
# migrate, on every single invocation.
# 10000 days (~27 years) — Play requires an upload certificate valid well past
# 2033, and a key that expires mid-life is an outage you schedule for yourself.
# -storepass:env reads the password from the named environment variable rather
# than from argv, so it never appears in `ps` output for anything else running
# on this machine.
KSPW="$PW" keytool -genkeypair \
  -storetype PKCS12 \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass:env KSPW -keypass:env KSPW \
  -dname "CN=Miles, O=$ORG, C=$COUNTRY"

# 077 so the file lands readable only by you — it contains the password in
# plaintext, which is the format Gradle requires.
umask 077
cat > key.properties <<PROPS
storeFile=$KEYSTORE
storePassword=$PW
keyAlias=$ALIAS
keyPassword=$PW
PROPS

unset PW PW2 KSPW

echo
echo "Created:"
echo "  android/$KEYSTORE   (the key — BACK THIS UP OFF THIS MACHINE)"
echo "  android/key.properties  (contains the password in plaintext, gitignored)"
echo
echo "Verify with:   cd mobile/android && ./gradlew :app:signingReport"
echo "Then tell the release session, which will build the first AAB."
