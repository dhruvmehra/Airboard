# Performance Telemetry + Local Dictation Log — Design

**Date:** 2026-07-26
**Status:** Approved

## Goal

Dhruv can answer, without building or hosting anything: how many people use
Airboard, and how fast dictation is for them (STT vs LLM split, timeout
rate) — plus, locally on his own Mac, see his recent dictations with their
timing breakdown. No transcript text ever leaves any machine.

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Backend | **TelemetryDeck** (hosted, privacy-first app analytics, Swift SDK) | Purpose-built for exactly this; dashboards included; zero infrastructure. Metabase was considered and rejected — it is only a viewing layer and would require self-hosting ingest + Postgres ("building it yourself"). |
| Consent | Anonymous-by-design, ON by default, visible toggle + README disclosure | Team of 15 gets real numbers day one; open-source users get an honest, discoverable switch. |
| What is sent | Timing/version numbers ONLY — never transcript text, never file paths, never names | Privacy line of the product. |
| Which builds send | Production bundle (`com.pype.airboard`) only — dev builds never send | Same pattern as Sparkle updates; dev noise would pollute the stats. |
| Personal "what did I say + how long" | LOCAL persistent log + a "Recent dictations" list in the Performance window | Transcript-adjacent data stays on-device by definition; the Performance window is its natural home. |
| Downloads count | Not telemetry — GitHub Releases download counts (API/page) | Already exists; document where to look. |

## Architecture

```
TelemetryService.swift (new)
  wraps the TelemetryDeck SDK; no-ops entirely when:
  bundle != com.pype.airboard  OR  toggle off
  Signals:
    - "app.launched"            {appVersion, modelVersion}
    - "dictation.completed"     {sttMs, llmMs, llmOutcome: ok|timeout|error|off,
                                 audioSeconds (rounded Int), mode: dictation|command|handsfree,
                                 appVersion}
  Anonymous install ID: random UUID in UserDefaults, fed to the SDK's
  built-in anonymization (never an email/name/hostname).
        ▲ called from
TranscriptionCoordinator / ParakeetTranscriptionService / TranscriptPostProcessor
  (the timing numbers already exist as log prints — this routes them)
        also feeds
PerformanceLog.swift (new, local-only, ALL builds incl. dev)
  appends one JSON line per dictation to
  ~/Library/Application Support/<bundle id>/performance.jsonl:
    {ts, mode, audioSeconds, sttMs, llmMs, llmOutcome, words, preview}
  preview = first 40 chars of the final text (LOCAL file only, never sent).
  Rotation: keep the newest ~1000 lines (rewrite on overflow).
        ▲ read by
PerformanceView (modified)
  new "Recent dictations" section: last 10 entries — time-ago, preview,
  and a compact timing readout ("2.1s audio · STT 180ms · LLM 520ms" or
  "LLM timed out"), DS mono numerals.
  + the telemetry toggle: "Share anonymous performance stats" with a
  one-line explanation and a "what is sent" disclosure.
```

## Privacy contract (verbatim for README)

Production builds send anonymous usage signals to TelemetryDeck: timing
numbers (speech-to-text and cleanup durations), outcome flags, audio
length in seconds, app version, and a random install identifier. Never any
transcript text, file names, personal data, or network identity. The
"Share anonymous performance stats" switch in the Performance window turns
it off entirely. Debug builds never send anything.

## Failure handling

- SDK/network failures are fire-and-forget: telemetry must never delay,
  block, or fail a dictation (send off the hot path, after insertion).
- performance.jsonl unwritable → skip silently (same never-block rule).
- Malformed lines in performance.jsonl are skipped on read; rotation
  rewrites the file clean.

## Out of scope

- Custom dashboards/Metabase/SQL (TelemetryDeck's dashboards are the UI).
- Any transcript-content telemetry, error-body telemetry, or crash
  reporting (separate decision for another day).
- Historical backfill (stats start at 1.0.9).
- In-app charts beyond the recent-dictations list.

## Verification

- Scratch tests: PerformanceLog append/rotate/read round-trip; malformed
  line tolerance.
- Manual (Dhruv): dev build → dictate → Performance window shows the entry
  with STT/LLM split; toggle exists and persists; dev build sends nothing
  (no TelemetryDeck app ID configured for dev / bundle check — verify via
  Console/log). Prod verification post-1.0.9: signals appear in the
  TelemetryDeck dashboard; timing averages chartable.
- README disclosure present; changelog entry present.

## Setup prerequisite (Dhruv, one-time, ~5 min)

Create a free TelemetryDeck account + an app entry to get the App ID; the
ID is a public write-only token and lives in Info.plist (fine to commit —
same class of value as the Sparkle public key).
