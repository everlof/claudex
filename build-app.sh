#!/bin/bash
# Assemble Claudex.app from the SwiftPM release build.
# Produces a proper .app bundle so MenuBarExtra + LSUIElement work and the app can
# be code-signed for stable macOS automation permissions.
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
mkdir -p "$BUNDLE/Contents/Helpers"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BIN_PATH/ClaudexStatusBridge" "$BUNDLE/Contents/Helpers/ClaudexStatusBridge"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# App icon (CFBundleIconFile points at "Claudex" → Contents/Resources/Claudex.icns).
if [ -f "$ROOT/Resources/Claudex.icns" ]; then
    cp "$ROOT/Resources/Claudex.icns" "$BUNDLE/Contents/Resources/$APP_NAME.icns"
fi

# Code sign with a STABLE identity so Apple Events permissions persist across rebuilds.
# Ad-hoc signatures change every build; an Apple Development certificate keeps a stable
# code identity for Terminal/iTerm frontmost-session detection.
#
# Override with CLAUDEX_SIGN_ID="Apple Development: Your Name (TEAMID)"; otherwise we pick
# the first available Apple Development identity, falling back to ad-hoc. Set
# CLAUDEX_ADHOC_SIGN=1 to force ad-hoc (used by sandboxed Homebrew builds), or
# CLAUDEX_REQUIRE_SIGNING=1 to make an explicit signing failure fatal (public releases).
SIGN_ID="${CLAUDEX_SIGN_ID:-}"
REQUIRE_SIGNING="${CLAUDEX_REQUIRE_SIGNING:-0}"
if [ -z "$SIGN_ID" ] && [ "${CLAUDEX_ADHOC_SIGN:-0}" != "1" ]; then
    # `|| true` so a sandbox that blocks identity lookup can't abort us under `set -e`.
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)"
fi

# The apple-events entitlement is required under the hardened runtime to send Apple
# Events (we query Terminal/iTerm for the frontmost tab). Without it, AppleScript is
# blocked with no prompt.
ENTITLEMENTS="$ROOT/Resources/Claudex.entitlements"
HELPER="$BUNDLE/Contents/Helpers/ClaudexStatusBridge"

sign_ad_hoc() {
    codesign --force --options runtime --sign - "$HELPER" >/dev/null 2>&1
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
        --sign - "$BUNDLE" >/dev/null 2>&1
}

if [ -n "$SIGN_ID" ]; then
    echo "▸ Code signing with: $SIGN_ID"
    SIGN_ARGS=(--force --options runtime --sign "$SIGN_ID")
    if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then
        SIGN_ARGS+=(--timestamp)
    fi
    # Sign nested code first, then seal it into the app bundle. `--deep` signing can
    # accidentally apply the app's Apple Events entitlement to the helper.
    if codesign "${SIGN_ARGS[@]}" "$HELPER" >/dev/null 2>&1 \
        && codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" \
            "$BUNDLE" >/dev/null 2>&1; then
        echo "  ✓ stable signature + apple-events entitlement"
    else
        if [ "$REQUIRE_SIGNING" = "1" ]; then
            echo "  signing with required identity failed" >&2
            exit 1
        fi
        echo "  signing with identity failed; falling back to ad-hoc"
        sign_ad_hoc
    fi
else
    echo "▸ Code signing (ad-hoc)"
    sign_ad_hoc
fi

codesign --verify --deep --strict "$BUNDLE"

echo "✓ Built $BUNDLE"
