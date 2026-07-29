# Voice Assistant (pi-powered) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the command-mode "Unknown Command" dead end with an LLM assistant (pi, headless, OpenRouter) that answers questions via toast, with exactly two tools: exact arithmetic and HTTPS fetch.

**Architecture:** `TranscriptionCoordinator` falls through to a new `AssistantService` after all existing matchers. The service spawns `pi -p` hermetically per ask, loading a bundled two-tool TypeScript extension; a Foundation-only `AssistantPrompt` builds the system prompt (live UTC offsets) and parses output. Setup (pi install + OpenRouter key) is a new settings window; a smoke script gates releases.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (existing app), pi coding agent ≥0.80 (Node CLI, spawned via `Process`), OpenRouter (`openai/gpt-oss-120b:low` default), TypeScript extension loaded by pi at runtime (no build step).

**Spec:** `docs/superpowers/specs/2026-07-29-voice-assistant-design.md` — read it first.

## Global Constraints

- Swift files live in `Airboard/Airboard/` — the Xcode project auto-discovers them (PBXFileSystemSynchronizedRootGroup). NEVER edit `project.pbxproj`.
- Project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; pure/nonisolated helpers must be marked `nonisolated` if called off-main.
- All UI uses DesignSystem v2 tokens (`DS.*`); dark-only; run `scripts/check_design_system.sh` before commit of any UI task.
- pi spawn contract (probe-verified, spec §AssistantService): stdin CLOSED, flags `--no-session --no-extensions --no-skills --no-context-files --no-builtin-tools --offline`, extension via `-e`, provider `openrouter`, default model `openai/gpt-oss-120b:low`, 60s hard timeout, neutral cwd.
- The LLM never does arithmetic (calc tool) and only reaches the network via `fetch_url` (https only, 4000-char truncation).
- Assistant model string lives in UserDefaults key `assistantModel`, default `openai/gpt-oss-120b:low`. OpenRouter key lives in Keychain via `KeychainHelper.saveAPIKey(_:forHost:)` with host `openrouter.ai`.
- Toast copy verbatim from spec: "Assistant timed out", "The assistant can't do that yet", "Assistant isn't set up yet — open Assistant settings", "Add your OpenRouter key in Assistant settings", "Assistant had a problem".
- Telemetry: signal `assistant.ask`, floatValue = duration ms, params outcome/appVersion only — never question text. PerformanceLog previews are LOCAL ONLY.
- Build gate for every task: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"` must print `** BUILD SUCCEEDED **`. SourceKit editor diagnostics are stale-index noise; xcodebuild is truth.
- Scratch tests: multi-file `swiftc` requires an `@main struct` wrapper (top-level code fails). Keep scratch tests in `/private/tmp/assistanttest/`.
- Commit messages end with the project's standard Co-Authored-By/Claude-Session trailer (see `git log`).

---

### Task 1: Tools extension + release smoke script

**Files:**
- Create: `Airboard/assistant-tools.txt` (inside the synced group → auto-copied to app Resources; `.txt` because Xcode excludes `.ts` from resource copying — verified. Airboard copies it to `assistant-tools.ts` at runtime; pi needs the real extension to transpile)
- Create: `scripts/check_assistant.sh` (executable)
- Modify: `build_release.sh` (Step 0 gate, right after the design-system check)

**Interfaces:**
- Produces: bundle resource `assistant-tools.ts` registering pi tools `calc(expr)` and `fetch_url(url)`. Task 2 locates it via `Bundle.main.url(forResource: "assistant-tools", withExtension: "ts")`.

- [ ] **Step 1: Write the extension**

Create `Airboard/assistant-tools.txt`:

```typescript
// Airboard assistant tools — loaded by pi via `-e`. The assistant's ENTIRE
// reach. Shipped as .txt (Xcode won't copy .ts to Resources); Airboard
// copies this to assistant-tools.ts at runtime before handing it to pi.
// reach: exact local arithmetic + HTTPS GET. No fs, no shell, no other tools
// (Airboard spawns pi with --no-builtin-tools).
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "calc",
    label: "Calc",
    description:
      "Evaluate an arithmetic expression exactly. ALWAYS use this for any arithmetic — never compute numbers yourself.",
    parameters: Type.Object({
      expr: Type.String({ description: "Arithmetic expression, e.g. 500*83.6" }),
    }),
    async execute(_id: string, params: { expr: string }) {
      if (!/^[0-9+\-*/(). ]+$/.test(params.expr)) throw new Error("invalid expression");
      const v = Function(`"use strict";return (${params.expr})`)();
      return { content: [{ type: "text", text: String(v) }], details: {} };
    },
  });
  pi.registerTool({
    name: "fetch_url",
    label: "Fetch URL",
    description:
      "HTTP GET a URL, return body text (truncated to 4000 chars). Use for fresh data like exchange rates.",
    parameters: Type.Object({
      url: Type.String({ description: "Full https:// URL" }),
    }),
    async execute(_id: string, params: { url: string }, signal: AbortSignal) {
      if (!params.url.startsWith("https://")) throw new Error("https only");
      const res = await fetch(params.url, { signal });
      const text = await res.text();
      return { content: [{ type: "text", text: text.slice(0, 4000) }], details: {} };
    },
  });
}
```

- [ ] **Step 2: Write the smoke script**

Create `scripts/check_assistant.sh`:

```bash
#!/bin/bash
# Release gate: prove pi + the bundled extension still work end-to-end.
# Fails the release if a pi update broke the extension API (pi has no
# stability guarantee) or if pi is missing on the publishing machine.
set -euo pipefail
cd "$(dirname "$0")/.."

PI="$(/bin/zsh -lc 'which pi' 2>/dev/null || true)"
if [[ -z "$PI" ]]; then
    echo "❌ assistant gate: pi is not installed (curl -fsSL https://pi.dev/install.sh | sh)"
    exit 1
fi

TMP_TS="$(mktemp -d)/assistant-tools.ts"
cp Airboard/assistant-tools.txt "$TMP_TS"

OUT="$("$PI" -p --no-session --no-extensions --no-skills --no-context-files \
    --no-builtin-tools --offline -e "$TMP_TS" \
    --provider openrouter --model "openai/gpt-oss-120b:low" \
    --system-prompt "Use the calc tool for arithmetic. Reply with the number only." \
    "What is 2+2?" </dev/null 2>&1 | tail -1)"

if [[ "$OUT" != *"4"* ]]; then
    echo "❌ assistant gate: expected 4, got: $OUT"
    exit 1
fi
echo "✅ assistant gate: calc round-trip OK ($OUT)"
```

Then: `chmod +x scripts/check_assistant.sh`

- [ ] **Step 3: Run the smoke script — expect PASS (pi is installed and authed on this machine)**

Run: `./scripts/check_assistant.sh`
Expected: `✅ assistant gate: calc round-trip OK (4)`

- [ ] **Step 4: Wire into the release gate**

In `build_release.sh`, find the Step 0 design-system gate invocation (`scripts/check_design_system.sh`) and add immediately after it, same style:

```bash
./scripts/check_assistant.sh
```

- [ ] **Step 5: Verify the .ts file lands in the app bundle**

Run:
```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"
ls "/Users/dhruvmehra/Library/Developer/Xcode/DerivedData/Airboard-alcdmmnppzbmcjgtmvqnekbkuqbu/Build/Products/Debug/Airboard Dev.app/Contents/Resources/assistant-tools.txt"
```
Expected: `BUILD SUCCEEDED` and the ls path printed.

- [ ] **Step 6: Commit**

```bash
git add Airboard/assistant-tools.txt scripts/check_assistant.sh build_release.sh
git commit -m "feat: assistant tools extension (calc + fetch_url) and release smoke gate"
```

---

### Task 2: AssistantPrompt (pure) + scratch tests

**Files:**
- Create: `Airboard/AssistantPrompt.swift` (Foundation-only, `nonisolated`, scratch-testable)
- Test: `/private/tmp/assistanttest/prompt_test.swift`

**Interfaces:**
- Produces (Task 3 consumes):
  - `AssistantPrompt.systemPrompt(now: Date) -> String`
  - `AssistantPrompt.parse(_ raw: String) -> AssistantReply` where `enum AssistantReply: Equatable { case answer(String); case unsupported(String); case empty }`

- [ ] **Step 1: Write the failing scratch test**

Create `/private/tmp/assistanttest/prompt_test.swift`:

```swift
import Foundation

@main struct PromptTest {
    static func main() {
        func check(_ cond: Bool, _ label: String) { print(cond ? "PASS: \(label)" : "FAIL: \(label)"); if !cond { exit(1) } }

        // Fixed instants: July (DST active in US) and January (DST off).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let july = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
        let january = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!

        let pJuly = AssistantPrompt.systemPrompt(now: july)
        let pJan = AssistantPrompt.systemPrompt(now: january)
        check(pJuly.contains("IST") && pJuly.contains("+05:30"), "IST offset present")
        check(pJuly.contains("PT") && pJuly.contains("-07:00"), "Pacific is PDT in July")
        check(pJan.contains("-08:00"), "Pacific is PST in January")
        check(pJuly.contains("ONE short line"), "one-line contract present")
        check(pJuly.contains("UNSUPPORTED"), "unsupported contract present")
        check(pJuly.contains("calc"), "calc rule present")
        check(pJuly.contains("frankfurter"), "rates source present")

        check(AssistantPrompt.parse("  42 rupees.\n") == .answer("42 rupees."), "trims")
        check(AssistantPrompt.parse("UNSUPPORTED: cannot send messages.") == .unsupported("cannot send messages."), "unsupported parsed")
        check(AssistantPrompt.parse("unsupported: no email access") == .unsupported("no email access"), "case-insensitive")
        check(AssistantPrompt.parse("line one\nline two") == .answer("line one — line two"), "newlines collapsed")
        check(AssistantPrompt.parse("   \n ") == .empty, "empty detected")
        if case .answer(let a) = AssistantPrompt.parse(String(repeating: "x", count: 500)) {
            check(a.count <= 201, "truncated to toast size")
        } else { check(false, "long answer should still be .answer") }
        print("ALL PASS")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mkdir -p /private/tmp/assistanttest && swiftc Airboard/AssistantPrompt.swift /private/tmp/assistanttest/prompt_test.swift -o /private/tmp/assistanttest/prompt_test 2>&1 | head -3`
Expected: FAIL — `Airboard/AssistantPrompt.swift` does not exist yet.

- [ ] **Step 3: Implement AssistantPrompt**

Create `Airboard/AssistantPrompt.swift`:

```swift
//
//  AssistantPrompt.swift
//
//  Pure prompt-building and output-parsing for the voice assistant.
//  Foundation-only on purpose: compiles standalone for scratch tests.
//  The offsets table is THE defense against DST hallucination — the model
//  does arithmetic on offsets macOS computed, it never recalls them.
//

import Foundation

enum AssistantReply: Equatable {
    case answer(String)
    case unsupported(String)
    case empty
}

enum AssistantPrompt {

    /// Abbreviations + major cities the prompt carries offsets for.
    static let zones: [(label: String, identifier: String)] = [
        ("IST (India)", "Asia/Kolkata"),
        ("PT/PST/PDT (US Pacific, SF/LA/Seattle)", "America/Los_Angeles"),
        ("MT (US Mountain, Denver)", "America/Denver"),
        ("CT (US Central, Chicago/Austin)", "America/Chicago"),
        ("ET/EST/EDT (US Eastern, New York/Toronto)", "America/New_York"),
        ("UTC", "UTC"),
        ("UK (London)", "Europe/London"),
        ("CET (Paris/Berlin/Madrid/Rome)", "Europe/Paris"),
        ("EET (Athens/Helsinki)", "Europe/Helsinki"),
        ("MSK (Moscow)", "Europe/Moscow"),
        ("GST (Dubai)", "Asia/Dubai"),
        ("PKT (Karachi)", "Asia/Karachi"),
        ("BDT (Dhaka)", "Asia/Dhaka"),
        ("ICT (Bangkok)", "Asia/Bangkok"),
        ("SGT (Singapore)", "Asia/Singapore"),
        ("HKT (Hong Kong)", "Asia/Hong_Kong"),
        ("CST-China (Beijing/Shanghai)", "Asia/Shanghai"),
        ("JST (Tokyo)", "Asia/Tokyo"),
        ("KST (Seoul)", "Asia/Seoul"),
        ("AEST (Sydney/Melbourne)", "Australia/Sydney"),
        ("NZT (Auckland)", "Pacific/Auckland"),
        ("BRT (São Paulo)", "America/Sao_Paulo"),
        ("ART (Buenos Aires)", "America/Argentina/Buenos_Aires"),
        ("PET (Lima)", "America/Lima"),
        ("COT (Bogotá)", "America/Bogota"),
        ("CLT (Santiago)", "America/Santiago"),
        ("EAT (Nairobi)", "Africa/Nairobi"),
        ("SAST (Johannesburg)", "Africa/Johannesburg"),
        ("WAT (Lagos)", "Africa/Lagos"),
        ("HST (Honolulu)", "Pacific/Honolulu"),
    ]

    static func offsetString(secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let s = abs(secondsFromGMT)
        return String(format: "%@%02d:%02d", sign, s / 3600, (s % 3600) / 60)
    }

    static func systemPrompt(now: Date = Date(), localZone: TimeZone = .current) -> String {
        let table = zones.compactMap { zone -> String? in
            guard let tz = TimeZone(identifier: zone.identifier) else { return nil }
            return "\(zone.label)=\(offsetString(secondsFromGMT: tz.secondsFromGMT(for: now)))"
        }.joined(separator: ", ")

        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE MMMM d yyyy, h:mm a"
        fmt.timeZone = localZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let localNow = fmt.string(from: now)
        let localOffset = offsetString(secondsFromGMT: localZone.secondsFromGMT(for: now))

        return """
        You are a voice assistant inside a macOS dictation app, answering via a small toast notification.
        Answer in ONE short line. No preamble, no markdown, numbers first.
        The user's local time is \(localNow) (UTC\(localOffset)).
        Current UTC offsets (already DST-adjusted — use these, never recall offsets yourself): \(table).
        ALWAYS use the calc tool for any arithmetic — never compute numbers yourself.
        Mark day rollover in time conversions with (-1d) or (+1d).
        Exchange rates: fetch https://api.frankfurter.app/latest?from=XXX&to=YYY (ISO codes), then calc the amount.
        For other fresh facts you may fetch_url a relevant https page; if you cannot find a reliable source, say so plainly.
        If the request needs abilities you lack (sending messages, reading email or calendars, editing files, controlling apps), reply exactly: UNSUPPORTED: <short reason>
        """
    }

    /// Normalize pi's stdout into a toast-ready reply.
    static func parse(_ raw: String) -> AssistantReply {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        if text.uppercased().hasPrefix("UNSUPPORTED:") {
            let reason = String(text.dropFirst("UNSUPPORTED:".count))
                .trimmingCharacters(in: .whitespaces)
            return .unsupported(reason)
        }
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
        return .answer(text)
    }
}
```

- [ ] **Step 4: Run the scratch test — expect ALL PASS**

Run: `swiftc Airboard/AssistantPrompt.swift /private/tmp/assistanttest/prompt_test.swift -o /private/tmp/assistanttest/prompt_test && /private/tmp/assistanttest/prompt_test`
Expected: every line `PASS: …` then `ALL PASS`.

- [ ] **Step 5: Build gate, then commit**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add Airboard/AssistantPrompt.swift
git commit -m "feat: assistant system prompt builder and reply parser (pure, scratch-tested)"
```

---

### Task 3: AssistantService (pi spawn)

**Files:**
- Create: `Airboard/AssistantService.swift`

**Interfaces:**
- Consumes: `AssistantPrompt.systemPrompt(now:)`, `AssistantPrompt.parse(_:)`, `AssistantReply` (Task 2); `KeychainHelper.readAPIKey(forHost:)` (existing); bundle resource `assistant-tools.txt` (Task 1 — staged to `assistant-tools.ts` in the workdir before spawn).
- Produces (Task 4 consumes):
  - `enum AssistantOutcome { case answer(String); case unsupported(String); case needsPi; case needsKey; case timeout; case failure }`
  - `AssistantService.shared.ask(_ question: String) async -> (outcome: AssistantOutcome, durationMs: Int)`
  - `AssistantService.shared.isPiInstalled() -> Bool` and `AssistantService.shared.hasKey() -> Bool` (Task 5 uses for status rows)
  - `AssistantService.openRouterHost = "openrouter.ai"`, UserDefaults key `assistantModel`
  - `AssistantService.shared.invalidatePiPathCache()` (Task 5 calls after install)

- [ ] **Step 1: Verify the env var pi reads for OpenRouter (spec open item)**

```bash
mv ~/.pi/agent/auth.json ~/.pi/agent/auth.json.bak
KEY=$(python3 -c "import json;print(json.load(open('$HOME/.pi/agent/auth.json.bak'))['openrouter'])" 2>/dev/null || true)
# If KEY printed a dict/object instead of a bare key, open auth.json.bak and copy the raw key string manually.
OPENROUTER_API_KEY="$KEY" pi -p --no-session --no-extensions --no-skills --no-context-files --no-tools --offline --provider openrouter --model "openai/gpt-oss-120b:low" "Say OK" </dev/null
mv ~/.pi/agent/auth.json.bak ~/.pi/agent/auth.json
```
Expected: a reply containing "OK" — proves `OPENROUTER_API_KEY` env works with auth.json absent. **Restore auth.json regardless of outcome.** If the env var is ignored (auth error), the code below already contains the fallback: pass `--api-key <key>` in the argument list — enable it and note the deviation in your report.

- [ ] **Step 2: Implement AssistantService**

Create `Airboard/AssistantService.swift`:

```swift
//
//  AssistantService.swift
//
//  Spawns the pi coding agent headlessly to answer one voice question.
//  Probe-verified contract (2026-07-28): stdin MUST be closed or pi hangs
//  forever; hermetic flags keep the user's personal pi setup out; the
//  extension provides the ONLY tools (calc, fetch_url).
//

import Foundation
import AppKit

enum AssistantOutcome {
    case answer(String)
    case unsupported(String)
    case needsPi
    case needsKey
    case timeout
    case failure
}

final class AssistantService {
    static let shared = AssistantService()
    static let openRouterHost = "openrouter.ai"
    static let modelDefaultsKey = "assistantModel"
    static let defaultModel = "openai/gpt-oss-120b:low"
    private static let timeoutSeconds: TimeInterval = 60

    private var cachedPiPath: String?

    private init() {}

    // MARK: - Status (settings UI + preflight)

    /// Resolve pi via a login shell — GUI apps don't inherit shell PATH.
    private func piPath() -> String? {
        if let cached = cachedPiPath { return cached }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "which pi"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else { return nil }
        cachedPiPath = out
        return out
    }

    func invalidatePiPathCache() { cachedPiPath = nil }
    func isPiInstalled() -> Bool { piPath() != nil }
    func hasKey() -> Bool { KeychainHelper.hasAPIKey(forHost: Self.openRouterHost) }

    private var model: String {
        let m = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? ""
        return m.isEmpty ? Self.defaultModel : m
    }

    /// Neutral working directory — never the user's cwd.
    private func workDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard")
            .appendingPathComponent("assistant")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Ask

    func ask(_ question: String) async -> (outcome: AssistantOutcome, durationMs: Int) {
        let started = Date()
        func done(_ o: AssistantOutcome) -> (AssistantOutcome, Int) {
            (o, Int(Date().timeIntervalSince(started) * 1000))
        }

        guard let pi = piPath() else { return done(.needsPi) }
        guard let key = KeychainHelper.readAPIKey(forHost: Self.openRouterHost), !key.isEmpty else {
            return done(.needsKey)
        }
        // Bundled as .txt (Xcode won't copy .ts to Resources); pi needs the
        // real extension to transpile, so stage a .ts copy in our workdir.
        guard let extSrc = Bundle.main.url(forResource: "assistant-tools", withExtension: "txt") else {
            print("❌ Assistant: bundled extension missing")
            return done(.failure)
        }
        let extTS = workDir().appendingPathComponent("assistant-tools.ts")
        do {
            try? FileManager.default.removeItem(at: extTS)
            try FileManager.default.copyItem(at: extSrc, to: extTS)
        } catch {
            print("❌ Assistant: failed to stage extension: \(error)")
            return done(.failure)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pi)
        proc.currentDirectoryURL = workDir()
        proc.arguments = [
            "-p", "--no-session", "--no-extensions", "--no-skills",
            "--no-context-files", "--no-builtin-tools", "--offline",
            "-e", extTS.path,
            "--provider", "openrouter",
            "--model", model,
            // If Step 1 proved the env var insufficient, add: "--api-key", key,
            "--system-prompt", AssistantPrompt.systemPrompt(),
            question,
        ]
        var env = ProcessInfo.processInfo.environment
        env["OPENROUTER_API_KEY"] = key
        proc.environment = env

        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()          // keep pi's stderr out of our log noise
        proc.standardInput = FileHandle.nullDevice  // CRITICAL: open stdin = infinite hang

        do { try proc.run() } catch {
            print("❌ Assistant: failed to spawn pi: \(error)")
            return done(.failure)
        }

        let timedOut = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var finished = false
            proc.terminationHandler = { _ in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                proc.terminate()
                cont.resume(returning: true)
            }
        }
        if timedOut { return done(.timeout) }

        let raw = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            print("❌ Assistant: pi exited \(proc.terminationStatus): \(raw.prefix(300))")
            return done(.failure)
        }
        switch AssistantPrompt.parse(raw) {
        case .answer(let text): return done(.answer(text))
        case .unsupported(let reason): return done(.unsupported(reason))
        case .empty: return done(.failure)
        }
    }
}
```

- [ ] **Step 3: Build gate**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Airboard/AssistantService.swift
git commit -m "feat: AssistantService — hermetic headless pi spawn with 60s timeout"
```

---

### Task 4: Coordinator wiring, thinking state, long-dwell toast, metrics

**Files:**
- Modify: `Airboard/TranscriptionCoordinator.swift:525-546` (the memory-classify fallthrough + Unknown Command block inside `handleCommandMode`)
- Modify: `Airboard/FloatingWindowManager.swift:594-598` (`showToast` gains a duration parameter)
- Modify: `Airboard/TelemetryService.swift` (new `assistantAsked` signal)

**Interfaces:**
- Consumes: `AssistantService.shared.ask(_:)` → `(outcome: AssistantOutcome, durationMs: Int)` (Task 3); `PerformanceLog.shared.append(_:)` + `DictationRecord` (existing); `TelemetryService.send` pattern (existing private `send(_:floatValue:params:)`).
- Produces: toast copy exact per Global Constraints; `showToast(_:duration:)` used by Task 5 too.

- [ ] **Step 1: Toast duration parameter**

In `Airboard/FloatingWindowManager.swift`, change `showToast` and thread the duration into `presentToast`'s auto-dismiss (currently a fixed 2s `asyncAfter` before the fade-out; keep the fade animation unchanged):

```swift
func showToast(_ text: String, duration: TimeInterval = 2.0) {
    DispatchQueue.main.async { [weak self] in
        self?.presentToast(text, duration: duration)
    }
}

private func presentToast(_ text: String, duration: TimeInterval) {
    // ...existing body unchanged, except the dismiss delay:
    // DispatchQueue.main.asyncAfter(deadline: .now() + duration) { ... existing fade ... }
}
```

(Adjust the one `asyncAfter(deadline: .now() + 2.0)` inside `presentToast` to use `duration`. All existing call sites keep the 2s default.)

- [ ] **Step 2: Telemetry signal**

In `Airboard/TelemetryService.swift`, add alongside `dictationCompleted(record:)`, following its exact style (same gates, same appVersion param source):

```swift
func assistantAsked(durationMs: Int, outcome: String) {
    send("assistant.ask",
         floatValue: Double(durationMs),
         params: ["outcome": outcome, "appVersion": appVersion])
}
```

(If `appVersion` is a local inside `dictationCompleted` rather than a property, replicate how it's computed there.)

- [ ] **Step 3: Replace the Unknown Command dead end**

In `Airboard/TranscriptionCoordinator.swift`, replace the block from `print("❓ Could not parse command: \(text)")` through the end of the `UNUserNotificationCenter.current().add(request)` closure (lines ~533-545) with:

```swift
        // Nothing claimed the utterance — hand it to the assistant.
        print("🤖 Assistant ask: \(text)")
        await MainActor.run {
            FloatingWindowManager.shared.showFloatingIndicator(
                isRecording: false, isTranscribing: true, isCommandMode: true)
        }
        let (outcome, durationMs) = await AssistantService.shared.ask(text)
        await MainActor.run {
            FloatingWindowManager.shared.showFloatingIndicator(
                isRecording: false, isTranscribing: false, isCommandMode: false)
            switch outcome {
            case .answer(let answer):
                FloatingWindowManager.shared.showCommandExecuted()
                FloatingWindowManager.shared.showToast(answer, duration: 8.0)
            case .unsupported:
                FloatingWindowManager.shared.showToast("The assistant can't do that yet", duration: 4.0)
            case .needsPi:
                FloatingWindowManager.shared.showToast("Assistant isn't set up yet — open Assistant settings", duration: 5.0)
            case .needsKey:
                FloatingWindowManager.shared.showToast("Add your OpenRouter key in Assistant settings", duration: 5.0)
            case .timeout:
                FloatingWindowManager.shared.showToast("Assistant timed out", duration: 4.0)
            case .failure:
                FloatingWindowManager.shared.showToast("Assistant had a problem", duration: 4.0)
            }
        }
        recordAssistantMetrics(question: text, outcome: outcome, durationMs: durationMs)
```

Then add this private method to `TranscriptionCoordinator` (near `recordDictationMetrics`, mirroring how it builds a `DictationRecord` from `transcriptionService.lastSttMs` / `lastAudioSeconds`):

```swift
    private func recordAssistantMetrics(question: String, outcome: AssistantOutcome, durationMs: Int) {
        let outcomeString: String
        switch outcome {
        case .answer: outcomeString = "ok"
        case .unsupported: outcomeString = "unsupported"
        case .needsPi, .needsKey: outcomeString = "setup_missing"
        case .timeout: outcomeString = "timeout"
        case .failure: outcomeString = "error"
        }
        let record = DictationRecord(
            ts: Date(),
            mode: "assistant",
            audioSeconds: transcriptionService.lastAudioSeconds,
            sttMs: transcriptionService.lastSttMs,
            llmMs: durationMs,
            llmOutcome: outcomeString,
            words: question.split(separator: " ").count,
            preview: String(question.prefix(40))
        )
        PerformanceLog.shared.append(record)
        TelemetryService.shared.assistantAsked(durationMs: durationMs, outcome: outcomeString)
    }
```

(Match `DictationRecord`'s actual memberwise initializer — check how `recordDictationMetrics` constructs it and mirror exactly; do not change the record's schema.)

Also remove the now-unused `import UserNotifications`-dependent pieces ONLY if nothing else in the file uses UN* (search first — permission flows elsewhere may use it; if used elsewhere, leave the import).

- [ ] **Step 4: Build gate**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Live smoke via dev app (controller/user will field-verify; implementer verifies logs only)**

```bash
cp ~/Library/Logs/Airboard.log /private/tmp/assistanttest/pre-launch.log 2>/dev/null || true
osascript -e 'tell application id "com.pype.airboard.dev" to quit' 2>/dev/null; sleep 2
open "/Users/dhruvmehra/Library/Developer/Xcode/DerivedData/Airboard-alcdmmnppzbmcjgtmvqnekbkuqbu/Build/Products/Debug/Airboard Dev.app"
```
Note in your report that the dev app was relaunched with assistant wiring; interactive dictation testing is the user's field pass.

- [ ] **Step 6: Commit**

```bash
git add Airboard/TranscriptionCoordinator.swift Airboard/FloatingWindowManager.swift Airboard/TelemetryService.swift
git commit -m "feat: route unmatched command-mode speech to the assistant with toast answers"
```

---

### Task 5: Assistant settings window (setup flow)

**Files:**
- Create: `Airboard/AssistantSettingsView.swift`
- Modify: `Airboard/FloatingWindowManager.swift` (add `showAssistantSettingsWindow()`, mirroring `showCleanupSettingsWindow()` at line ~452)
- Modify: `Airboard/AirboardPopover.swift` (add an "Assistant" row next to the existing Memory row — grep for how the Memory row triggers `showMemorySettingsWindow` and mirror it)

**Interfaces:**
- Consumes: `AssistantService.shared.isPiInstalled()`, `.hasKey()`, `.invalidatePiPathCache()`, `AssistantService.openRouterHost`, `AssistantService.modelDefaultsKey`, `AssistantService.defaultModel` (Task 3); `KeychainHelper.saveAPIKey(_:forHost:)`, `.readAPIKey(forHost:)`, `.deleteAPIKey(forHost:)` (existing); DS tokens.
- Produces: the window the failure toasts refer to ("open Assistant settings").

- [ ] **Step 1: Create AssistantSettingsView**

Create `Airboard/AssistantSettingsView.swift`:

```swift
//
//  AssistantSettingsView.swift
//
//  Setup + settings for the voice assistant: install the pi engine
//  (one click, official installer), OpenRouter API key, model override.
//

import SwiftUI

struct AssistantSettingsView: View {
    @State private var piInstalled = AssistantService.shared.isPiInstalled()
    @State private var apiKey: String = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost) ?? ""
    @State private var model: String = UserDefaults.standard.string(forKey: AssistantService.modelDefaultsKey) ?? AssistantService.defaultModel
    @State private var installing = false
    @State private var installFailed = false
    @State private var keySaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assistant")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Label.primary)

            Text("Ask anything in command mode (hold hotkey + ⌘) — time zones, currencies, quick facts. Questions go to OpenRouter; the assistant can fetch web pages but can never touch your files.")
                .font(.system(size: 11))
                .foregroundColor(DS.Label.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Step 1: engine
            HStack(spacing: 8) {
                Image(systemName: piInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(piInstalled ? DS.Accent.success : DS.Label.tertiary)
                Text(piInstalled ? "Assistant engine installed" : "Assistant engine (pi) not installed")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Label.primary)
                Spacer()
                if !piInstalled {
                    Button(installing ? "Installing…" : (installFailed ? "Retry install" : "Install")) {
                        runInstaller()
                    }
                    .disabled(installing)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Fill.quaternary))

            // Step 2: key
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Label.primary)
                HStack(spacing: 8) {
                    SecureField("sk-or-…", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(DS.Typo.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8).stroke(DS.Border.control, lineWidth: 1))
                    Button(keySaved ? "Saved ✓" : "Save") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            KeychainHelper.deleteAPIKey(forHost: AssistantService.openRouterHost)
                        } else {
                            KeychainHelper.saveAPIKey(trimmed, forHost: AssistantService.openRouterHost)
                        }
                        keySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
                    }
                }
                Text("Get one at openrouter.ai/keys. Used only for assistant questions.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.tertiary)
            }

            // Model override
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Label.primary)
                TextField(AssistantService.defaultModel, text: $model)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.mono(11))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8).stroke(DS.Border.control, lineWidth: 1))
                    .onSubmit {
                        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: AssistantService.modelDefaultsKey)
                    }
                Text("Any OpenRouter model id, optionally with :off/:minimal/:low/:medium/:high thinking suffix. Harder questions are fine on slower thinking models.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 380, height: 360)
        .background(DS.Surface.panel)
    }

    private func runInstaller() {
        installing = true
        installFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "curl -fsSL https://pi.dev/install.sh | sh"]
            proc.standardInput = FileHandle.nullDevice
            let ok = (try? proc.run()) != nil
            if ok { proc.waitUntilExit() }
            DispatchQueue.main.async {
                AssistantService.shared.invalidatePiPathCache()
                piInstalled = AssistantService.shared.isPiInstalled()
                installFailed = !piInstalled
                installing = false
            }
        }
    }
}
```

- [ ] **Step 2: Window host in FloatingWindowManager**

Add `showAssistantSettingsWindow()` next to `showCleanupSettingsWindow()` (~line 452), copying that method's exact NSWindow/NSHostingView pattern (title "Assistant", content `AssistantSettingsView()`, same size handling, same teardown registration in `cleanup()`).

- [ ] **Step 3: Popover entry**

In `Airboard/AirboardPopover.swift`, find the Memory settings row (grep `showMemorySettingsWindow`) and add an "Assistant" row directly below it, same visual style/icon treatment (SF Symbol `sparkles`), calling `FloatingWindowManager.shared.showAssistantSettingsWindow()`.

- [ ] **Step 4: Design-system + build gates**

```bash
./scripts/check_design_system.sh
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Airboard/AssistantSettingsView.swift Airboard/FloatingWindowManager.swift Airboard/AirboardPopover.swift
git commit -m "feat: assistant settings window — one-click pi install, OpenRouter key, model override"
```

---

### Task 6: Docs + changelog

**Files:**
- Modify: `README.md` (new Assistant section after "Set up your Memory"; one bullet in Privacy)
- Modify: `CHANGELOG.md` (`## [Unreleased]`)
- Modify: `CLAUDE.md` (source-organization table: add the three new files on the Commands/Assistant row)

**Interfaces:** none — copy below is final.

- [ ] **Step 1: README Assistant section**

Insert after the "Set up your Memory" section:

```markdown
## Ask the Assistant

Hold hotkey + ⌘ and just ask — anything that isn't a known command goes to
the assistant:

> "What time is 11 AM IST in PDT and EST?"
> "Convert 500 dollars to rupees"
> "What's the latest FluidAudio release?"

The answer appears as a toast. Setup (once, in popover → **Assistant**):
click **Install** (fetches the [pi](https://pi.dev) engine) and paste an
[OpenRouter](https://openrouter.ai/keys) API key. The assistant can do
exact math and fetch web pages — it cannot touch your files, run commands,
or control apps, and says so honestly when asked to.
```

- [ ] **Step 2: README Privacy bullet**

Add to the Privacy list:

```markdown
- Assistant questions (hold hotkey + ⌘, unmatched speech only) are sent as
  text to OpenRouter under your own API key, and the assistant may fetch
  public web pages to answer. Nothing is sent unless you ask it something;
  saved memories are never included.
```

- [ ] **Step 3: CHANGELOG bullet under [Unreleased]**

```markdown
- Ask the Assistant: hold hotkey + ⌘ and ask anything — time zones,
  currency, quick facts. Answers by toast in seconds; one-click setup in
  the popover (pi engine + OpenRouter key). The assistant can fetch web
  pages and do exact math, and can never touch your files.
```

- [ ] **Step 4: CLAUDE.md source table**

In the Source Organization table, extend the Commands row (or add an Assistant row):

```markdown
| Assistant | `AssistantService.swift` (headless pi spawn), `AssistantPrompt.swift` (pure prompt/parse), `AssistantSettingsView.swift`, `assistant-tools.txt` (pi extension: calc + fetch_url — the assistant's only tools; ships as .txt, staged as .ts at runtime) |
```

- [ ] **Step 5: Build gate + commit**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | grep -E "error:|BUILD"
git add README.md CHANGELOG.md CLAUDE.md
git commit -m "docs: assistant usage, setup, and privacy disclosure"
```

---

## Field test checklist (user, after all tasks)

1. Timezone ask → correct toast with rollover markers, ~3–8s.
2. Currency ask → live rate, exact arithmetic.
3. Factual ask ("latest FluidAudio release") → sourced answer or honest miss.
4. Misfire ("send this to Ashish") → "can't do that yet" toast.
5. Rename pi temporarily (`sudo mv $(which pi){,.bak}`) → setup toast; settings window Install button visible; restore.
6. Delete OpenRouter key in settings → key toast; re-add → works.
7. Performance window shows `assistant` rows; TelemetryDeck shows `assistant.ask` (prod only later).
8. Existing commands unaffected: "open safari", "delete last word", "remember X" all still instant.
