# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Airboard (formerly "Murmur") is a macOS voice transcription app. Users press a hotkey, speak, and transcribed text is inserted into the active application. All ML inference runs locally using FluidAudio (NVIDIA Parakeet TDT 0.6B v3, speech-to-text, CoreML/ANE — requires Apple Silicon).

## Build & Run

- Open `Airboard.xcodeproj` in Xcode and build with Cmd+R
- Minimum deployment target: macOS 14.0
- **Signing discipline (do not break this):** Debug (`com.pype.airboard.dev`) signs with
  Apple Development; Release (`com.pype.airboard`) signs with Developer ID Application
  (manual style). Never launch a prod-bundle-id app signed with the dev cert — macOS
  TCC records permission grants against the code signature, and a mismatched signature
  silently poisons Microphone/Accessibility grants for the real app (fix:
  `tccutil reset Microphone com.pype.airboard`). Test builds that must run the prod
  bundle id must be built in the Release configuration so they carry the correct cert.
- Swift 5.0, universal binary (x86_64 + arm64)
- Dependencies managed via Swift Package Manager (configured in the Xcode project, no standalone Package.swift)

### Release Build

```bash
./build_release.sh              # patch release: auto-bumps from last git tag
./build_release.sh minor        # 1.0.x -> 1.1.0
./build_release.sh major        # 1.x.y -> 2.0.0
./build_release.sh 1.2.0        # explicit version
./create_dmg.sh path/to/App.app # DMG only (version read from the app)
```

`build_release.sh` requires a clean git tree and a `## [Unreleased]` section in
`CHANGELOG.md`. It stamps `MARKETING_VERSION`, promotes the changelog section,
builds/signs/notarizes the DMG, then commits and tags `vX.Y.Z`. Afterwards:
`git push origin main --tags`.

Each release also signs the DMG with the Sparkle EdDSA key (login Keychain of the publishing Mac) and appends a signed item to `appcast.xml`, which ships in the release commit. Installed production apps poll that feed and update automatically; dev builds never check.

## Versioning & Changelog

- Version source of truth: git tags (`vX.Y.Z`). The release script derives the
  next version from the latest tag.
- User-facing changes go under `## [Unreleased]` in `CHANGELOG.md` as they are
  made; the release script moves them under the released version.

## Dependencies (SPM)

| Package | Purpose |
|---------|---------|
| FluidAudio (pinned to 0.15.5) | Local speech-to-text (Parakeet TDT 0.6B v3, CoreML) |
| Sparkle (pinned to 2.9.4) | Auto-update (appcast.xml at repo root, served raw) |

Model auto-downloads on first run (version defined in `ParakeetTranscriptionService.modelVersion`); cache path is printed at launch (`AsrModels.defaultCacheDirectory`).

## Architecture

### Core Flow

```
HotkeyManager (detects key press)
  → TranscriptionCoordinator (orchestrator singleton)
    → AudioRecorder / ChunkedAudioRecorder (captures audio)
    → ParakeetTranscriptionService (FluidAudio/Parakeet transcription)
    → TranscriptPostProcessor (FillerRules always; optional remote LLM via TranscriptRefiner)
    → CommandDetector (checks for voice commands)
    → TextInserter (inserts via Accessibility API) or CommandExecutor
    → FloatingWindowManager (visual feedback)
```

### Key Patterns

- **Coordinator pattern**: `TranscriptionCoordinator` is the central singleton managing the entire recording→transcription→insertion lifecycle
- **SwiftUI + NSWindow**: SwiftUI views hosted in NSWindow/NSPanel for floating indicator and popovers
- **Combine**: `@Published` properties on coordinator for reactive state updates
- **NotificationCenter**: Cross-component communication for permission changes, hotkey changes, UI state
- **Singleton services**: Most managers are singletons accessed via `.shared`

### Recording Modes

- **Dictation**: Hold primary hotkey → record → release → transcribe → insert text
- **Command**: Primary hotkey + Command → detect and execute voice commands
- **Hands-free**: Double-tap hotkey → continuous recording until next tap

### Source Organization (all in `Airboard/Airboard/`)

| Area | Key Files |
|------|-----------|
| Entry point | `AirboardApp.swift` (AppDelegate-based) |
| Audio capture | `AudioRecorder.swift`, `ChunkedAudioRecorder.swift` (policy) on `MicCaptureEngine.swift` (device-pinned capture); `MicDeviceManager.swift` (device list + per-device rules) |
| ML inference | `ParakeetTranscriptionService.swift` |
| Orchestration | `TranscriptionCoordinator.swift` |
| Input handling | `HotkeyManager.swift` |
| Text output | `TextInserter.swift` (Accessibility API) |
| Commands | `CommandDetector.swift`, `CommandExecutor.swift`, `CommandTypes.swift` |
| Context | `AppContextDetector.swift` (detects active app type: email, code, messaging, etc.) |
| UI | `FloatingWindowManager.swift`, `AirboardPopover.swift`, `SetupWindowController.swift` |
| Settings | `MenuBarManager.swift`, `HotkeySettingsView.swift` |
| Post-processing | `TranscriptPostProcessor.swift` (orchestrator), `FillerRules.swift`, `TranscriptRefiner.swift` (OpenAI-compatible HTTP client), `CleanupSettingsView.swift`, `KeychainHelper.swift` |
| Diagnostics | `PerformanceMonitor.swift`, `PerformanceView.swift`, `FeedbackManager.swift` |
| Updates | `UpdaterManager.swift` (Sparkle; production bundle only) |

### Key Enums/Types

- `RecordingMode`: `.dictation` or `.command`
- `CommandType`: `.openWebsite`, `.openApp`, `.searchWeb`, `.systemControl`, etc.
- `AppType`: `.email`, `.messaging`, `.code`, `.document`, `.browser`, `.general`
- `HotkeyOption`: `.rightOption`, `.leftOption`, `.rightCommand`, `.leftCommand`, `.rightControl`, `.fn`

## Required Permissions

- **Microphone**: For audio recording
- **Accessibility**: For text insertion into other apps via CGEvent
- Permissions managed in `SetupWindowController` on first launch

## Testing

No XCTest target exists. Testing is manual: build, grant permissions, and dictate into a real app.

## UserDefaults Keys

- `primaryHotkey`, `commandModifierHotkey` — hotkey configuration
- `hasCompletedSetup` — first-run setup completion flag
- `aiCleanupEnabled` — AI cleanup toggle (default false; turning it on with no server configured opens the setup window)
- `cleanupServerURL`, `cleanupModelName` — cleanup endpoint config (API key lives in the Keychain, service `<bundle id>.cleanup` — dev and prod have separate entries)
- `micRuleByDevice` — per-external-device mic choice (externalDeviceUID → chosenMicUID); no rule = system default
