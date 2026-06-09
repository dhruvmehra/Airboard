# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Airboard (formerly "Murmur") is a macOS voice transcription app. Users press a hotkey, speak, and transcribed text is inserted into the active application. All ML inference runs locally using WhisperKit (Whisper large-v3-turbo, speech-to-text).

## Build & Run

- Open `Airboard.xcodeproj` in Xcode and build with Cmd+R
- Minimum deployment target: macOS 14.0
- Swift 5.0, universal binary (x86_64 + arm64)
- Dependencies managed via Swift Package Manager (configured in the Xcode project, no standalone Package.swift)

### Release Build

```bash
./build_release.sh   # Builds, signs, notarizes, and creates DMG
./create_dmg.sh      # Creates DMG only
```

## Dependencies (SPM)

| Package | Purpose |
|---------|---------|
| WhisperKit (pinned to a fixed revision) | Local speech-to-text (Whisper model) |

Model auto-downloads on first run:
- Whisper: `~/.cache/whisperkit/models/openai_whisper-large-v3-v20240930_turbo_632MB` (~630 MB; name defined in `LocalTranscriptionService.whisperModelName`)

## Architecture

### Core Flow

```
HotkeyManager (detects key press)
  → TranscriptionCoordinator (orchestrator singleton)
    → AudioRecorder / ChunkedAudioRecorder (captures audio)
    → LocalTranscriptionService (WhisperKit transcription)
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
| Audio capture | `AudioRecorder.swift`, `ChunkedAudioRecorder.swift` |
| ML inference | `LocalTranscriptionService.swift` |
| Orchestration | `TranscriptionCoordinator.swift` |
| Input handling | `HotkeyManager.swift` |
| Text output | `TextInserter.swift` (Accessibility API) |
| Commands | `CommandDetector.swift`, `CommandExecutor.swift`, `CommandTypes.swift` |
| Context | `AppContextDetector.swift` (detects active app type: email, code, messaging, etc.) |
| UI | `FloatingWindowManager.swift`, `AirboardPopover.swift`, `SetupWindowController.swift` |
| Settings | `MenuBarManager.swift`, `HotkeySettingsView.swift`, `VocabularyManager.swift` |
| Diagnostics | `PerformanceMonitor.swift`, `PerformanceView.swift`, `FeedbackManager.swift` |

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
