#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Charkle"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

if [[ "${1:-}" == "--rebuild" || ! -d "$APP_BUNDLE" ]]; then
  "$ROOT_DIR/scripts/build-app.sh" release
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: $APP_BUNDLE not found." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "1.4.1")"
ARCH="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null | tr ' ' '-' || echo "arm64")"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
FINAL_DMG="$DIST_DIR/$DMG_NAME"
VOL_NAME="$APP_NAME $VERSION"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/charkle-dmg.XXXXXX")"
RW_DMG="$WORK_DIR/${APP_NAME}-rw.dmg"
STAGE_DIR="$WORK_DIR/stage"
BG_DIR="$STAGE_DIR/.background"
MOUNT_POINT=""
VERIFY_MOUNT=""

cleanup() {
  if [[ -n "$VERIFY_MOUNT" && -d "$VERIFY_MOUNT" ]]; then
    hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR" "$BG_DIR"

echo "==> Staging $APP_NAME.app and Applications link..."
cp -RX "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
xattr -cr "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Verifying signed app bundle..."
codesign -v --deep --strict "$STAGE_DIR/$APP_NAME.app"

# Generate minimalist 2x Retina DMG installer background (660x420pt -> 1320x840px)
swift - "$BG_DIR/background.png" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments[1]
let width = 1320
let height = 840

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    exit(1)
}

// Crisp gallery off-white gradient ground matching Charkle's neutral light canvas
let topColor = CGColor(colorSpace: colorSpace, components: [0.976, 0.976, 0.972, 1.0])!
let botColor = CGColor(colorSpace: colorSpace, components: [0.945, 0.945, 0.938, 1.0])!
let grad = CGGradient(colorsSpace: colorSpace, colors: [topColor, botColor] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: 0), options: [])

// Subtle architectural dot grid
ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.12, 0.14, 0.18, 0.055])!)
let step = 44
for y in stride(from: 36, to: height - 20, by: step) {
    for x in stride(from: 36, to: width - 20, by: step) {
        ctx.fillEllipse(in: CGRect(x: CGFloat(x) - 1.5, y: CGFloat(y) - 1.5, width: 3, height: 3))
    }
}

// Soft rounded drop pedestals for Charkle.app (left) and Applications (right)
// Finder icon coordinates are (175, 195) and (485, 195) in 660x420 top-down points -> (350, 450) & (970, 450) in 1320x840 bottom-up px
let leftCenter = CGPoint(x: 350, y: 450)
let rightCenter = CGPoint(x: 970, y: 450)
for center in [leftCenter, rightCenter] {
    let box = CGRect(x: center.x - 134, y: center.y - 138, width: 268, height: 268)
    let path = CGPath(roundedRect: box, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.72])!)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.08, 0.10, 0.14, 0.08])!)
    ctx.setLineWidth(2.0)
    ctx.addPath(path)
    ctx.strokePath()
}

// Directional arrow between the two pedestals
let arrowY: CGFloat = 450
ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.23, 0.51, 0.96, 0.85])!)
ctx.setLineWidth(6.0)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 560, y: arrowY))
ctx.addLine(to: CGPoint(x: 750, y: arrowY))
ctx.strokePath()
ctx.move(to: CGPoint(x: 722, y: arrowY + 22))
ctx.addLine(to: CGPoint(x: 754, y: arrowY))
ctx.addLine(to: CGPoint(x: 722, y: arrowY - 22))
ctx.strokePath()

// Crisp typography via NSGraphicsContext
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx

let titleAttr: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 38, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
]
let title = "Charkle" as NSString
let titleSize = title.size(withAttributes: titleAttr)
title.draw(at: CGPoint(x: (CGFloat(width) - titleSize.width) / 2, y: CGFloat(height) - 106), withAttributes: titleAttr)

let subAttr: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.36, green: 0.38, blue: 0.42, alpha: 1.0)
]
let subtitle = "将 Charkle 拖入右侧「应用程序」文件夹即可完成安装" as NSString
let subSize = subtitle.size(withAttributes: subAttr)
subtitle.draw(at: CGPoint(x: (CGFloat(width) - subSize.width) / 2, y: 76), withAttributes: subAttr)

NSGraphicsContext.restoreGraphicsState()

guard let cgImage = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = NSSize(width: 660, height: 420) // Mark 2x Retina DPI so Finder displays it at 660x420pt
guard let pngData = rep.representation(using: .png, properties: [:]) else { exit(1) }
try pngData.write(to: URL(fileURLWithPath: outPath))
SWIFT

# Copy custom volume icon if present
if [[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
  cp -X "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$STAGE_DIR/.VolumeIcon.icns"
fi

echo "==> Creating temporary read-write disk image..."
hdiutil create \
  -srcfolder "$STAGE_DIR" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  "$RW_DMG" >/dev/null

echo "==> Mounting image to apply Finder layout and volume icon..."
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_POINT="$(echo "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "ERROR: Failed to mount $RW_DMG" >&2
  exit 1
fi

if [[ -f "$MOUNT_POINT/.VolumeIcon.icns" ]] && command -v SetFile >/dev/null 2>&1; then
  SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns" || true
  SetFile -a C "$MOUNT_POINT" || true
fi

# Best-effort Finder visual layout (skipped gracefully if Automation permission is unavailable)
VOL_BASENAME="$(basename "$MOUNT_POINT")"
osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$VOL_BASENAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {180, 140, 840, 560}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 108
    set background picture of viewOptions to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {175, 195}
    set position of item "Applications" of container window to {485, 195}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

echo "==> Compressing final read-only DMG ($FINAL_DMG)..."
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null

echo "==> Verifying DMG integrity and inner code signature..."
hdiutil verify "$FINAL_DMG" >/dev/null
VERIFY_MOUNT="$WORK_DIR/verify-mount"
mkdir -p "$VERIFY_MOUNT"
hdiutil attach "$FINAL_DMG" -readonly -nobrowse -noverify -mountpoint "$VERIFY_MOUNT" >/dev/null
codesign -v --deep --strict "$VERIFY_MOUNT/$APP_NAME.app"
hdiutil detach "$VERIFY_MOUNT" >/dev/null
VERIFY_MOUNT=""

DMG_SIZE="$(du -h "$FINAL_DMG" | awk '{print $1}')"
echo "==> Done: $FINAL_DMG ($DMG_SIZE)"
