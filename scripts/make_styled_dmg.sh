#!/bin/bash
#
# Build the styled Airboard installer DMG per the design system
# (ui_kits/airboard-app/dmg-installer.html): rendered background with
# version, drop-zone layout, hidden chrome. Called by build_release.sh
# and create_dmg.sh.
#
# Usage: make_styled_dmg.sh /path/to/Airboard.app /path/to/output.dmg
#
# Notes:
# - Stages in /private/tmp: hdiutil's helper daemon lacks TCC access to
#   user folders like ~/Desktop.
# - The output DMG must NEVER be written inside the staged folder — that
#   images the DMG into its own volume (shipped bug in 1.0.7's installer
#   window).
# - Icon layout needs Finder scripting; first run may prompt to allow
#   controlling Finder.

set -euo pipefail

APP_PATH=$1
OUT_DMG=$2
VOL_NAME="Airboard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d "$APP_PATH" ] || { echo "❌ App not found: $APP_PATH"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")

# App icon for the background's brand header
ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "AppIcon")
ICNS="$APP_PATH/Contents/Resources/${ICON_NAME%.icns}.icns"
[ -f "$ICNS" ] || { echo "❌ App icon not found: $ICNS"; exit 1; }

STAGE=$(mktemp -d /private/tmp/airboard-dmg.XXXXXX)
RW_DMG=$(mktemp -u /private/tmp/airboard-rw.XXXXXX).dmg
cleanup() {
    hdiutil detach "/Volumes/${VOL_NAME}" -quiet 2>/dev/null || true
    rm -rf "$STAGE" "$RW_DMG"
}
trap cleanup EXIT

echo "🎨 Rendering DMG background (v${VERSION})"
mkdir "$STAGE/.background"
swift "$SCRIPT_DIR/render_dmg_background.swift" "$VERSION" "$ICNS" "$STAGE/.background"
# Single multi-DPI TIFF so Finder renders crisp on Retina
tiffutil -cathidpicheck "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null
rm "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png"

cp -R "$APP_PATH" "$STAGE/Airboard.app"
ln -s /Applications "$STAGE/Applications"

# Unmount any stale volume from a previous run, then build read-write
hdiutil detach "/Volumes/${VOL_NAME}" -quiet 2>/dev/null || true
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDRW "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -noautoopen >/dev/null

echo "🪟 Laying out installer window"
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Airboard"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 878, 568}
        set vo to icon view options of container window
        set arrangement of vo to not arranged
        set icon size of vo to 84
        set text size of vo to 13
        set background picture of vo to file ".background:background.tiff"
        set position of item "Airboard.app" to {176, 209}
        set position of item "Applications" to {502, 209}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
sleep 1

hdiutil detach "/Volumes/${VOL_NAME}" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -o "$OUT_DMG" -ov >/dev/null

SIZE=$(du -h "$OUT_DMG" | cut -f1)
echo "✅ Styled DMG: $OUT_DMG ($SIZE)"
