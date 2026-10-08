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
- **🧠 Learns your vocabulary**: fix a misheard name after dictating, or let it notice names on your screen — a small card asks before saving, and from then on it's written right *where it fits* ("ask bright AI" → Brite AI; "a bright idea" stays). Filler words ("um", "uh") are always removed locally.

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

## Your vocabulary

Airboard learns the names and terms you use. Two ways:

- **Fix it once.** Dictate, then correct a misheard word by hand (e.g.
  "bright" → "Brite"). A card asks **"Learned: bright → Brite"** — ignore
  it to keep, or click Undo.
- **It notices your screen.** Names that keep appearing in your apps
  become suggestions: after dictating, a card asks **"Did you mean
  Parakeet?"**.

Learned words are applied in context — a decision model checks each one
("ask bright AI" → "Brite AI", "a bright idea" stays). See or delete them
in the popover → **Vocabulary**. They live in a markdown file you own:
`~/Library/Application Support/com.pype.airboard/memory.md`.

**Setup:** popover → **OpenRouter key** → paste a key from
[openrouter.ai/keys](https://openrouter.ai/keys). This is the only place
the key is set; it powers vocabulary decisions and the assistant (both
will move on-device). Without a key, only confirmed multi-word spellings
apply and nothing reads your screen.

## Ask the Assistant

Hold hotkey + ⌘ and just ask — anything that isn't a known command goes to
the assistant:

> "What time is 11 AM IST in PDT and EST?"
> "Convert 500 dollars to rupees"
> "What's the latest FluidAudio release?"

The answer appears as a toast. Setup (once): popover → **Assistant** →
**Install** (fetches the [pi](https://pi.dev) engine), and set your key in
popover → **OpenRouter key**. The assistant can do
exact math and fetch web pages — it cannot touch your files, run commands,
or control apps, and says so honestly when asked to.

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
- Vocabulary learning (only with your OpenRouter key set): when a dictated sentence may contain a learned word, that one sentence and the candidate word are sent to OpenRouter for a yes/no decision; when a new word is learned, the edited words are; and harvested screen words are checked one at a time. Never audio, files, screen dumps, or your vocabulary file. Screen text is read locally and never sent; password fields are never read.
- The model is downloaded once from Hugging Face, then runs fully offline.
- Optional, opt-in feedback reports (when you tap "Report issue") send only the text/metadata you choose to submit.
- Assistant questions (hold hotkey + ⌘, unmatched speech only) are sent as
  text to OpenRouter under your own API key, and the assistant may fetch
  public web pages to answer. Nothing is sent unless you ask it something.
- **Anonymous performance stats**: production builds send anonymous usage
  signals to TelemetryDeck (a German, GDPR-focused analytics service):
  timing numbers (speech-to-text durations), outcome flags,
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
