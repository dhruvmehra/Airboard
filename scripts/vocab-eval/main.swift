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
