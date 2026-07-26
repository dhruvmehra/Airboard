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
| Backend | **Supabase (hosted Postgres, free tier) + Metabase run locally when wanted** | User decision (revised from TelemetryDeck): full ownership of the raw data and unrestricted SQL (percentiles included). No ingest server needed — the app POSTs rows to Supabase's auto-generated REST API with an insert-only anon key (Row Level Security); Metabase runs on Dhruv's MacBook via Docker against the Supabase connection string, nothing hosted. TelemetryDeck rejected: floatValue-only charting, no percentiles, limited raw-data access. |
| Consent | Anonymous-by-design, ON by default, visible toggle + README disclosure | Team of 15 gets real numbers day one; open-source users get an honest, discoverable switch. |
| What is sent | Timing/version numbers ONLY — never transcript text, never file paths, never names | Privacy line of the product. |
| Which builds send | Production bundle (`com.pype.airboard`) only — dev builds never send | Same pattern as Sparkle updates; dev noise would pollute the stats. |
| Personal "what did I say + how long" | LOCAL persistent log + a "Recent dictations" list in the Performance window | Transcript-adjacent data stays on-device by definition; the Performance window is its natural home. |
| Downloads count | Not telemetry — GitHub Releases download counts (API/page) | Already exists; document where to look. |

## Architecture

```
TelemetryService.swift (new, ours — no SDK)
  One URLSession POST per event to Supabase's auto-generated REST API
  (PostgREST): POST {url}/rest/v1/events with the public ANON key
  (insert-only via Row Level Security — the key cannot read or delete).
  Fire-and-forget off the hot path (detached Task after insertion);
  failures are dropped silently — telemetry never delays or blocks a
  dictation. No-ops entirely when: bundle != com.pype.airboard OR
  toggle off. Config (SUPABASE_URL + anon key) in Info.plist — public
  write-only values, same class as the Sparkle public key.

  ONE table, one row per event — full SQL freedom (percentiles etc.):
    events(
      id bigint identity, created_at timestamptz default now(),
      event text,               -- 'launch' | 'dictation'
      install_id uuid,          -- random per install, stored in UserDefaults
      app_version text, model_version text,
      mode text,                -- dictation | command | handsfree (null for launch)
      stt_ms int, llm_ms int,   -- llm_ms null when LLM didn't run
      llm_outcome text,         -- ok | timeout | error | guarded | skipped | off
      audio_seconds int
    )
  RLS: enable; single policy `allow anon insert` (no select/update/delete
  for anon). Supabase free tier: 500MB database — years of events at this
  row size.

  Dashboards: Supabase SQL editor day one (saved queries provided in the
  README-adjacent docs); Metabase locally on demand:
    docker run -d -p 3000:3000 metabase/metabase
  pointed at the Supabase Postgres connection string. Nothing hosted.
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

Production builds send anonymous usage rows to a database operated by
the project maintainers (Supabase-hosted Postgres): timing numbers
(speech-to-text and cleanup durations in ms), an outcome flag, dictation
mode, audio length in seconds, app and model versions, and a random
install identifier (a UUID generated on first launch — no name, email,
hostname, or hardware ID). Never any transcript text, audio, file names,
or personal data; the app's database credential can only insert rows,
never read them. The "Share anonymous performance stats" switch in the
Performance window turns it off entirely. Debug builds never send
anything.

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

## llm_outcome values (fixed enum strings — no free text, ever)

ok (cleanup output used) | timeout (4s budget expired, fallback inserted) |
error (transport/HTTP failure, fallback) | guarded (refusal/ratio guard
discarded the output, fallback) | skipped (dictation under the 6-word
gate) | off (cleanup disabled/unconfigured). Error MESSAGES and response
bodies are never sent — outcomes are single words by construction.

## Setup prerequisite (Dhruv, one-time, ~10 min)

Create a free Supabase project → run the provided SQL (table + RLS
insert-only policy, delivered in the plan) in the SQL editor → copy the
project URL and anon key into Info.plist. Both values are public-safe
(write-only by policy) and fine to commit.
