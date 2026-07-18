# Parakeet ASR Swap — Design

**Date:** 2026-07-18
**Status:** Approved

## Goal

Replace WhisperKit (Whisper large-v3-turbo) with Parakeet TDT 0.6B v3 via the
FluidAudio Swift SDK as Airboard's local speech-to-text engine. Better English
accuracy (~6.3% vs ~7.8% avg WER on Open ASR benchmarks) and ~10× faster
transcription (~110× realtime on Apple Silicon via CoreML/ANE), so text appears
near-instantly on hotkey release.

## Scope

**In scope**
- Swap the ASR engine behind the existing service boundary.
- Remove the custom vocabulary feature (UI + manager) — its mechanism was
  Whisper prompt tokens, which Parakeet does not support, and the user
  confirmed it is not needed.
- Add a trivial post-processing seam for a future LLM cleanup stage.
- One-time cleanup of the orphaned Whisper model cache.
- Documentation and changelog updates.

**Out of scope (explicitly deferred)**
- Always-on mic ring buffer / pre-roll to fix first-word clipping (user
  declined always-on mic; possible future project with different trade-offs).
- Noise suppression.
- LLM post-processing of transcripts (future project; this design only leaves
  the seam).
- Any changes to recording, hotkeys, command detection, text insertion, or UI
  beyond removing vocabulary screens.

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Integration approach | FluidAudio SDK (SPM) | Same abstraction level as WhisperKit; handles download, preprocessing, TDT decode, long-audio chunking. Alternatives (direct CoreML, sherpa-onnx) cost weeks or lose ANE. |
| Model variant | Parakeet TDT 0.6B **v3** | FluidAudio default/best-supported; 25 languages free; English WER within noise of v2 (~6.32% vs ~6.05%). Same download size — v2 is a one-line A/B change if ever wanted. |
| Custom vocabulary | Remove | No prompt-conditioning mechanism in Parakeet; user does not use the feature. |
| Audio pipeline | Unchanged | 16kHz mono WAV files from AVAudioRecorder are exactly Parakeet's input format. |
| Old Whisper cache | Delete once on first launch | Only Airboard created it; nothing will ever read it again; saves users 630MB. |
| Testing | Manual, by user | No XCTest target exists; this project does not add one. |

## Architecture

```
TranscriptionCoordinator
  → ParakeetTranscriptionService   (new — FluidAudio AsrManager, Parakeet v3)
  → TranscriptPostProcessor        (new seam — identity function for now)
  → CommandDetector / TextInserter / FloatingWindowManager   (unchanged)
```

### ParakeetTranscriptionService (new file, replaces LocalTranscriptionService)

Keeps the exact published surface the coordinator already consumes:

- `@Published transcription: String`
- `@Published isTranscribing: Bool`
- `@Published error: String?`
- `@Published isDownloadingModel: Bool`
- `@Published downloadProgress: Double`
- `@Published isModelReady: Bool`
- `func ensureModelReady() async`
- `func transcribe(audioURL: URL) async` — **signature change:** the
  `context:` parameter is dropped (it existed only to build Whisper prompt
  tokens). Call sites in the coordinator update accordingly. App-context
  detection itself stays — it is still used for insertion behavior and
  feedback.

Internal flow:
1. On init, start an async initialization task (same pattern as today):
   download Parakeet v3 models via FluidAudio if not cached, load, then run a
   short silent-audio warmup **before** setting `isModelReady = true`
   (preserves the stuck-orange-bug fix).
2. `transcribe(audioURL:)` keeps the existing guards: file < 1KB → "Recording
   too short"; empty result → "No speech detected"; deletes the audio file
   after transcription (success or failure), same as today.
3. If initialization failed (e.g., no internet on first run), the next
   transcribe attempt retries initialization instead of requiring an app
   restart.

Exact FluidAudio API names (AsrManager/AsrModels etc.) and the model cache
path are verified against current FluidAudio documentation at implementation
time; this spec fixes the behavior, not the SDK call signatures.

### TranscriptPostProcessor (new file, tiny)

The future-LLM seam: `process(_ text: String, context: AppContext?) -> String`,
returning its input unchanged. Applied at the coordinator's two transcription
call sites (dictation path and hands-free chunk path). The future LLM project
implements this function and touches nothing else.

### Removals

- WhisperKit SPM dependency (package reference + product).
- `LocalTranscriptionService.swift`.
- `VocabularyManager.swift`, `DictionaryView.swift`, and their entry points in
  the popover/menu UI (verify all references at implementation time; the
  Whisper prompt builder was their only functional consumer).

### One-time Whisper cache cleanup

On launch, if `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`
exists, delete it and log. Exact-path deletion only — this directory was
created by Airboard's WhisperKit integration and used by nothing else. Runs
cheaply every launch (existence check → no-op when absent), so it needs no
persisted flag.

## Download UX

Unchanged from the user's perspective: floating indicator with progress during
first-run download (~1–1.5GB for Parakeet v3 vs 630MB for Whisper — README
updated accordingly), dictation waits until the model is ready. Use FluidAudio's
real download progress if exposed; otherwise keep today's simulated progress
animation. First launch also compiles CoreML models once (~a minute of
"getting ready"); subsequent launches load from cache in well under a second.

## Error handling

Same contract as today: initialization failure publishes `error` and clears
downloading state; transcription errors publish `error` and reset
`isTranscribing`; the coordinator's existing error display path is untouched.
Improvement: init failure no longer bricks dictation until restart (retry on
next attempt, see above).

## Documentation

- CLAUDE.md: dependency table (WhisperKit → FluidAudio), model name, cache
  path, architecture diagram, remove vocabulary references.
- README.md: features list (drop custom vocabulary), first-run download
  section (new size + path), acknowledgments (FluidAudio/NVIDIA Parakeet
  alongside or replacing WhisperKit credit).
- CHANGELOG.md: entry under `[Unreleased]`.

## Verification (manual, run by the user)

1. Fresh launch → model downloads with progress indicator → ready state.
2. Short dictation into a real app.
3. Long dictation (>15s — exercises FluidAudio's internal chunking).
4. Hands-free mode (double-tap; chunked recorder path).
5. Command mode (hotkey + ⌘).
6. Dictation attempt before model ready → clean "not ready" feedback.
7. Old Whisper cache directory removed after first launch.
8. Project builds with WhisperKit fully removed (no stray references).

## Risks

- **FluidAudio API drift** — the SDK is young and evolves; API verified at
  implementation time. The service boundary means any breakage is contained to
  one file.
- **Accuracy character change** — Parakeet formats numbers/punctuation
  differently than Whisper in places. Benchmarks say net-better; the user's
  manual testing is the acceptance gate.
- **Larger first-run download** (~1–1.5GB vs 630MB) — accepted trade-off,
  documented in README.
