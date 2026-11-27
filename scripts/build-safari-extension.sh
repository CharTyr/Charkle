#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_APPEX="${1:?Usage: build-safari-extension.sh <output-dir/CharkleSafariExtension.appex>}"
EXT_SRC="$ROOT_DIR/Resources/BrowserExtension"
SAFARI_SRC="$ROOT_DIR/Resources/SafariExtension"

if [[ ! -f "$EXT_SRC/manifest.json" ]]; then
  echo "ERROR: Browser extension source not found at $EXT_SRC" >&2
  exit 1
fi

ARCH="$(uname -m)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$OUT_APPEX"
mkdir -p "$OUT_APPEX/Contents/MacOS" "$OUT_APPEX/Contents/Resources/icons" "$OUT_APPEX/Contents/Resources/lib"

echo "==> Compiling native Safari Web Extension binary ($ARCH)..."
xcrun swiftc \
  -module-name CharkleSafariExtension \
  -parse-as-library \
  -application-extension \
  -target "${ARCH}-apple-macos15.0" \
  -sdk "$SDK_PATH" \
  -framework Foundation \
  -framework SafariServices \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
  -O \
  "$SAFARI_SRC/SafariWebExtensionHandler.swift" \
  -o "$OUT_APPEX/Contents/MacOS/CharkleSafariExtension"

chmod +x "$OUT_APPEX/Contents/MacOS/CharkleSafariExtension"
cp -X "$SAFARI_SRC/Info.plist" "$OUT_APPEX/Contents/Info.plist"

# Copy shared extension assets (popup, options, content, page bridges, lib, icons)
for f in content.js page-bridge.js x-bridge-loader.js popup.html popup.css popup.js options.html options.css options.js; do
  cp -X "$EXT_SRC/$f" "$OUT_APPEX/Contents/Resources/$f"
done
cp -X "$EXT_SRC"/lib/*.js "$OUT_APPEX/Contents/Resources/lib/"
cp -X "$EXT_SRC"/icons/* "$OUT_APPEX/Contents/Resources/icons/"

# Produce Safari-clean manifest.json (strips Chrome-only notifications/open_in_tab/background.type)
# and a classic single-file background.js (universally supported on every macOS Safari 15.4+ runtime).
python3 - "$EXT_SRC" "$OUT_APPEX/Contents/Resources" <<'PY'
import json
import re
import sys
from pathlib import Path

src_dir = Path(sys.argv[1])
dst_dir = Path(sys.argv[2])

manifest = json.loads((src_dir / 'manifest.json').read_text(encoding='utf-8'))
manifest['permissions'] = [p for p in manifest.get('permissions', []) if p != 'notifications']
if isinstance(manifest.get('options_ui'), dict):
    manifest['options_ui'].pop('open_in_tab', None)
manifest['background'] = {
    'service_worker': 'background.js',
}
(dst_dir / 'manifest.json').write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + '\n',
    encoding='utf-8',
)

def strip_esm(source: str) -> str:
    # Remove multi-line or single-line ESM import declarations
    cleaned = re.sub(
        r'(?m)^\s*import\s+(?:[\s\S]*?)\s+from\s+[\'"][^\'"]+[\'"];?\s*$',
        '',
        source,
    )
    # Strip leading `export ` keyword on declarations
    cleaned = re.sub(
        r'(?m)^(\s*)export\s+(?=(?:async\s+)?(?:function|const|let|var|class)\b)',
        r'\1',
        cleaned,
    )
    return cleaned.strip()

bundle_parts = [
    '// Auto-bundled classic Safari MV3 Service Worker — generated from Resources/BrowserExtension',
    '(function () {',
    '  "use strict";',
]
for rel in ['lib/url-detect.js', 'lib/storage.js', 'lib/api.js', 'background.js']:
    code = strip_esm((src_dir / rel).read_text(encoding='utf-8'))
    bundle_parts.append(f'// --- {rel} ---\n{code}')
bundle_parts.append('})();\n')

out_bg = dst_dir / 'background.js'
out_bg.write_text('\n\n'.join(bundle_parts), encoding='utf-8')
PY

# Verify generated classic Safari background script and content bridges parse cleanly in JS engine
if command -v node >/dev/null 2>&1; then
  node --check "$OUT_APPEX/Contents/Resources/background.js"
  node --check "$OUT_APPEX/Contents/Resources/content.js"
  node --check "$OUT_APPEX/Contents/Resources/page-bridge.js"
  node --check "$OUT_APPEX/Contents/Resources/x-bridge-loader.js"
fi

echo "==> Built Safari Web Extension: $OUT_APPEX"
