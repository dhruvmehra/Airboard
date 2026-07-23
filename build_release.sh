#!/bin/bash

# Airboard release script: versions, builds, signs, notarizes, tags.
#
# Usage (run from repo root):
#   ./build_release.sh            # patch bump from last git tag (v1.0.3 -> 1.0.4)
#   ./build_release.sh minor      # 1.0.3 -> 1.1.0
#   ./build_release.sh major      # 1.0.3 -> 2.0.0
#   ./build_release.sh 1.2.0      # explicit version
#
# The version is stamped into the Xcode project (MARKETING_VERSION), the
# CHANGELOG.md [Unreleased] section is promoted to the new version, and on
# success the bump is committed and tagged vX.Y.Z.

set -e

cd "$(dirname "$0")"

APP_NAME="Airboard"
PBXPROJ="Airboard.xcodeproj/project.pbxproj"
CHANGELOG="CHANGELOG.md"
BUILD_DIR="build/release-build"
RELEASE_DIR="release"

# Signing & Notarization
DEVELOPER_ID="Developer ID Application: Dhruv Mehra (67X7WDGF5G)"
TEAM_ID="67X7WDGF5G"
# Store password in keychain: xcrun notarytool store-credentials "airboard-notarize" --apple-id "dhruvdking@gmail.com" --team-id "67X7WDGF5G"
KEYCHAIN_PROFILE="airboard-notarize"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# --- Preflight: clean tree so the tag matches what we build -----------------
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}❌ Working tree is dirty. Commit or stash first so the release tag matches the build.${NC}"
    git status --short
    exit 1
fi

# --- Determine version -------------------------------------------------------
LAST_TAG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || true)

if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    VERSION="$1"
elif [ -z "$LAST_TAG" ]; then
    # No release tag yet: publish whatever the project currently says
    VERSION=$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);/\1/p' "$PBXPROJ" | head -1)
    echo -e "${BLUE}ℹ️  No release tag found; using project version ${VERSION}${NC}"
else
    BASE="${LAST_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE"
    case "${1:-patch}" in
        major) VERSION="$((MAJOR + 1)).0.0" ;;
        minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
        patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
        *) echo -e "${RED}❌ Unknown argument '$1' (use major, minor, patch, or X.Y.Z)${NC}"; exit 1 ;;
    esac
fi

if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo -e "${RED}❌ Tag v${VERSION} already exists${NC}"
    exit 1
fi

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
echo -e "${GREEN}🚀 Releasing ${APP_NAME} ${VERSION}${NC} (last tag: ${LAST_TAG:-none})"

# --- Stamp version into project + changelog ----------------------------------
echo -e "${BLUE}🏷  Step 1: Set MARKETING_VERSION and CURRENT_PROJECT_VERSION = ${VERSION}${NC}"
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
# Sparkle compares CFBundleVersion — it must advance every release.
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9.]*;/CURRENT_PROJECT_VERSION = ${VERSION};/g" "$PBXPROJ"

echo -e "${BLUE}📝 Step 2: Promote CHANGELOG [Unreleased] -> ${VERSION}${NC}"
if ! grep -q "^## \[Unreleased\]" "$CHANGELOG"; then
    echo -e "${RED}❌ No '## [Unreleased]' section in ${CHANGELOG}. Add your changes there first.${NC}"
    git checkout -- "$PBXPROJ"
    exit 1
fi
TODAY=$(date +%Y-%m-%d)
awk -v ver="$VERSION" -v date="$TODAY" '
    /^## \[Unreleased\]/ { print; print ""; print "## [" ver "] - " date; next }
    { print }
' "$CHANGELOG" > "${CHANGELOG}.tmp" && mv "${CHANGELOG}.tmp" "$CHANGELOG"

# Extract this version's section from the changelog as the release notes
NOTES=$(awk "/^## \[${VERSION}\]/{flag=1; next} /^## \[/{flag=0} flag" "$CHANGELOG")

# --- Build --------------------------------------------------------------------
echo -e "${BLUE}🔨 Step 3: Build (Release, universal)${NC}"
rm -rf "${BUILD_DIR}" "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

xcodebuild -project Airboard.xcodeproj \
    -scheme Airboard \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -destination "generic/platform=macOS" \
    ARCHS="x86_64 arm64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build

APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}❌ App not found at ${APP_PATH}${NC}"
    exit 1
fi
cp -R "$APP_PATH" "${RELEASE_DIR}/"

echo -e "${BLUE}🔏 Step 4: Sign${NC}"
codesign --deep --force --options runtime --sign "${DEVELOPER_ID}" "${RELEASE_DIR}/${APP_NAME}.app"

echo -e "${BLUE}💾 Step 5: Create DMG${NC}"
# Stage in a system temp dir: hdiutil's helper daemon lacks TCC access to
# ~/Desktop and fails with "Operation not permitted" when the source folder
# lives there.
DMG_STAGE=$(mktemp -d /private/tmp/airboard-dmg.XXXXXX)
cp -R "${RELEASE_DIR}/${APP_NAME}.app" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO \
    "${DMG_STAGE}/${DMG_NAME}"
mv "${DMG_STAGE}/${DMG_NAME}" "${RELEASE_DIR}/${DMG_NAME}"
rm -rf "${DMG_STAGE}"

# Sign the DMG itself (not just the app inside) so Gatekeeper reports
# "Notarized Developer ID" on the disk image too.
codesign --force --sign "${DEVELOPER_ID}" "${RELEASE_DIR}/${DMG_NAME}"

echo -e "${BLUE}📤 Step 6: Notarize${NC}"
xcrun notarytool submit "${RELEASE_DIR}/${DMG_NAME}" \
    --keychain-profile "${KEYCHAIN_PROFILE}" \
    --wait

echo -e "${BLUE}📎 Step 7: Staple${NC}"
xcrun stapler staple "${RELEASE_DIR}/${DMG_NAME}"
rm -rf "${RELEASE_DIR}/${APP_NAME}.app"

echo -e "${BLUE}📡 Step 7b: Sign update and append appcast item${NC}"
SIGN_UPDATE=$(find "${BUILD_DIR}/SourcePackages/artifacts" build/DerivedData/SourcePackages/artifacts -name sign_update -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo -e "${RED}❌ sign_update not found. Build once in Xcode (resolves Sparkle artifacts) or: brew install --cask sparkle${NC}"
    exit 1
fi

# Outputs: sparkle:edSignature="..." length="..."
ED_ATTRIBUTES=$("$SIGN_UPDATE" "${RELEASE_DIR}/${DMG_NAME}" | tr -d '\n')
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

ITEM=$(cat <<ITEM_EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<pre>
${NOTES}
</pre>]]></description>
            <enclosure url="https://github.com/dhruvmehra/Airboard/releases/download/v${VERSION}/${DMG_NAME}" ${ED_ATTRIBUTES} type="application/octet-stream"/>
        </item>
ITEM_EOF
)

# Newest item goes directly after the <language> line
awk -v item="$ITEM" '{print} /<language>en<\/language>/{print item}' appcast.xml > appcast.xml.tmp && mv appcast.xml.tmp appcast.xml
echo -e "${GREEN}✅ appcast.xml updated${NC}"

# --- Commit + tag (only after everything above succeeded) ---------------------
echo -e "${BLUE}🏁 Step 8: Commit and tag v${VERSION}${NC}"
git add "$PBXPROJ" "$CHANGELOG" appcast.xml
git commit -m "Release ${VERSION}"
git tag "v${VERSION}"

# --- Publish -------------------------------------------------------------
echo -e "${BLUE}🌐 Step 9: Push and publish GitHub release${NC}"
git push origin main --tags

if command -v gh >/dev/null 2>&1; then
    gh release create "v${VERSION}" "${RELEASE_DIR}/${DMG_NAME}" \
        --title "${APP_NAME} ${VERSION}" \
        --notes "${NOTES}"
else
    echo "gh CLI not found — create the release manually:"
    echo "  gh release create v${VERSION} ${RELEASE_DIR}/${DMG_NAME} --title \"${APP_NAME} ${VERSION}\""
fi

DMG_SIZE=$(du -h "${RELEASE_DIR}/${DMG_NAME}" | cut -f1)
echo ""
echo -e "${GREEN}✅ ${APP_NAME} ${VERSION} released and published!${NC}"
echo -e "${GREEN}📦 ${RELEASE_DIR}/${DMG_NAME} (${DMG_SIZE})${NC}"
