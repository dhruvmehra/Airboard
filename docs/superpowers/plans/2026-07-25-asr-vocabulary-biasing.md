> **REVERTED 2026-07-25.** The acoustic biasing layer was built, field-tested, and removed — FluidAudio 0.15.5's rescorer over-fires at small personal vocab sizes across all tunable thresholds. Do NOT re-execute this document; see the tombstone comment in ParakeetTranscriptionService.swift. The confirmation-card portions survived (in simplified, flat-memory form).

# ASR Vocabulary Biasing + Memory Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Memory's words get recognized by the recognizer (CTC word-spotting rescore after every Parakeet transcription), and every "remember…" fact is confirmed in an editable DS pop-up whose edits teach the glossary automatically.

**Architecture:** Strictly additive to the ASR path — `AsrManager.transcribe(url)` stays byte-identical; a new `VocabularyBiasingEngine` runs FluidAudio's CTC keyword-spotter + rescorer over the result when (and only when) the watch-list is non-empty. Pure logic (watch-list assembly, vocab-file serialization, extraction-JSON parsing, edit-diffing, name reconciliation) lives in a Foundation-only `MemoryBias.swift` for scratch testing. The confirm pop-up is a key-accepting DS card presented by FloatingWindowManager.

**Tech Stack:** FluidAudio 0.15.5 (pinned; APIs verified against the checkout source — the library's own CustomVocabulary.md Quick Start is STALE, do not follow it), SwiftUI/AppKit.

**Spec:** `docs/superpowers/specs/2026-07-25-asr-vocabulary-biasing-design.md`

## Global Constraints

- **Empty watch-list = zero cost**: no CTC model download, no extra memory, `transcribe` behavior byte-identical to today. The helper (~97.5MB, HF repo `FluidInference/parakeet-ctc-110m-coreml`, variant `.ctc110m`) downloads lazily on the first non-empty watch-list.
- **Never block or fail dictation on biasing**: any biasing error (download failed, rescore threw, no tokenTimings) → use Parakeet's raw result and log. Rescoring failures are silent to the user.
- Parakeet TDT 0.6B v3 + `AsrManager` remain the transcriber — no manager migration; the rescore pass slots AFTER the existing `transcribe` call.
- **The saved (user-edited) text is the truth**: it becomes the note; extracted names are reconciled against it (names absent from the saved text are dropped; edit-diff replacements are added via glossary pairs); the pre-edit garble never reaches the watch-list.
- Nothing stored silently: every `.remember` goes through the confirm pop-up (⏎ Save / esc Cancel). Glossary teachings ("correct X to Y") stay immediate.
- Watch-list cap: 200 terms — all glossary entries first (curated), then extracted names newest-first; log what was dropped.
- Privacy: the watch-list is consumed on-device only. The cleanup LLM's glossary block is UNCHANGED by this project (share toggle still governs it); extracted names are NOT added to the cleanup prompt.
- `MemoryData` gains a field — decoding MUST be backward-compatible with existing memory.json files (missing key ≠ corrupt file; a wipe here destroys user memories).
- New pure-logic files are Foundation-only (scratch-testable via swiftc). `VocabularyBiasingEngine` imports FluidAudio and is verified via xcodebuild + runtime logs + the manual pass.
- Build gate every task: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`. Ignore SourceKit/IDE diagnostics (stale-index noise). No project.pbxproj edits (auto-synced). DS tokens only in UI; `./scripts/check_design_system.sh` must pass on UI tasks.
- Paths: sources live at `Airboard/<File>.swift` under the repo root.

### Verified FluidAudio API contract (from the pinned checkout — cite in dispatches, do not re-derive)

```swift
// CustomVocabularyContext.swift:44
CustomVocabularyTerm(text: String, weight: Float? = nil, aliases: [String]? = nil,
                     tokenIds: [Int]? = nil, ctcTokenIds: [Int]? = nil, minSimilarity: Float? = nil)
// CustomVocabularyContext.swift:273 — THE entry point: loads vocab file (simple format:
// "Term: alias1, alias2" per line), downloads+loads CTC models, tokenizes terms.
static func loadWithCtcTokens(from path: String, ctcVariant: CtcModelVariant = .ctc110m)
    async throws -> (vocab: CustomVocabularyContext, models: CtcModels)
// CtcModels.swift:196/241/255/275
CtcModels.downloadAndLoad(to:variant:) / CtcModels.modelsExist(at:) / CtcModels.defaultCacheDirectory(for:)
// NOTE: no progressHandler on CTC download — download state is shown as an
// indeterminate toast, not a progress bar (accepted deviation from spec's
// "reuse progress UI"; the spec's intent is "visible download state").
// Rescoring pattern (FluidAudioCLI TranscribeCommand.swift runBatch, lines 483-565):
let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
let spotResult = try await spotter.spotKeywordsWithLogProbs(
    audioSamples: samples, customVocabulary: vocab, minScore: nil)
let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
let rescorer = try await VocabularyRescorer.create(
    spotter: spotter, vocabulary: vocab, config: VocabularyRescorer.Config(),
    ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
let out = rescorer.ctcTokenRescore(
    transcript: result.text, tokenTimings: tokenTimings,
    logProbs: spotResult.logProbs, frameDuration: spotResult.frameDuration,
    cbw: vocabConfig.cbw, marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
    minSimilarity: vocabConfig.minSimilarity)
// out.text / out.wasModified; requires result.tokenTimings non-empty.
```

---

### Task 1: MemoryData gains extractedNames (backward-compatible) + revision counter

**Files:**
- Modify: `Airboard/MemoryStore.swift`
- Test: scratch `/private/tmp/biastest/store_migration_test.swift` (not committed)

**Interfaces:**
- Consumes: existing MemoryStore API.
- Produces: `MemoryData.extractedNames: [String]`; `MemoryStore.addExtractedNames(_ names: [String])` (dedup case-insensitive vs glossary terms AND existing extracted names), `removeExtractedName(at index: Int)`; `MemoryStore.revision: Int` (in-memory, monotonically increments on every mutation — biasing rebuild trigger; NOT persisted).

- [ ] **Step 1: Add the field with backward-compatible decoding**

In `MemoryData`, add the property and REPLACE the synthesized decoding so old files (no `extractedNames` key) decode cleanly instead of tripping corrupt-recovery:

```swift
struct MemoryData: Codable, Equatable {
    var glossary: [GlossaryEntry] = []
    var notes: [String] = []
    var shareWithLLM: Bool = true
    /// Proper names auto-extracted from confirmed facts — acoustic
    /// watch-list only, never sent to the cleanup LLM.
    var extractedNames: [String] = []

    init() {}

    // Backward-compatible decoding: memory.json files written before
    // extractedNames existed must load, not be treated as corrupt —
    // corrupt-recovery would wipe the user's memories to .bad.
    private enum CodingKeys: String, CodingKey {
        case glossary, notes, shareWithLLM, extractedNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glossary = try c.decodeIfPresent([GlossaryEntry].self, forKey: .glossary) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        shareWithLLM = try c.decodeIfPresent(Bool.self, forKey: .shareWithLLM) ?? true
        extractedNames = try c.decodeIfPresent([String].self, forKey: .extractedNames) ?? []
    }
}
```

- [ ] **Step 2: Mutations + revision counter on MemoryStore**

```swift
    /// Monotonic change counter (in-memory only). The biasing engine
    /// compares it to decide when to rebuild its vocabulary.
    private(set) var revision: Int = 0
```

Increment `revision += 1` inside `save()` (single choke point — every mutation passes through it). Add:

```swift
    /// Add auto-extracted proper names. Case-insensitive dedup against
    /// glossary terms and already-extracted names.
    func addExtractedNames(_ names: [String]) {
        var changed = false
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let lower = name.lowercased()
            let inGlossary = data.glossary.contains { $0.term.lowercased() == lower }
            let alreadyExtracted = data.extractedNames.contains { $0.lowercased() == lower }
            if !inGlossary && !alreadyExtracted {
                data.extractedNames.append(name)
                changed = true
            }
        }
        if changed { save() }
    }

    func removeExtractedName(at index: Int) {
        guard data.extractedNames.indices.contains(index) else { return }
        data.extractedNames.remove(at: index)
        save()
    }
```

- [ ] **Step 3: Scratch test — the migration case is the point**

Write `/private/tmp/biastest/store_migration_test.swift`:

```swift
import Foundation

func check(_ cond: Bool, _ label: String) {
    print(cond ? "PASS: \(label)" : "FAIL: \(label)")
    if !cond { exit(1) }
}

let dir = URL(fileURLWithPath: "/private/tmp/biastest/work", isDirectory: true)
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let url = dir.appendingPathComponent("memory.json")

// OLD-FORMAT file (pre-extractedNames) must decode, NOT corrupt-recover
let oldFormat = """
{"glossary":[{"heardAs":"pipe","id":"D8EDFDC6-F1BA-4325-ACCE-75C9AD7A0562","note":"","term":"Pype"}],
 "notes":["I work at Pype"],"shareWithLLM":false}
"""
try! oldFormat.data(using: .utf8)!.write(to: url)
let s1 = MemoryStore(fileURL: url)
check(s1.data.notes == ["I work at Pype"], "old-format notes survive migration")
check(s1.data.glossary.first?.term == "Pype", "old-format glossary survives")
check(s1.data.shareWithLLM == false, "old-format share flag survives")
check(s1.data.extractedNames.isEmpty, "extractedNames defaults empty")
check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("memory.json.bad").path),
      "old format did NOT trip corrupt recovery")

// Extracted names: add, dedup vs glossary and self, persist, remove
let r0 = s1.revision
s1.addExtractedNames(["Ashish", "pype", "ashish", "  "])
check(s1.data.extractedNames == ["Ashish"], "dedup vs glossary(Pype) + self + blanks")
check(s1.revision > r0, "revision bumped on save")
let r1 = s1.revision
s1.addExtractedNames(["ASHISH"])
check(s1.revision == r1, "no-op add does not save or bump revision")
let s2 = MemoryStore(fileURL: url)
check(s2.data.extractedNames == ["Ashish"], "extractedNames round-trips")
s2.removeExtractedName(at: 0)
check(s2.data.extractedNames.isEmpty, "removal works")
print("ALL PASS")
```

- [ ] **Step 4: Run test + build**

Run: `mkdir -p /private/tmp/biastest && cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && swiftc Airboard/MemoryStore.swift /private/tmp/biastest/store_migration_test.swift -o /private/tmp/biastest/store_migration_test && /private/tmp/biastest/store_migration_test`
Expected: `ALL PASS`.
Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Airboard/MemoryStore.swift
git commit -m "feat: extractedNames on MemoryData (backward-compatible) + revision counter"
```

---

### Task 2: MemoryBias — pure watch-list/diff/extraction logic

**Files:**
- Create: `Airboard/MemoryBias.swift`
- Test: scratch `/private/tmp/biastest/bias_logic_test.swift` (not committed)

**Interfaces:**
- Consumes: `MemoryData` (Task 1 shape).
- Produces (exact names later tasks use): `enum MemoryBias` with
  `static let termCap = 200`;
  `static func watchList(from data: MemoryData) -> [(term: String, aliases: [String])]`;
  `static func vocabFileContent(from data: MemoryData) -> String?` (nil when empty — simple format `Term: alias1, alias2` / bare `Term`, colons stripped from terms/aliases);
  `static func parseFactExtraction(_ reply: String, fallback: String) -> (sentence: String, names: [String])`;
  `static func editDiffPairs(heard: String, saved: String) -> [(term: String, heardAs: String)]`;
  `static func reconcile(names: [String], savedText: String) -> [String]`.

- [ ] **Step 1: Write MemoryBias.swift**

```swift
//
//  MemoryBias.swift
//
//  Pure logic for the ASR vocabulary watch-list and the memory confirm
//  pop-up: watch-list assembly (glossary first, extracted names after,
//  capped), FluidAudio simple-format vocab serialization, storage-LLM
//  extraction-JSON parsing, edit-diff glossary learning, and name
//  reconciliation against the user's saved text.
//
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

enum MemoryBias {

    /// Biasing quality degrades on huge lists; glossary (curated) wins,
    /// extracted names fill the remainder newest-first.
    static let termCap = 200

    static func watchList(from data: MemoryData) -> [(term: String, aliases: [String])] {
        var seen = Set<String>()
        var out: [(term: String, aliases: [String])] = []
        for entry in data.glossary {
            let term = sanitize(entry.term)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let aliases = entry.heardAs.isEmpty ? [] : [sanitize(entry.heardAs)]
            out.append((term, aliases.filter { !$0.isEmpty }))
            if out.count == termCap { return out }
        }
        for name in data.extractedNames.reversed() {  // newest first
            let term = sanitize(name)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            out.append((term, []))
            if out.count == termCap { break }
        }
        return out
    }

    /// FluidAudio simple vocab format: one term per line, optionally
    /// "Term: alias1, alias2". Nil when there is nothing to bias.
    static func vocabFileContent(from data: MemoryData) -> String? {
        let list = watchList(from: data)
        guard !list.isEmpty else { return nil }
        return list.map { item in
            item.aliases.isEmpty ? item.term : "\(item.term): \(item.aliases.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    /// The simple format uses ':' and ',' as separators — strip them from
    /// values so a weird term can't corrupt the file.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the storage LLM's reply: {"sentence": "...", "names": ["..."]}.
    /// Anything malformed degrades to (fallback-or-raw-reply, no names) —
    /// extraction is an enhancement, never a gate.
    static func parseFactExtraction(_ reply: String, fallback: String) -> (sentence: String, names: [String]) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap JSON in code fences — strip one layer.
        let unfenced = trimmed
            .replacingOccurrences(of: "^```(json)?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = unfenced.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let sentence = obj["sentence"] as? String,
              !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Not JSON: treat a plausible plain-sentence reply as the
            // cleaned sentence; anything empty falls back to the raw note.
            let plain = trimmed
            if !plain.isEmpty && !plain.hasPrefix("{") && plain.count < max(200, fallback.count * 3) {
                return (plain, [])
            }
            return (fallback, [])
        }
        let names = (obj["names"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (sentence.trimmingCharacters(in: .whitespacesAndNewlines), names)
    }

    /// Single-token substitutions between the heard fact and the saved
    /// fact become glossary pairs: "reparty" -> "Ashish". Insertions,
    /// deletions, or restructures teach nothing (token counts must match).
    static func editDiffPairs(heard: String, saved: String) -> [(term: String, heardAs: String)] {
        let heardTokens = tokens(heard)
        let savedTokens = tokens(saved)
        guard heardTokens.count == savedTokens.count, !heardTokens.isEmpty else { return [] }
        var pairs: [(String, String)] = []
        for (h, s) in zip(heardTokens, savedTokens) where h.lowercased() != s.lowercased() {
            // Only word-like tokens teach; both sides must be letters.
            guard h.allSatisfy({ $0.isLetter }), s.allSatisfy({ $0.isLetter }) else { continue }
            pairs.append((s, h.lowercased()))
            if pairs.count == 3 { break }  // a save teaches at most 3 pairs
        }
        return pairs
    }

    /// Names must exist in the user's SAVED text to survive — the pre-edit
    /// garble never reaches the watch-list.
    static func reconcile(names: [String], savedText: String) -> [String] {
        let lower = savedText.lowercased()
        return names.filter { lower.contains($0.lowercased()) }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 2: Scratch test**

Write `/private/tmp/biastest/bias_logic_test.swift`:

```swift
import Foundation

func check(_ cond: Bool, _ label: String) {
    print(cond ? "PASS: \(label)" : "FAIL: \(label)")
    if !cond { exit(1) }
}

var data = MemoryData()
data.glossary = [GlossaryEntry(term: "Pype", heardAs: "pipe", note: "")]
data.extractedNames = ["Ashish", "Meera"]

// watch-list: glossary first, extracted newest-first, dedup
let wl = MemoryBias.watchList(from: data)
check(wl.map(\.term) == ["Pype", "Meera", "Ashish"], "order: glossary, then extracted newest-first")
check(wl[0].aliases == ["pipe"], "heardAs becomes alias")

// vocab file serialization
let content = MemoryBias.vocabFileContent(from: data)!
check(content == "Pype: pipe\nMeera\nAshish", "simple-format serialization")
check(MemoryBias.vocabFileContent(from: MemoryData()) == nil, "empty store -> nil")
var weird = MemoryData()
weird.glossary = [GlossaryEntry(term: "A:B,C", heardAs: "a:b", note: "")]
check(MemoryBias.vocabFileContent(from: weird) == "AB C: ab", "separators sanitized")

// cap
var big = MemoryData()
big.extractedNames = (0..<300).map { "Name\($0)" }
check(MemoryBias.watchList(from: big).count == MemoryBias.termCap, "cap enforced")

// extraction parsing
var r = MemoryBias.parseFactExtraction(#"{"sentence":"My co-founder is Ashish.","names":["Ashish"]}"#, fallback: "raw")
check(r.sentence == "My co-founder is Ashish." && r.names == ["Ashish"], "well-formed JSON")
r = MemoryBias.parseFactExtraction("```json\n{\"sentence\":\"I work at Pype.\",\"names\":[]}\n```", fallback: "raw")
check(r.sentence == "I work at Pype.", "code-fenced JSON unfenced")
r = MemoryBias.parseFactExtraction("My gym closes Mondays.", fallback: "raw")
check(r.sentence == "My gym closes Mondays." && r.names.isEmpty, "plain sentence accepted, no names")
r = MemoryBias.parseFactExtraction("{broken json", fallback: "raw note")
check(r.sentence == "raw note" && r.names.isEmpty, "malformed JSON -> fallback")

// edit-diff learning
var pairs = MemoryBias.editDiffPairs(heard: "My founder is Reparty.", saved: "My founder is Ashish.")
check(pairs.count == 1 && pairs[0].term == "Ashish" && pairs[0].heardAs == "reparty", "substitution teaches pair")
pairs = MemoryBias.editDiffPairs(heard: "I work at pipe", saved: "I work at Pype Labs")
check(pairs.isEmpty, "insertion (count mismatch) teaches nothing")
pairs = MemoryBias.editDiffPairs(heard: "same text here", saved: "same text here")
check(pairs.isEmpty, "no change teaches nothing")

// reconciliation
let names = MemoryBias.reconcile(names: ["Reparty", "Ashish"], savedText: "My founder is Ashish.")
check(names == ["Ashish"], "garble dropped, kept name survives")
print("ALL PASS")
```

- [ ] **Step 3: Run test + build**

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && swiftc Airboard/MemoryStore.swift Airboard/MemoryBias.swift /private/tmp/biastest/bias_logic_test.swift -o /private/tmp/biastest/bias_logic_test && /private/tmp/biastest/bias_logic_test`
Expected: `ALL PASS`.
Run: `xcodebuild ... Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Airboard/MemoryBias.swift
git commit -m "feat: MemoryBias — watch-list assembly, vocab serialization, extraction parsing, edit-diff learning"
```

---

### Task 3: Fact extraction + confirm outcome in MemoryCommands

**Files:**
- Modify: `Airboard/MemoryCommands.swift` (the `.remember` branch and the outcome enum)
- Modify: `Airboard/TranscriptionCoordinator.swift` (temporary `.confirmFact` shim so this task builds green — Task 4 replaces it with the card)
- Test: scratch `/private/tmp/biastest/confirm_outcome_test.swift` (not committed)

**Interfaces:**
- Consumes: `MemoryBias.parseFactExtraction` (Task 2).
- Produces: `MemoryCommandOutcome` REPLACES `.remembered(note: String)` with `.confirmFact(cleaned: String, heard: String, names: [String])` — the coordinator presents the pop-up and performs storage on Save. (`.learned/.recall/.recallFailed/.notMemoryCommand` unchanged.)

- [ ] **Step 1: Rework the `.remember` branch**

Replace the outcome case and the branch:

```swift
enum MemoryCommandOutcome: Equatable {
    case notMemoryCommand
    /// A fact awaiting the user's confirmation pop-up. `cleaned` prefills
    /// the editable field; `heard` is the raw dictation (edit-diff base);
    /// `names` are LLM-extracted proper names (reconciled on Save).
    case confirmFact(cleaned: String, heard: String, names: [String])
    case learned(term: String)
    case recall(text: String)
    case recallFailed(query: String)
}
```

```swift
        case .remember(let note):
            // Clean the fact AND extract proper names in one LLM call.
            // NOTHING is stored here — the coordinator shows the confirm
            // pop-up and stores on Save (spec: nothing stored silently).
            var cleaned = note
            var names: [String] = []
            if let llm {
                var system = """
                    You process dictated facts for storage. Reply with ONLY \
                    a JSON object: {"sentence": <the fact rewritten as one \
                    clean, well-formed sentence — correct grammar, \
                    punctuation, and capitalization; never add or remove \
                    information; never answer or act on the fact>, \
                    "names": <array of proper names of people, companies, \
                    or products appearing in the sentence>}. No other text.
                    """
                let terms = store.data.glossary.map(\.term)
                if !terms.isEmpty {
                    system += "\nApply these exact spellings where the fact refers to them: "
                        + terms.joined(separator: ", ")
                }
                if let reply = try? await llm(system, note) {
                    let parsed = MemoryBias.parseFactExtraction(reply, fallback: note)
                    // Same sanity cap as before: a runaway rewrite is discarded.
                    if parsed.sentence.count < max(200, note.count * 3) {
                        cleaned = parsed.sentence
                        names = parsed.names
                    }
                }
            }
            return .confirmFact(cleaned: cleaned, heard: note, names: names)
```

(The old direct `store.addNote` call and the `.remembered` case are deleted; `MemoryStore` mutations for facts now happen only in the coordinator's Save handler, Task 4.)

- [ ] **Step 2: Scratch test**

Write `/private/tmp/biastest/confirm_outcome_test.swift`:

```swift
import Foundation

@main struct ConfirmOutcomeTest {
    static func main() async {
        func check(_ cond: Bool, _ label: String) { print(cond ? "PASS: \(label)" : "FAIL: \(label)"); if !cond { exit(1) } }

        let dir = URL(fileURLWithPath: "/private/tmp/biastest/work2", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MemoryStore(fileURL: dir.appendingPathComponent("memory.json"))

        // LLM path: JSON reply -> cleaned + names, nothing stored
        var out = await MemoryCommands.handle(text: "remember my co-founder is a shish", store: store,
            llm: { _, _ in #"{"sentence":"My co-founder is Ashish.","names":["Ashish"]}"# })
        check(out == .confirmFact(cleaned: "My co-founder is Ashish.", heard: "My co-founder is a shish", names: ["Ashish"]),
              "confirmFact carries cleaned + heard + names")
        check(store.data.notes.isEmpty, "NOTHING stored before confirmation")

        // LLM error -> raw as cleaned, no names, still confirm-gated
        out = await MemoryCommands.handle(text: "remember I like tea", store: store,
            llm: { _, _ in throw URLError(.timedOut) })
        check(out == .confirmFact(cleaned: "I like tea", heard: "I like tea", names: []), "LLM error -> raw fact to confirm")

        // No LLM -> raw to confirm
        out = await MemoryCommands.handle(text: "remember offline fact", store: store, llm: nil)
        check(out == .confirmFact(cleaned: "Offline fact", heard: "Offline fact", names: []), "offline -> raw to confirm")

        // Other intents unchanged
        out = await MemoryCommands.handle(text: "correct pipe to Pype", store: store, llm: nil)
        check(out == .learned(term: "Pype"), "correct still immediate")
        out = await MemoryCommands.handle(text: "open safari", store: store, llm: nil)
        check(out == .notMemoryCommand, "passthrough intact")
        print("ALL PASS")
    }
}
```

- [ ] **Step 3: Temporary coordinator shim (keeps this task's build green)**

The enum change makes `handleCommandMode`'s switch non-exhaustive. Replace the `.remembered` case in `Airboard/TranscriptionCoordinator.swift` with this TEMPORARY handler (Task 4 replaces it with the confirmation card — the marker comment is the contract):

```swift
        case .confirmFact(let cleaned, _, _):
            // TEMPORARY (replaced by the confirmation card in the next
            // task): store directly so the build stays green mid-plan.
            print("🧠 Memory: remembered '\(cleaned)' (confirm card pending)")
            await MainActor.run {
                MemoryStore.shared.addNote(cleaned)
                FloatingWindowManager.shared.showCommandExecuted()
                FloatingWindowManager.shared.showToast("Remembered: \(cleaned)")
                self.showNotification(title: "Remembered", body: cleaned)
            }
            return
```

- [ ] **Step 4: Run test + build**

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && swiftc Airboard/MemoryStore.swift Airboard/MemoryBias.swift Airboard/MemoryCommands.swift /private/tmp/biastest/confirm_outcome_test.swift -o /private/tmp/biastest/confirm_outcome_test && /private/tmp/biastest/confirm_outcome_test`
Expected: `ALL PASS`.
Run: `xcodebuild ... Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Airboard/MemoryCommands.swift Airboard/TranscriptionCoordinator.swift
git commit -m "feat: remember returns confirmFact (cleaned + extracted names); storage deferred to confirmation"
```

---

### Task 4: Confirm pop-up (DS card) + coordinator save/cancel wiring

**Files:**
- Create: `Airboard/MemoryConfirmView.swift`
- Modify: `Airboard/FloatingWindowManager.swift` (add `showMemoryConfirm`), `Airboard/TranscriptionCoordinator.swift` (`.confirmFact` branch replaces `.remembered`)

**Interfaces:**
- Consumes: `.confirmFact(cleaned:heard:names:)` (Task 3); `MemoryBias.editDiffPairs/reconcile` (Task 2); `MemoryStore.addNote/addGlossary/addExtractedNames` (Task 1); existing `showToast`.
- Produces: `FloatingWindowManager.showMemoryConfirm(cleaned: String, heard: String, names: [String], onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void)`.

- [ ] **Step 1: Coordinator branch**

In `TranscriptionCoordinator.handleCommandMode`, replace the `.remembered` case with:

```swift
        case .confirmFact(let cleaned, let heard, let names):
            print("🧠 Memory: confirming fact '\(cleaned)' (heard: '\(heard)', names: \(names))")
            await MainActor.run {
                FloatingWindowManager.shared.showMemoryConfirm(
                    cleaned: cleaned, heard: heard, names: names,
                    onSave: { savedText in
                        let store = MemoryStore.shared
                        store.addNote(savedText)
                        // Edits teach: single-word substitutions become
                        // glossary pairs ("reparty" -> "Ashish").
                        for pair in MemoryBias.editDiffPairs(heard: heard, saved: savedText) {
                            store.addGlossary(term: pair.term, heardAs: pair.heardAs)
                        }
                        // Names survive only if present in the SAVED text.
                        store.addExtractedNames(MemoryBias.reconcile(names: names, savedText: savedText))
                        print("🧠 Memory: stored '\(savedText)'")
                        FloatingWindowManager.shared.showToast("Remembered: \(savedText)")
                    },
                    onCancel: {
                        print("🧠 Memory: confirmation cancelled")
                    })
            }
            return
```

- [ ] **Step 2: MemoryConfirmView.swift**

```swift
//
//  MemoryConfirmView.swift
//
//  The memory confirmation card: every "remember…" fact is shown here for
//  edit/save before anything is stored (spec: nothing stored silently).
//  DS v2 HUD language — same surface as the popover/toast family. Hosted
//  in a KEY-ACCEPTING panel (it takes typing), so native controls render
//  normally; the non-activating-panel lesson does not apply here.
//

import SwiftUI

struct MemoryConfirmView: View {
    @State var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(DS.Tint.purple)
                        .frame(width: 24, height: 24)
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Accent.command)
                }
                Text("Remember this?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Label.primary)
                Spacer()
                Text("⏎ save · esc cancel")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Label.tertiary)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Label.primary)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .stroke(DS.Border.control, lineWidth: 1))
                .onSubmit { if canSave { onSave(text) } }

            HStack(spacing: 8) {
                Text("Edits teach Airboard the right spelling.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Label.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { onSave(text) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Label.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                        .fill(DS.Accent.primary))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous)
            .fill(DS.Surface.hud))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous)
            .strokeBorder(DS.Surface.hudBorder, lineWidth: 1))
        .onAppear { focused = true }
    }
}
```

- [ ] **Step 3: showMemoryConfirm in FloatingWindowManager**

Add next to the toast section (single pending panel — a new confirm replaces an unanswered one, latest wins per spec):

```swift
    // MARK: - Memory confirm card

    private var memoryConfirmWindow: NSPanel?

    func showMemoryConfirm(
        cleaned: String, heard: String, names: [String],
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Latest wins: an unanswered card is replaced (its fact drops).
            self.memoryConfirmWindow?.close()
            self.memoryConfirmWindow = nil
            guard let screen = NSScreen.main else { return }

            let dismiss: () -> Void = { [weak self] in
                self?.memoryConfirmWindow?.close()
                self?.memoryConfirmWindow = nil
            }
            let view = MemoryConfirmView(
                text: cleaned,
                onSave: { saved in dismiss(); onSave(saved) },
                onCancel: { dismiss(); onCancel() })

            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            let frame = NSRect(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 60,
                width: size.width, height: size.height)

            // Key-accepting panel: the card takes typing. .nonactivatingPanel
            // is deliberately NOT used here.
            let panel = NSPanel(contentRect: frame,
                                styleMask: [.titled, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            // A confirm card has exactly two exits: Save and Cancel.
            // Hide the traffic lights the .titled mask would show.
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = hosting
            self.memoryConfirmWindow = panel
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
```

Also add `memoryConfirmWindow` teardown to `cleanup()` alongside the other windows.

- [ ] **Step 4: Build + DS check + escape/enter sanity**

Run: `xcodebuild ... Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `./scripts/check_design_system.sh | tail -2` → `✅ Design-system check passed`
Note in the report: Enter submits via `.onSubmit` (single-line submit of the vertical-axis field) and ⌘⏎ via the Save shortcut; esc cancels via shortcut. Runtime behavior is on the user's manual pass.

- [ ] **Step 5: Commit**

```bash
git add Airboard/MemoryConfirmView.swift Airboard/FloatingWindowManager.swift Airboard/TranscriptionCoordinator.swift
git commit -m "feat: memory confirmation card — nothing stored silently; edits teach glossary pairs"
```

---

### Task 5: VocabularyBiasingEngine + transcription integration

**Files:**
- Create: `Airboard/VocabularyBiasingEngine.swift`
- Modify: `Airboard/ParakeetTranscriptionService.swift` (rescore pass after `transcribe`)

**Interfaces:**
- Consumes: `MemoryBias.vocabFileContent(from:)`, `MemoryStore.shared.{data,revision}`; the verified FluidAudio contract in Global Constraints.
- Produces: `actor VocabularyBiasingEngine` — `static let shared`; `func rescore(text: String, tokenTimings: [TokenTiming], audioURL: URL) async -> String?` (nil = no change / biasing unavailable; NEVER throws to the caller).

- [ ] **Step 1: Write VocabularyBiasingEngine.swift**

```swift
//
//  VocabularyBiasingEngine.swift
//
//  On-device acoustic vocabulary biasing: after Parakeet transcribes, a
//  CTC keyword spotter re-examines the audio for the user's memory terms
//  (glossary + extracted names) and a rescorer corrects the transcript
//  from acoustic evidence (NVIDIA CTC Word Spotter, arXiv:2406.07096, as
//  shipped in FluidAudio 0.15.5 — the exact pattern of FluidAudioCLI's
//  batch mode; the library doc's Quick Start is stale, do not follow it).
//
//  Contract: empty watch-list = completely inert (no download, no memory,
//  no rescore). Any failure -> nil (caller keeps Parakeet's raw text).
//

import Foundation
import AVFoundation
import FluidAudio

actor VocabularyBiasingEngine {
    static let shared = VocabularyBiasingEngine()

    private var vocab: CustomVocabularyContext?
    private var ctcModels: CtcModels?
    private var spotter: CtcKeywordSpotter?
    private var builtRevision: Int = -1
    private var downloadFailedThisLaunch = false

    /// Rescore a transcript against the memory watch-list. nil = leave the
    /// transcript alone (empty list, unavailable helper, or any failure).
    func rescore(text: String, tokenTimings: [TokenTiming], audioURL: URL) async -> String? {
        await rebuildIfNeeded()
        guard let vocab, let ctcModels, let spotter, !tokenTimings.isEmpty else { return nil }

        do {
            guard let samples = Self.loadSamples(from: audioURL) else { return nil }
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocab, minScore: nil)
            guard !spotResult.logProbs.isEmpty else { return nil }

            let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: vocab,
                config: VocabularyRescorer.Config(),
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
            let out = rescorer.ctcTokenRescore(
                transcript: text, tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs, frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: vocabConfig.minSimilarity)
            if out.wasModified {
                print("🎯 Vocabulary biasing corrected: '\(text)' -> '\(out.text)'")
                return out.text
            }
            return nil
        } catch {
            print("⚠️ Vocabulary biasing skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rebuild the vocabulary when memory changed. Empty watch-list tears
    /// biasing down entirely (zero cost). First non-empty list triggers
    /// the one-time ~97.5MB CTC helper download (no progress API — an
    /// indeterminate toast announces start and completion).
    private func rebuildIfNeeded() async {
        let (revision, content) = await MainActor.run {
            (MemoryStore.shared.revision, MemoryBias.vocabFileContent(from: MemoryStore.shared.data))
        }
        guard revision != builtRevision else { return }

        guard let content else {
            vocab = nil; ctcModels = nil; spotter = nil
            builtRevision = revision
            return
        }
        guard !downloadFailedThisLaunch else { return }

        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vocabFile = dir.appendingPathComponent("bias-vocabulary.txt")
            try content.write(to: vocabFile, atomically: true, encoding: .utf8)

            let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let needsDownload = !CtcModels.modelsExist(at: cacheDir)
            if needsDownload {
                print("📥 Downloading name-recognition helper (~98MB, one time)...")
                await MainActor.run {
                    FloatingWindowManager.shared.showToast("Downloading name recognition (98 MB, one time)…")
                }
            }
            let (loadedVocab, loadedModels) = try await CustomVocabularyContext.loadWithCtcTokens(
                from: vocabFile.path, ctcVariant: .ctc110m)
            vocab = loadedVocab
            ctcModels = loadedModels
            spotter = CtcKeywordSpotter(models: loadedModels, blankId: loadedModels.vocabulary.count)
            builtRevision = revision
            print("🎯 Vocabulary biasing active: \(loadedVocab.terms.count) terms")
            if needsDownload {
                await MainActor.run {
                    FloatingWindowManager.shared.showToast("Name recognition ready")
                }
            }
        } catch {
            print("⚠️ Vocabulary biasing unavailable: \(error.localizedDescription)")
            downloadFailedThisLaunch = true  // retry next launch, not every dictation
        }
    }

    /// 16kHz mono Float32 samples from the recorded WAV.
    private static func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
```

NOTE for the implementer: `TokenTiming` is FluidAudio's token-timing type as returned by `ASRResult.tokenTimings` — check the exact optional/array type on `ASRResult` in the checkout (`AsrTypes.swift`) and match the parameter type precisely; adjust the signature to `[TokenTiming]` or the actual element type name if it differs, keeping the rest of the contract identical. Also verify `rescorer.ctcTokenRescore`'s exact parameter list against `VocabularyRescorer+TokenRescoring.swift` before assuming — the plan's call matches the CLI's usage at FluidAudioCLI/TranscribeCommand.swift:483-565.

- [ ] **Step 2: Rescore pass in ParakeetTranscriptionService**

In `transcribe(audioURL:)`, after `let transcribedText = result.text.trimmingCharacters(...)` and the empty check, insert BEFORE `transcription = transcribedText` (and move the file deletion to AFTER the rescore since it needs the audio):

```swift
            var finalText = transcribedText
            if let timings = result.tokenTimings, !timings.isEmpty {
                if let corrected = await VocabularyBiasingEngine.shared.rescore(
                    text: transcribedText, tokenTimings: timings, audioURL: audioURL) {
                    finalText = corrected
                }
            }
```

Then use `finalText` for `transcription`, logs, and completion. Confirm the audio file deletion happens after the rescore call in every path.

- [ ] **Step 3: Build + inert-path verification**

Run: `xcodebuild ... Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Then verify the zero-cost path: `defaults read` is not needed — run the app with an EMPTY memory store (move `~/Library/Application Support/com.pype.airboard.dev/memory.json` aside temporarily), dictate once, and confirm the log contains NO `🎯`/`📥` lines and no CTC download. Restore the file after.

- [ ] **Step 4: Commit**

```bash
git add Airboard/VocabularyBiasingEngine.swift Airboard/ParakeetTranscriptionService.swift
git commit -m "feat: on-device vocabulary biasing — CTC word-spotter rescores transcripts with memory terms"
```

---

### Task 6: Extracted names in the Memory window

**Files:**
- Modify: `Airboard/MemorySettingsView.swift`

**Interfaces:**
- Consumes: `MemoryStore.data.extractedNames`, `removeExtractedName(at:)` (Task 1).
- Produces: nothing new.

- [ ] **Step 1: Add a "Names" section**

Between the Facts section and the share toggle, following the existing section pattern exactly (header + caption + rows with trash buttons; use the file's existing `dsMemoryFieldChrome`-style row treatment):

```swift
                    Divider()

                    // ---- Extracted names (acoustic watch-list) ----
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Names")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Label.primary)
                        Text("Picked up from your facts — helps Airboard recognize them when you speak. Never sent anywhere.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Label.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.data.extractedNames.isEmpty {
                            Text("No names yet — they appear when you save facts that mention people or companies.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Label.tertiary)
                        }
                        ForEach(Array(store.data.extractedNames.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 8) {
                                Text(name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(DS.Label.primary)
                                Spacer()
                                Button {
                                    store.removeExtractedName(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(DS.Label.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                                .fill(DS.Fill.quaternary))
                        }
                    }
```

- [ ] **Step 2: Build + DS check**

Run: `xcodebuild ... Debug build 2>&1 | tail -3 && ./scripts/check_design_system.sh | tail -2`
Expected: `** BUILD SUCCEEDED **` and `✅ Design-system check passed`

- [ ] **Step 3: Commit**

```bash
git add Airboard/MemorySettingsView.swift
git commit -m "feat: extracted names visible and deletable in the Memory window"
```

---

### Task 7: Docs + changelog

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]`), `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: CHANGELOG.md**

Under `## [Unreleased]` `### Added` (after the Airboard Memory bullet):

```markdown
- Name recognition: words you teach Airboard (and names from your saved facts) are now recognized by the speech model itself — a small on-device helper (98 MB, downloaded once when you first teach a word) re-checks the audio for your words and corrects the transcript from sound, not guessing. "Pype" and "Ashish" come out right even with AI Cleanup off
- Memory confirmation: every "remember…" fact now shows a small card to review and edit before it's saved — and correcting a misheard name in the card teaches Airboard the right spelling automatically
```

Under `### Changed` (create if absent):

```markdown
- Nothing is stored to memory silently anymore — facts always pass through the confirmation card
```

- [ ] **Step 2: CLAUDE.md**

In the Source Organization Memory row, add `MemoryBias.swift` (watch-list + confirm-card logic) and `VocabularyBiasingEngine.swift` (CTC acoustic biasing), and `MemoryConfirmView.swift`. Add one line under the memory.json note: "The bias watch-list (glossary + extractedNames, cap 200) feeds an on-device CTC rescorer (FluidAudio custom vocabulary, `.ctc110m` helper, lazily downloaded); empty memory = biasing fully inert."

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: changelog + CLAUDE.md for vocabulary biasing and memory confirmation"
```

---

## Manual Verification (Dhruv — the release gate)

1. Fresh empty memory: dictate → log shows no biasing lines, no download. (Zero-cost path.)
2. ⌥+⌘ "correct pipe to Pype" → first non-empty watch-list → "Downloading name recognition…" toast once; "🎯 Vocabulary biasing active: N terms" in the log.
3. **The acoustic test**: AI Cleanup OFF → dictate "send the deck to pipe" → "Pype" appears (recognizer-level fix, no LLM involved). "The water pipe is leaking" → stays "pipe" (needs acoustic + similarity match, not blanket replacement).
4. ⌥+⌘ "remember my co-founder is Ashish" → confirm card appears prefilled with the cleaned fact → if a name got garbled, edit it → Save → toast shows the stored text; Memory window shows the fact, the learned glossary pair (if edited), and the name under Names.
5. Dictate the name again → recognized (the edit taught the watch-list).
6. esc on the card → nothing stored anywhere.
7. Memory gauge (Activity Monitor): ~130MB delta only after biasing activates.
8. Regression: dictation, hands-free, command mode, mic picker unchanged; existing teammates' upgrade path = empty extractedNames decodes fine (Task 1's migration test covers the file format).
