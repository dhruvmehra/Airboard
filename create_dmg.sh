#!/bin/bash

# Create the styled installer DMG from an already-built Airboard.app
# (no signing/notarization). Thin wrapper over scripts/make_styled_dmg.sh.
# Usage: ./create_dmg.sh /path/to/Airboard.app

set -e

APP_PATH=$1

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Usage: ./create_dmg.sh /path/to/Airboard.app"
    exit 1
fi

# Read the version from the app itself so the filename always matches
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_NAME="Airboard-${VERSION}.dmg"

"$(dirname "$0")/scripts/make_styled_dmg.sh" "$APP_PATH" "$DMG_NAME"
