# Sparkle Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully-automatic Sparkle updates in Airboard 1.0.4 — installed copies detect new GitHub releases via an appcast in the repo, download in the background, and install on quit.

**Architecture:** Sparkle 2.9.4 (SPM binary) wrapped by a small `UpdaterManager` that only arms for the production bundle id. Fully-automatic behavior configured via Info.plist keys. `appcast.xml` lives at the repo root, served raw; `build_release.sh` signs each DMG with Sparkle's EdDSA key (private key in the publishing Mac's Keychain) and appends the feed item in the release commit.

**Tech Stack:** Sparkle 2.9.4 (SPM), Swift 5 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), bash release script, `raw.githubusercontent.com` hosting.

**Spec:** `docs/superpowers/specs/2026-07-19-sparkle-auto-update-design.md`

## Global Constraints

- Repo root is `/Users/dhruvmehra/Desktop/proj/Airboard/Airboard`; paths relative to it; commands run from it.
- Sparkle pinned to **exact version 2.9.4** (`https://github.com/sparkle-project/Sparkle`, product `Sparkle`).
- Feed URL exactly: `https://raw.githubusercontent.com/dhruvmehra/Airboard/main/appcast.xml`.
- The updater must NEVER run in dev builds: runtime gate `Bundle.main.bundleIdentifier == "com.pype.airboard"` (dev is `com.pype.airboard.dev`).
- Fully-automatic mode: `SUEnableAutomaticChecks = YES`, `SUAutomaticallyUpdate = YES` preset in Info.plist (suppresses Sparkle's first-launch permission prompt).
- Sparkle compares `CFBundleVersion`: the release script must stamp `CURRENT_PROJECT_VERSION = ${VERSION}` (currently hardcoded `1`).
- The EdDSA private key lives in the login Keychain of this Mac (created by Sparkle's `generate_keys`); it is never written to the repo. The public key ships in `Airboard/Info.plist`.
- New `.swift` files under `Airboard/` are auto-included (filesystem-synchronized group).
- No XCTest target exists and none is added. Per-task verification:
  `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.
- Commit after every task with the exact message given. Do NOT run `./build_release.sh` in any task — releasing 1.0.4 is the user's decision after the E2E test passes.

---

### Task 1: Add Sparkle SPM dependency

**Files:**
- Modify: `Airboard.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `import Sparkle` available to the app target; Sparkle's helper tools appear under DerivedData SourcePackages artifacts after the first build.

The project has two package references (FluidAudio `FA1DA0D10000000000000001`, mlx-era IDs are absent — cleanup removed MLX; check the current `packageReferences` list and mirror the existing wiring). Use IDs: `FA1DA0D30000000000000001` (package ref), `FA1DA0D30000000000000002` (product), `FA1DA0D30000000000000003` (build file).

- [ ] **Step 1: Add the package reference**

In `packageReferences = (...)` (inside the `PBXProject` section), add after the existing entries:

```
				FA1DA0D30000000000000001 /* XCRemoteSwiftPackageReference "Sparkle" */,
```

- [ ] **Step 2: Add the remote package definition**

In the `XCRemoteSwiftPackageReference` section, add:

```
		FA1DA0D30000000000000001 /* XCRemoteSwiftPackageReference "Sparkle" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/sparkle-project/Sparkle";
			requirement = {
				kind = exactVersion;
				version = 2.9.4;
			};
		};
```

- [ ] **Step 3: Add the product dependency, build file, and links**

In the `XCSwiftPackageProductDependency` section:

```
		FA1DA0D30000000000000002 /* Sparkle */ = {
			isa = XCSwiftPackageProductDependency;
			package = FA1DA0D30000000000000001 /* XCRemoteSwiftPackageReference "Sparkle" */;
			productName = Sparkle;
		};
```

In the `PBXBuildFile` section:

```
		FA1DA0D30000000000000003 /* Sparkle in Frameworks */ = {isa = PBXBuildFile; productRef = FA1DA0D30000000000000002 /* Sparkle */; };
```

In the Frameworks phase `files = (...)`:

```
				FA1DA0D30000000000000003 /* Sparkle in Frameworks */,
```

In the target's `packageProductDependencies = (...)`:

```
				FA1DA0D30000000000000002 /* Sparkle */,
```

- [ ] **Step 4: Resolve and build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. Then confirm the tools arrived:

Run: `ls ./build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`
Expected: `generate_appcast`, `generate_keys`, `sign_update` (path may have one extra directory level — find with `find ./build/DerivedData/SourcePackages/artifacts -name sign_update` and record the actual path in your report).

- [ ] **Step 5: Commit**

```bash
git add Airboard.xcodeproj
git commit -m "Add Sparkle 2.9.4 dependency"
```

---

### Task 2: EdDSA keys, Info.plist, appcast skeleton

**Files:**
- Modify: `Airboard/Info.plist`
- Create: `appcast.xml` (repo root)

**Interfaces:**
- Produces: `SUPublicEDKey` in the built app's Info.plist; a valid empty feed at the URL the app will poll; the private key in the login Keychain (item name "Private key for signing Sparkle updates").

- [ ] **Step 1: Generate the key pair (idempotent)**

Run (use the actual tool path recorded in Task 1):

```bash
GENERATE_KEYS=$(find ./build/DerivedData/SourcePackages/artifacts -name generate_keys | head -1)
"$GENERATE_KEYS" -p 2>/dev/null || "$GENERATE_KEYS"
"$GENERATE_KEYS" -p
```

`generate_keys` creates the key in the login Keychain on first run; `-p` prints the base64 public key. Record the public key in your report. If the Keychain prompts for access, report BLOCKED — the user must be present for that.

- [ ] **Step 2: Add the Sparkle keys to Info.plist**

`Airboard/Info.plist` is a small hand-maintained plist merged into the generated one. Add inside the top-level `<dict>`:

```xml
	<key>SUFeedURL</key>
	<string>https://raw.githubusercontent.com/dhruvmehra/Airboard/main/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>REPLACE_WITH_THE_PUBLIC_KEY_PRINTED_IN_STEP_1</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAutomaticallyUpdate</key>
	<true/>
```

(The `REPLACE_WITH_...` string must be replaced with the actual base64 key before committing — a literal placeholder in the committed plist is a task failure.)

- [ ] **Step 3: Create the empty feed**

Create `appcast.xml` at the repo root with exactly:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkle-project.org/xml/rss" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Airboard</title>
        <link>https://github.com/dhruvmehra/Airboard</link>
        <description>Airboard updates</description>
        <language>en</language>
    </channel>
</rss>
```

- [ ] **Step 4: Build and verify the merged plist**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Run: `/usr/libexec/PlistBuddy -c "Print :SUFeedURL" -c "Print :SUPublicEDKey" -c "Print :SUEnableAutomaticChecks" -c "Print :SUAutomaticallyUpdate" "./build/DerivedData/Build/Products/Debug/Airboard Dev.app/Contents/Info.plist"`
Expected: the feed URL, a base64 key (not the REPLACE placeholder), `true`, `true`.

- [ ] **Step 5: Commit**

```bash
git add Airboard/Info.plist appcast.xml
git commit -m "Add Sparkle feed config, public key, and empty appcast"
```

---

### Task 3: UpdaterManager + AppDelegate + popover row

**Files:**
- Create: `Airboard/UpdaterManager.swift`
- Modify: `Airboard/AirboardApp.swift` (one call in `applicationDidFinishLaunching`)
- Modify: `Airboard/AirboardPopover.swift` (callback param + row + preview)
- Modify: `Airboard/FloatingWindowManager.swift` (popover argument)

**Interfaces:**
- Consumes: Sparkle (Task 1).
- Produces: `UpdaterManager.shared.start()`, `UpdaterManager.shared.checkForUpdates()`, `UpdaterManager.isEnabled: Bool`.

- [ ] **Step 1: Create UpdaterManager**

Create `Airboard/UpdaterManager.swift` with exactly:

```swift
//
//  UpdaterManager.swift
//
//  Owns the Sparkle updater. Fully-automatic behavior (check at launch +
//  daily, background download, install on quit) is configured in Info.plist
//  (SUEnableAutomaticChecks / SUAutomaticallyUpdate). This class decides
//  only WHETHER the updater runs: production bundle only — dev builds
//  never contact the feed.
//  See docs/superpowers/specs/2026-07-19-sparkle-auto-update-design.md
//

import Foundation
import Sparkle

class UpdaterManager {
    static let shared = UpdaterManager()

    /// Auto-update is armed only for the production app; the dev build
    /// (com.pype.airboard.dev) must never phone home or self-replace.
    static let isEnabled = Bundle.main.bundleIdentifier == "com.pype.airboard"

    private var controller: SPUStandardUpdaterController?

    private init() {}

    /// Called once at launch. No-op in dev builds.
    func start() {
        guard Self.isEnabled, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        print("🔄 Sparkle updater started (feed: \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "?"))")
    }

    /// User-initiated check from the popover — shows Sparkle's UI.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
```

- [ ] **Step 2: Start it at launch**

In `Airboard/AirboardApp.swift`, in `applicationDidFinishLaunching`, directly after the `cleanupLegacyWhisperModels()` line, add:

```swift
        UpdaterManager.shared.start()
```

- [ ] **Step 3: Popover row**

Read `Airboard/AirboardPopover.swift` first. Then:

1. Add a callback parameter alongside the existing ones:
```swift
    let onCheckForUpdates: () -> Void
```
2. Add a hover state:
```swift
    @State private var isHoveringUpdate = false
```
3. Add a button row AFTER the "Report Issue" row, matching the neighboring rows' exact structure (icon circle, 13/11pt text, chevron, hover background — copy the Report Issue row's modifiers):
```swift
                // Check for Updates Button (production builds only)
                if UpdaterManager.isEnabled {
                    Button(action: onCheckForUpdates) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(isHoveringUpdate ? 0.15 : 0.1))
                                    .frame(width: 32, height: 32)

                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.blue)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Check for Updates")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)

                                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(isHoveringUpdate ? 0.04 : 0))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringUpdate = $0 }
                }
```
4. Update the `#Preview` to pass `onCheckForUpdates: {},` in the matching position.

- [ ] **Step 4: Wire it in FloatingWindowManager**

In the `AirboardPopover(...)` construction, add in the matching position:

```swift
            onCheckForUpdates: {
                UpdaterManager.shared.checkForUpdates()
            },
```

(The dev popover hides the row via `UpdaterManager.isEnabled`, so no height change is needed for the build you can see; the production popover gains one row — bump the `popoverHeight` constant by 52 only if you can verify clipping, otherwise leave it and note it for the release smoke test.)

- [ ] **Step 5: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Airboard/UpdaterManager.swift Airboard/AirboardApp.swift Airboard/AirboardPopover.swift Airboard/FloatingWindowManager.swift
git commit -m "Wire Sparkle updater: production-only, popover check row"
```

---

### Task 4: Release-script integration

**Files:**
- Modify: `build_release.sh`

**Interfaces:**
- Consumes: `sign_update` from the Sparkle SPM artifacts (Task 1); `appcast.xml` (Task 2).
- Produces: each release stamps `CURRENT_PROJECT_VERSION`, appends a signed appcast item, and commits the feed with the release.

- [ ] **Step 1: Stamp CFBundleVersion**

In `build_release.sh`, find:

```bash
echo -e "${BLUE}🏷  Step 1: Set MARKETING_VERSION = ${VERSION}${NC}"
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
```

Replace with:

```bash
echo -e "${BLUE}🏷  Step 1: Set MARKETING_VERSION and CURRENT_PROJECT_VERSION = ${VERSION}${NC}"
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
# Sparkle compares CFBundleVersion — it must advance every release.
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9.]*;/CURRENT_PROJECT_VERSION = ${VERSION};/g" "$PBXPROJ"
```

- [ ] **Step 2: Move the NOTES extraction up**

The `NOTES=$(awk ...)` line currently lives in Step 9 (publish). Move it up so it sits directly after the changelog promotion block (end of "Step 2: Promote CHANGELOG"), because the appcast item needs it too. Where it used to be in Step 9, it is simply no longer re-declared (the variable is already set).

- [ ] **Step 3: Add the appcast step**

After the staple step (`xcrun stapler staple ...` and the `rm -rf "${RELEASE_DIR}/${APP_NAME}.app"` line) and BEFORE "Step 8: Commit and tag", insert:

```bash
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
```

- [ ] **Step 4: Include the appcast in the release commit**

In "Step 8: Commit and tag", find:

```bash
git add "$PBXPROJ" "$CHANGELOG"
```

Replace with:

```bash
git add "$PBXPROJ" "$CHANGELOG" appcast.xml
```

- [ ] **Step 5: Syntax check + dry validation**

Run: `bash -n build_release.sh` → no output.

Validate the awk insertion logic against a scratch copy:

```bash
cp appcast.xml /tmp/appcast_test.xml
ITEM="        <item><title>TEST</title></item>"
awk -v item="$ITEM" '{print} /<language>en<\/language>/{print item}' /tmp/appcast_test.xml | grep -c "TEST"
```
Expected: `1`. Also confirm the result is valid XML: `awk -v item="$ITEM" '{print} /<language>en<\/language>/{print item}' /tmp/appcast_test.xml | xmllint --noout -` → no output (xmllint ships with macOS).

- [ ] **Step 6: Commit**

```bash
git add build_release.sh
git commit -m "Release script: stamp CFBundleVersion, sign and append appcast item"
```

---

### Task 5: End-to-end update test

**Files:** none committed (scratch only) — this task PROVES the feature before the user releases 1.0.4.

**Interfaces:**
- Consumes: everything from Tasks 1–4.

Work in a scratch dir: `SCRATCH=/private/tmp/sparkle-e2e && mkdir -p "$SCRATCH"`.

- [ ] **Step 1: Build a "current" 1.0.4 app and a "newer" 1.0.5 DMG**

```bash
cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard

# 1.0.4 (the version that will self-update)
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Release \
  -derivedDataPath "$SCRATCH/dd104" -destination "generic/platform=macOS" \
  MARKETING_VERSION=1.0.4 CURRENT_PROJECT_VERSION=1.0.4 build 2>&1 | tail -2
mkdir -p "$SCRATCH/UpdateTest"
cp -R "$SCRATCH/dd104/Build/Products/Release/Airboard.app" "$SCRATCH/UpdateTest/"

# 1.0.5 (the update)
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Release \
  -derivedDataPath "$SCRATCH/dd105" -destination "generic/platform=macOS" \
  MARKETING_VERSION=1.0.5 CURRENT_PROJECT_VERSION=1.0.5 build 2>&1 | tail -2
mkdir -p "$SCRATCH/dmgsrc"
cp -R "$SCRATCH/dd105/Build/Products/Release/Airboard.app" "$SCRATCH/dmgsrc/"
hdiutil create -volname "Airboard" -srcfolder "$SCRATCH/dmgsrc" -ov -format UDZO "$SCRATCH/Airboard-1.0.5.dmg"
```

Expected: two `** BUILD SUCCEEDED **`, a DMG in `$SCRATCH`.

- [ ] **Step 2: Build the test feed**

```bash
SIGN_UPDATE=$(find ./build/DerivedData/SourcePackages/artifacts "$SCRATCH/dd104/SourcePackages/artifacts" -name sign_update -type f 2>/dev/null | head -1)
ED_ATTRIBUTES=$("$SIGN_UPDATE" "$SCRATCH/Airboard-1.0.5.dmg" | tr -d '\n')
cat > "$SCRATCH/appcast-test.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkle-project.org/xml/rss" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Airboard</title>
        <language>en</language>
        <item>
            <title>Version 1.0.5</title>
            <sparkle:version>1.0.5</sparkle:version>
            <sparkle:shortVersionString>1.0.5</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<pre>E2E test build</pre>]]></description>
            <enclosure url="http://localhost:8123/Airboard-1.0.5.dmg" ${ED_ATTRIBUTES} type="application/octet-stream"/>
        </item>
    </channel>
</rss>
EOF
(cd "$SCRATCH" && python3 -m http.server 8123 >/dev/null 2>&1 &)
echo $! > /tmp/sparkle_e2e_server.pid
curl -s http://localhost:8123/appcast-test.xml | head -3
```

Expected: the XML header echoes back.

- [ ] **Step 3: Point the test app at the local feed and run the update cycle**

```bash
# Feed override for the PROD bundle id (cleaned up in Step 5)
defaults write com.pype.airboard SUFeedURL "http://localhost:8123/appcast-test.xml"
open "$SCRATCH/UpdateTest/Airboard.app"
sleep 90   # launch check + background download of the 1.0.5 DMG
pkill -TERM -f "UpdateTest/Airboard.app" ; sleep 20   # install-on-quit runs now
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SCRATCH/UpdateTest/Airboard.app/Contents/Info.plist"
```

Expected: `1.0.5` — the app on disk replaced itself. If it still prints `1.0.4`, check Sparkle's activity in the unified log (`log show --last 5m --predicate 'process CONTAINS "Airboard" OR process CONTAINS "Updater"' | grep -i sparkle | tail -20`), wait another 30s and re-check (background installs can lag), and re-run the cycle once. **Note:** the fresh app may prompt for microphone permission on launch — irrelevant to the update flow; ignore it. **Fallback if automation proves flaky:** report DONE_WITH_CONCERNS with exact reproduction state so the controller can hand the visual check (popover → Check for Updates) to the user.

- [ ] **Step 4: Dev build never phones home**

```bash
defaults delete com.pype.airboard.dev SUFeedURL 2>/dev/null
log stream --predicate 'process == "Airboard Dev"' --style compact > /tmp/devlog.txt 2>&1 &
LOGPID=$!
open "./build/DerivedData/Build/Products/Debug/Airboard Dev.app"
sleep 20; kill $LOGPID
grep -ci "sparkle\|SUFeedURL\|appcast" /tmp/devlog.txt || echo "0 sparkle activity — dev gate holds"
pkill -f "Airboard Dev.app"
```

Expected: `0 sparkle activity — dev gate holds` (and the console print "Sparkle updater started" must NOT appear for the dev build).

- [ ] **Step 5: Clean up**

```bash
defaults delete com.pype.airboard SUFeedURL
kill $(cat /tmp/sparkle_e2e_server.pid) 2>/dev/null
rm -rf "$SCRATCH" /tmp/devlog.txt /tmp/sparkle_e2e_server.pid /tmp/appcast_test.xml
git status --short   # expect: clean (this task commits nothing)
```

- [ ] **Step 6: Report**

No commit. The report must state plainly: did the app self-update from 1.0.4 → 1.0.5 (the feature's acceptance test), and did the dev build stay silent?

---

### Task 6: Docs, changelog, and user handoff notes

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `CHANGELOG.md`

- [ ] **Step 1: CLAUDE.md**

1. Dependencies table: add row `| Sparkle (pinned to 2.9.4) | Auto-update (appcast.xml at repo root, served raw) |`
2. Release Build section: after the existing paragraph about `build_release.sh`, add: "Each release also signs the DMG with the Sparkle EdDSA key (login Keychain of the publishing Mac) and appends a signed item to `appcast.xml`, which ships in the release commit. Installed production apps poll that feed and update automatically; dev builds never check."
3. Source Organization: add row `| Updates | `UpdaterManager.swift` (Sparkle; production bundle only) |`

- [ ] **Step 2: README.md**

Features: add bullet `- **🔄 Auto-updates**: production builds keep themselves current in the background (Sparkle; updates are EdDSA-signed and notarized)`.

- [ ] **Step 3: CHANGELOG.md**

Under `## [Unreleased]` → `### Added`, append:

```markdown
- Automatic updates (Sparkle): the app checks at launch and daily, downloads in the background, and installs on quit. "Check for Updates" available in the menu popover
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md CHANGELOG.md
git commit -m "Docs for Sparkle auto-update"
```

- [ ] **Step 5: Report the user handoff checklist**

Include verbatim in your report (the controller relays it):

1. **Back up the Sparkle private key** (one-time, do it now): run
   `find ~/Desktop/proj/Airboard/Airboard/build -name generate_keys | head -1` then
   `<that path> -x ~/Desktop/sparkle-private-key-backup.key` and store the file
   somewhere safe OFF this Mac (password manager attachment). Losing this key
   means every user reinstalls manually once.
2. **Release 1.0.4** whenever dogfooding satisfies: `./build_release.sh` (one
   command; now also updates the appcast).
3. Team installs 1.0.4 manually (their last manual install ever).
