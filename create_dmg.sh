#!/bin/bash

# Create a DMG from an already-built Airboard.app (no signing/notarization).
# Usage: ./create_dmg.sh /path/to/Airboard.app

set -e

APP_PATH=$1
APP_NAME="Airboard"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Usage: ./create_dmg.sh /path/to/Airboard.app"
    exit 1
fi

# Read the version from the app itself so the filename always matches
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "📦 Creating DMG from $APP_PATH (version $VERSION)..."

TMP_DIR=$(mktemp -d)
cp -R "$APP_PATH" "$TMP_DIR/"
ln -s /Applications "$TMP_DIR/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$TMP_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

rm -rf "$TMP_DIR"

SIZE=$(du -h "$DMG_NAME" | cut -f1)
echo "✅ Done: $DMG_NAME ($SIZE)"
