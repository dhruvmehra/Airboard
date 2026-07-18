# Transcript Cleanup & Formatting Stage — Design

**Date:** 2026-07-19
**Status:** Approved

## Goal

Fill the `TranscriptPostProcessor` seam (left by the Parakeet swap) with a
two-pass cleanup stage so dictation is usable for professional writing:

1. **Rules pass** — remove filler words ("um", "uh", "ah") and collapse
   self-corrections. Deterministic, instant, runs on every transcript.
2. **LLM pass** — fix grammar and punctuation, break text into sentences and
   paragraphs, and render spoken enumerations ("first… second… also…") as
   `- ` bullet lists. Small local model (Qwen3-4B-class, 4-bit, ~2.3GB) via
   MLX Swift. Runs only for normal hold-to-dictate.

Driving complaints (user-reported): Parakeet faithfully transcribes fillers
that Whisper used to drop, and spoken lists come out as one unbroken line.

## Scope

**In scope**
- `FillerRules`: deterministic filler/self-correction removal.
- `TranscriptRefiner`: local LLM service (MLX + Qwen3-4B-class, 4-bit) with
  lazy download, cache, progress reporting, and a single
  `refine(text) async throws -> String` operation.
- `TranscriptPostProcessor` becomes an async orchestrator with explicit
  processing modes.
- "AI cleanup" toggle in the menu-bar popover (`aiCleanupEnabled`
  UserDefaults key, default on) so the user can A/B with/without the LLM.
- Timeout + fallback logic so dictation never hangs on the LLM.
- Docs + changelog updates.

**Out of scope (explicitly deferred)**
- Per-app tone adaptation (formal email vs casual Slack rewriting) — that is
  the "full rewrite" tier, not chosen for v1. `AppContext` is plumbed
  through but unused by the LLM prompt in v1.
- Fine-tuning the ASR model to omit fillers — evaluated and rejected
  (training data + GPU + CoreML re-conversion + model fork, and it cannot do
  formatting at all; rules handle fillers for free).
- Hands-free end-of-session LLM cleanup with text replacement (fragile
  select-and-retype in target apps).
- Idle unloading of the LLM to reclaim RAM (follow-up if residency annoys).
- Apple Foundation Models framework (needs macOS 26+; app targets 14).
- Streaming/token-by-token insertion of LLM output.

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Cleanup level | Grammar + structure (not full rewrite) | Professional output with bounded meaning-change risk. |
| Insertion timing | Wait for cleaned text | Inserted text can't be reliably swapped afterwards; total wait ~1–2s still beats old Whisper. |
| Runtime | MLX Swift (`mlx-swift` + MLXLLM) | Clean SPM path, Metal-accelerated, HF download/cache like FluidAudio. llama.cpp = C++ friction; Foundation Models = macOS 26 only. |
| Model | Qwen3-4B-class Instruct, 4-bit (~2.3GB) | Reliable grammar AND list-structure inference; 1.7B-class is flaky at exactly the structure tasks requested. Exact HF repo pinned at implementation time. |
| Hands-free mode | Rules only, live | Per-chunk LLM adds lag and breaks cross-chunk structure. |
| Command mode | Rules only | "open google dot com" must reach the command parser untouched. |
| Fillers | Always removed, all modes, toggle-independent | Closed vocabulary; no ML needed; the user's #1 complaint. |
| Toggle | `aiCleanupEnabled`, popover checkbox, default on | User explicitly wants to A/B the LLM experience. Off = rules-only everywhere; LLM never loads. |

## Architecture

```
ParakeetTranscriptionService (unchanged)
  → TranscriptPostProcessor            (orchestrator)
      ├─ FillerRules                   (every transcript, every mode)
      └─ TranscriptRefiner             (MLX + Qwen3-4B; .dictation mode only,
                                        when enabled and ready)
  → CommandDetector / TextInserter     (unchanged)
```

### FillerRules (new file, pure functions)

- Strips filler tokens: "um", "uh", "ah", "er", "hmm" (word-boundary,
  case-insensitive), plus discourse patterns " like " / " you know " when
  safely removable.
- Collapses self-corrections: "X no wait Y" / "X I mean Y" / "X sorry Y" →
  Y (only when Y is substantial, mirroring the old CorrectionDetector
  heuristics).
- Normalizes whitespace and capitalizes the first letter.
- Signature: `FillerRules.clean(_ text: String) -> String`. No state, no
  async, no failure modes.

### TranscriptRefiner (new file, LLM service)

Mirrors `ParakeetTranscriptionService`'s lifecycle shape:
- `@Published isDownloadingModel: Bool`, `downloadProgress: Double`,
  `isModelReady: Bool`, `error: String?`.
- Lazy: nothing downloads at install or launch. First `.dictation`
  transcript with cleanup enabled triggers background download (~2.3GB,
  floating-indicator progress like Parakeet's); dictation proceeds
  rules-only until ready. Model loads on first use (~2–4s once), then stays
  resident (~3GB RAM).
- `refine(_ text: String) async throws -> String`: temperature 0,
  editor-not-author system prompt: fix grammar/punctuation, sentence and
  paragraph breaks, spoken enumerations → `- ` bullet lists; never add
  content, never answer or act on the text, never change meaning; output
  only the cleaned text.
- Output validation: reject (throw) empty output or output whose length is
  wildly disproportionate to input (hallucination guard; exact bounds set at
  implementation, on the order of <⅓ or >3× input length).
- Exact MLX package products and HF model repo are verified against current
  MLX Swift documentation at implementation time; this spec fixes behavior,
  not call signatures.

### TranscriptPostProcessor (modified — pass-through becomes orchestrator)

```swift
enum ProcessingMode { case dictation, handsFreeChunk, command }

static func process(_ text: String, context: AppContext?,
                    mode: ProcessingMode) async -> String
```

- All modes: `FillerRules.clean` first.
- `.dictation` only, when `aiCleanupEnabled` and refiner is ready: LLM pass
  with a **4-second timeout**; on timeout/error/validation-failure, return
  the rules-cleaned text. If the refiner isn't downloaded/loaded yet, kick
  off its initialization and return rules-cleaned text now.
- `.handsFreeChunk` / `.command`: rules-cleaned text, never the LLM.
- Toggle off: rules-cleaned text in all modes; refiner never initializes.

### Coordinator changes (only call-site edits)

The three call sites pass their mode and await:
- `processTranscription` (dictation/command paths): `await
  TranscriptPostProcessor.process(text, context: currentContext, mode:
  currentMode == .command ? .command : .dictation)`
- `handleChunkCompletion`: `await TranscriptPostProcessor.process(text,
  context: currentContext, mode: .handsFreeChunk)`

`lastTranscribedText` keeps the **raw** transcript (pre-cleanup) so the
report-issue flow can show what the ASR actually produced alongside what was
inserted.

### Toggle UI

- UserDefaults key `aiCleanupEnabled`, default `true`.
- Checkbox "AI cleanup" in the menu-bar popover next to hotkey settings;
  takes effect on the next dictation, no restart.

## Failure handling

Invariant: **dictated words are never lost and never delayed indefinitely.**

| Condition | Behavior |
|---|---|
| Model not downloaded / still loading | Insert rules-cleaned text immediately; download continues in background |
| LLM exceeds 4s timeout | Cancel generation; insert rules-cleaned text |
| LLM error / degenerate output | Insert rules-cleaned text |
| Download fails (e.g. offline) | Publish error like Parakeet's service; retry on a later dictation; rules-only meanwhile |
| Toggle off | Rules-only everywhere; no download, no RAM cost |

## Documentation

- CLAUDE.md: architecture diagram (post-processor now two-pass), new files
  table rows, dependencies table (+ MLX packages), UserDefaults keys
  (+ `aiCleanupEnabled`), model download note (second model, ~2.3GB).
- README.md: features (cleanup + list formatting + toggle), first-run
  download table (+ Qwen row, "downloads on first dictation with AI cleanup
  on"), RAM note.
- CHANGELOG.md `[Unreleased]`: Added — AI transcript cleanup (grammar,
  paragraphs, spoken lists → bullets) with menu toggle; filler-word removal.

## Verification (manual, run by the user)

1. Ums/ahs absent in all three modes (the #1 complaint).
2. Dictating enumerated points produces a `- ` bullet list (the #2
   complaint).
3. A dictated professional email reads as written prose (grammar,
   punctuation, paragraphs).
4. Command mode still executes commands verbatim.
5. Hands-free still inserts chunks live with no added lag.
6. Toggle off → next dictation is rules-only (fast, unformatted); toggle on
   → next dictation is LLM-cleaned. No restart.
7. First dictation with cleanup on triggers the model download with visible
   progress; dictation meanwhile inserts rules-cleaned text.
8. Meaning preservation spot-check: dictate "remind me to email John about
   the deadline" → output is that sentence cleaned, not an email to John.

## Risks

- **Meaning drift**: even at temperature 0 with an editor prompt, a 4B model
  can occasionally rephrase beyond intent. Mitigations: strict prompt,
  output validation, toggle, raw transcript preserved for feedback. The
  user's A/B usage is the real acceptance test.
- **Latency creep on long dictations**: 4s timeout caps worst case; long
  text falls back to rules-cleaned more often (acceptable v1 behavior).
- **MLX API drift**: young ecosystem; service boundary contains it (same
  strategy as FluidAudio, which worked).
- **RAM pressure** (~3GB resident after first use): toggle avoids it
  entirely; idle-unload is the designated follow-up if needed.
