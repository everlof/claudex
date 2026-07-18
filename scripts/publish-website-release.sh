#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALLOW_UNNOTARIZED=0
for arg in "$@"; do
  case "$arg" in
    --allow-unnotarized) ALLOW_UNNOTARIZED=1 ;;
    -h|--help)
      echo "usage: scripts/publish-website-release.sh [--allow-unnotarized]"
      echo "env: MJUKIS_DEV_PATH, CLAUDEX_RELEASE_URL"
      exit 0
      ;;
    *)
      echo "publish-website-release.sh: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

MJUKIS_DEV_PATH="${MJUKIS_DEV_PATH:-/Users/david/mjukis/projects/mjukis.dev}"
if [ -z "$MJUKIS_DEV_PATH" ] || [ ! -d "$MJUKIS_DEV_PATH" ]; then
  echo "publish-website-release.sh: set MJUKIS_DEV_PATH to a mjukis.dev checkout" >&2
  exit 2
fi
VERSION="${CLAUDEX_VERSION:-}"
if [ -z "$VERSION" ]; then
  TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
  VERSION="${TAG#v}"
fi
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
fi
APP="$ROOT/Claudex.app"
ZIP="$ROOT/dist/Claudex-$VERSION.zip"
RELEASE_URL="${CLAUDEX_RELEASE_URL:-https://github.com/everlof/claudex/releases/download/v$VERSION/Claudex-$VERSION.zip}"

if [ ! -d "$APP" ] || [ ! -f "$ZIP" ]; then
  echo "publish-website-release.sh: missing $APP or $ZIP" >&2
  echo "Run ./scripts/release.sh first." >&2
  exit 1
fi

if ! spctl --assess --type execute --verbose=4 "$APP"; then
  echo "publish-website-release.sh: Gatekeeper rejected $APP" >&2
  if [ "$ALLOW_UNNOTARIZED" -ne 1 ]; then
    echo "Pass --allow-unnotarized only for an explicitly documented non-notarized beta." >&2
    exit 3
  fi
fi

node "$MJUKIS_DEV_PATH/scripts/update-app-release.js" \
  --app claudex \
  --name "Claudex" \
  --tagline "Claude and Codex usage at a glance" \
  --platform "macOS" \
  --status "released" \
  --version "$VERSION" \
  --direct-url "$RELEASE_URL" \
  --website-url "https://github.com/everlof/claudex" \
  --repo-url "https://github.com/everlof/claudex" \
  --release-date "$(date -u +%F)" \
  --description "A menu-bar app that shows Claude and Codex usage across multiple logins, rate-limit windows, reset countdowns, and usage history."

echo "Updated mjukis.dev metadata for Claudex $VERSION."
echo "Review $MJUKIS_DEV_PATH, then run npm run build and npm run deploy there."
