#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALLOW_UNNOTARIZED=0
UNIVERSAL=1
SIGNING_MODE="development"
NOTARIZE=0
SIGNING_IDENTITY="${CLAUDEX_DISTRIBUTION_SIGN_ID:-Developer ID Application: MJUKIS AB (SMQ3E8Y57T)}"
NOTARY_PROFILE="${CLAUDEX_NOTARY_PROFILE:-mjukis-notary}"
NOTARY_TIMEOUT="${CLAUDEX_NOTARY_TIMEOUT:-30m}"

usage() {
  cat <<EOF
usage: scripts/release.sh [options]

Options:
  --developer-id               Sign with a Developer ID Application identity
  --notarize                   Developer ID sign, submit, staple, and verify
  --signing-identity IDENTITY  Override the Developer ID identity
  --notary-profile PROFILE     notarytool keychain profile (default: $NOTARY_PROFILE)
  --allow-unnotarized          Permit a local/private non-Gatekeeper package
  --no-universal               Build only the current architecture

Environment:
  CLAUDEX_DISTRIBUTION_SIGN_ID Default Developer ID identity
  CLAUDEX_NOTARY_PROFILE       Default notarytool keychain profile
  CLAUDEX_NOTARY_TIMEOUT       notarytool wait timeout (default: $NOTARY_TIMEOUT)
  CLAUDEX_SWIFT_FLAGS          Extra SwiftPM build flags
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-unnotarized) ALLOW_UNNOTARIZED=1 ;;
    --no-universal) UNIVERSAL=0 ;;
    --developer-id) SIGNING_MODE="developer-id" ;;
    --notarize)
      SIGNING_MODE="developer-id"
      NOTARIZE=1
      ;;
    --signing-identity)
      if [ "${2:-}" = "" ]; then
        echo "release.sh: --signing-identity requires a value" >&2
        exit 2
      fi
      SIGNING_IDENTITY="$2"
      shift
      ;;
    --notary-profile)
      if [ "${2:-}" = "" ]; then
        echo "release.sh: --notary-profile requires a value" >&2
        exit 2
      fi
      NOTARY_PROFILE="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "release.sh: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
  shift
done

VERSION="${CLAUDEX_VERSION:-}"
if [ -z "$VERSION" ]; then
  TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
  VERSION="${TAG#v}"
fi
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
fi
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
if [ "$VERSION" != "$SHORT_VERSION" ] || [ "$VERSION" != "$BUILD_VERSION" ]; then
  echo "release.sh: release version $VERSION does not match bundle versions $SHORT_VERSION ($BUILD_VERSION)" >&2
  exit 2
fi
APP="Claudex.app"
DIST="$ROOT/dist"
ZIP="$DIST/Claudex-$VERSION.zip"

echo "==> Claudex release $VERSION"
echo "==> signing mode: $SIGNING_MODE"

if [ "$SIGNING_MODE" = "developer-id" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning)"
  if [[ "$IDENTITIES" != *"\"$SIGNING_IDENTITY\""* ]]; then
    echo "release.sh: no codesigning identity matching '$SIGNING_IDENTITY' was found" >&2
    exit 3
  fi
  export CLAUDEX_SIGN_ID="$SIGNING_IDENTITY"
  export CLAUDEX_REQUIRE_SIGNING=1
fi

if [ "$NOTARIZE" -eq 1 ]; then
  xcrun -f notarytool >/dev/null
  xcrun -f stapler >/dev/null
  echo "==> notarization profile: $NOTARY_PROFILE"
  # Fail before a long build if the stored credentials are missing or invalid.
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
fi

if [ "$UNIVERSAL" -eq 1 ] && [ -z "${CLAUDEX_SWIFT_FLAGS:-}" ]; then
  export CLAUDEX_SWIFT_FLAGS="--arch arm64 --arch x86_64"
  echo "==> universal build (arm64 + x86_64)"
fi
./build-app.sh release

echo "==> verify code signature"
codesign --verify --deep --strict "$APP"
if [ "$SIGNING_MODE" = "developer-id" ]; then
  for executable in "$APP" "$APP/Contents/Helpers/ClaudexStatusBridge"; do
    SIGNATURE_INFO="$(codesign -dvv "$executable" 2>&1)"
    if [[ "$SIGNATURE_INFO" != *"Authority=$SIGNING_IDENTITY"* ]]; then
      echo "release.sh: $executable is not signed with the required Developer ID identity" >&2
      exit 3
    fi
  done
fi

echo "==> binary architectures"
file "$APP/Contents/MacOS/Claudex"
file "$APP/Contents/Helpers/ClaudexStatusBridge"
if [ "$UNIVERSAL" -eq 1 ]; then
  lipo "$APP/Contents/MacOS/Claudex" -verify_arch arm64 x86_64
  lipo "$APP/Contents/Helpers/ClaudexStatusBridge" -verify_arch arm64 x86_64
  echo "==> verified arm64 + x86_64 app and helper"
fi

mkdir -p "$DIST"
rm -f "$ZIP"
echo "==> zipping -> $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" -eq 1 ]; then
  echo "==> submitting $ZIP to Apple notarization"
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout "$NOTARY_TIMEOUT"

  echo "==> stapling notarization ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --deep --strict "$APP"

  echo "==> Gatekeeper assessment"
  spctl --assess --type execute --verbose=4 "$APP"

  echo "==> re-zipping stapled app -> $ZIP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "==> Gatekeeper assessment"
  if spctl --assess --type execute --verbose=4 "$APP"; then
    echo "==> Gatekeeper accepted"
  else
    echo "==> Gatekeeper rejected $APP" >&2
    if [ "$ALLOW_UNNOTARIZED" -ne 1 ]; then
      echo "release.sh: refusing public direct-download package without notarization" >&2
      echo "release.sh: use --notarize, or --allow-unnotarized only for local/private builds" >&2
      exit 3
    fi
    echo "==> continuing because --allow-unnotarized was passed" >&2
  fi
fi

echo "==> release package complete"
echo "    version: $VERSION"
echo "    app    : $ROOT/$APP"
echo "    zip    : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "    sha256 : $(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [ "$NOTARIZE" -eq 1 ]; then
  echo "    status : Developer ID signed, notarized, stapled, Gatekeeper accepted"
elif [ "$SIGNING_MODE" = "developer-id" ]; then
  echo "    status : Developer ID signed, not notarized"
else
  echo "    status : local development/ad-hoc build"
fi
