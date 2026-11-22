#!/usr/bin/env bash
set -euo pipefail

# Installs a user-designed app icon (.png, .icns, .jpg, or .webp) into Resources/AppIcon.icns
# Usage: ./scripts/set-app-icon.sh /path/to/your-icon.png

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
  echo "Usage: $0 <path-to-1024px-png-or-icns>" >&2
  exit 1
fi

EXT="${SRC##*.}"
EXT_LOWER="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"
OUT_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
OUT_PNG="$ROOT_DIR/Resources/AppIcon-1024.png"

if [[ "$EXT_LOWER" == "icns" ]]; then
  cp "$SRC" "$OUT_ICNS"
  echo "Installed $OUT_ICNS"
else
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  ICONSET="$TMP_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"

  sips -s format png -z 1024 1024 "$SRC" --out "$OUT_PNG" >/dev/null
  for spec in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" \
    "1024:icon_512x512@2x.png"; do
    sz="${spec%%:*}"
    name="${spec#*:}"
    sips -s format png -z "$sz" "$sz" "$OUT_PNG" --out "$ICONSET/$name" >/dev/null
  done

  iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
  echo "Generated $OUT_ICNS from $SRC"
fi

if [[ -d "$ROOT_DIR/dist/Charkle.app" ]]; then
  cp "$OUT_ICNS" "$ROOT_DIR/dist/Charkle.app/Contents/Resources/AppIcon.icns"
  touch "$ROOT_DIR/dist/Charkle.app"
  echo "Updated dist/Charkle.app icon bundle."
fi
