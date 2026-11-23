#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Charkle"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME and charkle CLI/MCP helper ($CONFIG)..."
cd "$ROOT_DIR"
swift build -c "$CONFIG" --product "$APP_NAME"
swift build -c "$CONFIG" --product "charkle-cli"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
CLI_BIN_PATH="$BIN_DIR/charkle-cli"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: Binary not found at $BIN_PATH" >&2
  exit 1
fi
if [[ ! -f "$CLI_BIN_PATH" ]]; then
  echo "ERROR: Helper CLI binary not found at $CLI_BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_BUNDLE..."
# Stage and sign outside iCloud-synced ~/Documents so FileProvider never injects
# `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` detritus before codesign.
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/charkle-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE_BUNDLE="$STAGE_DIR/$APP_NAME.app"
mkdir -p "$STAGE_BUNDLE/Contents/MacOS" "$STAGE_BUNDLE/Contents/Resources" "$STAGE_BUNDLE/Contents/Helpers"

cp -X "$BIN_PATH" "$STAGE_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$STAGE_BUNDLE/Contents/MacOS/$APP_NAME"
cp -X "$CLI_BIN_PATH" "$STAGE_BUNDLE/Contents/Helpers/charkle"
chmod +x "$STAGE_BUNDLE/Contents/Helpers/charkle"
cp -X "$ROOT_DIR/Resources/Info.plist" "$STAGE_BUNDLE/Contents/Info.plist"

# Copy SwiftPM resource bundles (including bundled SVG icon assets)
for bundle in "$BIN_DIR"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -RX "$bundle" "$STAGE_BUNDLE/Contents/Resources/"
  fi
done

# Embed offline Charkle -> Figma / FigJam Bridge plugin
if [[ -d "$ROOT_DIR/Resources/FigmaPlugin" ]]; then
  python3 - "$ROOT_DIR/Resources/FigmaPlugin" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
tpl = p / 'ui-template.html'
if tpl.exists():
    s = tpl.read_text(encoding='utf-8')
    for marker, file in [('/*__JSZIP__*/', 'jszip.min.js'), ('/*__SHA256__*/', 'sha256.min.js')]:
        s = s.replace(marker, (p / file).read_text(encoding='utf-8'))
    (p / 'ui.html').write_text(s, encoding='utf-8')
PY
  mkdir -p "$STAGE_BUNDLE/Contents/Resources/FigmaPlugin"
  cp -X "$ROOT_DIR/Resources/FigmaPlugin/manifest.json" \
        "$ROOT_DIR/Resources/FigmaPlugin/code.js" \
        "$ROOT_DIR/Resources/FigmaPlugin/ui.html" \
        "$ROOT_DIR/Resources/FigmaPlugin/JSZIP-LICENSE.md" \
        "$ROOT_DIR/Resources/FigmaPlugin/SHA256-LICENSE.txt" \
        "$STAGE_BUNDLE/Contents/Resources/FigmaPlugin/"
fi

# Embed app-level Google Desktop OAuth client for zero-setup end-user Google Sign-In if present
if [[ -f "$ROOT_DIR/Resources/GoogleOAuthClient.json" ]]; then
  cp -X "$ROOT_DIR/Resources/GoogleOAuthClient.json" "$STAGE_BUNDLE/Contents/Resources/GoogleOAuthClient.json"
fi

# Use prebuilt AppIcon.icns (default Light variant) and bundle switchable AppIcon PNG variants
if [[ -d "$ROOT_DIR/Resources/AppIcons" ]]; then
  cp -X "$ROOT_DIR/Resources/AppIcons"/AppIcon-*.png "$STAGE_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp -X "$ROOT_DIR/Resources/AppIcon.icns" "$STAGE_BUNDLE/Contents/Resources/AppIcon.icns"
elif [[ -f "$ROOT_DIR/Resources/AppIcon-1024.png" ]]; then
  ICONSET_DIR="$STAGE_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    sz="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$sz" "$sz" "$ROOT_DIR/Resources/AppIcon-1024.png" --out "$ICONSET_DIR/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$STAGE_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Strip any extended attributes before codesign
xattr -cr "$STAGE_BUNDLE"

# Prefer a stable code-signing certificate (Developer ID or Apple Development) so macOS Keychain
# binds ACL permissions to a stable Designated Requirement instead of a changing ad-hoc CDHash.
SIGN_IDENTITY="${CHARKLE_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Developer ID Application:/ {print $2; exit}'
  )"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Apple Development:/ {print $2; exit}'
  )"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing $APP_NAME.app with stable code-signing certificate..."
  codesign --force --sign "$SIGN_IDENTITY" "$STAGE_BUNDLE/Contents/Helpers/charkle"
  codesign --force --sign "$SIGN_IDENTITY" "$STAGE_BUNDLE"
else
  echo "==> No signing certificate found; falling back to ad-hoc signing (-)"
  codesign --force --deep --sign - "$STAGE_BUNDLE" >/dev/null 2>&1 || true
fi

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
ditto "$STAGE_BUNDLE" "$APP_BUNDLE"
echo "==> Done: $APP_BUNDLE"
