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
    }
}
