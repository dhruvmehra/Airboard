# Self-Learning Vocabulary — Design

**Status:** Approved design, pending spec review
**Date:** 2026-10-07
**Decided with:** Dhruv (brainstorm + live probes on his M4: Gemma 3 270M
via MLX, Jev 1.13 and Mercury Decide via OpenRouter)

## What this is

Parakeet mishears the names and terms Dhruv uses most — "bright AI" for
Brite AI, "paraket" for Parakeet, "cloud code" for Claude Code, "a lisha"
for Alisha. Memory can already hold correct spellings, but (a) he has to
add them by hand, and (b) they are only applied by the remote cleanup LLM,
which is off on his build — so today they do nothing.

This feature makes Airboard learn those terms by itself and write them
correctly from then on, with zero added latency on ordinary dictations.
It learns from two signals: the fixes he makes right after a dictation,
and the names/terms that appear on his screen. Every new lesson is shown
on a small confirm card; nothing changes his text without a confirmed rule
or a decision model agreeing in context.

## Goals / non-goals

Goals:
- Learn spellings automatically from (A) post-dictation edits and
  (B) on-screen text, with a one-click confirm/deny card.
- Apply confirmed spellings on every dictation, context-aware ("bright AI is
  hiring" → Brite AI; "a bright idea" → unchanged).
- Speed: **+0ms** for dictations that contain no learned term; **≤350ms**
  worst case for those that do.
- Decisions are made by a decision model (Jev), not hand-written rules,
  behind one swappable seam so a fine-tuned local Gemma 3 270M can replace
  it later.
- Bring-your-own-key: no API key ships in the app or the repo.

Non-goals (this spec):
- Grammar, punctuation, and formatting fixes (next phase; decisions #3/#5
  in the map below).
- Learning facts ("Cait is my colleague") — only spellings.
- "Write an email for me" generation.
- Acoustic keyword spotting (see Future work).
- Fine-tuning Gemma (separate project; its data rules are fixed here).

## Decisions made during the brainstorm

| Decision | Choice | Why |
|---|---|---|
| Where spellings are learned from | Both: post-dictation edits **and** on-screen text, screen reading unrestricted (local only; secure/password fields always skipped) | Edits are the most precise signal; screen text learns terms before they're ever misheard |
| Typed-text capture | Read the focused window via the **existing Accessibility permission**; no keystroke tap | Input Monitoring is a keylogger-class permission — not needed, since typed text is visible in the window |
| Involvement | Quick confirm card; **ignored "Learned" card = Keep**; ignored "Did you mean" = nothing | His own edit is already strong evidence; screen guesses are not |
| Decision maker | **Jev 1.13** (TypeSafe, via OpenRouter Decisions API) | Probe: 24/25 vs Gemma 270M untuned 14/25 (always-yes) |
| Fallback decision model | Mercury Decide (same `/v1/systemone` schema) | Probe: 23/25, tighter p90 (345ms), free tier |
| Candidate finding | Text sound codes (original Metaphone; Double Metaphone gave identical match/no-match results on every fixture at a third of the code), 1–3-word windows | All real mishearings matched; "brightness"/"is working" correctly not matched; ~1ms, no model |
| Personal data & training | **No user content is logged for training.** Future Gemma fine-tuning uses synthetic data only | Models must learn *how to decide*, not the user's vocabulary |
| API key | BYOK, Keychain-only, **the same OpenRouter key the Assistant already uses** (`KeychainHelper`, host `openrouter.ai`) | No key in app/repo; one OpenRouter key per app, not two |

## Probe results (2026-10-06/07, Apple M4, 16GB, from Bangalore)

Same 25 hand-written cases (14 "apply this term here?", 11 "is this edit a
spelling fix?"); hand-written sentences, which used real personal names — the repo copies use stand-ins.

| | Jev 1.13 | Mercury Decide | Gemma 3 270M (4-bit, untuned) |
|---|---|---|---|
| Accuracy | **24/25** | 23/25 | 14/25 (answered "yes" to all 14 apply cases) |
| Latency p50 / p90 / max | 237 / 643 / 887ms | 273 / 345 / 1557ms | 14ms median (local) |
| Size / cost | $0.0008 per 50 calls | free | 151MB download |

Both API models missed "for sell" → Vercel (two words → one). The set is
small and self-written: a strong signal, not proof. Gemma 270M is fast
enough (≈14ms) but needs fine-tuning before it can make these calls.

## Architecture

```
Parakeet text
  → FillerRules (um/uh)                         unchanged
  → VocabularyRules.apply()                     NEW — dictation path
        CandidateFinder (sound codes, exact phrases)
        DecisionEngine  (Jev, batched, 350ms deadline)
  → TextInserter.insertText()                   unchanged
  → CorrectionWatcher.observe(insertion)        NEW — background
  ↺ VocabularyHarvester (every ~30s)            NEW — background
  → VocabularyCard (Keep/Undo, Yes/No)          NEW — UI
  → MemoryStore (memory.md) + VocabularyCache   rules + hidden cache
```

### Units

Each unit has one job and can be tested on its own. Pure logic is
Foundation-only so it compiles in standalone scratch tests (the repo's
existing pattern for `MemoryBias`/`FillerRules`).

**`SoundCode`** (pure) — original Metaphone encoding of a word or phrase
(spaces removed before encoding, so "a lisha" → ALX = "Alisha").
Plus a one-edit tolerance check for codes of 4+ sounds ("super base"
SPRBS vs "Supabase" SPBS); shorter codes must match exactly.

**`SpellingRule`** (pure) — parse/render the one memory-line format:
`"<term>" is the correct spelling — often heard as "<heard>".`
(the exact string `MemoryBias.spellingMemory` already produces). Only lines
matching this shape become rules; every other memory line is untouched
and still goes to the cleanup LLM as today.

**`CandidateFinder`** (pure) — given a transcript, confirmed rules, and
screen terms, returns ≤5 candidates `(span, term, source, meaning?)`:
- exact: a rule's "heard as" phrase appears (case-insensitive, word
  boundaries — "brightness" never matches "bright");
- sound-alike: a 1–3-word window whose sound code equals (or is one edit
  from) a rule term's or screen term's code.
Pre-built index keyed by sound code; ~1ms for hundreds of terms. A
candidate is only a *question*, never a change.

**`DecisionEngine`** (protocol) — `decide([Question], deadline) async ->
[Answer?]`. Questions are typed yes/no with criteria; answers carry a
probability. Implementations:
- `OpenRouterDecisionEngine` — `POST https://openrouter.ai/api/alpha/decisions`,
  model `typesafe/jev-1.13`. All questions about ONE sentence are batched
  into one request with one shared `state` (probe: 160–270ms for a
  3-question batch). Questions about different sentences are never merged
  into one state — merging 5 unrelated sentences dropped a clear "yes"
  to 0.50. The apply question tells Jev the term is "a name or term this
  user often says" (without it, "email bright AI" → Brite AI scored 0.40)
  but never what the term is.
- Fallback model `inception/mercury-decide:free` (same schema), used only
  if Jev errors with time left before the deadline.
- Later: `LocalGemmaDecisionEngine` (MLX), drop-in.

**`VocabularyRules`** — the dictation-path orchestrator:
1. No candidates → return text unchanged (+0ms).
2. Ask `DecisionEngine` once with all candidates, 350ms deadline.
3. Confirmed rule + yes (p ≥ **0.5**) → replace span with term.
   (Calibrated by probe: with the generic prompt every true "yes" scored
   ≥ 0.62 and every true "no" ≤ 0.22, so 0.5 got 14/14 where 0.7 got
   11/14. Applies only to rules the user already confirmed.)
   Confirmed rule + no → leave as spoken.
   Screen term + yes (p ≥ 0.7) → insert as spoken, queue a "Did you
   mean" card.
4. Timeout/error/no key → confirmed *exact* rules apply; sound-alikes and
   screen terms skipped.
Session cache: a (span, term) pair Jev answered "no" for is not re-asked
this session.

**`CorrectionWatcher`** — after each successful insertion into an
AX-readable field, re-reads that field at ~2s, 5s, 10s. If the inserted
text is still present with 1–2 word-like tokens changed (reusing
a new `EditDiff`, which also handles 2-words-to-1 like "a lisha" →
"Alisha" — `MemoryBias.editDiffPairs` requires equal word counts), asks
Jev "spelling fix
of the same word/name, or a change of meaning?". Yes (p ≥ 0.7) → queue a
"Learned" card. Stops on app switch, a new recording, heavy edits, or
an unreadable field (terminals). Secure text fields are never read.

**`VocabularyHarvester`** — every ~30s while an app is frontmost and no
recording is active, reads the focused window's text via AX (skipping
secure fields), extracts capitalized words, CamelCase and dotted/tech
tokens, and keeps frequency counts of the top ~500 in `VocabularyCache`.
Before a term can ever be suggested, Jev filters junk ("is this a real
name or product/technical term, not a UI label or a sentence-initial
word?"); the verdict is cached per term.

**`VocabularyCache`** (pure + JSON file, App Support, not user-facing) —
harvested term counts, per-term junk verdicts, and rejected pairs
(Undo / No). Clearing it only resets suggestions; confirmed rules live in
`memory.md`.

**`VocabularyCard`** (SwiftUI in a **non-activating** NSPanel — must never
take focus; unlike `MemoryConfirmView`, which is key-accepting):

| Card | Text | Buttons | Ignored ~8s |
|---|---|---|---|
| Learned | "Learned: bright AI → **Brite AI**" | Keep · Undo | **Keep** |
| Did you mean | "Did you mean **Parakeet**?" | Yes · No | nothing (not re-asked for a while) |

One card at a time, never during recording, max ~4 per hour, extras
queued. Keep/Yes → `MemoryStore.addMemory(SpellingRule…)`. Yes also fixes
the just-inserted word in place when the field is AX-writable. Undo/No →
rejected pair stored in `VocabularyCache`, never asked again.

## Settings & keys

- New "Learn my vocabulary" section (in Memory settings): master toggle
  (on by default once a key exists), OpenRouter key field, test button,
  and a note that each decision sends one sentence + one term to
  OpenRouter/TypeSafe; recommend enabling OpenRouter zero-data-retention
  for that key.
- Key: the OpenRouter key already stored for the Assistant
  (`KeychainHelper`, host `openrouter.ai`, per-bundle service so dev and
  prod stay separate). Settings shows whether it's set and lets the user
  set it from either screen. No key in source, release, or appcast.
- No key → exact confirmed rules still apply locally; watcher, harvester
  and sound-alikes off.
- Toggle off → behavior identical to today.

## Privacy

- Local: screen text and edits are processed on-device; the harvest cache
  stays in App Support.
- Sent off-device (only with a key, only per decision): the one sentence
  (or edit) plus the one candidate term and its short meaning. Never the
  memory file, never screen dumps, never audio.
- Not logged anywhere: sentences, terms, or answers. Metrics only
  (count, latency, timeout, confidence bucket) via the existing
  PerformanceLog/telemetry funnel — numbers/enums only, same rule as
  today.
- Future training data: synthetic only (invented and public names, e.g.
  "Zentrix AI", "Kubernetes"), labeled by Jev. No user content. Test
  fixtures and the eval set in this repo use neutral stand-ins (Brite,
  Cait, Alisha) — the repo is public.

## Error handling

The guarantee: **this feature can never delete or block dictated text.**
Worst case, a word stays as Parakeet heard it.

| Failure | Behavior |
|---|---|
| No key / offline / OpenRouter down | Exact confirmed rules only; no cards |
| Jev > 350ms | Abandon call; exact rules only; count a timeout |
| Jev error | Try Mercury if time remains, else exact rules only |
| Malformed answer or p < 0.7 | Treated as "no" |
| Field not AX-readable | Watcher skips; harvester skips that app |
| Heavy edit / app switch | Watcher stops, learns nothing |
| Hand-edited memory.md | Non-matching lines ignored for rules, kept as memories |
| Bad rule learned | Undo on card, or delete the line in Memory settings |

## Map of future decision points (out of scope here)

For the decision-engine roadmap; each is a yes/no question a decision
model can answer:

| # | Decision | Today | Phase |
|---|---|---|---|
| 3 | Is this a self-correction ("3pm, no wait, 4pm")? | removed 2026-10-06 | grammar |
| 4 | Real utterance or ASR hallucination? | phrase list | later |
| 5 | Does this text need LLM cleanup? | ≥6 words | grammar |
| 8 | Is this a fact worth remembering? | — | later |
| 9 | Edit command or text to type? | exact phrases | later |
| 10 | Device command or assistant question? | prefix rules | later |
| 11 | Memory intent (remember/recall/correct)? | remote LLM | later |

## Testing

No XCTest target exists; follow the repo's pattern.
1. **Scratch tests (pure units):** SoundCode (the probe table below as
   fixtures), SpellingRule parse/render round-trip, CandidateFinder
   (exact, sound-alike, word boundaries, ≤5 cap), session/rejection
   caching.
2. **Offline decision eval set (synthetic only):** the 25 probe cases
   plus more, run against Jev/Mercury on prompt changes to track accuracy
   and latency; later the pass/fail gate for a fine-tuned Gemma
   (target ≥ 23/25 at ~15ms).
3. **Manual app script:** learned term corrected; "a bright idea" left alone;
   fix a word in Notes → Learned card → ignore → rule kept; Undo removes
   it; screen term → Did you mean → Yes fixes in place; network off →
   dictation instant, exact rules still apply; Terminal → no watcher.
4. **Latency check:** PerformanceLog gains decision ms + outcome per
   dictation to verify +0ms / ≤350ms in real use.

Sound-code fixtures (original Metaphone, spaces stripped):

| Heard | Code | Term | Code | Expect |
|---|---|---|---|---|
| bright AI | BRT | Brite AI | BRT | match |
| paraket | PRKT | Parakeet | PRKT | match |
| cloud code | KLTKT | Claude Code | KLTKT | match |
| a lisha | ALX | Alisha | ALX | match |
| kate | KT | Cait | KT | match |
| for sell | FRSL | Vercel | FRSL | match |
| super base | SPRBS | Supabase | SPBS | one-edit match |
| brightness | BRTNS | Brite | BRT | no match |
| is working | ASWRKNK | Cait | KT | no match |

## Relationship to earlier decisions

- **MemoryStore header ("NOTHING here is ever applied by local
  find-and-replace")**: amended narrowly — confirmed `SpellingRule` lines
  are applied locally, and only after a decision model agrees in context
  (or as an exact match when it can't be reached). All other memory lines
  remain LLM-only.
- **July 2026 acoustic biasing removal** (`ParakeetTranscriptionService`
  note; `2026-07-25-asr-vocabulary-biasing-design.md`): that feature
  applied sound matches blindly. Here a sound match is only a question to
  a context-aware decision model, and text-level codes rejected the
  July's "is working" → name case outright (ASWRKNK vs a 2–4-sound name).

## Future work

- Fine-tune Gemma 3 270M (LoRA, MLX) on synthetic Jev-labeled data;
  swap in as `LocalGemmaDecisionEngine` (~14ms, offline).
- Acoustic keyword spotting as a second candidate source, only with an
  offline eval harness of recorded utterances.
- Fact learning (#8), grammar/punctuation (#3, #5).
