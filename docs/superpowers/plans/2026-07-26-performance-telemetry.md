# Performance Telemetry + Local Dictation Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anonymous team performance signals to TelemetryDeck (prod builds only, toggleable) plus a local per-dictation timing log surfaced in the Performance window.

**Architecture:** `TranscriptPostProcessor` starts returning a `ProcessOutcome` (text + llmMs + outcome enum) instead of a bare String; `ParakeetTranscriptionService` exposes its last STT ms + audio seconds; the coordinator funnels every completed dictation through one `recordDictationMetrics` helper that feeds `PerformanceLog` (local jsonl, all builds) and `TelemetryService` (TelemetryDeck SDK, prod bundle + toggle only). `PerformanceView` shows the recent entries and the share toggle.

**Tech Stack:** TelemetryDeck SwiftSDK 2.x via SPM (github.com/TelemetryDeck/SwiftSDK, product `TelemetryDeck`), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-07-26-performance-telemetry-design.md` (verified SDK facts embedded there — floatValue-only charting drives the signal schema).

## Global Constraints

- Telemetry NEVER delays, blocks, or fails a dictation: `TelemetryDeck.signal()` already enqueues off-thread; our calls happen after insertion-side work, and every TelemetryService entry point is a cheap guard-then-enqueue.
- Sending is gated on ALL of: bundle id == `com.pype.airboard`, toggle on (`shareAnalytics`, default true), App ID present in Info.plist (key `TelemetryDeckAppID`, non-empty, not `UNSET`). Dev builds therefore never send — and the code ships before Dhruv creates the TelemetryDeck account.
- Signals (one chartable number each, per the verified floatValue constraint): `app.launched` (params appVersion, modelVersion), `dictation.stt` (floatValue sttMs; params mode, llmOutcome, appVersion), `dictation.llm` (floatValue llmMs; params llmOutcome, appVersion; only when the LLM ran).
- `llmOutcome` fixed strings: `ok | timeout | error | guarded | skipped | off` — never free text, never error bodies.
- Local log (`performance.jsonl`, App Support, ALL builds): `{ts, mode, audioSeconds, sttMs, llmMs, llmOutcome, words, preview}` — preview = first 40 chars, LOCAL ONLY, never sent. Rotation: keep newest 1000 lines.
- New pure-logic file (`PerformanceLog.swift`) is Foundation-only (scratch-testable via swiftc).
- Build gate every task: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`. Ignore SourceKit diagnostics (stale noise). DS tokens only in UI; `./scripts/check_design_system.sh` on UI tasks.
- Sources at `Airboard/<File>.swift`. The pbxproj DOES get edited in Task 3 (SPM package reference) — the one sanctioned exception; mirror the existing Sparkle entries exactly.

---

### Task 1: PerformanceLog (local jsonl)

**Files:**
- Create: `Airboard/PerformanceLog.swift`
- Test: scratch `/private/tmp/perftest/perflog_test.swift` (not committed)

**Interfaces:**
- Produces: `struct DictationRecord: Codable` (`ts: Date, mode: String, audioSeconds: Double, sttMs: Int, llmMs: Int?, llmOutcome: String, words: Int, preview: String`); `final class PerformanceLog` — `static let shared`, `init(fileURL: URL? = nil)`, `func append(_ record: DictationRecord)`, `func recent(_ count: Int) -> [DictationRecord]` (newest first).

- [ ] **Step 1: Write PerformanceLog.swift**

```swift
//
//  PerformanceLog.swift
//
//  Local, persistent per-dictation timing log (JSON Lines). Powers the
//  Performance window's "Recent dictations" list. LOCAL ONLY — the
//  preview text never leaves this Mac; telemetry sends numbers only.
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

struct DictationRecord: Codable {
    var ts: Date
    var mode: String          // dictation | command | handsfree
    var audioSeconds: Double
    var sttMs: Int
    var llmMs: Int?           // nil when the LLM didn't run
    var llmOutcome: String    // ok | timeout | error | guarded | skipped | off
    var words: Int
    var preview: String       // first 40 chars of the final text
}

final class PerformanceLog {
    static let shared = PerformanceLog()

    private let fileURL: URL
    private let maxLines = 1000
    private let queue = DispatchQueue(label: "com.pype.airboard.perflog")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("performance.jsonl")
        }
    }

    /// Append one record. Never blocks the caller; never throws — a
    /// failed write is a silently dropped stat, not a problem.
    func append(_ record: DictationRecord) {
        queue.async { [fileURL, maxLines] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8) else { return }

            var lines = (try? String(contentsOf: fileURL, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Newest-first. Malformed lines are skipped, never fatal.
    func recent(_ count: Int) -> [DictationRecord] {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n")
                .reversed()
                .prefix(count * 2)  // headroom for malformed lines
                .compactMap { line in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(DictationRecord.self, from: data)
                }
                .prefix(count)
                .map { $0 }
        }
    }
}
```

- [ ] **Step 2: Scratch test**

Write `/private/tmp/perftest/perflog_test.swift`:

```swift
import Foundation

@main struct PerfLogTest {
    static func main() {
        func check(_ cond: Bool, _ label: String) {
            print(cond ? "PASS: \(label)" : "FAIL: \(label)"); if !cond { exit(1) }
        }
        let dir = URL(fileURLWithPath: "/private/tmp/perftest/work", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("performance.jsonl")

        let log = PerformanceLog(fileURL: url)
        for i in 0..<5 {
            log.append(DictationRecord(ts: Date(), mode: "dictation", audioSeconds: 2.5,
                sttMs: 100 + i, llmMs: i % 2 == 0 ? 500 : nil,
                llmOutcome: i % 2 == 0 ? "ok" : "off", words: 10, preview: "hello \(i)"))
        }
        Thread.sleep(forTimeInterval: 0.5)  // async appends settle
        let recent = log.recent(3)
        check(recent.count == 3, "recent returns requested count")
        check(recent[0].sttMs == 104 && recent[2].sttMs == 102, "newest first")
        check(recent[1].llmMs == nil && recent[1].llmOutcome == "off", "nil llmMs round-trips")

        // malformed line tolerated
        let raw = try! String(contentsOf: url, encoding: .utf8) + "not json{{{\n"
        try! raw.write(to: url, atomically: true, encoding: .utf8)
        check(PerformanceLog(fileURL: url).recent(5).count == 5, "malformed line skipped")

        // rotation
        let log2 = PerformanceLog(fileURL: url)
        for i in 0..<1100 {
            log2.append(DictationRecord(ts: Date(), mode: "d", audioSeconds: 1,
                sttMs: i, llmMs: nil, llmOutcome: "off", words: 1, preview: ""))
        }
        Thread.sleep(forTimeInterval: 2.0)
        let lineCount = try! String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").count
        check(lineCount <= 1000, "rotation caps the file (got \(lineCount))")
        check(PerformanceLog(fileURL: url).recent(1)[0].sttMs == 1099, "newest survives rotation")
        print("ALL PASS")
    }
}
```

- [ ] **Step 3: Run test + build + commit**

Run: `mkdir -p /private/tmp/perftest && cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && swiftc Airboard/PerformanceLog.swift /private/tmp/perftest/perflog_test.swift -o /private/tmp/perftest/perflog_test && /private/tmp/perftest/perflog_test` → `ALL PASS`.
Run the Debug build gate → `** BUILD SUCCEEDED **`.

```bash
git add Airboard/PerformanceLog.swift
git commit -m "feat: PerformanceLog — persistent local per-dictation timing log with rotation"
```

---

### Task 2: Metrics plumbing (outcome enum through the pipeline)

**Files:**
- Modify: `Airboard/TranscriptPostProcessor.swift` (process returns `ProcessOutcome`)
- Modify: `Airboard/ParakeetTranscriptionService.swift` (expose `lastSttMs`, `lastAudioSeconds`)
- Modify: `Airboard/TranscriptionCoordinator.swift` (two `TranscriptPostProcessor.process` call sites at ~:325 and ~:413; add `recordDictationMetrics`)

**Interfaces:**
- Produces: `struct ProcessOutcome { let text: String; let llmMs: Int?; let llmOutcome: String }`; `ParakeetTranscriptionService.lastSttMs: Int`, `.lastAudioSeconds: Double`; `TranscriptionCoordinator.recordDictationMetrics(mode: String, finalText: String)` (private — reads the exposed values and calls PerformanceLog + TelemetryService).

- [ ] **Step 1: ProcessOutcome in TranscriptPostProcessor**

Change the signature and every return so the outcome is explicit (current file: guard-return at :41-46, success at :54, catch at :55-58):

```swift
struct ProcessOutcome {
    let text: String
    let llmMs: Int?           // nil when the LLM didn't run
    let llmOutcome: String    // ok | timeout | error | guarded | skipped | off
}
```

```swift
    static func process(_ text: String, context: AppContext?, mode: ProcessingMode) async -> ProcessOutcome {
        let ruled = FillerRules.clean(text)

        guard mode == .dictation else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "off")
        }
        guard aiCleanupEnabled, TranscriptRefiner.shared.isConfigured else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "off")
        }
        guard ruled.split(separator: " ").count >= llmMinimumWords else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "skipped")
        }

        do {
            let startTime = Date()
            let refined = try await withTimeout(seconds: llmTimeoutSeconds) {
                try await TranscriptRefiner.shared.refine(ruled)
            }
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            print("⏱️ LLM cleanup: \(ms)ms")
            return ProcessOutcome(text: refined, llmMs: ms, llmOutcome: "ok")
        } catch {
            let outcome: String
            switch error {
            case TranscriptRefiner.RefineError.degenerateOutput:
                outcome = "guarded"
            case TranscriptRefiner.RefineError.timeout, is TimeoutError:
                outcome = "timeout"
            default:
                outcome = "error"
            }
            print("⚠️ Cleanup LLM skipped (\(error.localizedDescription)); inserting rules-cleaned text (\(outcome))")
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: outcome)
        }
    }
```

IMPORTANT: read the current file first — the timeout mechanism (`withTimeout`) throws a specific error type; match it exactly in the `timeout` case (if it throws `RefineError.timeout` or a private `TimeoutError`, use what exists; add `is TimeoutError` only if that type exists). Preserve the existing hands-free `.handsFreeChunk` behavior: it currently gets rules-only — the first guard covers it (mode != .dictation → "off").

- [ ] **Step 2: Expose STT timing from ParakeetTranscriptionService**

Add published-free stored properties (plain vars — read after `transcribe` returns, same task context):

```swift
    /// Timing of the most recent transcribe() — read by the coordinator's
    /// metrics recording after the call returns.
    private(set) var lastSttMs: Int = 0
    private(set) var lastAudioSeconds: Double = 0
```

In `transcribe(audioURL:)`, set them where the duration is computed (after the `result` is obtained): `lastSttMs = Int(duration)` (the existing `duration` is already ms) and `lastAudioSeconds = result.duration` (ASRResult's audio duration; verify the property name in FluidAudio's ASRResult — it exists as `duration`).

- [ ] **Step 3: Coordinator — thread the outcome + record metrics**

At both call sites, `TranscriptPostProcessor.process` now returns `ProcessOutcome`; use `.text` where the String was used. Then add to the coordinator:

```swift
    /// One funnel for every completed dictation: local log always,
    /// telemetry when its gates allow.
    private func recordDictationMetrics(mode: String, outcome: ProcessOutcome) {
        let record = DictationRecord(
            ts: Date(),
            mode: mode,
            audioSeconds: transcriptionService.lastAudioSeconds,
            sttMs: transcriptionService.lastSttMs,
            llmMs: outcome.llmMs,
            llmOutcome: outcome.llmOutcome,
            words: outcome.text.split(separator: " ").count,
            preview: String(outcome.text.prefix(40)))
        PerformanceLog.shared.append(record)
        TelemetryService.shared.dictationCompleted(record: record)
    }
```

Call it in `processTranscription` right after the `process(...)` call (mode string: `mode == .command ? "command" : "dictation"`), and in `handleChunkCompletion` after its `process(...)` call with `"handsfree"`. NOTE: `TelemetryService` doesn't exist until Task 3 — for THIS task's green build, create a minimal placeholder in this commit:

```swift
// Airboard/TelemetryService.swift — filled in by the next task
import Foundation

final class TelemetryService {
    static let shared = TelemetryService()
    func dictationCompleted(record: DictationRecord) {}
    func appLaunched() {}
}
```

- [ ] **Step 4: Build + commit**

Debug build gate → `** BUILD SUCCEEDED **`. Then dictate once in the dev build and confirm `performance.jsonl` gains a line (manual smoke, or note for the user pass).

```bash
git add Airboard/TranscriptPostProcessor.swift Airboard/ParakeetTranscriptionService.swift Airboard/TranscriptionCoordinator.swift Airboard/TelemetryService.swift
git commit -m "feat: dictation metrics funnel — outcome enum through the pipeline into the local log"
```

---

### Task 3: TelemetryDeck SDK + TelemetryService

**Files:**
- Modify: `Airboard.xcodeproj/project.pbxproj` (add SPM package — mirror the Sparkle entries)
- Modify: `Airboard/TelemetryService.swift` (replace the placeholder)
- Modify: `Airboard/AirboardApp.swift` (init + launch signal)
- Modify: `Airboard/Info.plist` if a source Info.plist exists (else the Info.plist keys live in build settings — check how `SUPublicEDKey` was added and use the same mechanism) — add `TelemetryDeckAppID` = `UNSET`.

**Interfaces:**
- Consumes: `DictationRecord` (Task 1), placeholder API (Task 2).
- Produces: working `TelemetryService.shared.appLaunched()` / `.dictationCompleted(record:)`; UserDefaults key `shareAnalytics` (Bool, default true — read via `object(forKey:) as? Bool ?? true`).

- [ ] **Step 1: Add the SPM dependency**

In `project.pbxproj`, add a `XCRemoteSwiftPackageReference` for `https://github.com/TelemetryDeck/SwiftSDK` with `kind = upToNextMajorVersion; minimumVersion = 2.0.0;` and a `XCSwiftPackageProductDependency` for product `TelemetryDeck`, attached to the app target's `packageProductDependencies` — copy the structural pattern of the existing Sparkle entries in the same file (same sections, new UUIDs). Then verify resolution:

Run: `xcodebuild -project Airboard.xcodeproj -resolvePackageDependencies 2>&1 | tail -5`
Expected: resolution succeeds and `Package.resolved` gains TelemetryDeck pinned 2.x.

- [ ] **Step 2: Real TelemetryService**

```swift
//
//  TelemetryService.swift
//
//  Anonymous performance telemetry via TelemetryDeck. HARD GATES — all
//  must hold or every call is a no-op:
//    1. production bundle (com.pype.airboard) — dev builds never send
//    2. "Share anonymous performance stats" toggle on (default true)
//    3. a real App ID in Info.plist (TelemetryDeckAppID != UNSET/empty)
//  Never any transcript text: signals carry numbers and fixed enum
//  strings only. signal() enqueues to the SDK's disk-backed batch queue
//  off-thread — telemetry cannot delay a dictation by construction.
//

import Foundation
import TelemetryDeck

final class TelemetryService {
    static let shared = TelemetryService()

    static let shareKey = "shareAnalytics"

    var sharingEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.shareKey) as? Bool ?? true
    }
    func setSharingEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.shareKey)
    }

    private let active: Bool
    private let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    private init() {
        let isProd = Bundle.main.bundleIdentifier == "com.pype.airboard"
        let appID = Bundle.main.infoDictionary?["TelemetryDeckAppID"] as? String ?? ""
        let configured = !appID.isEmpty && appID != "UNSET"
        active = isProd && configured
        guard active else { return }
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    private func send(_ name: String, parameters: [String: String] = [:], floatValue: Double? = nil) {
        guard active, sharingEnabled else { return }
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }

    func appLaunched() {
        send("app.launched", parameters: [
            "appVersion": appVersion,
            "modelVersion": "parakeet-tdt-0.6b-v3",
        ])
    }

    func dictationCompleted(record: DictationRecord) {
        send("dictation.stt",
             parameters: ["mode": record.mode,
                          "llmOutcome": record.llmOutcome,
                          "appVersion": appVersion],
             floatValue: Double(record.sttMs))
        if let llmMs = record.llmMs {
            send("dictation.llm",
                 parameters: ["llmOutcome": record.llmOutcome,
                              "appVersion": appVersion],
                 floatValue: Double(llmMs))
        }
    }
}
```

- [ ] **Step 3: App init + launch signal + Info.plist key**

In `AirboardApp.applicationDidFinishLaunching`, after the sibling-instance guard block: `TelemetryService.shared.appLaunched()` (the singleton's init runs the SDK initialize; calling it here is early enough). Add the `TelemetryDeckAppID` Info.plist entry with value `UNSET` via the same mechanism the project used for `SUPublicEDKey` (check: `grep -rn "SUPublicEDKey" Airboard.xcodeproj/project.pbxproj Airboard/Info.plist` and mirror it).

- [ ] **Step 4: Build + verify inert-by-default + commit**

Debug build gate → `** BUILD SUCCEEDED **`. Verify the dev build sends nothing: launch the dev app, confirm no TelemetryDeck network activity is possible (bundle gate short-circuits before SDK init — assert via the code path, and note that `active == false` means `TelemetryDeck.initialize` is never called in dev).

```bash
git add Airboard.xcodeproj/project.pbxproj Airboard/TelemetryService.swift Airboard/AirboardApp.swift Airboard.xcodeproj/project.xcworkspace 2>/dev/null || true
git add -A
git commit -m "feat: TelemetryDeck telemetry — prod-only, toggleable, numbers-only signals"
```

---

### Task 4: Performance window — recent dictations + share toggle

**Files:**
- Modify: `Airboard/PerformanceView.swift`

**Interfaces:**
- Consumes: `PerformanceLog.shared.recent(10)`, `TelemetryService.shared.sharingEnabled/setSharingEnabled`.

- [ ] **Step 1: Add the sections**

Read the existing file and match its section pattern (DS tokens; metric values in `DS.Typo.mono`). Append after the existing metric sections:

1. **Recent dictations**: `@State private var recentRecords: [DictationRecord] = []` populated `.onAppear { recentRecords = PerformanceLog.shared.recent(10) }`. Each row: relative time ("2m ago" via `RelativeDateTimeFormatter`), the preview in `DS.Label.secondary` (lineLimit 1), and a mono timing line: `"\(String(format: "%.1f", r.audioSeconds))s audio · STT \(r.sttMs)ms" + (r.llmMs.map { " · LLM \($0)ms" } ?? (r.llmOutcome == "timeout" ? " · LLM timed out" : ""))`. Empty state: "Dictations will appear here with their timing breakdown."
2. **Share toggle** (native `.switch` tinted `DS.Accent.success` — regular window):

```swift
Toggle(isOn: Binding(
    get: { TelemetryService.shared.sharingEnabled },
    set: { TelemetryService.shared.setSharingEnabled($0) }
)) {
    VStack(alignment: .leading, spacing: 2) {
        Text("Share anonymous performance stats")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Label.primary)
        Text("Production builds send timing numbers (STT/LLM ms, outcome, audio length, app version) to TelemetryDeck. Never any text you dictate. Debug builds send nothing.")
            .font(.system(size: 10))
            .foregroundColor(DS.Label.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
.toggleStyle(.switch)
.tint(DS.Accent.success)
```

(A `@State private var shareOn` mirror + onChange is fine if the Binding needs a view refresh.)

- [ ] **Step 2: Build + DS gate + commit**

Debug build gate + `./scripts/check_design_system.sh` → both green.

```bash
git add Airboard/PerformanceView.swift
git commit -m "feat: Performance window — recent dictations with timing split + telemetry toggle"
```

---

### Task 5: Docs

**Files:**
- Modify: `README.md` (Privacy section), `CHANGELOG.md` (`## [Unreleased]`), `CLAUDE.md`

- [ ] **Step 1: README** — append to the existing Privacy section the spec's "Privacy contract" paragraph VERBATIM (it was written for this purpose), plus one line: downloads are visible on the GitHub Releases page (no telemetry involved).
- [ ] **Step 2: CHANGELOG** under `### Added`:

```markdown
- Performance window shows your recent dictations with a timing breakdown (audio length, speech-to-text ms, AI cleanup ms) from a local log that never leaves your Mac
- Anonymous performance telemetry (production builds only): timing numbers and outcome flags go to TelemetryDeck so we can see how fast dictation is across installs — never any text you dictate. "Share anonymous performance stats" in the Performance window turns it off
```

- [ ] **Step 3: CLAUDE.md** — Diagnostics row gains `PerformanceLog.swift` + `TelemetryService.swift`; add one line: "Telemetry: TelemetryDeck, prod bundle only, gated on `shareAnalytics` default-true + `TelemetryDeckAppID` in Info.plist (UNSET = inert); signals carry numbers/enums only — never transcript text."
- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md CLAUDE.md
git commit -m "docs: telemetry disclosure + changelog + CLAUDE.md"
```

---

## Manual Verification (Dhruv)

1. Dev build: dictate 3 times (one with cleanup on, one short <6 words, one with Wi-Fi off) → Performance window shows all three with correct outcome flavors (ok / skipped / timeout-or-error); previews match; times sane.
2. Toggle off → persists across relaunch.
3. Dev build sends nothing (bundle gate; `TelemetryDeckAppID` also still UNSET).
4. **Prerequisite before the 1.0.9 release build**: create the TelemetryDeck account + app, put the real App ID into the `TelemetryDeckAppID` value.
5. Post-release: signals appear in the TelemetryDeck dashboard within a few hours (their ingestion is batch); build an insight charting `dictation.stt` floatValue mean.
