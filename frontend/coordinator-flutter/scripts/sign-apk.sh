#!/usr/bin/env bash
# Sign (and optionally build) the Flutter coordinator release APK with the FULL
# signature set: v1 (JAR), v2, v3 AND v4. This is a wrapper because AGP 9 / the
# build-tools can no longer do the job on their own:
#
#   * AGP 9 removed v1 support from Gradle — `enableV1Signing = true` in
#     app/build.gradle.kts became a no-op, so a plain `flutter build apk --release`
#     emits ONLY v2+v3. MIUI/HyperOS installers still read the v1 JAR manifest and
#     reject a v2-only APK as "this app may be infected by a virus" — the same block
#     the native coordinator-android app (agpksigner-verified v1+v2+v3) must dodge.
#   * Even the newest build-tools apksigner (< 36) refuses --v1-signing-enabled.
#     v1 was removed from apksigner in build-tools 36.0.0. So this script prefers
#     the NEWEST build-tools whose apksigner still advertises --v1-signing-enabled.
#
# Usage:
#   ./scripts/sign-apk.sh build        # flutter build apk --release, then sign + verify
#   ./scripts/sign-apk.sh              # same as `sign` — re-sign the existing APK
#   ./scripts/sign-apk.sh sign
#
# Env overrides:
#   ANDROID_HOME  where to look for build-tools (default: $ANDROID_HOME)
#   APKSIGNER     use a specific apksigner binary (skips build-tools probing)
#   APK           which APK to sign (default: build/app/outputs/flutter-apk/app-release.apk)
#
# The keystore/keystore.properties live OUTSIDE git (same pair as coordinator-android);
# passwords are read and passed via environment, never printed.
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS_PROPERTIES="$APP_ROOT/android/keystore.properties"
KS_DIR="$APP_ROOT/android/app"

apk="${APK:-$APP_ROOT/build/app/outputs/flutter-apk/app-release.apk}"
mode="${1:-sign}"

if [[ ! -f "$KS_PROPERTIES" ]]; then
  echo "ERROR: $KS_PROPERTIES not found — copy from coordinator-android/keystore.properties and point storeFile at the keystore." >&2
  exit 1
fi

# Pick an apksigner. The newest build-tools may have dropped v1 (>= 36.0.0), so take
# the newest that still offers --v1-signing-enabled. `APKSIGNER` overrides entirely.
if [[ -n "${APKSIGNER:-}" ]]; then
  apksigner="$APKSIGNER"
elif [[ -n "${ANDROID_HOME:-}" ]]; then
  apksigner=""
  for v in "$ANDROID_HOME"/build-tools/*; do
    [[ -x "$v/apksigner" ]] || continue
    if "$v/apksigner" sign --help 2>&1 | grep -q -- '--v1-signing-enabled'; then
      apksigner="$v/apksigner"   # iterate sorted (glob sorts lexically = numeric here)
    fi
  done
else
  echo "ERROR: ANDROID_HOME is not set — cannot find apksigner." >&2
  exit 1
fi
if [[ -z "$apksigner" || ! -x "$apksigner" ]]; then
  echo "ERROR: no build-tools apksigner supports the v1 scheme (build-tools < 36 required)." >&2
  exit 1
fi
echo "Using: $apksigner"

if [[ "$mode" == "build" ]]; then
  (cd "$APP_ROOT" && flutter build apk --release)
elif [[ "$mode" != "sign" ]]; then
  echo "Usage: $0 [build|sign]" >&2
  exit 2
fi

[[ -f "$apk" ]] || { echo "ERROR: APK not found: $apk (build it first, or use '$0 build')." >&2; exit 1; }

read_secret() { grep -E "^${1}=" "$KS_PROPERTIES" | head -1 | cut -d= -f2-; }
store_file="$(read_secret storeFile)"
store_pass="$(read_secret storePassword)"
key_alias="$(read_secret keyAlias)"
key_pass="$(read_secret keyPassword)"

# storeFile is resolved relative to the app module, exactly as Gradle does.
if [[ "$store_file" == /* ]]; then
  keystore="$store_file"
else
  keystore="$KS_DIR/$store_file"
fi

for v in store_file store_pass key_alias key_pass; do
  [[ -n "${!v}" ]] || { echo "ERROR: keystore.properties is missing '$v'." >&2; exit 1; }
done
[[ -f "$keystore" ]] || { echo "ERROR: keystore not found: $keystore" >&2; exit 1; }

# Re-sign in place: v1 + v2 + v3 + v4, min SDK 21 so the v1 manifest is honoured
# even on phones that only know the JAR scheme. v4 writes its signature to the
# `<apk>.idsig` file (Android 11+ streaming installs). Note apksigner verify
# (build-tools <= 37) reports "Verified using v4: false" even for a good idsig —
# the verify command never reads the idsig — so v4 is validated by its header below.
"$apksigner" sign \
  --ks "$keystore" \
  --ks-pass "pass:$store_pass" \
  --ks-key-alias "$key_alias" \
  --key-pass "pass:$key_pass" \
  --v1-signing-enabled true \
  --v2-signing-enabled true \
  --v3-signing-enabled true \
  --v4-signing-enabled true \
  --min-sdk-version 21 \
  --out "$apk" \
  "$apk"

echo "--- verifying $apk ---"
verify_output="$("$apksigner" verify --verbose --min-sdk-version 21 "$apk" 2>&1)" \
  || { echo "ERROR: apksigner verify failed:" >&2; printf '%s\n' "$verify_output" >&2; exit 1; }
printf '%s\n' "$verify_output" | grep -E "Verified using (v1|v2|v3|v4)|Number of signers" || true
# v1/v2/v3 are what the real installers enforce (MIUI's v1-only checker above all) — all three must hold.
for scheme in "v1 scheme" "v2 scheme" "v3 scheme"; do
  if ! printf '%s\n' "$verify_output" | grep -qE "Verified using $scheme \(.*\): true"; then
    echo "ERROR: APK is missing a valid $scheme signature." >&2
    exit 1
  fi
done

idsig="$apk.idsig"
if [[ ! -f "$idsig" ]]; then
  echo "ERROR: $idsig missing — v4 streaming-install signature was not produced." >&2
  exit 1
fi
idsig_header="$(od -An -tx1 -N4 "$idsig" | tr -d ' \n')"
if [[ "$idsig_header" != "02000000" ]]; then
  echo "ERROR: $idsig has unexpected header $idsig_header (expected 02000000) — corrupt idsig." >&2
  exit 1
fi
echo "Signed APK: $apk"
echo "v4 idsig:   $idsig ($(stat -c %s "$idsig") bytes, header $idsig_header)"