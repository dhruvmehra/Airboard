// Offline correction-trace eval for EditDiff (synthetic traces only).
// Scores the frozen v1 baseline and the current EditDiff side by side.
// Run: scripts/correction-eval/run.sh [-v]
import Foundation

struct Trace: Decodable {
    struct Pair: Decodable { let heard, corrected: String }
    let cat, before, inserted, after: String
    let expected: [Pair]
}

struct Score {
    var tp = 0, fp = 0, fn = 0, traces = 0, exact = 0
    var precision: Double { tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp) }
    var recall: Double { tp + fn == 0 ? 1 : Double(tp) / Double(tp + fn) }
    var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
    mutating func add(_ o: Score) { tp += o.tp; fp += o.fp; fn += o.fn; traces += o.traces; exact += o.exact }
}

/// Pairs are compared with edge punctuation trimmed; `heard` ignores case
/// (it's what we typed), `corrected` must match exactly (it's the lesson).
func key(_ heard: String, _ corrected: String) -> String {
    func trim(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let c = t.last, ".,!?;:\"“”()".contains(c) { t.removeLast() }
        while let c = t.first, "\"“”(".contains(c) { t.removeFirst() }
        return t
    }
    return trim(heard).lowercased() + " → " + trim(corrected)
}

@main struct CorrectionEval {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        let verbose = args.contains("-v")
        let path = args.first { $0 != "-v" } ?? "traces.json"
        let traces = try! JSONDecoder().decode([Trace].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for (i, t) in traces.enumerated() where !t.before.contains(t.inserted) {
            print("BAD TRACE #\(i): inserted text not in before"); exit(2)
        }
        let pos = traces.filter { !$0.expected.isEmpty }.count
        print("\(traces.count) traces (\(pos) with corrections, \(traces.count - pos) negatives)\n")

        let impls: [(String, (Trace) -> [EditDiff.Correction])] = [
            ("baseline", { t in EditDiffBaseline.correction(before: t.before, after: t.after, inserted: t.inserted).map { [$0] } ?? [] }),
            ("v2", { t in EditDiff.corrections(before: t.before, after: t.after, inserted: t.inserted) }),
        ]
        var cats: [String] = []
        for t in traces where !cats.contains(t.cat) { cats.append(t.cat) }

        var results: [String: [String: Score]] = [:]
        for (name, run) in impls {
            var byCat: [String: Score] = [:]
            for (i, t) in traces.enumerated() {
                let got = Set(run(t).map { key($0.heard, $0.corrected) })
                let want = Set(t.expected.map { key($0.heard, $0.corrected) })
                var s = Score()
                s.tp = got.intersection(want).count
                s.fp = got.subtracting(want).count
                s.fn = want.subtracting(got).count
                s.traces = 1
                s.exact = got == want ? 1 : 0
                byCat[t.cat, default: Score()].add(s)
                if verbose && got != want {
                    print("  [\(name)] #\(i) \(t.cat): want \(want.sorted()) got \(got.sorted())")
                }
            }
            results[name] = byCat
        }
        if verbose { print("") }

        func pct(_ x: Double) -> String { String(format: "%5.1f", x * 100) }
        print("category       n  | baseline        P     R     F1    exact     | v2              P     R     F1    exact")
        var totals: [String: Score] = [:]
        for c in cats {
            var line = c.padding(toLength: 13, withPad: " ", startingAt: 0)
            line += String(format: "%3d", results["baseline"]![c]!.traces) + "  |"
            for (name, _) in impls {
                let s = results[name]![c]!
                totals[name, default: Score()].add(s)
                line += "  tp\(s.tp) fp\(s.fp) fn\(s.fn)".padding(toLength: 16, withPad: " ", startingAt: 0)
                line += " \(pct(s.precision)) \(pct(s.recall)) \(pct(s.f1)) \(s.exact)/\(s.traces)".padding(toLength: 26, withPad: " ", startingAt: 0)
                if name == "baseline" { line += " |" }
            }
            print(line)
        }
        print("")
        for (name, _) in impls {
            let s = totals[name]!
            let negTraces = cats.filter { $0.hasPrefix("neg") }.map { results[name]![$0]! }
            let falseAlarms = negTraces.reduce(0) { $0 + $1.traces - $1.exact }
            print("\(name.padding(toLength: 9, withPad: " ", startingAt: 0)) precision \(pct(s.precision))%  recall \(pct(s.recall))%  F1 \(pct(s.f1))%  (tp \(s.tp), fp \(s.fp), fn \(s.fn)); exact traces \(s.exact)/\(s.traces); negatives with any output \(falseAlarms)")
        }

        // ── Learned cards (what the user would actually see) ─────────────
        // strict  = EditDiff as above → RuleLearning (no key, dictionary)
        // watcher = EditDiff(newNames: true), as CorrectionWatchPolicy calls
        //           it since 2026-10-12 → RuleLearning (no key, dictionary)
        // A pair counts as carded when its proposal is learnDirect.
        let learnPath = path.replacingOccurrences(of: "traces.json", with: "traces-learn.json")
        let learnTraces = (try? JSONDecoder().decode([Trace].self, from: Data(contentsOf: URL(fileURLWithPath: learnPath)))) ?? []
        let all = traces + learnTraces
        let dict = RuleLearning.loadOrdinaryWords()
        let ord: (String) -> Bool = { dict.contains($0) }
        func cards(_ t: Trace, newNames: Bool) -> Set<String> {
            Set(EditDiff.corrections(before: t.before, after: t.after, inserted: t.inserted, newNames: newNames)
                .filter { RuleLearning.propose($0, fixed: t.after, source: .keyboard, existing: [], hasKey: false,
                                               isOrdinaryWord: ord).gate == .learnDirect }
                .map { key($0.heard, $0.corrected) })
        }
        print("\nLearned cards, no key (EditDiff → RuleLearning with the dictionary) — \(traces.count) traces + \(learnTraces.count) in traces-learn.json")
        var carded: [String: [Int: Set<String>]] = [:]
        for (mode, nn) in [("strict", false), ("watcher", true)] {
            var sc = Score(), negWithCard = 0
            var byCat: [String: Score] = [:]
            for (i, t) in all.enumerated() {
                let got = cards(t, newNames: nn)
                carded[mode, default: [:]][i] = got
                let want = Set(t.expected.map { key($0.heard, $0.corrected) })
                var x = Score()
                x.tp = got.intersection(want).count; x.fp = got.subtracting(want).count; x.fn = want.subtracting(got).count
                x.traces = 1; x.exact = got == want ? 1 : 0
                sc.add(x); byCat[t.cat, default: Score()].add(x)
                if t.expected.isEmpty && !got.isEmpty { negWithCard += 1 }
            }
            print("  \(mode.padding(toLength: 8, withPad: " ", startingAt: 0)) card precision \(pct(sc.precision))%  card recall \(pct(sc.recall))%  (tp \(sc.tp), fp \(sc.fp), fn \(sc.fn)); negatives with a card \(negWithCard)")
            if verbose {
                for c in byCat.keys.sorted() {
                    let x = byCat[c]!
                    print("      \(c.padding(toLength: 16, withPad: " ", startingAt: 0)) tp\(x.tp) fp\(x.fp) fn\(x.fn)")
                }
            }
        }
        var newlyCarded: [String] = []
        for (i, t) in all.enumerated() where t.expected.isEmpty {
            let extra = carded["watcher"]![i]!.subtracting(carded["strict"]![i]!)
            if !extra.isEmpty { newlyCarded.append("#\(i) \(t.cat): \(extra.sorted())") }
        }
        print("  negatives that NEWLY produce a card in watcher mode: \(newlyCarded.count)")
        for n in newlyCarded { print("    \(n)") }
        // Pairs the newNames path adds, on the learn traces (diff level).
        var lp = Score()
        for t in learnTraces {
            let got = Set(EditDiff.corrections(before: t.before, after: t.after, inserted: t.inserted, newNames: true)
                .map { key($0.heard, $0.corrected) })
            let want = Set(t.expected.map { key($0.heard, $0.corrected) })
            lp.tp += got.intersection(want).count; lp.fp += got.subtracting(want).count; lp.fn += want.subtracting(got).count
            if verbose && got != want { print("    learn trace: want \(want.sorted()) got \(got.sorted())") }
        }
        print("  traces-learn.json (EditDiff newNames, diff level): precision \(pct(lp.precision))%  recall \(pct(lp.recall))%  (tp \(lp.tp), fp \(lp.fp), fn \(lp.fn))")
    }
}
