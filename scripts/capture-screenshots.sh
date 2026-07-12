#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUTPUT="$ROOT/docs/screenshots"
mkdir -p "$OUTPUT"

echo "==> building signed screenshot app"
./build-app.sh release

APP="$ROOT/Claudex.app/Contents/MacOS/Claudex"
SCENARIOS=(
  "overview:1200:overview.png"
  "handoff:850:handoff.png"
  "single:560:single-account.png"
)

for spec in "${SCENARIOS[@]}"; do
  IFS=: read -r scenario height filename <<< "$spec"
  destination="$OUTPUT/$filename"
  echo "==> capturing $scenario -> docs/screenshots/$filename"
  env \
    CLAUDEX_CAPTURE=1 \
    CLAUDEX_CAPTURE_EXIT=1 \
    CLAUDEX_CAPTURE_HEIGHT="$height" \
    CLAUDEX_CAPTURE_PATH="$destination" \
    CLAUDEX_DEMO_SCENARIO="$scenario" \
    "$APP"
  if [ ! -s "$destination" ]; then
    echo "capture-screenshots.sh: $filename was not produced" >&2
    exit 1
  fi
done

# The README's primary product image is the full overview scenario.
cp "$OUTPUT/overview.png" "$ROOT/docs/screenshot.png"

echo "==> screenshots updated"
for image in "$OUTPUT"/*.png "$ROOT/docs/screenshot.png"; do
  dimensions="$(sips -g pixelWidth -g pixelHeight "$image" 2>/dev/null | tail -2 | tr '\n' ' ')"
  echo "    ${image#"$ROOT/"} · $dimensions"
done
