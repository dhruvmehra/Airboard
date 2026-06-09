# Airboard 🎤

A lightweight macOS voice transcription app. Press a hotkey, speak, and your words are inserted into whatever app you're using. **All speech recognition runs locally on your Mac — no audio ever leaves your machine and no API key is required.**

## Features

- **🎯 Hotkey activated**: Hold your hotkey (default: Right Option) to record, release to transcribe
- **🔒 Fully local & private**: Transcription runs on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Apple Neural Engine / CoreML). No cloud, no API key.
- **🧠 Grammar cleanup**: Optional on-device grammar correction (Flan-T5 via ONNX Runtime), toggleable
- **🗣️ Voice commands**: Open apps/websites, web search, system controls, timers (hold hotkey + ⌘)
- **🙌 Hands-free mode**: Double-tap the hotkey for continuous dictation
- **📱 Context-aware**: Adapts to the active app (email, code, messaging, docs)
- **✨ Auto-insert**: Text appears directly where your cursor is, via the Accessibility API
- **📖 Custom vocabulary**: Teach it names and jargon for better accuracy

## Requirements

- macOS 14.0 or later (Apple Silicon recommended)
- Xcode 16+ to build
- Microphone + Accessibility permissions (prompted on first launch)

## First run — heads up ⚠️

On first launch Airboard **downloads its ML models (~1.5 GB total)** and caches them locally:

| Model | Purpose | Size | Cached at |
|-------|---------|------|-----------|
| Whisper `small` (WhisperKit) | Speech → text | ~0.5 GB | `~/.cache/whisperkit/models/` |
| Flan-T5 (ONNX) | Grammar cleanup | ~1.1 GB | `~/.cache/airboard/models/vennify/` |

The download happens in the background and needs an internet connection **once**; everything is offline after that. If you start dictating before the download finishes, the first transcription will wait for the model.

## Build & Run

1. Clone and open:
   ```bash
   git clone https://github.com/dhruvmehra/Airboard.git
   cd Airboard
   open Airboard.xcodeproj
   ```
2. Build and run (⌘R). No configuration or API keys needed.
3. Grant permissions when prompted:
   - **Microphone** — click Allow
   - **Accessibility** — open System Settings → Privacy & Security → Accessibility and enable Airboard (required to insert text)

### Release build

```bash
./build_release.sh   # builds, signs, notarizes, and creates a DMG
./create_dmg.sh      # DMG only (no signing/notarization)
```

## Usage

1. Hold your hotkey (default **Right Option ⌥**)
2. Speak
3. Release — the text inserts where your cursor is

Visual feedback (floating indicator): 🔴 recording · 🟠 transcribing · 🟣 command mode · 🔵 downloading models.

**Modes:** hold = dictate · hold + ⌘ = voice command · double-tap = hands-free.

Hotkey, vocabulary, and grammar correction are all configurable from the menu-bar popover.

## Architecture (high level)

```
HotkeyManager → TranscriptionCoordinator
  → AudioRecorder / ChunkedAudioRecorder   (capture)
  → LocalTranscriptionService              (WhisperKit, local)
  → GrammarCorrectionService               (ONNX Flan-T5, optional)
  → CommandDetector / CommandExecutor      (voice commands)
  → TextInserter                           (Accessibility API)
  → FloatingWindowManager                  (UI feedback)
```

See `CLAUDE.md` for a fuller breakdown of the source layout.

## Privacy

- Audio is processed entirely on-device; nothing is sent to any transcription server.
- Models are downloaded once from Hugging Face, then run fully offline.
- Optional, opt-in feedback reports (when you tap "Report issue") send only the text/metadata you choose to submit.

## License

MIT License — see LICENSE file.

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for on-device Whisper
- OpenAI Whisper and ONNX Runtime
- Inspired by Wispr Flow
