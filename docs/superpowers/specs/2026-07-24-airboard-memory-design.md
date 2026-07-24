# Airboard Memory (vocabulary glossary + personal facts) — Design

**Date:** 2026-07-24
**Status:** Approved

## Goal

Airboard remembers two kinds of things and uses them everywhere it writes:

1. **Vocabulary** — proper nouns and spellings the ASR mishears ("pipe" →
   Pype, "air board" → Airboard), corrected **in context** on every cleaned
   dictation.
2. **Personal facts** — free-form notes ("My co-founder is Ashish —
   ashish@pype.ai", "I work at Pype", "My address is …") that enrich cleanup
   and can be recalled as inserted text on command ("write my address",
   "fill in where I work").

This is the memory **foundation**: the future action feature ("send an
email to my co-founder") will read the same store; no actions are built
here.

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Scope | Foundation only (store + teaching + recall-as-text) | Actions (email…) are the deferred action-taking project; memory must not block on it. |
| Teaching | Voice (command mode) + settings UI | Explicit and reliable. Auto-learning from watching the user's edits REJECTED: AX surveillance, fragile, wrong about intent. |
| Privacy line | Vocabulary AND notes ride in the cleanup prompt | User's explicit choice (his key, his provider). A visible "Share memory with AI Cleanup" switch (default ON) keeps it opt-out for open-source users. |
| Fact shape | Free-form note sentences | Handles any fact ever spoken; exactly the format LLMs use best. Structured schemas rejected as rigid. |
| Vocabulary mechanism | **Glossary applied ONLY by the cleanup LLM — no local find-and-replace** | User's correction: "pipe" sometimes means pipe. Only a reader of the sentence can decide; blind replacement corrupts legitimate uses. Consequence: vocabulary correction requires AI Cleanup on; with it off, dictation is verbatim (no corruption either). |
| Storage | JSON at `~/Library/Application Support/<bundle id>/memory.json` | App code + settings UI are the editors; JSON round-trips reliably. Dev/prod isolated by bundle id (Keychain precedent). Rendered to a human-readable text block at prompt time — the LLM never sees raw JSON. |
| Voice deletion | Not in v1 | Destructive voice commands need confirmation UX; the settings UI is the safe delete path. |

## Architecture

```
MemoryStore.swift (new)            ← load/save memory.json, atomic writes
  ├─ glossary: [{term, heardAs, note?}]
  ├─ notes: [String]
  └─ shareWithLLM: Bool (default true)
        ▲ read by                          ▲ taught by
TranscriptRefiner                   CommandDetector (new intents)
  cleanup prompt gains a              "remember <sentence>"   → append note
  MEMORY block (rendered              "correct <heard> to <term>" /
  glossary + notes) when              "spell <word> as <spelling>"
  shareWithLLM && entries exist         → append glossary entry
                                      "write/insert/fill (in) my <thing>"
                                        → recall: resolve → TextInserter
MemorySettingsView.swift (new)     ← DS-styled window: glossary table,
  opened from a new popover row       notes list, share toggle; edit/delete
```

### Cleanup prompt integration

- The MEMORY block is appended by code alongside the system prompt (outside
  the user-editable custom prompt, so custom prompts keep memory), framed
  as data with the same injection discipline as the `<dictation>` envelope.
- Glossary instruction: "When the dictation plausibly refers to one of
  these terms, use the exact spelling; otherwise leave the word as spoken."
  ("send the deck to pipe" → Pype; "the water pipe is leaking" → unchanged.)
- Notes let mid-dictation references resolve ("I work at — my company" →
  Pype).

### Command-mode intents (the "action trigger")

- Detection: local prefix/pattern match first ("remember …", "correct … to
  …", "write my …", "fill in …"). Recall resolution (which note answers
  "where I work") goes to the cleanup LLM when configured; local fallback
  is a keyword match over notes so core recalls work offline.
- Teach feedback: the floating pill confirms ("Remembered" / "Learned:
  Pype"). Recalled text inserts via the existing TextInserter path, exactly
  like dictation.
- Spelled-out corrections ("P-Y-P-E") are normalized during teaching by
  local letter-joining ("p y p e" / "p-y-p-e" → "Pype"). (Simplified from
  an earlier LLM-assisted idea during planning — the local join fully
  covers the case.)

### Settings

New **Memory** window (DS v2 styling, opaque panel, precedent:
CleanupSettingsView): glossary table (term / heard-as / delete), notes list
(add / edit / delete), "Share memory with AI Cleanup" toggle. Opened from a
new row in the popover.

## Failure handling

- memory.json unreadable/corrupt → start empty, back up the bad file aside
  (`memory.json.bad`), never crash, never silently overwrite good data.
- LLM unavailable during recall → local keyword fallback; no match → pill
  shows "Nothing remembered about that" and nothing is inserted.
- Teaching parse failure → pill shows what was heard; nothing stored.
- Cleanup off → dictation verbatim (documented consequence), teaching and
  settings still work, recall works via local fallback.

## Verification

- Scratch tests: MemoryStore round-trip + corrupt-file recovery; prompt
  block rendering; local recall fallback matching.
- Manual (Dhruv): teach "correct pipe to Pype" by voice → visible in
  settings → dictate "send the deck to pipe" → "Pype", and "the water pipe
  is leaking" stays "pipe"; "remember I work at Pype" → "fill in where I
  work" inserts Pype into a form field; "write my address" into Notes;
  share toggle OFF → cleanup request carries no MEMORY block (verify via
  a local mock server); dev and prod stores isolated.

## Out of scope

- Actions that USE memory (email composition, contact resolution into
  Mail) — the deferred action-taking project reads this same store.
- Auto-learning from user edits; structured fact schemas; voice deletion;
  memory sync between machines.
