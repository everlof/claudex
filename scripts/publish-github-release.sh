#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALLOW_UNNOTARIZED=0
NOTARIZE=1
NOTARY_PROFILE="${CLAUDEX_NOTARY_PROFILE:-mjukis-notary}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-unnotarized)
      ALLOW_UNNOTARIZED=1
      NOTARIZE=0
      ;;
    --notarize)
      NOTARIZE=1
      ALLOW_UNNOTARIZED=0
      ;;
    --notary-profile)
      if [ "${2:-}" = "" ]; then
        echo "publish-github-release.sh: --notary-profile requires a value" >&2
        exit 2
      fi
      NOTARY_PROFILE="$2"
      shift
      ;;
    -h|--help)
      echo "usage: scripts/publish-github-release.sh [--notarize] [--notary-profile PROFILE] [--allow-unnotarized]"
      echo "env: CLAUDEX_VERSION, CLAUDEX_NOTARY_PROFILE"
      echo "default: Developer ID sign, notarize, staple, and Gatekeeper-verify"
      exit 0
      ;;
    *)
      echo "publish-github-release.sh: unknown argument '$1'" >&2
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

TAG="v$VERSION"
APP="$ROOT/Claudex.app"
ZIP="$ROOT/dist/Claudex-$VERSION.zip"
URL="https://github.com/everlof/claudex/releases/download/$TAG/Claudex-$VERSION.zip"

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "publish-github-release.sh: missing local tag $TAG" >&2
  echo "Create and push the release tag before publishing the GitHub release asset." >&2
  exit 1
fi
if [ "$(git rev-list -n 1 "$TAG")" != "$(git rev-parse HEAD)" ]; then
  echo "publish-github-release.sh: $TAG does not point at HEAD" >&2
  exit 1
fi
if [ "$(git cat-file -t "$TAG")" != "tag" ]; then
  echo "publish-github-release.sh: $TAG must be an annotated tag" >&2
  exit 1
fi
REMOTE_TAG_COMMIT="$(git ls-remote --tags origin "refs/tags/$TAG^{}" | awk 'NR == 1 { print $1 }')"
if [ -z "$REMOTE_TAG_COMMIT" ] || [ "$REMOTE_TAG_COMMIT" != "$(git rev-parse HEAD)" ]; then
  echo "publish-github-release.sh: remote annotated tag $TAG does not point at HEAD" >&2
  exit 1
fi
if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo "publish-github-release.sh: working tree must be completely clean (including untracked files)" >&2
  exit 1
fi

release_args=()
if [ "$NOTARIZE" -eq 1 ]; then
  release_args+=(--notarize --notary-profile "$NOTARY_PROFILE")
elif [ "$ALLOW_UNNOTARIZED" -eq 1 ]; then
  release_args+=(--allow-unnotarized)
fi

./scripts/release.sh "${release_args[@]}"

GATEKEEPER_NOTE="Direct app download: \`Claudex-$VERSION.zip\` (universal macOS app for Apple Silicon and Intel)."
if spctl --assess --type execute --verbose=4 "$APP" >/dev/null 2>&1; then
  GATEKEEPER_NOTE="$GATEKEEPER_NOTE Developer ID signed, notarized by Apple, stapled, and Gatekeeper accepted."
else
  GATEKEEPER_NOTE="$GATEKEEPER_NOTE This app bundle is Apple Development signed, not Developer ID notarized, so macOS Gatekeeper may require an explicit Open action on first launch. Homebrew remains the recommended install path."
fi

CHANGELOG_NOTES="$(awk -v version="$VERSION" '
  $0 ~ "^## \\[" version "\\]" { printing = 1; next }
  printing && /^## \[/ { exit }
  printing { print }
' CHANGELOG.md)"
if [ -z "${CHANGELOG_NOTES//[[:space:]]/}" ]; then
  echo "publish-github-release.sh: CHANGELOG.md has no section for $VERSION" >&2
  exit 1
fi
RELEASE_NOTES="${CHANGELOG_NOTES}"$'\n\n'"${GATEKEEPER_NOTE}"

if gh release view "$TAG" --repo everlof/claudex >/dev/null 2>&1; then
  echo "==> upload asset to existing GitHub release $TAG"
  gh release upload "$TAG" "$ZIP" --repo everlof/claudex --clobber
  gh release edit "$TAG" --repo everlof/claudex --notes "$RELEASE_NOTES"
else
  echo "==> create GitHub release $TAG"
  gh release create "$TAG" "$ZIP" \
    --repo everlof/claudex \
    --title "Claudex $VERSION" \
    --notes "$RELEASE_NOTES"
fi

echo "==> GitHub release asset published"
echo "    url: $URL"
echo "    sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo ""
if [ "$ALLOW_UNNOTARIZED" -eq 1 ]; then
  echo "Next: ./scripts/publish-website-release.sh --allow-unnotarized"
else
  echo "Next: ./scripts/publish-website-release.sh"
fi
