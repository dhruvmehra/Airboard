# Sparkle Auto-Update — Design

**Date:** 2026-07-19
**Status:** Approved

## Goal

Ship Sparkle-based auto-update in Airboard 1.0.4 so it is the first version
the team installs. From then on, publishing a release means every installed
copy downloads it in the background and installs on quit/relaunch — no manual
DMG dance, no stragglers on old builds. Also required groundwork for
open-sourcing (public users get updates the same way).

## Scope

**In scope**
- Sparkle 2 (SPM) wired into the app: automatic checks (launch + daily),
  fully automatic download + install, standard Sparkle notice UI.
- "Check for Updates…" row in the menu-bar popover.
- `appcast.xml` at the repo root, served via
  `https://raw.githubusercontent.com/dhruvmehra/Airboard/main/appcast.xml`.
- EdDSA key generation (private key in the publishing Mac's Keychain +
  encrypted backup exported for the user to stash).
- Release-script integration: sign the DMG update, append the appcast item
  (with the changelog section as release notes), commit the feed with the
  release.
- Fix `CFBundleVersion` stamping (currently hardcoded `1` — Sparkle compares
  this, so updates would never trigger without the fix).

**Out of scope (explicitly deferred)**
- Delta updates, beta/staged channels, multiple feeds.
- App sandboxing changes (app is not sandboxed; Sparkle needs no XPC here).
- Auto-update for dev builds (`com.pype.airboard.dev` never checks).
- Rollback/downgrade UI.
- GitHub Pages hosting (raw.githubusercontent.com is sufficient; migration
  later is a URL change).

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Update UX | Fully automatic (background download, install on quit), notice UI shown | Team stays current while iterating fast; user picked this explicitly. First-launch permission prompt suppressed by presetting the Info.plist flags. |
| Feed hosting | `appcast.xml` committed at repo root, served raw | Repo is public; feed versioned with code; zero new infrastructure; HTTPS free. |
| Feed generation | Release script appends a signed `<item>` per release (`sign_update` for the EdDSA signature), release notes embedded from the promoted changelog section | Keeps the one-command pipeline; no separate archive folder to maintain. |
| Update archive | The existing notarized DMG | Sparkle supports DMG archives; no second artifact. |
| Keys | Sparkle `generate_keys`; private key in the publishing Mac's Keychain; encrypted backup exported once | Same trust model as notarization credentials — only this Mac publishes. Public key ships in Info.plist. |
| Dev-build gating | Updater initialized at runtime only when `Bundle.main.bundleIdentifier == "com.pype.airboard"` | The Info.plist is shared across configs; a runtime bundle-id check is the simplest reliable gate. Dev builds never phone home. |
| Versioning | Release script stamps `CURRENT_PROJECT_VERSION = <version>` alongside `MARKETING_VERSION` | Sparkle compares `CFBundleVersion`; the hardcoded `1` would break update detection permanently. |

## Architecture

```
AppDelegate
  └─ UpdaterManager (new, small)        — owns SPUStandardUpdaterController;
                                           inits only for the prod bundle id
AirboardPopover
  └─ "Check for Updates…" row           — calls UpdaterManager.checkForUpdates()

Repo root
  └─ appcast.xml                        — the feed; one <item> per release

build_release.sh
  └─ Step: sign DMG with sign_update → append <item> (version, length,
     EdDSA signature, CDATA release notes from CHANGELOG section) →
     include appcast.xml in the release commit
```

### UpdaterManager (new file)

- Wraps `SPUStandardUpdaterController` (Sparkle 2's standard controller with
  its built-in UI).
- `static let shared`; `func start()` called from
  `applicationDidFinishLaunching` — no-ops unless
  `Bundle.main.bundleIdentifier == "com.pype.airboard"`.
- `func checkForUpdates()` for the popover row (user-initiated check shows
  Sparkle's UI immediately).
- Exposes `var canCheckForUpdates: Bool` if the popover wants to disable the
  row in dev builds (dev popover hides the row entirely).

### Info.plist additions (Airboard/Info.plist, merged into the generated plist)

- `SUFeedURL` = `https://raw.githubusercontent.com/dhruvmehra/Airboard/main/appcast.xml`
- `SUPublicEDKey` = (public key from `generate_keys`)
- `SUEnableAutomaticChecks` = `YES` (presetting suppresses Sparkle's
  first-launch permission prompt)
- `SUAutomaticallyUpdate` = `YES` (background download + install on quit)

### Release-script changes

1. Stamp `CURRENT_PROJECT_VERSION = ${VERSION}` in both configs (same sed
   pattern as `MARKETING_VERSION`).
2. After notarization + staple: run Sparkle's `sign_update` on the DMG →
   EdDSA signature + length.
3. Append an `<item>` to `appcast.xml`: version (both `sparkle:version` and
   `sparkle:shortVersionString` = the release version), the GitHub release
   asset URL (`https://github.com/dhruvmehra/Airboard/releases/download/v${VERSION}/${DMG_NAME}`),
   signature, length, minimum system version 14.0, and the promoted
   changelog section as CDATA HTML description.
4. `git add appcast.xml` with the existing release commit, before tagging —
   so the tagged commit contains the feed that describes it. (The asset URL
   goes live at the `gh release create` step moments later; a brief window
   where the feed points at a not-yet-uploaded asset is harmless — Sparkle
   retries next cycle.)
5. `sign_update`/`generate_keys` binaries come from the Sparkle SPM checkout
   (`artifacts` in DerivedData) or Homebrew `sparkle` — resolved at
   implementation time; the script fails with a clear message if neither is
   found.

### Key management (one-time setup, part of implementation)

- Run Sparkle's `generate_keys` → private key lands in the login Keychain of
  the publishing Mac; public key printed for Info.plist.
- Export an encrypted backup (`generate_keys -x` file, encrypted with a
  passphrase the user chooses) and hand it to the user to store outside this
  machine. Losing the private key means one manual reinstall for all users —
  the backup makes that a non-event.

## Failure handling

| Condition | Behavior |
|---|---|
| Feed unreachable / GitHub down | Sparkle silently retries next cycle; app unaffected |
| Bad signature / tampered DMG | Sparkle rejects the update, logs; no install |
| Update fails mid-download | Retry next cycle |
| Dev build | Updater never initialized; no network calls to the feed |

## Migration note

1.0.3 (and earlier) installs have no Sparkle — the team's move to 1.0.4 is
one final manual install (quit → drag → replace). Everything after 1.0.4
is automatic.

## Verification (manual, end-to-end, before release)

1. Build a throwaway "1.0.5" DMG, sign its appcast item, serve a test feed
   locally (Sparkle honors a `-SUFeedURL` defaults override for testing).
2. Install the real 1.0.4 build, point it at the test feed → it detects
   1.0.5, downloads in background, installs on quit, relaunches as 1.0.5.
3. Dev build: confirm zero feed requests (updater never starts).
4. "Check for Updates…" row triggers an immediate visible check.
5. Feed unreachable → app launches and works normally, no errors surfaced.
6. `spctl` still accepts the final DMG (signing order unchanged: Sparkle's
   `sign_update` signature lives in the appcast, not in the DMG itself —
   notarization is unaffected).
7. Release 1.0.4 for real via `./build_release.sh` — the one command now
   produces app + DMG + tag + GitHub release + updated appcast.

## Risks

- **Private-key loss** → encrypted backup mitigates; worst case one manual
  reinstall wave.
- **raw.githubusercontent.com caching** (up to ~5 min CDN lag on feed
  updates) — harmless; updates arrive minutes later.
- **Hand-built appcast XML drift** — the format is small and stable; the
  end-to-end test in Verification catches malformed items before any release
  ships.
- **CFBundleVersion history**: existing installs report version `1`; the
  1.0.4 feed item's `sparkle:version` (`1.0.4`) compares greater, so the
  first automatic update (1.0.4 → 1.0.5) works. No action needed for
  pre-Sparkle installs (they update manually anyway).
