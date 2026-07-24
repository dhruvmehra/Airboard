# ASR Vocabulary Biasing + Memory Confirmation — Design

**Date:** 2026-07-25
**Status:** Approved

## Goal

Proper names and company words ("Pype", "Ashish") get recognized by the
RECOGNIZER, not just patched by the cleanup LLM — the mechanism Apple
Dictation, Wispr Flow, and NVIDIA's own Parakeet guidance all use. Plus:
no fact is ever stored silently — a sleek confirmation pop-up shows the
cleaned fact for edit/save, and edits teach the system automatically.

## Why this works (verified)

FluidAudio (already Airboard's ASR runtime) ships a documented, **Stable**
CTC vocabulary-boosting pipeline for Parakeet TDT 0.6B v3 — an
implementation of NVIDIA's CTC Word Spotter (arXiv:2406.07096): a separate
97.5MB CTC helper model runs on the same audio, a keyword spotter scores
the user's terms against per-instant acoustic probabilities, and a
rescorer corrects Parakeet's transcript from ACOUSTIC evidence (their
benchmark: 99.4% dictionary recall, ~26x real-time, ~130MB peak memory).
Parakeet remains the transcriber; nothing is replaced.
API: `CustomVocabularyContext(terms: [CustomVocabularyTerm(text:, weight:,
aliases:)])` on FluidAudio's sliding-window ASR manager.

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Mechanism | FluidAudio CTC vocabulary boosting (Approach 2, separate CTC encoder) | Only stable option for our 0.6B model; NVIDIA-recommended technique; already implemented in our dependency. |
| Contacts harvesting | **NO** | User decision: no permission prompt, more private. Names enter via facts, teaching, and pop-up edits only. |
| Watch-list sources | Glossary (term + heardAs aliases) + proper names auto-extracted from facts at storage time + pairs learned from pop-up edits | Fluid — no manual entry required. Capped at 200 terms (biasing degrades on huge lists). |
| Activation | Automatic: empty watch-list = zero cost (no download, no memory, behavior byte-identical to today); first entry triggers one lazy 97.5MB helper download | No setting to explain; 8GB teammates pay nothing until they use the feature. |
| Confirmation pop-up | EVERY "remember…" fact is confirmed in an editable DS-styled card before storage (⏎ Save / esc Cancel) | User requirement: nothing stored silently; the edit is where garbled names get fixed. |
| Learning from edits | Single-word substitutions between the heard fact and the saved fact become glossary pairs (heardAs → term) automatically | Correct once, recognized forever — consent-based learning, not surveillance. Structural rewrites teach nothing. |
| Privacy line | Watch-list is consumed ON-DEVICE by the acoustic spotter; only the glossary (as today) rides in the cleanup prompt under the existing share toggle | Fact-extracted names get acoustic biasing without ever being sent anywhere new. |
| Novel-name bootstrap | Honest limitation: a brand-new name arriving only via garbled audio can't self-heal; the pop-up edit or a spell-out ("spell it a-s-h-i-s-h") is the one-time teach | After one teach, the acoustic layer catches every future utterance. |

## Architecture

```
MemoryStore (existing)
  glossary [{term, heardAs, note}]  ←— pop-up edit diffs auto-add pairs
  notes [String]                    ←— pop-up-confirmed facts
  + biasTerms() -> [BiasTerm]       (new: glossary + extracted names, cap 200)
        │ consumed on-device by
ParakeetTranscriptionService (modified)
  adopts FluidAudio vocabulary boosting: CustomVocabularyContext built from
  biasTerms(); helper (97.5MB CTC encoder) downloaded lazily on first
  non-empty list, via the existing model-download progress UI; refreshed
  when memory changes; empty list = pipeline identical to today
        │
MemoryCommands (modified)
  .remember: LLM cleans fact AND extracts proper names (one call, JSON
  {sentence, names[]}, parsed defensively — parse failure degrades to
  sentence-only) → returns .confirmFact(cleaned:, heard:, names:) instead
  of storing directly
        │ presented by
MemoryConfirmView + FloatingWindowManager.showMemoryConfirm (new)
  DS v2 card: HUD surface + hairline, brain badge, editable text field
  prefilled with the cleaned fact, Save (⏎, DS primary) / Cancel (esc,
  quiet). Key-accepting floating panel (NOT non-activating — it takes
  typing; normal control rendering applies). On Save: store note (+
  extracted names to watch-list, + edit-diff glossary pairs); toast
  confirms. On Cancel: nothing stored.
```

### Edit-diff learning rule

Word-align the heard fact vs the saved fact. For each single-token
substitution where the replacement differs case-insensitively (e.g.
"reparty" → "Ashish"): add glossary entry (term = replacement, heardAs =
original, lowercased). Insertions, deletions, or multi-word restructures
teach nothing. Pairs appear in the Memory window like any taught entry.

## Failure handling

- Helper download fails/unavailable → transcription proceeds UNBIASED;
  never block or delay dictation. Retry on next launch.
- Extraction JSON malformed → treat as sentence-only (no names extracted).
- Pop-up dismissed via esc or window close → nothing stored, no teach.
- Pop-up while another pop-up is pending → replace the pending one
  (latest wins; the abandoned fact is dropped — command mode is
  single-utterance).
- Watch-list over cap → glossary entries win over extracted names;
  newest-first within each class; log what was dropped.

## Out of scope

- Contacts/calendar/screen harvesting (user decision).
- On-device model retraining / RL from corrections.
- Confirmation pop-ups for glossary teachings ("correct X to Y" stays
  immediate — it is already explicit) and recalls.
- Changing cleanup-LLM behavior (its glossary block is unchanged).

## Verification

- Scratch tests: biasTerms() assembly/cap/refresh; extraction JSON parsing
  (well-formed, malformed, empty); edit-diff pair derivation (substitution
  / insertion / restructure cases).
- Manual (Dhruv): teach "Pype" → dictate "send it to pipe" with cleanup
  OFF (isolates the acoustic layer) → "Pype" appears; "the water pipe is
  leaking" stays "pipe" (spotter needs acoustic match, not just text);
  "remember my co-founder is Ashish" → pop-up shows cleaned fact → edit a
  garbled name → Save → glossary shows the learned pair → dictate the name
  again, now recognized; esc stores nothing; helper download shows
  progress UI once; empty-memory user (fresh defaults) sees zero download
  and unchanged dictation; 8GB-machine memory check via Activity Monitor
  (~130MB delta only when biasing active).
- Regression: dictation, hands-free chunking, command mode, mic selection
  unchanged with empty watch-list.
