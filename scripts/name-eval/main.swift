// End-to-end name eval: correction event → learned rule → later dictations.
// Replays corpus.json (REAL Parakeet output for TTS audio, see gen.sh)
// through Glue.swift (a faithful copy of VocabularyLearning's glue) on top
// of the app's pure units. Deterministic and offline unless
// OPENROUTER_API_KEY is set (then the decision-model modes run too).
//
// Per voice (the speaker who corrects is the speaker who dictates later),
// per scenario, starting from an EMPTY rule set:
//   none      no learning — what Parakeet alone gives
//   keyboard  replay learn_keyboard events (user fixes the names in the field)
//   spelled   replay learn_spelled events (user spells the name out loud)
//   both      keyboard then spelled
//   oracle    memory.md seeded with the ideal rules (perfect learning) —
//             isolates the APPLY stage from the LEARN stage
// then every apply_pos / apply_neg utterance goes through the dictation path.
//
// Usage: name-eval corpus.json [-v] [--label NAME] [--summary FILE]
import Foundation

struct Corpus: Decodable {
    struct Slot: Decodable {
        let i: Int; let word: String; let term: String
        let heard: String?; let `class`: String; let merged: Bool?
    }
    struct Item: Decodable {
        let id: String; let sentence: String; let voice: String; let role: String; let label: String
        let truth: String; let raw: String; let slots: [Slot]
        let after: String?; let prev: String?; let acceptance: Bool?
        let spelling_heard: Bool?
    }
    let items: [Item]
}

// MARK: - Tokens (same as build_corpus.py)

struct Tok { let word: String; let key: String; let range: Range<String.Index> }

func tokens(_ text: String) -> [Tok] {
    var out: [Tok] = []
    var i = text.startIndex
    func isCore(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    while i < text.endIndex {
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
        guard i < text.endIndex else { break }
        var j = i
        while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
        var lo = i, hi = j
        while lo < hi, !isCore(text[lo]) { lo = text.index(after: lo) }
        while hi > lo, !isCore(text[text.index(before: hi)]) { hi = text.index(before: hi) }
        if lo < hi {
            let w = String(text[lo..<hi]).replacingOccurrences(of: "\u{2019}", with: "'")
            out.append(Tok(word: w, key: w.lowercased(), range: lo..<hi))
        }
        i = j
    }
    return out
}

/// LCS matches a[i] ↔ b[j] by `same`.
func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
    let n = a.count, m = b.count
    guard n > 0, m > 0 else { return [] }
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
        }
    }
    var out: [(Int, Int)] = []
    var i = 0, j = 0
    while i < n && j < m {
        if a[i] == b[j] { out.append((i, j)); i += 1; j += 1 }
        else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
    }
    return out
}

func stripPoss(_ w: String) -> String { w.hasSuffix("'s") ? String(w.dropLast(2)) : w }

/// Where each truth slot sits in `text`: a matched token (case-insensitive),
/// or the gap between its matched neighbours.
struct SlotPlace { let matched: Int?; let region: Range<Int>; let truthGap: Range<Int> }

func place(slots: [Corpus.Slot], truth: [Tok], text: [Tok]) -> [SlotPlace] {
    let pairs = lcs(truth.map(\.key), text.map(\.key))
    var t2o: [Int: Int] = [:]
    for (a, b) in pairs { t2o[a] = b }
    return slots.map { s in
        if let o = t2o[s.i] { return SlotPlace(matched: o, region: o..<(o + 1), truthGap: s.i..<(s.i + 1)) }
        var pt = s.i - 1; while pt >= 0, t2o[pt] == nil { pt -= 1 }
        var nt = s.i + 1; while nt < truth.count, t2o[nt] == nil { nt += 1 }
        let lo = pt >= 0 ? t2o[pt]! + 1 : 0
        let hi = nt < truth.count ? t2o[nt]! : text.count
        return SlotPlace(matched: nil, region: lo..<max(lo, hi), truthGap: (pt + 1)..<nt)
    }
}

/// The user's keyboard fix: misheard name tokens replaced by the truth.
func userFix(_ text: String, item: Corpus.Item) -> String {
    let tt = tokens(item.truth), ot = tokens(text)
    var edits: [(Range<String.Index>, String)] = []
    var done = Set<Int>()
    for (s, p) in zip(item.slots, place(slots: item.slots, truth: tt, text: ot)) {
        if let o = p.matched {
            if ot[o].word != s.word { edits.append((ot[o].range, s.word)) }
        } else if !p.region.isEmpty, !done.contains(p.region.lowerBound) {
            done.insert(p.region.lowerBound)
            let rep = tt[p.truthGap].map(\.word).joined(separator: " ")
            edits.append((ot[p.region.lowerBound].range.lowerBound..<ot[p.region.upperBound - 1].range.upperBound, rep))
        }
    }
    var out = text
    for (r, w) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { out.replaceSubrange(r, with: w) }
    return out
}

// MARK: - Metrics

struct Counts {
    var tp = 0, fn = 0, wrong = 0, fpExtra = 0
    var misheardSlots = 0, misheardTP = 0
    var negSentences = 0, negClean = 0
    var precision: Double? { let d = tp + wrong + fpExtra; return d == 0 ? nil : Double(tp) / Double(d) }
    var recall: Double? { let d = tp + fn + wrong; return d == 0 ? nil : Double(tp) / Double(d) }
    var misheardRecall: Double? { misheardSlots == 0 ? nil : Double(misheardTP) / Double(misheardSlots) }
    static func += (a: inout Counts, b: Counts) {
        a.tp += b.tp; a.fn += b.fn; a.wrong += b.wrong; a.fpExtra += b.fpExtra
        a.misheardSlots += b.misheardSlots; a.misheardTP += b.misheardTP
        a.negSentences += b.negSentences; a.negClean += b.negClean
    }
}

struct LearnCounts {
    var tp = 0, fp = 0, fn = 0, expected = 0, produced = 0, waitedOnCap = 0
    var precision: Double? { produced == 0 ? nil : Double(produced - fp) / Double(produced) }
    var recall: Double? { expected == 0 ? nil : Double(tp) / Double(expected) }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func pct(_ x: Double?) -> String { x.map { String(format: "%5.1f%%", $0 * 100) } ?? "   — " }

struct ApplyResult {
    var byKey: [String: Counts] = [:]   // "all", "name:Pype", "voice:Rishi", "class:dict", …
    var misses: [String] = []
}

/// Scores one apply utterance. input = what the vocabulary step received.
func score(item: Corpus.Item, input: String, output: String, result: inout ApplyResult, terms: Set<String>) {
    let tt = tokens(item.truth), ot = tokens(output), it = tokens(input)
    // What the pipeline changed: input ↔ output, exact words.
    let io = lcs(it.map(\.word), ot.map(\.word))
    var keptOut = Set<Int>(), keptIn = Set<Int>()
    for (a, b) in io { keptIn.insert(a); keptOut.insert(b) }
    var c = Counts()
    var perSlot: [(Corpus.Slot, String)] = []
    var okOut = Set<Int>()     // output tokens explained by a TP / WRONG slot
    if item.label == "pos" {
        for (s, p) in zip(item.slots, place(slots: item.slots, truth: tt, text: ot)) {
            let poss = s.word.hasSuffix("'s")
            let exact = p.matched.map { ot[$0].word == s.word } ?? false
            let possOK = poss && p.region.contains { o in
                let w = ot[o].word
                return w == s.word || w == s.term + "s" || stripPoss(w) == s.term
            }
            let outcome: String
            if exact || possOK { outcome = "TP"; c.tp += 1 }
            else if p.region.contains(where: { !keptOut.contains($0) }) { outcome = "WRONG"; c.wrong += 1 }
            else { outcome = "FN"; c.fn += 1 }
            if outcome != "FN" { okOut.formUnion(p.region) }
            if s.class != "correct" { c.misheardSlots += 1; if outcome == "TP" { c.misheardTP += 1 } }
            perSlot.append((s, outcome))
        }
    } else {
        c.negSentences = 1
    }
    // Change hunks not explained by a slot: false positives.
    var extra: [String] = []
    var j = 0, i = 0
    let ioSorted = io + [(it.count, ot.count)]
    for (a, b) in ioSorted {
        if a > i || b > j {
            let outIdx = Array(j..<b)
            if outIdx.isEmpty || !outIdx.allSatisfy({ okOut.contains($0) }) {
                extra.append(outIdx.isEmpty ? "(deleted \"\(it[i..<a].map(\.word).joined(separator: " "))\")"
                              : outIdx.map { ot[$0].word }.joined(separator: " "))
            }
        }
        i = a + 1; j = b + 1
    }
    c.fpExtra = extra.count
    if item.label == "neg" && extra.isEmpty { c.negClean = 1 }

    func add(_ key: String, _ x: Counts) { result.byKey[key, default: Counts()] += x }
    add("all", c)
    add("voice:\(item.voice)", c)
    add("label:\(item.label)", c)
    for (s, o) in perSlot {
        var x = Counts()
        switch o { case "TP": x.tp = 1; case "WRONG": x.wrong = 1; default: x.fn = 1 }
        if s.class != "correct" { x.misheardSlots = 1; x.misheardTP = o == "TP" ? 1 : 0 }
        add("name:\(s.term)", x)
        add("class:\(s.class)", x)
    }
    // Extra FPs, by which learned term they introduced.
    for e in extra {
        let name = terms.first { t in tokens(e).contains { stripPoss($0.word) == t } } ?? "other"
        var x = Counts(); x.fpExtra = 1
        add("name:\(name)", x)
    }
    let bad = perSlot.filter { $0.1 != "TP" }
    if !bad.isEmpty || !extra.isEmpty {
        let slots = bad.map { "\($0.0.term)=\($0.1)(heard \"\($0.0.heard ?? "")\")" }.joined(separator: " ")
        let fps = extra.isEmpty ? "" : " FP[\(extra.joined(separator: " | "))]"
        result.misses.append("\(item.id): \"\(output)\"  \(slots)\(fps)")
    }
}

// MARK: - Learn expectations

struct Expected: Hashable { let term: String; let heard: String; let possessive: Bool }

func norm(_ s: String) -> String { CandidateFinder.normalize(s.replacingOccurrences(of: "\u{2019}", with: "'")) }

func expectedRules(_ items: [Corpus.Item]) -> [Expected] {
    var out: [Expected] = []
    for it in items {
        if it.role == "learn_spelled" && it.spelling_heard == false { continue }
        var mergedDone = Set<String>()
        for s in it.slots where s.class != "correct" && s.class != "dropped" {
            guard let h = s.heard, !h.isEmpty else { continue }
            if s.merged == true {
                guard mergedDone.insert(h).inserted else { continue }
                let terms = it.slots.filter { $0.merged == true && $0.heard == h }.map(\.term)
                out.append(Expected(term: terms.joined(separator: " "), heard: h, possessive: false))
            } else {
                out.append(Expected(term: s.term, heard: h, possessive: s.word.hasSuffix("'s")))
            }
        }
    }
    var seen = Set<String>()
    return out.filter { seen.insert($0.term + "|" + norm($0.heard)).inserted }
}

func matches(_ r: SpellingRule, _ e: Expected) -> Bool {
    if r.term == e.term && norm(r.heardAs) == norm(e.heard) { return true }
    if e.possessive {
        let h = e.heard.replacingOccurrences(of: "\u{2019}", with: "'")
        let base = h.hasSuffix("'s") ? String(h.dropLast(2)) : h
        if r.term == e.term && norm(r.heardAs) == norm(base) { return true }
        if r.term == e.term + "'s" && norm(r.heardAs) == norm(h) { return true }
    }
    return false
}

/// TP/FP/FN of produced rules vs expected (a "Dhruv Mehra"/"drove mera"
/// rule covers both slots when its words split 1:1 onto expected pairs).
func scoreLearn(rules: [SpellingRule], expected: [Expected]) -> (LearnCounts, [String]) {
    var covered = Set<Int>()
    var lc = LearnCounts(); var notes: [String] = []
    lc.expected = expected.count; lc.produced = rules.count
    for r in rules {
        var hit = false
        for (k, e) in expected.enumerated() where matches(r, e) { covered.insert(k); hit = true }
        if !hit {
            let tw = r.term.split(separator: " "), hw = r.heardAs.split(separator: " ")
            if tw.count >= 2 && tw.count == hw.count {
                let parts = zip(tw, hw).map { SpellingRule(term: String($0), heardAs: String($1)) }
                let ks = parts.map { p in expected.firstIndex { matches(p, $0) } }
                if ks.allSatisfy({ $0 != nil }) { ks.forEach { covered.insert($0!) }; hit = true }
            }
        }
        if !hit { lc.fp += 1; notes.append("  learn FP: \(r.memoryLine)") }
    }
    lc.tp = covered.count
    lc.fn = expected.count - covered.count
    for (k, e) in expected.enumerated() where !covered.contains(k) {
        notes.append("  learn FN: \(e.term) ← \"\(e.heard)\"")
    }
    return (lc, notes)
}

// MARK: - Main

@main struct NameEval {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let verbose = args.contains("-v"); args.removeAll { $0 == "-v" }
        var label = "eval", summaryPath: String?
        if let i = args.firstIndex(of: "--label") { label = args[i + 1]; args.removeSubrange(i...(i + 1)) }
        if let i = args.firstIndex(of: "--summary") { summaryPath = args[i + 1]; args.removeSubrange(i...(i + 1)) }
        let path = args.first ?? "corpus.json"
        let corpus = try! JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path))).items
        let voices = corpus.reduce(into: [String]()) { if !$0.contains($1.voice) { $0.append($1.voice) } }
        let terms: Set<String> = Set(corpus.flatMap { $0.slots.map(\.term) })
        var summary: [(String, String)] = []

        let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        var modes: [(name: String, client: DecisionClient?, apply: TimeInterval, learn: TimeInterval)] =
            [("no-key", nil, 0.35, 5)]
        if let key {
            let c = DecisionClient(apiKey: key)
            modes.append(("key", c, 0.35, 5))
            modes.append(("key-generous-5s", c, 5, 5))
        }

        let roleCount = Dictionary(grouping: corpus, by: \.role).mapValues(\.count)
        print("== name-eval [\(label)] — \(corpus.count) utterances (\(roleCount.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))), voices: \(voices.joined(separator: " "))")
        print("   modes: \(modes.map(\.name).joined(separator: ", "))\(key == nil ? "  (OPENROUTER_API_KEY not set — with-key modes skipped)" : "")")

        let scenarios = ["none", "keyboard", "spelled", "both", "oracle"]
        for mode in modes {
            print("\n#### MODE \(mode.name)")
            print(pad("scenario", 9) + String(format: " │ %@ │ %@",
                         "LEARN  exp prod  TP  FP  FN   prec  recall  (cap-wait)" as NSString,
                         "APPLY  slots TP  FN WRONG FPx   prec  recall misheard-recall  neg-clean" as NSString))
            var detail: [String: ApplyResult] = [:]
            var accLines: [String] = []
            for sc in scenarios {
                var lcAll = LearnCounts()
                var ar = ApplyResult()
                var learnNotes: [String] = []
                for v in voices {
                    let app = GlueApp(client: mode.client, applyDeadline: mode.apply, learnDeadline: mode.learn)
                    let learnKB = corpus.filter { $0.voice == v && $0.role == "learn_keyboard" }
                    let learnSp = corpus.filter { $0.voice == v && $0.role == "learn_spelled" }
                    let events: [Corpus.Item] = sc == "keyboard" ? learnKB : sc == "spelled" ? learnSp
                        : sc == "both" ? learnKB + learnSp : []
                    let exp: [Expected] = sc == "oracle" ? expectedRules(learnKB + learnSp) : expectedRules(events)
                    if sc == "oracle" {
                        for e in exp { app.addMemory(SpellingRule(term: e.term, heardAs: e.heard).memoryLine) }
                    }
                    // Learn: one dictation every 30s; the user fixes names ~3s after insertion.
                    for ev in events {
                        await app.advance(to: app.now.addingTimeInterval(30))
                        await app.recordingStarted()
                        let out = await app.dictate(ev.raw)
                        guard let fid = await app.didInsert(out.text, pid: 1) else { continue }
                        if ev.role == "learn_keyboard" {
                            let after = (out.text == FillerRules.clean(ev.raw) ? ev.after : nil) ?? userFix(out.text, item: ev)
                            if after != out.text { app.userEdits(field: fid, to: after, at: app.now.addingTimeInterval(3)) }
                        }
                    }
                    await app.advance(to: app.now.addingTimeInterval(120))
                    let beforeDrain = app.rules.count
                    await app.drainCards()
                    if sc != "none" && sc != "oracle" {
                        var (lc, notes) = scoreLearn(rules: app.rules, expected: exp)
                        lc.waitedOnCap = app.rules.count - beforeDrain
                        lcAll.tp += lc.tp; lcAll.fp += lc.fp; lcAll.fn += lc.fn
                        lcAll.expected += lc.expected; lcAll.produced += lc.produced; lcAll.waitedOnCap += lc.waitedOnCap
                        learnNotes.append("  [\(v)] rules: " + (app.rules.isEmpty ? "(none)" : app.rules.map { "\($0.term)←\"\($0.heardAs)\"" }.joined(separator: ", ")))
                        learnNotes += notes.map { "  [\(v)]" + $0 }
                        if verbose { learnNotes += app.trace.map { "  [\(v)]    · " + $0 } }
                    }
                    // Apply.
                    for it in corpus where it.voice == v && (it.role == "apply_pos" || it.role == "apply_neg") {
                        let input = FillerRules.clean(it.raw)
                        let out = await app.dictate(it.raw)
                        score(item: it, input: input, output: out.text, result: &ar, terms: terms)
                        if sc == "both" && it.acceptance == true {
                            let pass = it.label == "pos"
                                ? tokens(out.text).map(\.word) == tokens(it.truth).map(\.word)
                                : out.text == input
                            accLines.append("  \(pass ? "PASS" : "FAIL") [\(v)] \(it.truth)  ← heard \"\(it.raw)\" → \"\(out.text)\"")
                        }
                    }
                    // Founder's literal sentences (typed, not Parakeet), with this voice's learned rules.
                    if sc == "both" {
                        for (input, want) in [("I work at pipe", "I work at Pype"), ("this is druv mehra", "this is Dhruv Mehra"),
                                              ("the water pipe burst", "the water pipe burst"), ("walk through the door", "walk through the door"),
                                              ("mera naam Rahul hai", "mera naam Rahul hai")] {
                            let out = await app.dictate(input).text
                            let want = FillerRules.clean(want)   // the app capitalises the first letter
                            accLines.append("  \(out == want ? "PASS" : "FAIL") [\(v)] literal \"\(input)\" → \"\(out)\" (want \"\(want)\")")
                        }
                    }
                }
                detail[sc] = ar
                let a = ar.byKey["all"] ?? Counts()
                let learnCol = (sc == "none" || sc == "oracle") ? String(repeating: " ", count: 53)
                    : String(format: "       %3d %4d %3d %3d %3d %@ %@  (%d)", lcAll.expected, lcAll.produced, lcAll.tp, lcAll.fp, lcAll.fn,
                             pct(lcAll.precision) as NSString, pct(lcAll.recall) as NSString, lcAll.waitedOnCap)
                let slots = a.tp + a.fn + a.wrong
                print(pad(sc, 9) + String(format: " │ %@ │        %4d %3d %3d %4d %3d %@ %@ %@          %d/%d", learnCol as NSString,
                             slots, a.tp, a.fn, a.wrong, a.fpExtra, pct(a.precision) as NSString, pct(a.recall) as NSString,
                             pct(a.misheardRecall) as NSString, a.negClean, a.negSentences))
                summary.append(("\(mode.name) \(sc) apply prec", pct(a.precision)))
                summary.append(("\(mode.name) \(sc) apply recall", pct(a.recall)))
                summary.append(("\(mode.name) \(sc) apply misheard-recall", pct(a.misheardRecall)))
                summary.append(("\(mode.name) \(sc) neg clean", "\(a.negClean)/\(a.negSentences)"))
                if sc != "none" && sc != "oracle" {
                    summary.append(("\(mode.name) \(sc) learn prec", pct(lcAll.precision)))
                    summary.append(("\(mode.name) \(sc) learn recall", pct(lcAll.recall)))
                }
                if verbose && sc != "none" && sc != "oracle" {
                    print("    learn detail (\(sc)):"); learnNotes.forEach { print("    " + $0) }
                }
                if verbose && sc != "none" {
                    print("    apply misses (\(sc)):"); ar.misses.forEach { print("      " + $0) }
                }
            }
            // Breakdowns for the scenarios that matter.
            for sc in ["both", "oracle"] {
                guard let ar = detail[sc] else { continue }
                print("\n  breakdown [\(mode.name) / \(sc)]   slots  TP  FN WRONG FPx   prec  recall  misheard-recall")
                let keys = ar.byKey.keys.filter { $0 != "all" }.sorted()
                for k in keys {
                    let c = ar.byKey[k]!
                    print("    " + pad(k, 18) + String(format: " %5d %3d %3d %4d %3d %@ %@ %@", c.tp + c.fn + c.wrong, c.tp, c.fn, c.wrong,
                                 c.fpExtra, pct(c.precision) as NSString, pct(c.recall) as NSString, pct(c.misheardRecall) as NSString))
                    if ["name:Pype", "name:Dhruv", "name:Mehra"].contains(k) {
                        summary.append(("\(mode.name) \(sc) \(k) recall", pct(c.recall)))
                        summary.append(("\(mode.name) \(sc) \(k) prec", pct(c.precision)))
                    }
                    if k.hasPrefix("class:") { summary.append(("\(mode.name) \(sc) \(k) recall", pct(c.recall))) }
                }
            }
            print("\n  acceptance [\(mode.name) / both]:")
            accLines.forEach { print($0) }
            let passN = accLines.filter { $0.hasPrefix("  PASS") }.count
            summary.append(("\(mode.name) acceptance pass", "\(passN)/\(accLines.count)"))
        }
        if let p = summaryPath {
            let text = summary.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n") + "\n"
            try? text.write(toFile: p, atomically: true, encoding: .utf8)
        }
    }
}
