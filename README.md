# Airboard 🎤

A lightweight macOS voice transcription app. Press a hotkey, speak, and your words are inserted into whatever app you're using. **All speech recognition runs locally on your Mac — no audio ever leaves your machine and no API key is required.**

## Features

- **🎯 Hotkey activated**: Hold your hotkey (default: Right Option) to record, release to transcribe
- **🔒 Fully local & private**: Transcription runs on-device via [FluidAudio](https://github.com/FluidInference/FluidAudio) / NVIDIA Parakeet (Apple Neural Engine / CoreML). No cloud, no API key.
- **🗣️ Voice commands**: Open apps/websites, web search, system controls, timers (hold hotkey + ⌘)
- **🙌 Hands-free mode**: Double-tap the hotkey for continuous dictation
- **📱 Context-aware**: Adapts to the active app (email, code, messaging, docs)
- **🎤 Pick your mic**: choose which microphone Airboard records from — remembered per headset, so connecting Bluetooth earphones never silently downgrades your transcription quality
- **✨ Auto-insert**: Text appears directly where your cursor is, via the Accessibility API
- **🔄 Auto-updates**: production builds keep themselves current in the background (Sparkle; updates are EdDSA-signed and notarized)
- **🪄 AI cleanup (optional)**: point Airboard at any OpenAI-compatible endpoint — your own Ollama, a team server, or a cloud API — and dictation comes back with grammar fixed, paragraphs added, and spoken points formatted as bullet/numbered lists. Does nothing until you configure a server; filler words ("um", "uh") are always removed locally either way. See [docs/cleanup-server-recipes.md](docs/cleanup-server-recipes.md).

## Requirements

- macOS 14.0 or later with Apple Silicon (required for the speech model)
- Xcode 16+ to build
- Microphone + Accessibility permissions (prompted on first launch)

## First run — heads up ⚠️

On first launch Airboard **downloads its speech model (~1 GB)** and caches it locally:

| Model | Purpose | Size | Cached at |
|-------|---------|------|-----------|
| Parakeet TDT 0.6B v3 (FluidAudio) | Speech → text | ~1 GB | printed at launch |

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

**Voice editing** (hold + ⌘): "delete all" · "delete last word" · "delete last two sentences" · "scratch that" (erases the last dictation).

The hotkey is configurable from the menu-bar popover.

## Set up your Memory (5 minutes, do this first)

Airboard has a personal memory: plain-language lines it uses to spell your
words right and to type your facts on command. It lives in a markdown file
you own (`~/Library/Application Support/com.pype.airboard/memory.md`) —
view it in the popover → **Memory**, or open the file in any editor.

**Step 1 — teach your spellings first** (hold hotkey + ⌘ and say it):

> "Correct pipe to Pype"
> "Correct enachi to Inakshi" — or spell it out: "spell it i-n-a-k-s-h-i"

Do this for your company, product names, and the teammates you mention
daily. Spellings first matters: facts you save afterwards come out spelled
right automatically.

**Step 2 — save the facts you'll want typed for you:**

> "Remember that I work at Pype"
> "Remember my work address is …"
> "Don't forget my GitHub handle is …"

Any phrasing works ("note this…", "keep in mind…"). A small card shows
each fact before it's saved — **edit anything the mic misheard, then press
⏎**. Correcting a name in that card teaches the spelling automatically.

**Step 3 — use it:**

- Just dictate: your words come out with your spellings applied in context
  ("send it to pipe" → "Pype", but "the water pipe" stays "pipe").
- Recall anywhere: put the cursor in any field, hold hotkey + ⌘, say
  "write my address" / "fill in where I work" — the fact types itself.

**Privacy:** memory is a local file. The "Share memory with AI Cleanup"
switch controls whether your lines ride along with cleanup requests to
your configured LLM; switched off, memory never leaves your Mac (voice
recall still works, locally).

## Architecture (high level)

```
HotkeyManager → TranscriptionCoordinator
  → AudioRecorder / ChunkedAudioRecorder   (capture)
  → ParakeetTranscriptionService           (FluidAudio/Parakeet, local)
  → CommandDetector / CommandExecutor      (voice commands)
  → TextInserter                           (Accessibility API)
  → FloatingWindowManager                  (UI feedback)
```

See `CLAUDE.md` for a fuller breakdown of the source layout.

## Privacy

- Audio never leaves your machine — speech recognition is fully local.
- By default, text never leaves your machine either. If you configure an AI cleanup server, dictated text (not audio) is sent to that server only — use HTTPS for anything beyond your own machines — only while the AI cleanup toggle is on.
- The model is downloaded once from Hugging Face, then runs fully offline.
- Optional, opt-in feedback reports (when you tap "Report issue") send only the text/metadata you choose to submit.
- **Anonymous performance stats**: production builds send anonymous usage
  signals to TelemetryDeck (a German, GDPR-focused analytics service):
  timing numbers (speech-to-text and cleanup durations), outcome flags,
  app version, plus the SDK's standard device context (device model, OS
  version, locale, screen resolution) and a random install identifier
  that is salted and hashed twice — once on your device, once server-side —
  so it cannot be traced back. Never any transcript text, audio, file
  names, or personal data. The "Share anonymous performance stats" switch
  in the Performance window turns it off entirely. Debug builds never
  send anything.
- Download counts come from the GitHub Releases page — no telemetry involved.

## License

MIT License — see LICENSE file.

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference for on-device Parakeet
- NVIDIA Parakeet
- Inspired by Wispr Flow
