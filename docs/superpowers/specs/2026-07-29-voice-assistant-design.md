# Airboard Voice Assistant (pi-powered) — Design

**Status:** Approved design, pending spec review — targets 1.1.0
**Date:** 2026-07-29
**Decided with:** Dhruv (brainstorm + live probes on his machine, pi 0.80.10)

## What this is

Command-mode speech that matches no known command currently dies as an
"Unknown Command" toast. This project replaces that dead end with an
assistant: an LLM (run via the pi coding agent, headless) understands the
question, optionally uses two safe tools (exact arithmetic, HTTPS fetch),
and answers in a toast. First target use cases: timezone conversion,
currency conversion, quick factual lookups.

This is phase F1+F2 of the assistant roadmap agreed on 2026-07-28:
F1 router + F2 web answers now; F4 agent dispatch and F5 MCP/pending-items
are separate future specs. `AssistantService` is the seam they build on.

## Goals / non-goals

Goals:
- Natural phrasing, LLM-understood — no fixed grammar for these asks.
- Zero-terminal setup: Airboard installs pi and manages the API key.
- Safety: the assistant can think and fetch HTTPS URLs. Nothing else.
- Honest UX: thinking state while working, specific failure toasts.

Non-goals (v1): MCP, agent/repo tasks, follow-up context between asks,
answer card UI (toast only), memory lines in prompts, latency
optimization (no warm RPC process, no provider detours — user explicitly
accepted seconds-scale answers; thinking models are fine).

## Command pipeline placement

In `TranscriptionCoordinator.handleCommandMode`, order becomes:

1. Exact memory verbs (`MemoryCommands.handle`)
2. Edit commands (`EditCommands.detect`)
3. `CommandDetector` (apps, websites, media, system, timers)
4. Memory LLM classify (`MemoryCommands.classify`) — existing behavior
5. **Assistant (`AssistantService.ask`)** — replaces the Unknown Command toast

Everything above the assistant stays instant and LLM-free. The assistant
only ever sees utterances nothing else claimed.

## AssistantService

New file `Airboard/AssistantService.swift`. Spawns pi per ask:

```
pi -p --no-session --no-extensions --no-skills --no-context-files \
   --no-builtin-tools --offline \
   -e <Resources>/assistant-tools.ts \
   --provider openrouter --model "openai/gpt-oss-120b:low" \
   --system-prompt <built per ask> \
   "<transcribed question>"
```

Spawn contract (each probe-verified 2026-07-28):
- **stdin MUST be closed** (`Process.standardInput = FileHandle.nullDevice`).
  pi reads stdin when non-TTY and hangs forever otherwise.
- Hermetic flags are mandatory: the user's personal pi extensions/skills/
  AGENTS.md must never load into a voice ask.
- API key passed via env (`OPENROUTER_API_KEY`) from Airboard's Keychain —
  never argv. (Verify exact env var name pi expects during implementation;
  `--api-key` flag is the fallback.)
- pi binary path resolved once via login shell (`/bin/zsh -lc 'which pi'`),
  cached; GUI apps don't inherit shell PATH.
- Hard timeout 60s, then SIGTERM; toast "Assistant timed out".
- Working directory: a neutral empty dir (Application Support), never the
  user's cwd.

Model + thinking level are a UserDefaults setting (`assistantModel`,
default `openai/gpt-oss-120b:low`); a text field in settings, no picker UI
in v1. OpenRouter key reuses the existing per-host Keychain machinery
(host `openrouter.ai`) — one key serves cleanup and assistant.

## The tools extension

`assistant-tools.ts` ships in the app bundle Resources (copied, not
compiled — pi loads .ts via jiti at runtime, probe-verified no build step):

- `calc(expr)` — local exact arithmetic, regex-restricted to
  `[0-9+-*/(). ]`. Exists because probes proved the model gets 500×83.6
  wrong at speed (returned 41,500). LLM must never do arithmetic.
- `fetch_url(url)` — HTTPS-only GET, body truncated to 4000 chars.
  This is the assistant's entire reach into the world.

No bash, no read/write/edit, no other tools. `--no-builtin-tools` + `-e`
yields exactly these two (probe-verified).

## System prompt contract

Built fresh per ask by `AssistantService`:
- Role: voice assistant answering via a small toast. ONE short line,
  no preamble, numbers first.
- Injected: current local date/time AND live UTC offsets for ~30 common
  zones + ~20 major cities, computed by macOS `TimeZone` (kills the DST
  hallucination class; model does arithmetic on given offsets — verified
  correct twice including day rollover, with (−1d)/(+1d) markers).
- Trusted sources: exchange rates via
  `https://api.frankfurter.app/latest?from=X&to=Y`.
- Arithmetic: ALWAYS via calc tool.
- Out-of-ability requests (send messages, read email, edit files, control
  apps): reply exactly `UNSUPPORTED: <short reason>` — probe-verified.
  Airboard renders that as "The assistant can't do that yet."

## Setup flow (bundle the experience, not the bytes)

pi is a Node app (165MB npm package, needs Node ≥22.19) — true embedding
would take the DMG from 6.7MB to 100MB+ per update. Rejected. Instead:

- Setup is one panel with both steps: **"Install assistant engine"**
  (one click — Airboard runs the official installer,
  `curl -fsSL https://pi.dev/install.sh | sh`, via login shell with a
  progress state; the installer handles Node itself) and an **OpenRouter
  key field**. The key is asked for explicitly during setup even when a
  cleanup key exists for another provider (e.g. Cerebras) — the assistant
  always uses OpenRouter in v1. If a Keychain key for `openrouter.ai`
  already exists (cleanup uses OpenRouter), the field is pre-filled.
  No `pi login` ever.
- First assistant use with anything missing → toast pointing at that
  panel, no spawn attempt.
- Release gate: `scripts/check_assistant.sh` smoke test (spawn pi with the
  bundled extension, ask "2+2 via calc", expect "4") so a pi update or
  extension-API break fails the release, not the user.

## UX

- HUD gains a **thinking** state (existing floating indicator, new phase)
  the moment the ask dispatches. Answers take 2.5–8s typically
  (probe-measured via OpenRouter; variance is real: same ask 2.7s and
  6.1s). Seconds-scale is accepted by design.
- Answer → long-dwell toast (~8s). Toast gains a `duration` parameter.
- Failure toasts are specific: "Assistant isn't set up yet — click to set
  up" / "Add your OpenRouter key in Settings" / "Assistant timed out" /
  "Couldn't fetch that" / "The assistant can't do that yet".

## Logging, telemetry, privacy

- `performance.jsonl`: mode `assistant`, duration ms, outcome
  (`ok|timeout|error|unsupported|setup_missing`), preview = the question
  (LOCAL ONLY, same rule as dictation previews).
- TelemetryDeck: signal `assistant.ask`, floatValue = duration ms, params
  mode/outcome/appVersion. Outcome enum fixed strings only; never
  question text.
- README privacy: assistant questions (text only) go to OpenRouter and
  any URLs the model fetches; nothing runs unless the user asks the
  assistant something. Memory lines are NOT sent (v1).

## Failure modes

| Condition | Behavior |
|---|---|
| pi not installed | setup offer toast; no spawn attempt |
| no OpenRouter key | settings-pointing toast; no spawn |
| pi exits non-zero / garbage output | "Assistant had a problem" + log |
| timeout 60s | SIGTERM + "Assistant timed out" |
| model replies UNSUPPORTED | "can't do that yet" toast |
| fetch fails inside pi | model says so; toast carries its one-liner |
| answer > toast size | truncate with ellipsis (card UI is future work) |

## Testing

- Scratch tests: pipeline precedence (assistant only reached when nothing
  else matches), pi output parsing, prompt-builder offset table.
- `scripts/check_assistant.sh` smoke test wired into release gate Step 0.
- Field pass (Dhruv): timezone ask, currency ask, factual ask, misfire
  ("send this to X"), pi-missing path (rename binary), no-key path,
  mid-ask new dictation (must not interfere).

## Probe evidence (2026-07-28, Dhruv's M4, pi 0.80.10, OpenRouter)

- stdin open → infinite hang. Closed → works.
- `thinking off` → 400 (reasoning mandatory on gpt-oss endpoints).
- `minimal`, no tools: 500×83.6 → **41,500 (wrong)**. With calc: 41,800 ✓.
- Timezone with injected offsets: correct twice incl. rollover, 2.7–6.1s.
- Live currency E2E (fetch frankfurter + calc): ₹ answer ✓, 6.1s.
- UNSUPPORTED contract: exact compliance, 2.3s.
- Single-file .ts extension: loads with zero build, imports resolve.

## Future seams

- **F4 agent dispatch:** `AssistantService` gains a `dispatch(task:)`
  running pi with full tools + high-thinking model in a configured repo,
  background + notification. Separate spec.
- **F5 pending items:** MCP-or-CLI-tools decision deferred; possibly
  Claude Code for just those asks. Separate spec.
- Answer card, follow-up context, memory-in-prompt, warm RPC: revisit
  after field use.
