# Self-Learning Vocabulary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Airboard learns the names and terms its user says (from the words they fix after dictating and from on-screen text), confirms each with a non-focus-stealing card, and writes them correctly on later dictations — context-aware, with +0ms on dictations that contain no learned term and ≤350ms on those that do.

**Architecture:** Pure, scratch-tested units find candidate spans by sound code (original Metaphone) and parse confirmed spelling lines from `memory.md`; a decision model (Jev 1.13 via the OpenRouter Decisions API, user's own key) answers yes/no per candidate under a hard 350ms deadline; `VocabularyLearning` orchestrates the dictation path, the post-insertion `CorrectionWatcher`, the background `VocabularyHarvester`, and the confirm cards. Every failure path leaves text exactly as Parakeet heard it.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, Accessibility API (AXUIElement), URLSession, OpenRouter Decisions API (`typesafe/jev-1.13`, fallback `inception/mercury-decide:free`). No new SPM dependencies.

**Spec:** `docs/superpowers/specs/2026-10-07-self-learning-vocabulary-design.md`

**Pre-verified:** every file in this plan was written, compiled and tested before the plan was saved (2026-10-07): all four pure scratch suites pass; the decision client and batching were tested live against Jev (same-sentence batches 160–270ms, never over the 350ms deadline); the synthetic eval gate passed twice (40/44 and 39/44, zero false positives, p50 ≈180–200ms); and the full integration compiled in a throwaway copy of the app with no new warnings and the design-system check passing.

## Global Constraints

- Swift files live in `Airboard/Airboard/` (repo path `Airboard/`); the project auto-discovers them (PBXFileSystemSynchronizedRootGroup). NEVER edit `project.pbxproj`.
- Project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; pure units are marked `nonisolated` (they're used from background tasks).
- Pure units are Foundation-only so they compile standalone. Scratch tests: multi-file `swiftc -parse-as-library` with an `@main struct` (top-level code fails); keep them in `/private/tmp/vocabtest/` — never commit them.
- **The repo is public.** No real user vocabulary anywhere in code, tests, docs or fixtures — use the stand-ins Brite / Cait / Alisha (prior convention: commit 8f428db).
- No API key in source, release, or appcast. The decision engine uses the user's own OpenRouter key, the one the Assistant already stores: `KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost)`.
- Never log sentences, terms, or answers. Metrics are numbers/enums only (`vocabMs`, `vocabOutcome`) in the local PerformanceLog.
- Decision API: `POST https://openrouter.ai/api/alpha/decisions`, model `typesafe/jev-1.13`, fallback `inception/mercury-decide:free` only on error with time left. Batch only questions about ONE sentence into one request (one shared `state`).
- Thresholds (probe-calibrated): apply a confirmed rule at p ≥ 0.5; create a new suggestion / learned card / term verdict at p ≥ 0.7. Dictation-path deadline 0.35s; background deadline 5s.
- Card copy verbatim: "Learned: <heard> → **<term>**" [Undo] [Keep]; "Did you mean **<term>**?" [No] [Yes]. Ignored after 8s: Learned → Keep; Did you mean → snoozed 7 days.
- All UI uses DesignSystem v2 tokens (`DS.*`); run `scripts/check_design_system.sh` before committing any UI task.
- Build gate for every task: `xcodebuild … build 2>&1 | grep -E "error:|BUILD"` prints `** BUILD SUCCEEDED **`. SourceKit editor diagnostics are stale-index noise; xcodebuild is truth.
- Commit messages end with the project's Co-Authored-By trailer (shown in each commit step).

## Review Focus

Inputs the spec implies but its happy path doesn't exercise — each is pinned by a test or manual check in the owning task:

1. **Emails, URLs, file paths** ("bright@brite.com", "~/bright/notes", "bright.io") must never be rewritten, even though "bright" sounds like a learned "Brite". → Task 2 test `email/path/url never candidates`.
2. **The confirm card must never take keyboard focus** — the user is often mid-sentence when it appears; a stolen keystroke is worse than no card. → Task 7 manual check M3.
3. **Network slow or down** must never delay dictation beyond 350ms or drop words. → Task 4 tests `10ms deadline -> nil fast`, `never exceeds deadline`, `bad key -> nil`; Task 7 manual check M6.
4. **Long dictations and repeated terms** — 400+ words against 500 harvested terms must stay fast; the same learned phrase twice is replaced both times. → Task 2 `worst case … under 20ms`; Task 5 `same span twice: both replaced`.
5. **Non-Latin text** (Hindi, emoji) — Metaphone only knows a–z; must produce no candidates and no crash. → Task 2 `non-Latin text: no candidates, no crash`.

---


### Task 1: SoundCode — "how it sounds" codes

**Files:**
- Create: `Airboard/SoundCode.swift`
- Test (scratch, not committed): `/private/tmp/vocabtest/soundcode_test.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SoundCode.code(_ text: String) -> String` (e.g. "for sell" → "FRSL"), `SoundCode.soundsAlike(_ a: String, _ b: String) -> Bool` (equal, or one edit apart when both ≥4 sounds), `SoundCode.editDistance(_:_:) -> Int`.

- [ ] **Step 1: Write the failing scratch test** at `/private/tmp/vocabtest/soundcode_test.swift`

```swift
import Foundation

@main struct SoundCodeTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }
        let alike: [(String, String)] = [
            ("bright AI", "Brite AI"), ("paraket", "Parakeet"), ("cloud code", "Claude Code"),
            ("cloud MD", "Claude MD"), ("a lisha", "Alisha"), ("kate", "Cait"),
            ("for sell", "Vercel"), ("super base", "Supabase"), ("cloud", "Claude"),
        ]
        for (h, t) in alike {
            check("\(h) ~ \(t) [\(SoundCode.code(h)) / \(SoundCode.code(t))]",
                  SoundCode.soundsAlike(SoundCode.code(h), SoundCode.code(t)))
        }
        let different: [(String, String)] = [
            ("brightness", "Brite"), ("is working", "Cait"), ("water", "Vercel"),
            ("cloudy", "Claude Code"), ("ship", "Cait"), ("brown", "Brite"),
        ]
        for (h, t) in different {
            check("\(h) !~ \(t) [\(SoundCode.code(h)) / \(SoundCode.code(t))]",
                  !SoundCode.soundsAlike(SoundCode.code(h), SoundCode.code(t)))
        }
        check("exact codes: bright=BRT", SoundCode.code("bright") == "BRT")
        check("exact codes: Parakeet=PRKT", SoundCode.code("Parakeet") == "PRKT")
        check("exact codes: Vercel=FRSL", SoundCode.code("Vercel") == "FRSL")
        check("exact codes: Alisha=ALX", SoundCode.code("Alisha") == "ALX")
        check("sch sounds K: school=SKL", SoundCode.code("school") == "SKL")
        check("empty input", SoundCode.code("") == "" && SoundCode.code("123 !!") == "")
        check("short codes need exact match", !SoundCode.soundsAlike("PP", "P"))
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run it — expect a compile failure (types don't exist yet)**

```bash
mkdir -p /private/tmp/vocabtest && swiftc -parse-as-library Airboard/SoundCode.swift /private/tmp/vocabtest/soundcode_test.swift -o /private/tmp/vocabtest/soundcode_test 2>&1 | head -3
```
Expected: `error: ... No such file` / `cannot find ... in scope`.

- [ ] **Step 3: Create `Airboard/SoundCode.swift`**

```swift
//
//  SoundCode.swift
//
//  "How it sounds" codes for candidate finding (original Metaphone,
//  Lawrence Philips 1990). Two spellings with the same code probably
//  sound alike: "bright AI" = "Brite AI" = BRT, "for sell" = "Vercel" = FRSL.
//  A matching code is only a QUESTION for the decision engine — never a
//  replacement on its own. Foundation-only: compiles standalone for
//  scratch tests.
//

import Foundation

nonisolated enum SoundCode {

    /// Code for a word or phrase. Spaces and non-letters are dropped first,
    /// so "a lisha" encodes the same as "Alisha".
    static func code(_ text: String) -> String {
        let letters = Array(text.lowercased().unicodeScalars
            .filter { $0.value >= 97 && $0.value <= 122 }
            .map { Character($0) })
        guard !letters.isEmpty else { return "" }

        var s = letters
        // Silent first letters.
        if s.count >= 2 {
            let pair = String(s[0...1])
            if ["kn", "gn", "pn", "wr", "ae"].contains(pair) { s.removeFirst() }
        }
        if s.first == "x" { s[0] = "s" }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        func at(_ i: Int) -> Character? { i >= 0 && i < s.count ? s[i] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { vowels.contains($0) } ?? false }

        var out = ""
        var i = 0
        while i < s.count {
            let c = s[i]
            let next = at(i + 1)
            let next2 = at(i + 2)

            // Doubled letters sound once (except "cc": "accept" = AKSPT).
            if c == at(i - 1) && c != "c" { i += 1; continue }

            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { out.append("A") }  // only a leading vowel counts
            case "b":
                // Silent in a trailing "mb" ("thumb").
                if !(at(i - 1) == "m" && next == nil) { out.append("B") }
            case "c":
                if at(i - 1) == "s" && next == "h" { out.append("K"); i += 1 }  // "school"
                else if next == "i" && next2 == "a" { out.append("X") }
                else if next == "h" { out.append("X"); i += 1 }
                else if next == "i" || next == "e" || next == "y" { out.append("S") }
                else { out.append("K") }
            case "d":
                if next == "g", let n2 = next2, "eiy".contains(n2) { out.append("J"); i += 1 }
                else { out.append("T") }
            case "g":
                if next == "h" && !isVowel(next2) && next2 != nil { i += 1 }        // "night"
                else if next == "n" && (next2 == nil || (next2 == "e" && at(i + 3) == "d")) { } // "sign", "signed"
                else if let n = next, "eiy".contains(n) { out.append("J") }
                else { out.append("K") }
            case "h":
                // Sounded only before a vowel and not after one.
                if isVowel(next) && !isVowel(at(i - 1)) { out.append("H") }
            case "k":
                if at(i - 1) != "c" { out.append("K") }
            case "p":
                if next == "h" { out.append("F"); i += 1 } else { out.append("P") }
            case "q":
                out.append("K")
            case "s":
                if next == "h" { out.append("X"); i += 1 }
                else if next == "i", let n2 = next2, "oa".contains(n2) { out.append("X") }
                else { out.append("S") }
            case "t":
                if next == "i", let n2 = next2, "oa".contains(n2) { out.append("X") }
                else if next == "h" { out.append("0"); i += 1 }
                else if !(next == "c" && next2 == "h") { out.append("T") }
            case "v":
                out.append("F")
            case "w", "y":
                if isVowel(next) { out.append(c == "w" ? "W" : "Y") }
            case "x":
                out.append("KS")
            case "z":
                out.append("S")
            default:  // f j l m n r
                out.append(Character(c.uppercased()))
            }
            i += 1
        }
        return out
    }

    /// Same sound, or — for codes of 4+ sounds — one sound apart
    /// ("super base" SPRBS ~ "Supabase" SPBS). Short codes must match
    /// exactly: one edit on "PP" would match nearly anything.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        return editDistance(a, b) <= 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}
```

- [ ] **Step 4: Run the scratch test — expect ALL PASS**

```bash
swiftc -parse-as-library Airboard/SoundCode.swift /private/tmp/vocabtest/soundcode_test.swift -o /private/tmp/vocabtest/soundcode_test && /private/tmp/vocabtest/soundcode_test
```
Expected: every line `PASS`, last line `ALL PASS`, exit 0. Each line shows both codes, e.g. `PASS for sell ~ Vercel [FRSL / FRSL]`.

- [ ] **Step 5: Build the app**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Airboard/SoundCode.swift
git commit -F - <<'EOF'
feat: SoundCode — Metaphone sound codes for vocabulary candidates (pure, scratch-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 2: SpellingRule + CandidateFinder

**Files:**
- Create: `Airboard/SpellingRule.swift`
- Create: `Airboard/CandidateFinder.swift`
- Test (scratch, not committed): `/private/tmp/vocabtest/units_test.swift`

**Interfaces:**
- Consumes: `SoundCode.code`, `SoundCode.soundsAlike` (Task 1).
- Produces: `SpellingRule(term:heardAs:)`, `.memoryLine`, `SpellingRule.parse(_ line: String) -> SpellingRule?`, `SpellingRule.rules(from memories: [String]) -> [SpellingRule]`; `Candidate { range: Range<String.Index>, span: String, term: String, source: Candidate.Source (.rule|.screen), exact: Bool }`; `CandidateFinder.find(in text: String, rules: [SpellingRule], screenTerms: [String]) -> [Candidate]` (≤5); `CandidateFinder.wordRanges(in:) -> [Range<String.Index>]`; `CandidateFinder.normalize(_:) -> String`; `CandidateFinder.isEmbedded(_:in:) -> Bool`.

- [ ] **Step 1: Write the failing scratch test** at `/private/tmp/vocabtest/units_test.swift`

```swift
import Foundation

@main struct UnitsTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { failures += 1 } }

        // SpellingRule
        let line = "\"Brite AI\" is the correct spelling — often heard as \"bright AI\"."
        let r = SpellingRule.parse(line)
        check("parse canonical", r == SpellingRule(term: "Brite AI", heardAs: "bright AI"))
        check("round trip", r.map { SpellingRule.parse($0.memoryLine) == $0 } ?? false)
        check("hyphen + no period", SpellingRule.parse("\"Alisha\" is the correct spelling - often heard as \"a lisha\"") != nil)
        check("curly quotes", SpellingRule.parse("\u{201C}Parakeet\u{201D} is the correct spelling — often heard as \u{201C}paraket\u{201D}.") != nil)
        check("ordinary memory is not a rule", SpellingRule.parse("Cait is my colleague.") == nil)
        check("same term/heard rejected", SpellingRule.parse("\"Brite\" is the correct spelling — often heard as \"brite\".") == nil)
        check("rules(from:) dedups + skips facts",
              SpellingRule.rules(from: [line, line, "My friend's name is Alisha."]).count == 1)

        let rules = [SpellingRule(term: "Brite AI", heardAs: "bright AI")]
        // CandidateFinder
        let c1 = CandidateFinder.find(in: "I work at bright AI as the CEO", rules: rules, screenTerms: [])
        check("exact rule match", c1.count == 1 && c1[0].span == "bright AI" && c1[0].exact && c1[0].source == .rule)
        let c2 = CandidateFinder.find(in: "Turn up the brightness today", rules: rules, screenTerms: [])
        check("word boundary: brightness untouched", c2.isEmpty)
        let c3 = CandidateFinder.find(in: "what a bright idea", rules: [SpellingRule(term: "Brite", heardAs: "brite")], screenTerms: [])
        check("sound-alike bright~Brite is a question", c3.count == 1 && c3[0].span == "bright" && !c3[0].exact)
        let c4 = CandidateFinder.find(in: "I use the paraket model", rules: [], screenTerms: ["Parakeet"])
        check("screen term candidate", c4.count == 1 && c4[0].term == "Parakeet" && c4[0].source == .screen)
        let c5 = CandidateFinder.find(in: "deploy it on for sell", rules: [], screenTerms: ["Vercel"])
        check("two words -> one term", c5.first?.span == "for sell")
        let c6 = CandidateFinder.find(in: "Brite AI is hiring", rules: rules, screenTerms: [])
        check("already-correct span skipped", c6.isEmpty)
        let c7 = CandidateFinder.find(in: "tell a lisha I'm late", rules: [], screenTerms: ["Alisha"])
        check("a lisha -> Alisha", c7.first?.span == "a lisha")
        let c8 = CandidateFinder.find(in: "Thanks, Alisha!", rules: [], screenTerms: ["Alisha"])
        check("exact term in text not re-asked", c8.isEmpty)
        let many = Array(repeating: "cloud", count: 12).joined(separator: " and ")
        check("cap at 5", CandidateFinder.find(in: many, rules: [], screenTerms: ["Claude"]).count == 5)
        check("empty text", CandidateFinder.find(in: "", rules: rules, screenTerms: ["X"]).isEmpty)
        check("wordRanges keeps CLAUDE.md and I'm",
              CandidateFinder.wordRanges(in: "edit CLAUDE.md, I'm done").count == 4)

        check("email/path/url never candidates",
              CandidateFinder.find(in: "see bright.io, mail bright@brite.com or open ~/bright/notes", rules: [], screenTerms: ["Brite"]).isEmpty)
        check("trailing punctuation still ok",
              CandidateFinder.find(in: "Ask bright AI, please.", rules: rules, screenTerms: []).first?.span == "bright AI")
        check("non-Latin text: no candidates, no crash",
              CandidateFinder.find(in: "नमस्ते 🙂 दोस्त", rules: rules, screenTerms: ["Brite"]).isEmpty)
        let longText = Array(repeating: "we should ship the new release to every customer before friday", count: 40).joined(separator: ". ")
        let t0 = Date()
        _ = CandidateFinder.find(in: longText, rules: rules, screenTerms: (0..<500).map { "Zq\($0)term" })
        check("worst case (no hits, 440 words x 500 terms) under 20ms", Date().timeIntervalSince(t0) < 0.02)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run it — expect a compile failure (types don't exist yet)**

```bash
mkdir -p /private/tmp/vocabtest && swiftc -parse-as-library Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift /private/tmp/vocabtest/units_test.swift -o /private/tmp/vocabtest/units_test 2>&1 | head -3
```
Expected: `error: ... No such file` / `cannot find ... in scope`.

- [ ] **Step 3: Create `Airboard/SpellingRule.swift`**

```swift
//
//  SpellingRule.swift
//
//  The one memory line that is applied locally: a confirmed spelling.
//  Format (the exact string MemoryBias.spellingMemory produces):
//    "Brite AI" is the correct spelling — often heard as "bright AI".
//  Every other memory line is NOT a rule and stays LLM-only.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct SpellingRule: Equatable, Hashable {
    let term: String     // correct spelling, e.g. "Brite AI"
    let heardAs: String  // how Parakeet writes it, e.g. "bright AI"

    /// The memory line for this rule — one shared phrasing with
    /// MemoryBias.spellingMemory, so card saves and voice teaching
    /// produce identical lines.
    var memoryLine: String {
        "\"\(term)\" is the correct spelling — often heard as \"\(heardAs)\"."
    }

    /// Lenient: em dash, en dash, or hyphen; optional trailing period;
    /// straight or curly quotes (hand edits in TextEdit curl them).
    static func parse(_ line: String) -> SpellingRule? {
        let normalized = line
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .trimmingCharacters(in: .whitespaces)
        let pattern = #"^"([^"]+)" is the correct spelling\s*[—–-]\s*often heard as "([^"]+)"\.?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let t = Range(m.range(at: 1), in: normalized),
              let h = Range(m.range(at: 2), in: normalized) else { return nil }
        let term = normalized[t].trimmingCharacters(in: .whitespaces)
        let heard = normalized[h].trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !heard.isEmpty, term.lowercased() != heard.lowercased() else { return nil }
        return SpellingRule(term: term, heardAs: heard)
    }

    static func rules(from memories: [String]) -> [SpellingRule] {
        var seen = Set<SpellingRule>()
        return memories.compactMap(parse).filter { seen.insert($0).inserted }
    }
}
```

- [ ] **Step 4: Create `Airboard/CandidateFinder.swift`**

```swift
//
//  CandidateFinder.swift
//
//  Finds spans of a transcript that MIGHT be a known term — the questions
//  to put to the decision engine. Never changes text itself.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct Candidate: Equatable {
    enum Source: Equatable { case rule, screen }
    let range: Range<String.Index>  // span in the transcript
    let span: String                // the text as heard, e.g. "bright AI"
    let term: String                // what it might be, e.g. "Brite AI"
    let source: Source
    let exact: Bool                 // span equals a confirmed rule's heardAs
}

nonisolated enum CandidateFinder {

    static let maxCandidates = 5
    static let maxWindow = 3

    /// Left-to-right, non-overlapping, at most 5. At each word: a confirmed
    /// exact phrase wins; else an identical sound code beats a one-sound-off
    /// code; ties go to the longest span. A span the text already spells
    /// correctly (any case) is skipped.
    static func find(in text: String, rules: [SpellingRule], screenTerms: [String]) -> [Candidate] {
        let words = wordRanges(in: text)
        guard !words.isEmpty else { return [] }

        var ruleByHeard: [String: SpellingRule] = [:]
        var byCode: [String: [(term: String, source: Candidate.Source)]] = [:]
        for r in rules {
            ruleByHeard[normalize(r.heardAs)] = r
            byCode[SoundCode.code(r.term), default: []].append((r.term, .rule))
        }
        let ruleTerms = Set(rules.map { $0.term.lowercased() })
        for t in screenTerms where !ruleTerms.contains(t.lowercased()) {
            byCode[SoundCode.code(t), default: []].append((t, .screen))
        }
        let codes = Array(byCode.keys)
        // Never touch emails, URLs, paths, file names: a word that sits in a
        // larger non-space chunk ("bright@brite.com", "~/bright/notes") or
        // contains a dot ("bright.io") is not a candidate.
        let embedded = words.map { isEmbedded($0, in: text) }

        var out: [Candidate] = []
        var i = 0
        while i < words.count && out.count < maxCandidates {
            if embedded[i] { i += 1; continue }
            var maxWidth = min(maxWindow, words.count - i)
            while maxWidth > 1 && embedded[i + maxWidth - 1] { maxWidth -= 1 }
            let rest = text[words[i].lowerBound...].lowercased()
            // The text already continues with the correct term here.
            func alreadyCorrect(_ term: String) -> Bool { rest.hasPrefix(term.lowercased()) }

            var best: (cand: Candidate, width: Int, rank: Int)?  // rank: 2 exact rule, 1 same code, 0 one edit
            for width in stride(from: maxWidth, through: 1, by: -1) {
                let range = words[i].lowerBound..<words[i + width - 1].upperBound
                let span = String(text[range])
                let key = normalize(span)
                if let r = ruleByHeard[key] {
                    best = (Candidate(range: range, span: span, term: r.term, source: .rule, exact: true), width, 2)
                    break  // a confirmed exact phrase always wins
                }
                let code = SoundCode.code(span)
                for hit in codes where SoundCode.soundsAlike(code, hit) {
                    let rank = hit == code ? 1 : 0
                    guard best == nil || rank > best!.rank,
                          let entry = byCode[hit]?.first(where: { normalize($0.term) != key && !alreadyCorrect($0.term) })
                    else { continue }
                    best = (Candidate(range: range, span: span, term: entry.term,
                                      source: entry.source, exact: false), width, rank)
                }
            }
            if let b = best {
                out.append(b.cand)
                i += b.width
            } else {
                i += 1
            }
        }
        return out
    }

    /// Ranges of word-like tokens (letters/digits, inner apostrophes and dots kept:
    /// "I'm", "CLAUDE.md").
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var idx = text.startIndex
        while idx < text.endIndex {
            let c = text[idx]
            let next = text.index(after: idx)
            let inner = (c == "'" || c == ".") && start != nil
                && next < text.endIndex && (text[next].isLetter || text[next].isNumber)
            if c.isLetter || c.isNumber || inner {
                if start == nil { start = idx }
            } else if let s = start {
                ranges.append(s..<idx); start = nil
            }
            idx = next
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    static func isEmbedded(_ word: Range<String.Index>, in text: String) -> Bool {
        if text[word].contains(".") { return true }
        var lo = word.lowerBound, hi = word.upperBound
        while lo > text.startIndex, !text[text.index(before: lo)].isWhitespace { lo = text.index(before: lo) }
        while hi < text.endIndex, !text[hi].isWhitespace { hi = text.index(after: hi) }
        let edge = CharacterSet(charactersIn: "\"'()[]{},.!?;:")
        let chunk = String(text[lo..<hi]).trimmingCharacters(in: edge)
        return chunk != String(text[word])
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
```

- [ ] **Step 5: Run the scratch test — expect ALL PASS**

```bash
swiftc -parse-as-library Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift /private/tmp/vocabtest/units_test.swift -o /private/tmp/vocabtest/units_test && /private/tmp/vocabtest/units_test
```
Expected: every line `PASS`, last line `ALL PASS`, exit 0. The `worst case` line proves 440 words × 500 terms stays under 20ms (measured ~1ms).

- [ ] **Step 6: Make `MemoryBias.spellingMemory` delegate to `SpellingRule`** (one phrasing, one place) — in `Airboard/MemoryBias.swift` replace

```swift
    static func spellingMemory(term: String, heardAs: String) -> String {
        "\"\(term)\" is the correct spelling — often heard as \"\(heardAs)\"."
    }
```

with

```swift
    static func spellingMemory(term: String, heardAs: String) -> String {
        SpellingRule(term: term, heardAs: heardAs).memoryLine
    }
```

(MemoryBias has no MemoryBias tests to break; the round-trip test above pins the string.)

- [ ] **Step 7: Build the app**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Airboard/SpellingRule.swift Airboard/CandidateFinder.swift Airboard/MemoryBias.swift
git commit -F - <<'EOF'
feat: SpellingRule + CandidateFinder — confirmed spellings and sound-alike candidates (pure, scratch-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 3: EditDiff — spot a small fix the user made

**Files:**
- Create: `Airboard/EditDiff.swift`
- Test (scratch, not committed): `/private/tmp/vocabtest/editdiff_test.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `EditDiff.correction(before: String, after: String, inserted: String) -> EditDiff.Correction?`, `EditDiff.Correction { heard: String, corrected: String }`.

- [ ] **Step 1: Write the failing scratch test** at `/private/tmp/vocabtest/editdiff_test.swift`

```swift
import Foundation

@main struct EditDiffTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ got: EditDiff.Correction?, _ want: EditDiff.Correction?) {
            let ok = got == want
            print(ok ? "PASS" : "FAIL", name, ok ? "" : "got \(String(describing: got))")
            if !ok { failures += 1 }
        }
        let C = EditDiff.Correction.init
        let ins = "bright AI is hiring engineers."
        check("one word", EditDiff.correction(before: "Hi. " + ins, after: "Hi. Brite AI is hiring engineers.", inserted: ins), C("bright", "Brite"))
        let ins2 = "tell a lisha I'm late"
        check("two words -> one", EditDiff.correction(before: ins2, after: "tell Alisha I'm late", inserted: ins2), C("a lisha", "Alisha"))
        let ins3 = "deploy it on for sell today"
        check("for sell -> Vercel", EditDiff.correction(before: ins3, after: "deploy it on Vercel today", inserted: ins3), C("for sell", "Vercel"))
        check("mid-word fix expands to word", EditDiff.correction(before: "use the paraket model", after: "use the parakeet model", inserted: "use the paraket model"), C("paraket", "parakeet"))
        check("case-only change ignored", EditDiff.correction(before: "bright ai rocks", after: "Bright AI rocks", inserted: "bright ai rocks"), nil)
        check("big rewrite ignored", EditDiff.correction(before: "one two three four five six", after: "seven eight nine ten eleven twelve", inserted: "one two three four five six"), nil)
        check("pure deletion ignored", EditDiff.correction(before: "a very big dog", after: "a big dog", inserted: "a very big dog"), nil)
        check("pure insertion ignored", EditDiff.correction(before: "a big dog", after: "a very big dog", inserted: "a big dog"), nil)
        check("edit outside insertion ignored", EditDiff.correction(before: "Dear Bob, thanks", after: "Dear Rob, thanks", inserted: "thanks"), nil)
        check("unchanged", EditDiff.correction(before: "same", after: "same", inserted: "same"), nil)
        check("number swap ignored (no letters)", EditDiff.correction(before: "pay 10 now", after: "pay 20 now", inserted: "pay 10 now"), nil)
        check("insertion missing from before", EditDiff.correction(before: "abc", after: "abd", inserted: "zzz"), nil)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run it — expect a compile failure (types don't exist yet)**

```bash
mkdir -p /private/tmp/vocabtest && swiftc -parse-as-library Airboard/EditDiff.swift /private/tmp/vocabtest/editdiff_test.swift -o /private/tmp/vocabtest/editdiff_test 2>&1 | head -3
```
Expected: `error: ... No such file` / `cannot find ... in scope`.

- [ ] **Step 3: Create `Airboard/EditDiff.swift`**

```swift
//
//  EditDiff.swift
//
//  Spots a small word fix the user made inside text Airboard just
//  inserted: "bright AI is hiring" -> "Brite AI is hiring" gives
//  (heard: "bright", corrected: "Brite"). Handles 2-words-to-1
//  ("a lisha" -> "Alisha"). Anything bigger than a 3-word swap,
//  or outside our insertion, teaches nothing.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated enum EditDiff {

    struct Correction: Equatable {
        let heard: String      // what Airboard typed
        let corrected: String  // what the user changed it to
    }

    static let maxWords = 3

    /// - before: the field's full text right after our insertion
    /// - after:  the field's full text now
    /// - inserted: the text we inserted (must appear in `before`)
    static func correction(before: String, after: String, inserted: String) -> Correction? {
        guard before != after,
              let insRange = before.range(of: inserted, options: .backwards) else { return nil }
        let b = Array(before), a = Array(after)

        // Common prefix / suffix, in characters.
        var p = 0
        while p < b.count && p < a.count && b[p] == a[p] { p += 1 }
        var s = 0
        while s < b.count - p && s < a.count - p && b[b.count - 1 - s] == a[a.count - 1 - s] { s += 1 }

        // Expand the changed region outward to whole words on both sides.
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" }
        var bStart = p, aStart = p
        while bStart > 0 && isWordChar(b[bStart - 1]) { bStart -= 1; aStart -= 1 }
        var bEnd = b.count - s, aEnd = a.count - s
        while bEnd < b.count && isWordChar(b[bEnd]) { bEnd += 1; aEnd += 1 }

        // The change must sit inside what we inserted.
        let insStart = before.distance(from: before.startIndex, to: insRange.lowerBound)
        let insEnd = before.distance(from: before.startIndex, to: insRange.upperBound)
        guard bStart >= insStart, bEnd <= insEnd, aStart <= aEnd else { return nil }

        let heard = String(b[bStart..<bEnd]).trimmingCharacters(in: .whitespaces)
        let corrected = String(a[aStart..<aEnd]).trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !corrected.isEmpty,
              heard.lowercased() != corrected.lowercased() else { return nil }

        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " .'-"))
        func ok(_ t: String) -> Bool {
            t.unicodeScalars.allSatisfy { allowed.contains($0) }
                && t.split(separator: " ").count <= maxWords
                && t.contains(where: { $0.isLetter })
        }
        guard ok(heard), ok(corrected) else { return nil }

        // Whole words added or removed ("a very big dog" -> "a big dog")
        // is an edit of content, not a spelling fix.
        let hw = heard.lowercased().split(separator: " "), cw = corrected.lowercased().split(separator: " ")
        func contains(_ big: [Substring], _ small: [Substring]) -> Bool {
            guard small.count < big.count else { return false }
            return (0...(big.count - small.count)).contains { Array(big[$0..<($0 + small.count)]) == small }
        }
        if contains(hw, cw) || contains(cw, hw) { return nil }
        return Correction(heard: heard, corrected: corrected)
    }
}
```

- [ ] **Step 4: Run the scratch test — expect ALL PASS**

```bash
swiftc -parse-as-library Airboard/EditDiff.swift /private/tmp/vocabtest/editdiff_test.swift -o /private/tmp/vocabtest/editdiff_test && /private/tmp/vocabtest/editdiff_test
```
Expected: every line `PASS`, last line `ALL PASS`, exit 0.

- [ ] **Step 5: Build the app**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Airboard/EditDiff.swift
git commit -F - <<'EOF'
feat: EditDiff — detect a 1-3 word spelling fix inside inserted text (pure, scratch-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 4: Decision types + OpenRouter decision client

**Files:**
- Create: `Airboard/DecisionTypes.swift`
- Create: `Airboard/DecisionClient.swift`
- Test (scratch, not committed): `/private/tmp/vocabtest/client_test.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DecisionQuestion { id, state: [String: String], instructions, yesMeans, noMeans }` with factories `.applyTerm(id:sentence:span:term:)`, `.spellingFix(id:sentence:heard:corrected:)`, `.isTerm(id:term:)`; `DecisionWire.endpoint`, `DecisionWire.body(model:state:questions:) -> Data?`, `DecisionWire.parse(_ data: Data) -> [String: Double]`; `DecisionClient(apiKey: String)` with `ask(state: [String: String], questions: [DecisionQuestion], deadline: TimeInterval) async -> [String: Double]?` (nil = timeout/failure; never throws).

- [ ] **Step 1: Write the failing scratch test** at `/private/tmp/vocabtest/client_test.swift`

```swift
import Foundation

@main struct ClientTest {
    static func main() async {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { failures += 1 } }
        let s = "email bright AI about a bright idea"
        let qs = [DecisionQuestion.applyTerm(id: "q0", sentence: s, span: "bright AI", term: "Brite AI"),
                  DecisionQuestion.applyTerm(id: "q1", sentence: s, span: "bright", term: "Brite")]
        check("no key -> nil", await DecisionClient(apiKey: "").ask(state: ["sentence": s], questions: qs, deadline: 1) == nil)
        check("no questions -> nil", await DecisionClient(apiKey: "x").ask(state: [:], questions: [], deadline: 1) == nil)
        let bad = DecisionClient(apiKey: "sk-or-v1-invalid")
        let t0 = Date()
        let badResult = await bad.ask(state: ["sentence": s], questions: qs, deadline: 2)
        check("bad key -> nil (both models tried, no crash)", badResult == nil)
        print("  bad key took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] else { print("skip live"); exit(failures == 0 ? 0 : 1) }
        let c = DecisionClient(apiKey: key)
        let t1 = Date()
        let tiny = await c.ask(state: ["sentence": s], questions: qs, deadline: 0.01)
        let tinyMs = Int(Date().timeIntervalSince(t1) * 1000)
        check("10ms deadline -> nil fast (\(tinyMs)ms)", tiny == nil && tinyMs < 100)
        var lat: [Int] = []; var last: [String: Double]?
        for _ in 0..<6 {
            let t = Date(); last = await c.ask(state: ["sentence": s], questions: qs, deadline: 0.35)
            lat.append(Int(Date().timeIntervalSince(t) * 1000))
        }
        print("  350ms deadline x6: \(lat)ms, last answers \(String(describing: last))")
        check("never exceeds deadline (+20ms slack)", lat.allSatisfy { $0 <= 370 })
        let full = await c.ask(state: ["sentence": s], questions: qs, deadline: 5)
        check("generous deadline answers both", full?.count == 2)
        check("bright AI -> yes, bright idea -> no", (full?["q0"] ?? 0) >= 0.5 && (full?["q1"] ?? 1) < 0.5)
        print("  answers: \(String(describing: full))")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run it — expect a compile failure (types don't exist yet)**

```bash
mkdir -p /private/tmp/vocabtest && swiftc -parse-as-library Airboard/DecisionTypes.swift Airboard/DecisionClient.swift /private/tmp/vocabtest/client_test.swift -o /private/tmp/vocabtest/client_test 2>&1 | head -3
```
Expected: `error: ... No such file` / `cannot find ... in scope`.

- [ ] **Step 3: Create `Airboard/DecisionTypes.swift`**

```swift
//
//  DecisionTypes.swift
//
//  Yes/no questions for a decision model, and the wire format of the
//  OpenRouter Decisions API (Jev, Mercury Decide share it). Pure: builds
//  request bodies and parses replies; no networking here.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct DecisionQuestion: Equatable {
    let id: String                  // unique within one request, e.g. "q0"
    let state: [String: String]     // minimal context (Jev degrades with noise)
    let instructions: String
    let yesMeans: String
    let noMeans: String

    /// "Did the speaker mean <term> where it says <span>?" The prior ("a
    /// name this user often says") matters: without it Jev scored "email
    /// bright AI" → Brite AI at 0.40 (probe 2026-10-07); it doesn't know the
    /// term exists. Never send what the term IS — only that it's theirs.
    static func applyTerm(id: String, sentence: String, span: String, term: String) -> DecisionQuestion {
        DecisionQuestion(
            id: id,
            state: ["sentence": sentence],
            instructions: "Speech recognition transcribed this sentence. \"\(term)\" is a name or term this user often says, and the recognizer often mishears it. Did the speaker actually mean \"\(term)\" where it says \"\(span)\"?",
            yesMeans: "\"\(span)\" is a mishearing of the name or term \"\(term)\".",
            noMeans: "\"\(span)\" is meant literally as an ordinary word, not \"\(term)\".")
    }

    /// "Is <heard> -> <corrected> a spelling fix of the same word/name?"
    static func spellingFix(id: String, sentence: String, heard: String, corrected: String) -> DecisionQuestion {
        DecisionQuestion(
            id: id,
            state: ["sentence": sentence, "edit": "\"\(heard)\" -> \"\(corrected)\""],
            instructions: "The user edited words in text produced by speech recognition. Is the edit a spelling fix of the same intended word or name (the recognizer misheard it), rather than a change to a different word or meaning?",
            yesMeans: "Same intended word or name, corrected spelling.",
            noMeans: "A different word, value, or meaning.")
    }

    /// "Is <term> a real name or product/technical term?" (harvest filter)
    static func isTerm(id: String, term: String) -> DecisionQuestion {
        DecisionQuestion(
            id: id,
            state: ["word": term],
            instructions: "This word was seen on a computer screen. Is it a proper name, brand, product, or technical term that a speech recognizer could misspell — not a common English word, UI label, or ordinary capitalized word?",
            yesMeans: "A specific name, brand, product, or technical term.",
            noMeans: "A common word, menu/UI label, or ordinary capitalized word.")
    }
}

nonisolated enum DecisionWire {
    static let endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    /// One request = ONE shared context. Callers batch only questions about
    /// the same sentence (the dictation path always does); different
    /// contexts go in separate, concurrent requests — merging unrelated
    /// sentences into one state measurably hurt accuracy (probe 2026-10-07:
    /// "bright AI is hiring" fell from yes to 0.50 when batched with 4 others).
    static func body(model: String, state: [String: String], questions: [DecisionQuestion]) -> Data? {
        var qs: [String: Any] = [:]
        for q in questions {
            qs[q.id] = [
                "type": "noul",
                "instructions": q.instructions,
                "criteria": ["true": q.yesMeans, "false": q.noMeans],
            ]
        }
        return try? JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": qs])
    }

    /// Probability of "yes" per question id. Missing/malformed → absent
    /// (callers treat absent as "no").
    static func parse(_ data: Data) -> [String: Double] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (id, raw) in answers {
            if let a = raw as? [String: Any], let p = (a["noul"] as? NSNumber)?.doubleValue, (0...1).contains(p) {
                out[id] = p
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Create `Airboard/DecisionClient.swift`**

```swift
//
//  DecisionClient.swift
//
//  Calls the OpenRouter Decisions API (Jev first, Mercury Decide if Jev
//  errors with time left). Hard deadline: returns nil when the answer
//  can't arrive in time — the caller then falls back. Never throws.
//  The key is passed in (read from the Keychain by the caller); it is
//  never logged. Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct DecisionClient: Sendable {
    let apiKey: String
    var models: [String] = ["typesafe/jev-1.13", "inception/mercury-decide:free"]
    var session: URLSession = .shared

    /// Probability of "yes" per question id, or nil on timeout/failure.
    func ask(state: [String: String], questions: [DecisionQuestion], deadline: TimeInterval) async -> [String: Double]? {
        guard !questions.isEmpty, !apiKey.isEmpty else { return nil }
        let start = Date()
        return await withTaskGroup(of: [String: Double]?.self) { group in
            group.addTask {
                for model in models {
                    let left = deadline - Date().timeIntervalSince(start)
                    guard left > 0.05 else { return nil }
                    if let answers = await call(model: model, state: state, questions: questions, timeout: left),
                       !answers.isEmpty {
                        return answers
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func call(model: String, state: [String: String], questions: [DecisionQuestion],
                      timeout: TimeInterval) async -> [String: Double]? {
        guard let body = DecisionWire.body(model: model, state: state, questions: questions) else { return nil }
        var req = URLRequest(url: DecisionWire.endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://github.com/dhruvmehra/Airboard", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Airboard", forHTTPHeaderField: "X-Title")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return DecisionWire.parse(data)
    }
}
```

- [ ] **Step 5: Run the scratch test — expect ALL PASS**

```bash
swiftc -parse-as-library Airboard/DecisionTypes.swift Airboard/DecisionClient.swift /private/tmp/vocabtest/client_test.swift -o /private/tmp/vocabtest/client_test && /private/tmp/vocabtest/client_test
```
Expected: every line `PASS`, last line `ALL PASS`, exit 0. Without `OPENROUTER_API_KEY` the live section prints `skip live` (offline checks still run). With a key: `OPENROUTER_API_KEY=sk-or-… /private/tmp/vocabtest/client_test` — expect the 350ms-deadline latencies all ≤370ms and `bright AI -> yes, bright idea -> no` passing.

- [ ] **Step 6: Build the app**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Airboard/DecisionTypes.swift Airboard/DecisionClient.swift
git commit -F - <<'EOF'
feat: decision client — OpenRouter Decisions API (Jev, Mercury fallback) with hard deadline

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 5: Resolver, hidden cache data, card queue, term extractor (pure learning state)

**Files:**
- Create: `Airboard/VocabularyResolver.swift`
- Create: `Airboard/VocabularyCacheData.swift`
- Create: `Airboard/VocabularyCardQueue.swift`
- Create: `Airboard/TermExtractor.swift`
- Test (scratch, not committed): `/private/tmp/vocabtest/rest_test.swift`

**Interfaces:**
- Consumes: `Candidate`, `CandidateFinder.find/normalize/wordRanges`, `SpellingRule` (Task 2).
- Produces: `VocabularyResolver.resolve(text:candidates:answers:) -> VocabularyResolver.Result { text, applied, suggestions: [Candidate] }`, `applyThreshold = 0.5`, `suggestThreshold = 0.7`; `VocabularyCacheData` (Codable: `termCounts`, `termVerdicts`, `rejected`, `snoozedUntil`; `addSightings(_:)`, `screenTerms`, `unjudged(limit:)`, `isBlocked(heard:term:now:)`, `reject(heard:term:)`, `snooze(heard:term:now:)`, `static pairKey(heard:term:)`); `VocabularyCard { kind: .learned|.didYouMean, heard, term }`; `VocabularyCardQueue` (`enqueue(_:)`, `next(now:isRecording:) -> VocabularyCard?`, `dismissed()`); `TermExtractor.terms(in text: String) -> [String]`.

- [ ] **Step 1: Write the failing scratch test** at `/private/tmp/vocabtest/rest_test.swift`

```swift
import Foundation

@main struct RestTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { failures += 1 } }

        // Resolver
        let rules = [SpellingRule(term: "Brite AI", heardAs: "bright AI"), SpellingRule(term: "Brite", heardAs: "brite")]
        let t1 = "email bright AI about a bright idea"
        let c1 = CandidateFinder.find(in: t1, rules: rules, screenTerms: [])
        check("finder: two candidates", c1.count == 2)
        let r1 = VocabularyResolver.resolve(text: t1, candidates: c1, answers: ["q0": 0.74, "q1": 0.12])
        check("yes replaces, no keeps", r1.text == "email Brite AI about a bright idea" && r1.applied == 1)
        let r2 = VocabularyResolver.resolve(text: t1, candidates: c1, answers: nil)
        check("engine down: exact multi-word rule only", r2.text == "email Brite AI about a bright idea")
        let single = [SpellingRule(term: "Brite", heardAs: "bright")]
        let t2 = "what a bright idea"
        let r2b = VocabularyResolver.resolve(text: t2, candidates: CandidateFinder.find(in: t2, rules: single, screenTerms: []), answers: nil)
        check("engine down: single-word rule NOT applied", r2b.text == t2 && r2b.applied == 0)
        let r3 = VocabularyResolver.resolve(text: t1, candidates: c1, answers: [:])
        check("missing answers = no", r3.text == t1 && r3.applied == 0)
        let t4 = "I use the paraket model"
        let c4 = CandidateFinder.find(in: t4, rules: [], screenTerms: ["Parakeet"])
        let r4 = VocabularyResolver.resolve(text: t4, candidates: c4, answers: ["q0": 0.9])
        check("screen term -> suggestion, text unchanged", r4.text == t4 && r4.suggestions.count == 1)
        let r5 = VocabularyResolver.resolve(text: t4, candidates: c4, answers: ["q0": 0.6])
        check("screen term below 0.7 -> nothing", r5.suggestions.isEmpty)
        let r6 = VocabularyResolver.resolve(text: t4, candidates: c4, answers: nil)
        check("engine down: no suggestions", r6.suggestions.isEmpty && r6.text == t4)

        let twice = "bright AI and bright AI"
        let ct = CandidateFinder.find(in: twice, rules: rules, screenTerms: [])
        check("same span twice: both replaced",
              VocabularyResolver.resolve(text: twice, candidates: ct, answers: ["q0": 0.9, "q1": 0.9]).text == "Brite AI and Brite AI")

        // Cache
        var d = VocabularyCacheData()
        d.addSightings(["Parakeet", "Parakeet", "Edit"]); d.addSightings(["Parakeet", "Edit", "Edit"])
        check("unjudged needs 3 sightings", Set(d.unjudged(limit: 10)) == ["Parakeet", "Edit"])
        d.termVerdicts["parakeet"] = true; d.termVerdicts["edit"] = false
        check("screenTerms = judged real only", d.screenTerms == ["Parakeet"])
        let now = Date()
        d.reject(heard: "bright AI", term: "Brite AI")
        check("rejected blocked (case-insensitive)", d.isBlocked(heard: "Bright ai", term: "brite AI", now: now))
        d.snooze(heard: "paraket", term: "Parakeet", now: now)
        check("snoozed blocked now", d.isBlocked(heard: "paraket", term: "Parakeet", now: now))
        check("snooze expires", !d.isBlocked(heard: "paraket", term: "Parakeet", now: now.addingTimeInterval(8 * 86400)))
        var big = VocabularyCacheData()
        big.addSightings((0..<600).map { "Term\($0)" })
        check("prunes to 500", big.termCounts.count == 500)
        let json = try! JSONEncoder().encode(d)
        check("codable round trip", (try? JSONDecoder().decode(VocabularyCacheData.self, from: json)) == d)

        // Card queue
        var q = VocabularyCardQueue()
        let a = VocabularyCard(kind: .learned, heard: "bright AI", term: "Brite AI")
        q.enqueue(a); q.enqueue(a)
        check("dedupe", q.pending.count == 1)
        check("not while recording", q.next(now: now, isRecording: true) == nil)
        check("shows", q.next(now: now, isRecording: false) == a)
        q.enqueue(VocabularyCard(kind: .didYouMean, heard: "paraket", term: "Parakeet"))
        check("one at a time", q.next(now: now, isRecording: false) == nil)
        q.dismissed()
        check("next after dismiss", q.next(now: now, isRecording: false)?.term == "Parakeet")
        var q2 = VocabularyCardQueue()
        for i in 0..<6 { q2.enqueue(VocabularyCard(kind: .learned, heard: "h\(i)x", term: "T\(i)y")) }
        var shown = 0
        for _ in 0..<6 { if q2.next(now: now, isRecording: false) != nil { shown += 1; q2.dismissed() } }
        check("max 4 per hour", shown == 4)
        check("resumes after an hour", q2.next(now: now.addingTimeInterval(3601), isRecording: false) != nil)

        // Term extractor
        let screen = "Deploy the app on Vercel tonight.\nWe use TypeScript and CLAUDE.md files. Ask Claude Code to help.\nThe Edit menu"
        let terms = TermExtractor.terms(in: screen)
        check("finds Vercel", terms.contains("Vercel"))
        check("finds TypeScript", terms.contains("TypeScript"))
        check("finds CLAUDE.md", terms.contains("CLAUDE.md"))
        check("finds Claude Code run", terms.contains("Claude Code"))
        check("skips sentence-initial Deploy/We/Ask/The", !terms.contains("Deploy") && !terms.contains("We") && !terms.contains("The"))
        check("lowercase words skipped", !terms.contains("tonight"))
        check("empty", TermExtractor.terms(in: "").isEmpty)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 2: Run it — expect a compile failure (types don't exist yet)**

```bash
mkdir -p /private/tmp/vocabtest && swiftc -parse-as-library Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift Airboard/VocabularyResolver.swift Airboard/VocabularyCacheData.swift Airboard/VocabularyCardQueue.swift Airboard/TermExtractor.swift /private/tmp/vocabtest/rest_test.swift -o /private/tmp/vocabtest/rest_test 2>&1 | head -3
```
Expected: `error: ... No such file` / `cannot find ... in scope`.

- [ ] **Step 3: Create `Airboard/VocabularyResolver.swift`**

```swift
//
//  VocabularyResolver.swift
//
//  Turns decision-engine answers into the final text. Pure: no I/O.
//  answers == nil means the engine was unreachable (no key, timeout,
//  error): only confirmed EXACT, MULTI-WORD rules apply then ("bright AI",
//  "a lisha") — a single common word ("bright") needs context, so it stays
//  as spoken rather than turning "a bright idea" into "a Brite idea".
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated enum VocabularyResolver {

    /// Confirmed rules: the user already approved these, and the probe
    /// separated yes (≥0.62) from no (≤0.22) cleanly at 0.5.
    static let applyThreshold = 0.5
    /// Screen terms create NEW suggestions — stricter.
    static let suggestThreshold = 0.7

    struct Result: Equatable {
        let text: String
        let applied: Int
        let suggestions: [Candidate]   // screen terms Jev believed: "Did you mean…?"
    }

    /// answers are keyed by candidate index ("q0", "q1", …).
    static func resolve(text: String, candidates: [Candidate], answers: [String: Double]?) -> Result {
        var replacements: [(Range<String.Index>, String)] = []
        var suggestions: [Candidate] = []
        for (i, c) in candidates.enumerated() {
            guard let answers else {
                if c.source == .rule && c.exact && c.span.split(separator: " ").count >= 2 {
                    replacements.append((c.range, c.term))
                }
                continue
            }
            let p = answers["q\(i)"] ?? 0
            switch c.source {
            case .rule where p >= applyThreshold:
                replacements.append((c.range, c.term))
            case .screen where p >= suggestThreshold:
                suggestions.append(c)
            default:
                break
            }
        }
        var out = text
        // Back to front so earlier ranges stay valid.
        for (range, term) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: term)
        }
        return Result(text: out, applied: replacements.count, suggestions: suggestions)
    }
}
```

- [ ] **Step 4: Create `Airboard/VocabularyCacheData.swift`**

```swift
//
//  VocabularyCacheData.swift
//
//  The hidden, non-user-facing learning state: harvested screen terms,
//  per-term "is this a real term?" verdicts, and pairs the user rejected.
//  Pure value type (Codable); VocabularyCache persists it. Confirmed
//  rules never live here — they live in memory.md.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct VocabularyCacheData: Codable, Equatable {
    var termCounts: [String: Int] = [:]     // term as seen -> sightings
    var termVerdicts: [String: Bool] = [:]  // lowercased term -> real term?
    var rejected: Set<String> = []          // pairKey: Undo / No — never ask again
    var snoozedUntil: [String: Date] = [:]  // pairKey: ignored "Did you mean"

    static let maxTerms = 500
    static let minSightings = 3
    static let snooze: TimeInterval = 7 * 24 * 3600

    static func pairKey(heard: String, term: String) -> String {
        CandidateFinder.normalize(heard) + "→" + CandidateFinder.normalize(term)
    }

    mutating func addSightings(_ terms: [String]) {
        for t in terms { termCounts[t, default: 0] += 1 }
        guard termCounts.count > Self.maxTerms else { return }
        let keep = termCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.maxTerms)
        termCounts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// Seen often enough and judged a real term.
    var screenTerms: [String] {
        termCounts.filter { $0.value >= Self.minSightings && termVerdicts[$0.key.lowercased()] == true }
            .sorted { $0.value > $1.value }.map(\.key)
    }

    /// Seen often enough, not yet judged — the harvester asks about these.
    func unjudged(limit: Int) -> [String] {
        Array(termCounts.filter { $0.value >= Self.minSightings && termVerdicts[$0.key.lowercased()] == nil }
            .sorted { $0.value > $1.value }.map(\.key).prefix(limit))
    }

    func isBlocked(heard: String, term: String, now: Date) -> Bool {
        let k = Self.pairKey(heard: heard, term: term)
        if rejected.contains(k) { return true }
        if let until = snoozedUntil[k], until > now { return true }
        return false
    }

    mutating func reject(heard: String, term: String) {
        rejected.insert(Self.pairKey(heard: heard, term: term))
    }

    mutating func snooze(heard: String, term: String, now: Date) {
        snoozedUntil[Self.pairKey(heard: heard, term: term)] = now.addingTimeInterval(Self.snooze)
    }
}
```

- [ ] **Step 5: Create `Airboard/VocabularyCardQueue.swift`**

```swift
//
//  VocabularyCardQueue.swift
//
//  Which confirm card to show next: one at a time, never while
//  recording, at most 4 per rolling hour, no duplicate pairs queued.
//  Pure: the caller supplies the clock. Foundation-only.
//

import Foundation

nonisolated struct VocabularyCard: Equatable {
    enum Kind: Equatable { case learned, didYouMean }
    let kind: Kind
    let heard: String     // "bright AI"
    let term: String      // "Brite AI"
}

nonisolated struct VocabularyCardQueue {
    static let maxPerHour = 4
    private(set) var pending: [VocabularyCard] = []
    private(set) var shownAt: [Date] = []
    private(set) var showing: VocabularyCard?

    mutating func enqueue(_ card: VocabularyCard) {
        let key = VocabularyCacheData.pairKey(heard: card.heard, term: card.term)
        let dup = (pending + (showing.map { [$0] } ?? []))
            .contains { VocabularyCacheData.pairKey(heard: $0.heard, term: $0.term) == key }
        if !dup { pending.append(card) }
    }

    /// The card to present now, or nil. Marks it as showing.
    mutating func next(now: Date, isRecording: Bool) -> VocabularyCard? {
        guard showing == nil, !isRecording, !pending.isEmpty else { return nil }
        shownAt = shownAt.filter { now.timeIntervalSince($0) < 3600 }
        guard shownAt.count < Self.maxPerHour else { return nil }
        let card = pending.removeFirst()
        shownAt.append(now)
        showing = card
        return card
    }

    mutating func dismissed() { showing = nil }
}
```

- [ ] **Step 6: Create `Airboard/TermExtractor.swift`**

```swift
//
//  TermExtractor.swift
//
//  Pulls candidate names/terms out of on-screen text for the harvester:
//  capitalized words not starting a sentence, CamelCase ("TypeScript",
//  "iPhone"), dotted tech names ("CLAUDE.md"), and runs of 2-3 such words
//  ("Claude Code"). Over-collects on purpose — the decision engine filters
//  junk before anything is suggested. Foundation-only.
//

import Foundation

nonisolated enum TermExtractor {

    static let maxTermsPerRead = 200

    static func terms(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ t: String) {
            guard t.count >= 3, t.count <= 40, seen.insert(t).inserted else { return }
            out.append(t)
        }
        for line in text.components(separatedBy: .newlines) {
            let ranges = CandidateFinder.wordRanges(in: line)
            var run: [String] = []
            var runStartsSentence = false
            func flush() {
                if run.count >= 2 { add(run.prefix(3).joined(separator: " ")) }
                // "Ask Claude Code" → also "Claude Code": a sentence-initial
                // word may just be an ordinary capitalized word.
                if runStartsSentence && run.count >= 3 { add(run.dropFirst().prefix(3).joined(separator: " ")) }
                run = []
                runStartsSentence = false
            }
            for (i, r) in ranges.enumerated() {
                let w = String(line[r])
                let sentenceStart = i == 0 || line[..<r.lowerBound]
                    .trimmingCharacters(in: .whitespaces).last.map { ".!?:".contains($0) } ?? true
                if isTechy(w) {
                    add(w); run.append(w)
                } else if isCapitalized(w) && !sentenceStart {
                    add(w); run.append(w)
                } else if isCapitalized(w) {
                    flush()
                    run = [w]       // may still start a multi-word name
                    runStartsSentence = true
                } else {
                    flush()
                }
            }
            flush()
            if out.count >= maxTermsPerRead { break }
        }
        return Array(out.prefix(maxTermsPerRead))
    }

    static func isCapitalized(_ w: String) -> Bool {
        guard let f = w.first, f.isUppercase, w.count > 1 else { return false }
        return w.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" }
    }

    /// CamelCase / inner capitals ("TypeScript", "iPhone") or dotted ("CLAUDE.md").
    static func isTechy(_ w: String) -> Bool {
        let letters = w.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        if w.contains(".") { return true }
        let innerUpper = w.dropFirst().contains(where: \.isUppercase)
        let hasLower = w.contains(where: \.isLowercase)
        return innerUpper && hasLower
    }
}
```

- [ ] **Step 7: Run the scratch test — expect ALL PASS**

```bash
swiftc -parse-as-library Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift Airboard/VocabularyResolver.swift Airboard/VocabularyCacheData.swift Airboard/VocabularyCardQueue.swift Airboard/TermExtractor.swift /private/tmp/vocabtest/rest_test.swift -o /private/tmp/vocabtest/rest_test && /private/tmp/vocabtest/rest_test
```
Expected: every line `PASS`, last line `ALL PASS`, exit 0.

- [ ] **Step 8: Build the app**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Airboard/VocabularyResolver.swift Airboard/VocabularyCacheData.swift Airboard/VocabularyCardQueue.swift Airboard/TermExtractor.swift
git commit -F - <<'EOF'
feat: vocabulary resolver, cache data, card queue, term extractor (pure, scratch-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 6: App integration — dictation path, watcher, harvester, confirm card

One build unit: these files reference each other (`VocabularyLearning` ↔ `VocabularyHarvester`, `CorrectionWatcher`, `VocabularyCardPresenter`), so they land together. Logic is already pinned by Tasks 1–5; this task is wiring, AX, and UI — verified by build + the manual checks in Task 7.

**Files:**
- Create: `Airboard/AXText.swift`, `Airboard/VocabularyCache.swift`, `Airboard/CorrectionWatcher.swift`, `Airboard/VocabularyHarvester.swift`, `Airboard/VocabularyCardView.swift`, `Airboard/VocabularyLearning.swift`
- Modify: `Airboard/FloatingWindowManager.swift` (`activeScreen` visibility), `Airboard/PerformanceLog.swift` (`DictationRecord`), `Airboard/TranscriptPostProcessor.swift` (`ProcessOutcome`, `process`), `Airboard/TranscriptionCoordinator.swift` (4 hooks), `Airboard/AirboardApp.swift` (start at launch)

**Interfaces:**
- Consumes: everything from Tasks 1–5; `KeychainHelper.readAPIKey(forHost:)`, `AssistantService.openRouterHost`, `MemoryStore.shared.memories/addMemory(_:)`, `TranscriptionCoordinator.shared.isRecording`, `FloatingWindowManager.shared.activeScreen`.
- Produces: `VocabularyLearning.shared` with `isEnabled`, `setEnabled(_:)`, `start()`, `client() -> DecisionClient?`, `process(_ text: String, useEngine: Bool) async -> VocabOutcome`, `recordingStarted()`, `didInsert(_ text: String, pid: pid_t)`; `VocabOutcome { text, ms: Int?, outcome: String }`; `ProcessOutcome.vocabMs/vocabOutcome`; `DictationRecord.vocabMs/vocabOutcome`. Task 7's settings UI uses `isEnabled`/`setEnabled`.


- [ ] **Step 1: Create `Airboard/AXText.swift`** — Accessibility helpers (focused field text, bounded window text, one in-place replace; secure fields never read)

```swift
//
//  AXText.swift
//
//  Read-only-by-default Accessibility helpers for vocabulary learning:
//  the focused field's text, a bounded walk of the focused window's text,
//  and a single in-place word replacement. Secure (password) fields are
//  never read. Uses the Accessibility permission Airboard already holds —
//  no keystroke capture.
//

import AppKit
import ApplicationServices

enum AXText {

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// The focused field's full text; nil if unreadable or secure.
    static func focusedFieldText(pid: pid_t) -> String? {
        guard let el = focusedElement(pid: pid), !isSecure(el) else { return nil }
        return string(el, kAXValueAttribute)
    }

    /// Replace the LAST occurrence of `span` in the focused field with `term`
    /// by selecting it and setting the selected text. Returns false (and
    /// changes nothing) when the app doesn't allow it.
    @discardableResult
    static func replaceInFocusedField(span: String, with term: String, pid: pid_t) -> Bool {
        guard let el = focusedElement(pid: pid), !isSecure(el),
              let text = string(el, kAXValueAttribute),
              let r = text.range(of: span, options: .backwards) else { return false }
        let ns = NSRange(r, in: text)
        var cf = CFRange(location: ns.location, length: ns.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
              AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, term as CFString) == .success
        else { return false }
        return true
    }

    /// Visible text of the focused window: a breadth-first walk collecting
    /// AXValue/AXTitle/AXDescription strings, skipping secure fields.
    /// Bounded (nodes and characters) so a huge web page can't stall us.
    static func windowText(pid: pid_t, maxNodes: Int = 1500, maxChars: Int = 20_000) -> String {
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return "" }
        var queue: [AXUIElement] = [window as! AXUIElement]
        var parts: [String] = []
        var chars = 0, visited = 0
        while !queue.isEmpty && visited < maxNodes && chars < maxChars {
            let el = queue.removeFirst()
            visited += 1
            if isSecure(el) { continue }
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = string(el, attr), !s.isEmpty {
                    parts.append(s); chars += s.count
                }
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let children = kids as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return String(parts.joined(separator: "\n").prefix(maxChars))
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
```


- [ ] **Step 2: Create `Airboard/VocabularyCache.swift`** — persists `VocabularyCacheData` to App Support `vocabulary-cache.json`

```swift
//
//  VocabularyCache.swift
//
//  Persists VocabularyCacheData as JSON in App Support
//  (vocabulary-cache.json). Hidden learning state only — clearing it just
//  resets suggestions; confirmed rules live in memory.md.
//

import Foundation

final class VocabularyCache {
    static let shared = VocabularyCache()

    private(set) var data: VocabularyCacheData
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(VocabularyCacheData.self, from: raw) {
            data = decoded
        } else {
            data = VocabularyCacheData()
        }
    }

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary-cache.json")
    }

    func update(_ change: (inout VocabularyCacheData) -> Void) {
        change(&data)
        do {
            try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ vocabulary cache save failed: \(error.localizedDescription)")
        }
    }
}
```


- [ ] **Step 3: Create `Airboard/CorrectionWatcher.swift`** — re-reads the field at 2/5/10s after insertion

```swift
//
//  CorrectionWatcher.swift
//
//  After an insertion, re-reads the same field at ~2s, 5s and 10s. If the
//  user fixed a word or two inside what we typed, hands the correction to
//  VocabularyLearning. Stops on app switch, a new recording, a learned
//  correction, or an unreadable/secure field (terminals: nothing happens).
//

import AppKit

final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    private var generation = 0
    static let checkDelays: [TimeInterval] = [2, 5, 10]

    func cancel() { generation += 1 }

    func observe(inserted: String, pid: pid_t, onCorrection: @escaping (EditDiff.Correction) -> Void) {
        generation += 1
        let gen = generation
        // Snapshot once the insertion has landed (paste restores the
        // clipboard at 0.5s; typed text is already there).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, gen == self.generation,
                  let before = AXText.focusedFieldText(pid: pid),
                  before.contains(inserted) else { return }
            for delay in Self.checkDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, gen == self.generation,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                          !TranscriptionCoordinator.shared.isRecording,
                          let after = AXText.focusedFieldText(pid: pid) else { return }
                    if let c = EditDiff.correction(before: before, after: after, inserted: inserted) {
                        self.generation += 1   // one lesson per insertion
                        onCorrection(c)
                    }
                }
            }
        }
    }
}
```


- [ ] **Step 4: Create `Airboard/VocabularyHarvester.swift`** — 30s screen-term harvest + per-term judging

```swift
//
//  VocabularyHarvester.swift
//
//  Every ~30s, reads the frontmost app's window text (never secure
//  fields, never Airboard itself, never while recording) and counts
//  candidate terms into VocabularyCache. Terms seen 3+ times get one
//  decision-engine check ("real name/term, or junk?"), cached forever.
//  Everything stays on this Mac except that one word per check.
//

import AppKit

final class VocabularyHarvester {
    static let shared = VocabularyHarvester()

    static let interval: TimeInterval = 30
    static let judgePerTick = 5
    private var timer: Timer?
    private var judging = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard VocabularyLearning.shared.isEnabled,
              !TranscriptionCoordinator.shared.isRecording,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let text = AXText.windowText(pid: app.processIdentifier)
        let terms = TermExtractor.terms(in: text)
        if !terms.isEmpty {
            VocabularyCache.shared.update { $0.addSightings(terms) }
        }
        judgePending()
    }

    private func judgePending() {
        guard !judging, let client = VocabularyLearning.shared.client() else { return }
        let pending = VocabularyCache.shared.data.unjudged(limit: Self.judgePerTick)
        guard !pending.isEmpty else { return }
        judging = true
        Task {
            // One request per term: different contexts never share a state.
            var verdicts: [String: Bool] = [:]
            await withTaskGroup(of: (String, Double?).self) { group in
                for term in pending {
                    group.addTask {
                        let q = DecisionQuestion.isTerm(id: "q0", term: term)
                        let a = await client.ask(state: q.state, questions: [q], deadline: 5)
                        return (term, a?["q0"])
                    }
                }
                for await (term, p) in group {
                    if let p { verdicts[term.lowercased()] = p >= VocabularyResolver.suggestThreshold }
                }
            }
            await MainActor.run {
                VocabularyCache.shared.update { d in
                    for (k, v) in verdicts { d.termVerdicts[k] = v }
                }
                self.judging = false
            }
        }
    }
}
```


- [ ] **Step 5: Create `Airboard/VocabularyCardView.swift`** — the card + a never-key, non-activating panel presenter

```swift
//
//  VocabularyCardView.swift
//
//  The vocabulary confirm card. MUST NOT take focus: the user keeps
//  typing while it's up (unlike MemoryConfirmView, which is key-accepting).
//  Non-activating, never-key panel; buttons accept the first click.
//  Ignored for 8s → .ignored (Learned = Keep, Did you mean = snooze).
//

import SwiftUI
import AppKit

struct VocabularyCardView: View {
    let card: VocabularyCard
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(DS.Tint.purple).frame(width: 24, height: 24)
                Image(systemName: card.kind == .learned ? "brain" : "questionmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Accent.command)
            }
            Group {
                if card.kind == .learned {
                    Text("Learned: \(card.heard) → ") + Text(card.term).bold()
                } else {
                    Text("Did you mean ") + Text(card.term).bold() + Text("?")
                }
            }
            .font(.system(size: 12))
            .foregroundColor(DS.Label.primary)
            .lineLimit(2)
            .frame(maxWidth: 300, alignment: .leading)
            Button(card.kind == .learned ? "Undo" : "No", action: onSecondary)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Label.secondary)
            Button(card.kind == .learned ? "Keep" : "Yes", action: onPrimary)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Label.onAccent)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Accent.primary))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous).fill(DS.Surface.hud))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous)
            .strokeBorder(DS.Surface.hudBorder, lineWidth: 1))
        .fixedSize()
    }
}

/// Never becomes key → the user's app keeps keyboard focus.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click without activating Airboard.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class VocabularyCardPresenter {
    static let shared = VocabularyCardPresenter()
    static let ignoreAfter: TimeInterval = 8

    private var panel: NSPanel?
    private var generation = 0

    func show(_ card: VocabularyCard, onChoice: @escaping (VocabularyCardChoice) -> Void) {
        dismiss()
        generation += 1
        let gen = generation
        var answered = false
        let finish: (VocabularyCardChoice) -> Void = { [weak self] choice in
            guard !answered, let self, gen == self.generation else { return }
            answered = true
            self.dismiss()
            onChoice(choice)
        }
        guard let screen = FloatingWindowManager.shared.activeScreen ?? NSScreen.main else { return }
        let hosting = FirstMouseHostingView(rootView: VocabularyCardView(
            card: card, onPrimary: { finish(.primary) }, onSecondary: { finish(.secondary) }))
        let size = hosting.fittingSize
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                           y: screen.visibleFrame.maxY - size.height - 16,
                           width: size.width, height: size.height)
        let p = NonKeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ignoreAfter) { finish(.ignored) }
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}
```


- [ ] **Step 6: Create `Airboard/VocabularyLearning.swift`** — the orchestrator

```swift
//
//  VocabularyLearning.swift
//
//  The self-learning vocabulary feature, in one place:
//  - process(): dictation path. Finds candidates, asks the decision
//    engine once (350ms hard limit), applies confirmed spellings in
//    context. +0ms when the text holds no candidate.
//  - didInsert(): queues "Did you mean" cards and starts the
//    CorrectionWatcher on the field we just typed into.
//  - cards: Keep/Undo (Learned; ignored = Keep), Yes/No (Did you mean;
//    ignored = snoozed). Keep/Yes write a SpellingRule line to memory.md.
//  Spec: docs/superpowers/specs/2026-10-07-self-learning-vocabulary-design.md
//

import AppKit

struct VocabOutcome {
    let text: String
    let ms: Int?          // nil when the engine wasn't called
    let outcome: String   // off | none | nokey | ok | applied | timeout
}

enum VocabularyCardChoice { case primary, secondary, ignored }

final class VocabularyLearning {
    static let shared = VocabularyLearning()

    static let enabledKey = "vocabLearningEnabled"
    static let deadline: TimeInterval = 0.35
    static let backgroundDeadline: TimeInterval = 5

    private var pendingSuggestions: [VocabularyCard] = []
    private var queue = VocabularyCardQueue()
    private var lastInsertPID: pid_t?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            VocabularyHarvester.shared.start()
        } else {
            VocabularyHarvester.shared.stop()
            CorrectionWatcher.shared.cancel()
        }
    }

    /// Call once at launch.
    func start() {
        if isEnabled { VocabularyHarvester.shared.start() }
    }

    /// BYOK: the OpenRouter key the Assistant already uses. nil = no key.
    func client() -> DecisionClient? {
        guard let key = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return DecisionClient(apiKey: key)
    }

    // MARK: - Dictation path

    /// useEngine=false (hands-free chunks): exact confirmed rules only,
    /// no network — live chunks must stay instant.
    func process(_ text: String, useEngine: Bool) async -> VocabOutcome {
        guard isEnabled else { return VocabOutcome(text: text, ms: nil, outcome: "off") }
        let rules = SpellingRule.rules(from: MemoryStore.shared.memories)
        let client = useEngine ? client() : nil
        let now = Date()
        let screen = client == nil ? [] : VocabularyCache.shared.data.screenTerms
        let candidates = CandidateFinder.find(in: text, rules: rules, screenTerms: screen).filter {
            !($0.source == .screen && VocabularyCache.shared.data.isBlocked(heard: $0.span, term: $0.term, now: now))
        }
        guard !candidates.isEmpty else { return VocabOutcome(text: text, ms: nil, outcome: "none") }

        guard let client else {
            let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: nil)
            return VocabOutcome(text: r.text, ms: nil, outcome: "nokey")
        }
        let start = Date()
        let questions = candidates.enumerated().map {
            DecisionQuestion.applyTerm(id: "q\($0.offset)", sentence: text, span: $0.element.span, term: $0.element.term)
        }
        let answers = await client.ask(state: ["sentence": text], questions: questions, deadline: Self.deadline)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: answers)
        pendingSuggestions = r.suggestions.map { VocabularyCard(kind: .didYouMean, heard: $0.span, term: $0.term) }
        let outcome = answers == nil ? "timeout" : (r.applied > 0 ? "applied" : "ok")
        print("🧠 Vocab: \(candidates.count) candidate(s), \(r.applied) applied, \(r.suggestions.count) suggested, \(outcome) in \(ms)ms")
        return VocabOutcome(text: r.text, ms: ms, outcome: outcome)
    }

    // MARK: - After insertion

    func recordingStarted() {
        CorrectionWatcher.shared.cancel()
    }

    func didInsert(_ text: String, pid: pid_t) {
        guard isEnabled else { return }
        lastInsertPID = pid
        for card in pendingSuggestions { queue.enqueue(card) }
        pendingSuggestions = []
        showNextCard()
        guard client() != nil else { return }
        CorrectionWatcher.shared.observe(inserted: text, pid: pid) { [weak self] correction in
            self?.considerEdit(correction, sentence: text)
        }
    }

    private func considerEdit(_ c: EditDiff.Correction, sentence: String) {
        guard !VocabularyCache.shared.data.isBlocked(heard: c.heard, term: c.corrected, now: Date()),
              let client = client() else { return }
        let known = SpellingRule.rules(from: MemoryStore.shared.memories).contains {
            CandidateFinder.normalize($0.heardAs) == CandidateFinder.normalize(c.heard) && $0.term == c.corrected
        }
        guard !known else { return }
        Task {
            let q = DecisionQuestion.spellingFix(id: "q0", sentence: sentence, heard: c.heard, corrected: c.corrected)
            let a = await client.ask(state: q.state, questions: [q], deadline: Self.backgroundDeadline)
            guard let p = a?["q0"], p >= VocabularyResolver.suggestThreshold else { return }
            await MainActor.run {
                self.queue.enqueue(VocabularyCard(kind: .learned, heard: c.heard, term: c.corrected))
                self.showNextCard()
            }
        }
    }

    // MARK: - Cards

    private func showNextCard() {
        guard let card = queue.next(now: Date(), isRecording: TranscriptionCoordinator.shared.isRecording) else { return }
        VocabularyCardPresenter.shared.show(card) { [weak self] choice in
            self?.resolve(card, choice)
        }
    }

    private func resolve(_ card: VocabularyCard, _ choice: VocabularyCardChoice) {
        queue.dismissed()
        let rule = SpellingRule(term: card.term, heardAs: card.heard)
        switch (card.kind, choice) {
        case (.learned, .primary), (.learned, .ignored):
            MemoryStore.shared.addMemory(rule.memoryLine)
        case (.learned, .secondary), (.didYouMean, .secondary):
            VocabularyCache.shared.update { $0.reject(heard: card.heard, term: card.term) }
        case (.didYouMean, .primary):
            MemoryStore.shared.addMemory(rule.memoryLine)
            if let pid = lastInsertPID {
                AXText.replaceInFocusedField(span: card.heard, with: card.term, pid: pid)
            }
        case (.didYouMean, .ignored):
            VocabularyCache.shared.update { $0.snooze(heard: card.heard, term: card.term, now: Date()) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showNextCard() }
    }
}
```


- [ ] **Step 7: Let the card presenter read the active screen**

In `Airboard/FloatingWindowManager.swift` replace

```swift
    private var activeScreen: NSScreen? {
```

with

```swift
    var activeScreen: NSScreen? {
```


- [ ] **Step 8: Record decision time in the local performance log** (optional fields → old log lines still decode)

In `Airboard/PerformanceLog.swift` replace

```swift
    var preview: String       // first 40 chars of the final text
}
```

with

```swift
    var preview: String       // first 40 chars of the final text
    var vocabMs: Int? = nil       // decision-engine time; nil = not called
    var vocabOutcome: String? = nil  // off | none | nokey | ok | applied | timeout
}
```


- [ ] **Step 9: Run vocabulary between filler removal and the LLM**

In `Airboard/TranscriptPostProcessor.swift` (the `ProcessOutcome` struct) replace

```swift
struct ProcessOutcome {
    let text: String
    let llmMs: Int?           // nil when the LLM didn't run
    let llmOutcome: String    // ok | timeout | error | guarded | skipped | off
}
```

with

```swift
struct ProcessOutcome {
    let text: String
    let llmMs: Int?           // nil when the LLM didn't run
    let llmOutcome: String    // ok | timeout | error | guarded | skipped | off
    var vocabMs: Int? = nil   // decision-engine time; nil = not called
    var vocabOutcome: String = "off"  // off | none | nokey | ok | applied | timeout
}
```

Then replace the whole `process(_:context:mode:)` function (from `    static func process(` up to, not including, `    private static func withTimeout(`) with:

```swift
    static func process(_ text: String, context: AppContext?, mode: ProcessingMode) async -> ProcessOutcome {
        let ruled = FillerRules.clean(text)

        // Learned spellings: dictation asks the decision engine (≤350ms);
        // hands-free chunks apply confirmed exact rules only (instant);
        // command mode stays verbatim for the command parser.
        guard mode != .command else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "off")
        }
        let vocab = await VocabularyLearning.shared.process(ruled, useEngine: mode == .dictation)
        var outcome = await refine(vocab.text, mode: mode)
        outcome.vocabMs = vocab.ms
        outcome.vocabOutcome = vocab.outcome
        return outcome
    }

    /// The optional remote LLM pass (unchanged behavior).
    private static func refine(_ ruled: String, mode: ProcessingMode) async -> ProcessOutcome {
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
            case TranscriptRefiner.RefineError.timeout:
                outcome = "timeout"
            default:
                outcome = "error"
            }
            print("⚠️ Cleanup LLM skipped (\(error.localizedDescription)); inserting rules-cleaned text (\(outcome))")
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: outcome)
        }
    }
```

(Behavior of the LLM pass is unchanged — `refine` is the old body verbatim. Dictation asks the engine; hands-free chunks get exact confirmed rules only so live chunks stay instant; command mode stays verbatim.)


- [ ] **Step 10: Coordinator hooks** — four edits in `Airboard/TranscriptionCoordinator.swift`:

(a) cancel the watcher when a new recording starts — replace

```swift
        // New session — invalidate any deferred cleanup/indicator work still
        // in flight from a previous session.
        sessionGeneration += 1
```

with

```swift
        // New session — invalidate any deferred cleanup/indicator work still
        // in flight from a previous session.
        sessionGeneration += 1
        VocabularyLearning.shared.recordingStarted()
```

(b) record vocab metrics — in `recordDictationMetrics`, replace

```swift
            words: outcome.text.split(separator: " ").count,
            preview: String(outcome.text.prefix(40)))
```

with

```swift
            words: outcome.text.split(separator: " ").count,
            preview: String(outcome.text.prefix(40)),
            vocabMs: outcome.vocabMs,
            vocabOutcome: outcome.vocabOutcome)
```

(c) pass the inserted text to the result handler — replace both occurrences of

```swift
handleInsertionResult(TextInserter.insertText(text, context: currentContext))
```

with

```swift
handleInsertionResult(TextInserter.insertText(text, context: currentContext), inserted: text)
```

and replace

```swift
        let result = TextInserter.insertText(text, context: currentContext)
        handleInsertionResult(result)
```

with

```swift
        let result = TextInserter.insertText(text, context: currentContext)
        handleInsertionResult(result, inserted: text)
```

(d) start learning after a successful insertion — replace

```swift
    private func handleInsertionResult(_ result: Result<Void, TextInsertionError>) {
        switch result {
        case .success:
            break // Success is handled by caller
```

with

```swift
    private func handleInsertionResult(_ result: Result<Void, TextInsertionError>, inserted text: String) {
        switch result {
        case .success:
            // Vocabulary learning: queue "Did you mean" cards, watch the
            // field for a quick fix the user makes to what we typed.
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                VocabularyLearning.shared.didInsert(text, pid: pid)
            }
```

Verify no old call sites remain:

```bash
grep -n 'handleInsertionResult' Airboard/TranscriptionCoordinator.swift
```
Expected: 4 lines, every call passing `inserted: text`.


- [ ] **Step 11: Start the harvester once setup is done** (Accessibility is granted by then)

In `Airboard/AirboardApp.swift` replace

```swift
                TypingActivityMonitor.shared.start()
            }
```

with

```swift
                TypingActivityMonitor.shared.start()
                // Self-learning vocabulary: screen-term harvester (needs
                // Accessibility, granted by now).
                VocabularyLearning.shared.start()
            }
```


- [ ] **Step 12: Build, re-run all pure suites, design-system check**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
for t in soundcode_test units_test editdiff_test rest_test; do /private/tmp/vocabtest/$t | tail -1; done
bash scripts/check_design_system.sh | tail -1
```
Expected: `** BUILD SUCCEEDED **`, four `ALL PASS`, `✅ Design-system check passed`. Also check no new warnings in the new files:

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep 'warning:' | grep -E 'Vocabulary|AXText|CorrectionWatcher|Decision|TranscriptPostProcessor'
```
Expected: no output.


- [ ] **Step 13: Commit**

```bash
git add Airboard/AXText.swift Airboard/VocabularyCache.swift Airboard/CorrectionWatcher.swift Airboard/VocabularyHarvester.swift Airboard/VocabularyCardView.swift Airboard/VocabularyLearning.swift Airboard/FloatingWindowManager.swift Airboard/PerformanceLog.swift Airboard/TranscriptPostProcessor.swift Airboard/TranscriptionCoordinator.swift Airboard/AirboardApp.swift
git commit -F - <<'EOF'
feat: self-learning vocabulary — dictation path, correction watcher, screen harvester, confirm card

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 7: Settings, docs, and manual verification

**Files:**
- Create: `Airboard/VocabularySettingsSection.swift`
- Modify: `Airboard/MemorySettingsView.swift`, `Airboard/AssistantSettingsView.swift` (copy), `Airboard/MemoryStore.swift` (header comment), `CLAUDE.md`, `CHANGELOG.md`, `docs/superpowers/specs/2026-10-07-self-learning-vocabulary-design.md` (record implementation decisions)

**Interfaces:**
- Consumes: `VocabularyLearning.shared.isEnabled/setEnabled(_:)` (Task 6), `KeychainHelper.save/read/deleteAPIKey(forHost:)`, `AssistantService.openRouterHost`.
- Produces: user-facing toggle (`UserDefaults` key `vocabLearningEnabled`, default on) and key field.

- [ ] **Step 1: Create `Airboard/VocabularySettingsSection.swift`**

```swift
//
//  VocabularySettingsSection.swift
//
//  "Learn my vocabulary" block inside Memory settings: master toggle,
//  OpenRouter key (BYOK — the same key the Assistant uses), and what
//  leaves the Mac.
//

import SwiftUI

struct VocabularySettingsSection: View {
    @State private var enabled = VocabularyLearning.shared.isEnabled
    @State private var apiKey = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost) ?? ""
    @State private var keySaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { enabled }, set: { enabled = $0; VocabularyLearning.shared.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn my vocabulary")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Label.primary)
                    Text("Learns names and terms from the words you fix after dictating and from text on your screen, and asks before saving each one.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Label.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(DS.Accent.success)

            HStack(spacing: 8) {
                SecureField("OpenRouter key (sk-or-…)", text: $apiKey)
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
            Text("Your own key, shared with the Assistant, kept in your Keychain. Each check sends one sentence and one word to OpenRouter — never your memory file or screen. Turn on zero data retention for this key at openrouter.ai. Without a key, only confirmed multi-word spellings (like \"bright AI\") are applied.")
                .font(.system(size: 10))
                .foregroundColor(DS.Label.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

- [ ] **Step 2: Show it in Memory settings** — in `Airboard/MemorySettingsView.swift` replace

```swift
                    Divider().padding(.vertical, 6)

                    Toggle(isOn: Binding(
                        get: { store.shareWithLLM },
```

with

```swift
                    Divider().padding(.vertical, 6)

                    VocabularySettingsSection()

                    Divider().padding(.vertical, 6)

                    Toggle(isOn: Binding(
                        get: { store.shareWithLLM },
```

- [ ] **Step 3: The Assistant's key is now shared — fix its copy.** In `Airboard/AssistantSettingsView.swift` replace

```swift
Text("Get one at openrouter.ai/keys. Used only for assistant questions.")
```

with

```swift
Text("Get one at openrouter.ai/keys. Used for assistant questions and vocabulary learning.")
```

- [ ] **Step 4: Amend the MemoryStore header** — in `Airboard/MemoryStore.swift` replace

```swift
//  Airboard's memory, Claude-style: a flat list of plain-language lines in
//  a human-editable markdown file. No schema, no fields — a spelling is
//  just a memory that says it's a spelling; the cleanup LLM reads the
//  lines and applies them in context. NOTHING here is ever applied by
//  local find-and-replace.
```

with

```swift
//  Airboard's memory, Claude-style: a flat list of plain-language lines in
//  a human-editable markdown file. No schema, no fields — a spelling is
//  just a memory that says it's a spelling; the cleanup LLM reads the
//  lines and applies them in context. ONE exception (2026-10-07): lines in
//  the exact SpellingRule shape ("X" is the correct spelling — often heard
//  as "Y".) are also applied locally by VocabularyLearning, and only when
//  a decision model agrees in context (or as an exact match when it can't
//  be reached). Every other line stays LLM-only.
```

- [ ] **Step 5: CLAUDE.md** — in the Source Organization table add, after the `| Memory |` row:

```markdown
| Vocabulary learning | `VocabularyLearning.swift` (orchestrator: dictation path ≤350ms, cards, watcher/harvester control), pure scratch-tested units `SoundCode`, `SpellingRule`, `CandidateFinder`, `EditDiff`, `TermExtractor`, `VocabularyResolver`, `VocabularyCacheData`, `VocabularyCardQueue`; `DecisionClient`/`DecisionTypes` (OpenRouter Decisions API, Jev — user's own key, shared with Assistant); `CorrectionWatcher`, `VocabularyHarvester`, `AXText`, `VocabularyCardView` (non-focus-stealing card), `VocabularySettingsSection` |
```

In the core-flow block, change the post-processing line to:

```text
    → TranscriptPostProcessor (FillerRules always; VocabularyLearning learned spellings; optional remote LLM via TranscriptRefiner)
```

Under "UserDefaults Keys" add:

```markdown
- `vocabLearningEnabled` — self-learning vocabulary toggle (default true). Confirmed spellings live in memory.md as SpellingRule lines; hidden learning state (harvested terms, verdicts, rejections) in App Support `vocabulary-cache.json`. Decisions send one sentence + one term to OpenRouter (user's key); nothing is logged but numbers
```

- [ ] **Step 6: CHANGELOG** — under `## [Unreleased]` add:

```markdown
- Airboard now learns your names and terms. Fix a misheard word right
  after dictating (or let it notice names on your screen) and a small card
  asks to remember it — ignore it and it's kept. From then on the word is
  written correctly, but only where it fits ("Ask bright AI" → Brite AI;
  "a bright idea" stays). Uses your own OpenRouter key; each check sends
  one sentence and one word. Toggle in Memory settings.
```

- [ ] **Step 7: Record implementation decisions in the spec** — append to the spec:

```markdown
## Implementation notes (2026-10-07, plan stage)

- **Session "no" cache dropped.** Decision answers are context-dependent
  ("store it in the cloud" no, "ask cloud to…" yes), so caching a "no"
  per (span, term) would block later correct answers. Calls stay bounded
  by the 5-candidate cap and per-term screen verdicts.
- **Hands-free chunks** apply confirmed exact rules only (no network) —
  live chunks must stay instant. **Command mode** is untouched (the
  command parser needs verbatim text).
- **Emails, URLs, paths, dotted names** are never candidates.
- **One concrete `DecisionClient`, no protocol yet.** The swappable seam
  is that single type; extract a `DecisionEngine` protocol when the second
  implementation (fine-tuned local Gemma) exists — not before.
- **No "Test key" button.** Save only; a bad key shows up as `nokey` /
  `timeout` outcomes in the Performance log on the next dictation with a
  learned word.
- **Offline / no key:** only confirmed *multi-word* exact phrases apply
  ("bright AI", "a lisha"). A single-word rule ("bright" → "Brite") needs
  the engine's context check, or "a bright idea" would become "a Brite
  idea" whenever the network drops. (Supersedes "exact confirmed rules
  only" in the error-handling table above.)
- **Eval gate:** `scripts/vocab-eval` — zero false positives and ≥85%
  overall on synthetic cases. Pre-plan runs: 40/44 and 39/44, 0 false
  positives, p50 ≈180–200ms.
```

- [ ] **Step 8: Build + design-system check**

```bash
xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
bash scripts/check_design_system.sh | tail -1
```
Expected: `** BUILD SUCCEEDED **`, `✅ Design-system check passed`.

- [ ] **Step 9: Manual verification (Debug build, `com.pype.airboard.dev`)** — run the app from Xcode (Cmd+R). In Memory settings, turn on "Learn my vocabulary" and paste an OpenRouter key. Then:

| # | Do | Expect |
|---|---|---|
| M1 | In TextEdit, dictate "Ask bright AI to send it". Fix "bright" → "Brite" by hand within 10s. | Within ~10s a card top-right: "Learned: bright → **Brite**". |
| M2 | Let that card sit 8s. | It disappears; Memory settings shows the line `"Brite" is the correct spelling — often heard as "bright".` |
| M3 | Trigger another card, and keep typing in TextEdit while it's up. | **Every keystroke lands in TextEdit** — the card never takes focus. Clicking Keep/Undo works on the first click and TextEdit stays frontmost. |
| M4 | Dictate "Ask bright to review it" and "What a bright idea". | First → "Ask Brite to review it"; second unchanged. Log shows `🧠 Vocab: … applied` / `… ok`. |
| M5 | Dictate "email bright@brite.com". | Unchanged. |
| M6 | Turn Wi-Fi off; dictate "Ask bright to review it" and "What a bright idea". | Both insert with no extra delay and **both stay unchanged** — offline, single-word rules wait for the engine (only multi-word confirmed phrases like "bright AI" apply offline). No error toast. |
| M7 | Card on screen → press Undo. | Line not saved (or removed only via Memory settings if already kept); the same pair never asks again. |
| M8 | Dictate into Terminal, then edit the text. | Nothing happens (field unreadable) — no card, no error. |
| M9 | Keep a page with "Parakeet" visible for ~2 min, then dictate "I use the paraket model" in TextEdit. | Text inserted as spoken, then "Did you mean **Parakeet**?"; Yes fixes the word in place and saves the rule. |
| M10 | Turn the toggle off; dictate "Ask bright to review it". | Unchanged (feature fully off). Open Performance → recent dictations still fine. |

Record any failure with the console log (`🧠 Vocab:` lines) before fixing.

- [ ] **Step 10: Commit**

```bash
git add Airboard/VocabularySettingsSection.swift Airboard/MemorySettingsView.swift Airboard/AssistantSettingsView.swift Airboard/MemoryStore.swift CLAUDE.md CHANGELOG.md docs/superpowers/specs/2026-10-07-self-learning-vocabulary-design.md
git commit -F - <<'EOF'
feat: vocabulary learning settings, docs, changelog

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```


### Task 8: Synthetic decision eval (the calibration gate)

**Files:**
- Create: `scripts/vocab-eval/cases.json`, `scripts/vocab-eval/main.swift`, `scripts/vocab-eval/run.sh`

**Interfaces:**
- Consumes: `DecisionQuestion`, `DecisionClient` (Task 4), `VocabularyResolver.applyThreshold/suggestThreshold` (Task 5).
- Produces: a repeatable gate for any prompt/threshold/model change — and later the pass/fail test for a fine-tuned local Gemma.

- [ ] **Step 1: Create `scripts/vocab-eval/cases.json`** — synthetic only (public or invented names; never a real user's vocabulary)

```json
{
  "note": "Synthetic decision cases for vocabulary learning. Public or invented names only — never a real user's vocabulary.",
  "apply": [
    {"sentence": "Ask bright AI to send the invoice", "span": "bright AI", "term": "Brite AI", "yes": true},
    {"sentence": "bright AI just closed a new customer", "span": "bright AI", "term": "Brite AI", "yes": true},
    {"sentence": "That was a bright idea from the team", "span": "bright", "term": "Brite", "yes": false},
    {"sentence": "The sun is very bright today", "span": "bright", "term": "Brite", "yes": false},
    {"sentence": "I use the paraket model for transcription", "span": "paraket", "term": "Parakeet", "yes": true},
    {"sentence": "The parakeet in the cage was singing all morning", "span": "parakeet", "term": "Parakeet", "yes": false},
    {"sentence": "Update the cloud MD file with the new rules", "span": "cloud MD", "term": "CLAUDE.md", "yes": true},
    {"sentence": "Store the backups in the cloud", "span": "cloud", "term": "Claude", "yes": false},
    {"sentence": "Open cloud code and run the tests", "span": "cloud code", "term": "Claude Code", "yes": true},
    {"sentence": "Our cloud costs went up this month", "span": "cloud", "term": "Claude", "yes": false},
    {"sentence": "Can you ask cloud to summarize this email", "span": "cloud", "term": "Claude", "yes": true},
    {"sentence": "Tell a lisha I'll be late for dinner", "span": "a lisha", "term": "Alisha", "yes": true},
    {"sentence": "Ask kate to review the pull request", "span": "kate", "term": "Cait", "yes": true},
    {"sentence": "We deploy everything on for sell", "span": "for sell", "term": "Vercel", "yes": true},
    {"sentence": "The house is for sell next month", "span": "for sell", "term": "Vercel", "yes": false},
    {"sentence": "Move the auth tables to super base", "span": "super base", "term": "Supabase", "yes": true},
    {"sentence": "The army built a super base in the desert", "span": "super base", "term": "Supabase", "yes": false},
    {"sentence": "Spin up a new pod on cube or nettie's", "span": "cube or nettie's", "term": "Kubernetes", "yes": true},
    {"sentence": "Put the ice cube in the glass", "span": "cube", "term": "Kubernetes", "yes": false},
    {"sentence": "Send the deck to zen tricks AI by Friday", "span": "zen tricks AI", "term": "Zentrix AI", "yes": true},
    {"sentence": "He showed me some zen tricks for meditation", "span": "zen tricks", "term": "Zentrix", "yes": false},
    {"sentence": "Write the migration in type script", "span": "type script", "term": "TypeScript", "yes": true}
  ],
  "spellingFix": [
    {"sentence": "bright AI is hiring engineers", "heard": "bright", "corrected": "Brite", "yes": true},
    {"sentence": "let's meet on Tuesday at noon", "heard": "Tuesday", "corrected": "Wednesday", "yes": false},
    {"sentence": "I use the paraket model", "heard": "paraket", "corrected": "Parakeet", "yes": true},
    {"sentence": "open cloud code in the terminal", "heard": "cloud", "corrected": "Claude", "yes": true},
    {"sentence": "this plan is cheap", "heard": "cheap", "corrected": "expensive", "yes": false},
    {"sentence": "send it to Cait", "heard": "Cait", "corrected": "Rahul", "yes": false},
    {"sentence": "the meeting is at five", "heard": "meeting", "corrected": "call", "yes": false},
    {"sentence": "talk to a lisha tonight", "heard": "a lisha", "corrected": "Alisha", "yes": true},
    {"sentence": "We use super base for the database", "heard": "super base", "corrected": "Supabase", "yes": true},
    {"sentence": "deploy it on for sell", "heard": "for sell", "corrected": "Vercel", "yes": true},
    {"sentence": "the price is ten dollars", "heard": "ten", "corrected": "twenty", "yes": false},
    {"sentence": "book a table at the cafe", "heard": "cafe", "corrected": "restaurant", "yes": false}
  ],
  "isTerm": [
    {"word": "Kubernetes", "yes": true}, {"word": "Supabase", "yes": true}, {"word": "TypeScript", "yes": true},
    {"word": "Vercel", "yes": true}, {"word": "Zentrix", "yes": true},
    {"word": "Edit", "yes": false}, {"word": "Window", "yes": false}, {"word": "Today", "yes": false},
    {"word": "Settings", "yes": false}, {"word": "Monday", "yes": false}
  ]
}
```

- [ ] **Step 2: Create `scripts/vocab-eval/main.swift`**

```swift
// Decision eval for vocabulary learning. Synthetic cases only.
// Run: OPENROUTER_API_KEY=… ./vocab-eval cases.json
import Foundation

struct Cases: Decodable {
    struct Apply: Decodable { let sentence, span, term: String; let yes: Bool }
    struct Fix: Decodable { let sentence, heard, corrected: String; let yes: Bool }
    struct Term: Decodable { let word: String; let yes: Bool }
    let apply: [Apply]; let spellingFix: [Fix]; let isTerm: [Term]
}

@main struct VocabEval {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else {
            print("Set OPENROUTER_API_KEY"); exit(2)
        }
        let path = CommandLine.arguments.dropFirst().first ?? "cases.json"
        let cases = try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let client = DecisionClient(apiKey: key)
        var lat: [Int] = []
        var falsePositives = 0   // said yes when the truth is no → would rewrite text wrongly
        func run(_ name: String, _ threshold: Double, _ items: [(DecisionQuestion, Bool, String)]) async -> (Int, Int) {
            var ok = 0
            for (q, want, label) in items {
                let t = Date()
                let p = await client.ask(state: q.state, questions: [q], deadline: 5)?["q0"]
                lat.append(Int(Date().timeIntervalSince(t) * 1000))
                let got = (p ?? 0) >= threshold
                if got && !want { falsePositives += 1 }
                if got == want { ok += 1 } else {
                    print("  WRONG \(name): want \(want ? "yes" : "no") p=\(p.map { String(format: "%.2f", $0) } ?? "nil")  \(label)")
                }
            }
            print("\(name): \(ok)/\(items.count) at threshold \(threshold)")
            return (ok, items.count)
        }
        let a = await run("apply", VocabularyResolver.applyThreshold, cases.apply.map {
            (DecisionQuestion.applyTerm(id: "q0", sentence: $0.sentence, span: $0.span, term: $0.term), $0.yes, $0.sentence) })
        let f = await run("spellingFix", VocabularyResolver.suggestThreshold, cases.spellingFix.map {
            (DecisionQuestion.spellingFix(id: "q0", sentence: $0.sentence, heard: $0.heard, corrected: $0.corrected), $0.yes, "\($0.heard) -> \($0.corrected)") })
        let t = await run("isTerm", VocabularyResolver.suggestThreshold, cases.isTerm.map {
            (DecisionQuestion.isTerm(id: "q0", term: $0.word), $0.yes, $0.word) })
        lat.sort()
        let total = a.0 + f.0 + t.0, n = a.1 + f.1 + t.1
        print("TOTAL \(total)/\(n) (\(total * 100 / n)%), false positives \(falsePositives), latency p50 \(lat[lat.count / 2])ms p90 \(lat[lat.count * 9 / 10])ms")
        // Gate: a wrong "yes" rewrites the user's text — never allowed.
        // A wrong "no" just leaves a word as heard — tolerated up to 15%.
        let pass = falsePositives == 0 && total * 100 >= n * 85
        print(pass ? "GATE PASS" : "GATE FAIL")
        exit(pass ? 0 : 1)
    }
}
```

- [ ] **Step 3: Create `scripts/vocab-eval/run.sh`** and make it executable (`chmod +x`)

```bash
#!/bin/bash
# Decision eval gate for vocabulary learning (synthetic cases only).
# Usage: OPENROUTER_API_KEY=sk-or-… scripts/vocab-eval/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -parse-as-library \
  Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift \
  Airboard/DecisionTypes.swift Airboard/DecisionClient.swift Airboard/VocabularyResolver.swift \
  scripts/vocab-eval/main.swift -o "$OUT/vocab-eval"
"$OUT/vocab-eval" scripts/vocab-eval/cases.json
```

- [ ] **Step 4: Run it**

```bash
OPENROUTER_API_KEY=sk-or-… scripts/vocab-eval/run.sh
```
Expected: last lines `TOTAL ≥38/44 …, false positives 0, …` and `GATE PASS`, exit 0. (Pre-plan: 40/44 and 39/44; known safe misses: "kate"→Cait, "cube or nettie's"→Kubernetes, cloud→Claude and for sell→Vercel as spelling fixes.) A `GATE FAIL` with any false positive blocks shipping — tighten the prompt or threshold, never relax the gate.

- [ ] **Step 5: Commit**

```bash
git add scripts/vocab-eval/cases.json scripts/vocab-eval/main.swift scripts/vocab-eval/run.sh
git commit -F - <<'EOF'
test: synthetic decision eval gate for vocabulary learning

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

