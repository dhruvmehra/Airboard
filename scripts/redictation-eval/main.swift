// Offline eval for RedictationLearner. Synthetic traces only — each is a
// short run of consecutive dictations as Airboard would insert them.
// Every turn goes through spelledRewrite (the dictation path) and then
// detect() against the turns before it (didInsert), exactly like the app.
// Run: ./redictation-eval traces.json            (deterministic, offline)
//      OPENROUTER_API_KEY=… ./redictation-eval traces.json
//        → also asks the decision model about every pair below
//          directCardStrength, as VocabularyLearning does.
import Foundation

struct Traces: Decodable {
    struct Turn: Decodable { let text: String; let dt: Double?; let app: Int32?; let scratched: Bool? }
    struct Trace: Decodable {
        let id: String
        let kind: String            // spelled | followUp | redictation | negative
        let source: String?         // "parakeet-probe" = text is real Parakeet output
        let turns: [Turn]
        let expect: [[String]]      // acceptable [heard, corrected] pairs; [] = nothing to learn
        let expectText: String?     // last turn after spelledRewrite
    }
    let traces: [Trace]
}

@main struct RedictationEval {
    static func norm(_ s: String) -> String { CandidateFinder.normalize(s) }

    static func main() async {
        let path = CommandLine.arguments.dropFirst().first ?? "traces.json"
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let traces = try! JSONDecoder().decode(Traces.self, from: data).traces
        let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let client = key.map { DecisionClient(apiKey: $0) }

        let kinds = LearnedPair.Kind.allCases.map(\.rawValue)
        var emitted: [String: Int] = [:], correct: [String: Int] = [:], spanRight: [String: Int] = [:]
        var expected: [String: Int] = [:], found: [String: Int] = [:]
        var gEmitted: [String: Int] = [:], gCorrect: [String: Int] = [:], gFound: [String: Int] = [:]
        var probeExpected: [String: Int] = [:], probeFound: [String: Int] = [:]
        var negTraces = 0, negClean = 0
        var textChecks = 0, textOK = 0

        for tr in traces {
            var t0 = Date(timeIntervalSince1970: 1_000_000)
            var history: [TranscriptTurn] = []
            var pairs: [LearnedPair] = []
            var lastText = ""
            for turn in tr.turns {
                t0 = t0.addingTimeInterval(turn.dt ?? 8)
                let rw = RedictationLearner.spelledRewrite(turn.text)
                pairs += rw.pairs
                let cur = TranscriptTurn(text: rw.text, at: t0, pid: turn.app ?? 1, scratched: turn.scratched ?? false)
                pairs += RedictationLearner.detect(current: cur, previous: history)
                history.append(cur)
                lastText = rw.text
            }
            if let want = tr.expectText {
                textChecks += 1
                if lastText == want { textOK += 1 } else { print("  TEXT  \(tr.id): got \"\(lastText)\"  want \"\(want)\"") }
            }
            let isPositive = !tr.expect.isEmpty
            if isPositive { expected[tr.kind, default: 0] += 1 } else { negTraces += 1 }
            var hit = false, gHit = false
            for p in pairs {
                let k = p.kind.rawValue
                emitted[k, default: 0] += 1
                let ok = tr.expect.contains { norm($0[0]) == norm(p.heard) && $0[1].lowercased() == p.corrected.lowercased() }
                let spanOK = tr.expect.contains { norm($0[0]) == norm(p.heard) }
                if ok { correct[k, default: 0] += 1; hit = true }
                if spanOK { spanRight[k, default: 0] += 1 }
                let tag = ok ? "ok   " : (spanOK ? "SPAN " : "WRONG")
                // Gate: strong pairs go straight to a card; weak ones need the model.
                var passes = p.strength >= RedictationLearner.directCardStrength
                var prob = ""
                if !passes, let client {
                    let q = DecisionQuestion.spellingFix(id: "q0", sentence: p.sentence, heard: p.heard, corrected: p.corrected)
                    let a = await client.ask(state: q.state, questions: [q], deadline: 5)?["q0"]
                    passes = (a ?? 0) >= VocabularyResolver.suggestThreshold
                    prob = " p=" + (a.map { String(format: "%.2f", $0) } ?? "nil")
                }
                if client != nil || passes {
                    if passes { gEmitted[k, default: 0] += 1; if ok { gCorrect[k, default: 0] += 1; gHit = true } }
                }
                if !ok || !prob.isEmpty {
                    print("  \(tag) \(tr.id) [\(k) s=\(String(format: "%.2f", p.strength))\(prob)\(passes ? " CARD" : "")]: \"\(p.heard)\" → \"\(p.corrected)\"")
                }
            }
            if isPositive, tr.source == "parakeet-probe" {
                probeExpected[tr.kind, default: 0] += 1
                if hit { probeFound[tr.kind, default: 0] += 1 }
            }
            if isPositive {
                if hit { found[tr.kind, default: 0] += 1 } else { print("  MISS  \(tr.id) (\(tr.kind))") }
                if gHit { gFound[tr.kind, default: 0] += 1 }
            } else if pairs.isEmpty { negClean += 1 }
        }

        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "  n/a" : String(format: "%5.1f%%", Double(a) * 100 / Double(b)) }
        print("")
        print("traces \(traces.count) (\(traces.count - negTraces) positive, \(negTraces) negative)\(client == nil ? "  [offline: no decision model]" : "  [decision model on]")")
        print("kind          precision (pairs)      span-precision   recall (traces)")
        for k in kinds {
            let e = emitted[k] ?? 0, c = correct[k] ?? 0, s = spanRight[k] ?? 0
            let x = expected[k] ?? 0, f = found[k] ?? 0
            print("\(k.padding(toLength: 13, withPad: " ", startingAt: 0)) \(pct(c, e)) (\(c)/\(e))".padding(toLength: 38, withPad: " ", startingAt: 0)
                  + " \(pct(s, e))".padding(toLength: 17, withPad: " ", startingAt: 0) + " \(pct(f, x)) (\(f)/\(x))")
        }
        print("cards (after gate: strength ≥ \(RedictationLearner.directCardStrength)\(client == nil ? "" : " or decision ≥ \(VocabularyResolver.suggestThreshold)")):")
        for k in kinds {
            let e = gEmitted[k] ?? 0, c = gCorrect[k] ?? 0, x = expected[k] ?? 0, f = gFound[k] ?? 0
            print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) precision \(pct(c, e)) (\(c)/\(e))  recall \(pct(f, x)) (\(f)/\(x))")
        }
        // Real Parakeet output only: the second take is the recognizer again,
        // not the user's spelling — this is the honest recall for followUp/redictation.
        print("recall on real Parakeet output (source=parakeet-probe):")
        for k in kinds {
            print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0)) \(pct(probeFound[k] ?? 0, probeExpected[k] ?? 0)) (\(probeFound[k] ?? 0)/\(probeExpected[k] ?? 0))")
        }
        print("negatives with no pair: \(negClean)/\(negTraces)")
        print("spelled rewrite text: \(textOK)/\(textChecks)")
    }
}
