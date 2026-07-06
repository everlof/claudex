#!/bin/bash
# Assemble Claudex.app from the SwiftPM release build.
# Produces a proper .app bundle so MenuBarExtra + LSUIElement work and the app can
# be code-signed for stable keychain access.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Claudex"
BUNDLE="$ROOT/$APP_NAME.app"
CONFIG="${1:-release}"

# Extra flags for `swift build`, e.g. --disable-sandbox when building under Homebrew.
SWIFT_FLAGS="${CLAUDEX_SWIFT_FLAGS:-}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" $SWIFT_FLAGS

BIN_PATH="$(swift build -c "$CONFIG" $SWIFT_FLAGS --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# Code sign with a STABLE identity so the keychain "Always Allow" grant persists
# across rebuilds. Ad-hoc signatures change every build, which forces a fresh keychain
# prompt each time; a consistent Apple Development cert keeps the same code identity, so
# the user only has to click "Always Allow" once.
#
# Override with CLAUDEX_SIGN_ID="Apple Development: Your Name (TEAMID)"; otherwise we pick
# the first available Apple Development identity, falling back to ad-hoc.
SIGN_ID="${CLAUDEX_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
fi

# The apple-events entitlement is required under the hardened runtime to send Apple
# Events (we query Terminal/iTerm for the frontmost tab). Without it, AppleScript is
# blocked with no prompt.
ENTITLEMENTS="$ROOT/Resources/Claudex.entitlements"

if [ -n "$SIGN_ID" ]; then
    echo "▸ Code signing with: $SIGN_ID"
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_ID" "$BUNDLE" >/dev/null 2>&1 && {
        echo "  ✓ stable signature + apple-events entitlement"
    } || {
        echo "  signing with identity failed; falling back to ad-hoc"
        codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$BUNDLE" >/dev/null 2>&1 || true
    }
else
    echo "▸ Code signing (ad-hoc — keychain will re-prompt after each rebuild)"
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$BUNDLE" >/dev/null 2>&1 || true
fi

echo "✓ Built $BUNDLE"
