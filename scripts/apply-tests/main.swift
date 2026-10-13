// Apply-side tests: a confirmed SpellingRule must apply on every later
// dictation (no key, timeout, hands-free = answers nil) and leave ordinary
// words alone. Compiled with the app's pure units by run.sh:
//   SoundCode, SpellingRule, CandidateFinder, VocabularyResolver.
// Built with -D NEW against the working tree; without it against git HEAD
// (the "before" numbers), where only find + resolve(answers: nil) exist.

import Foundation

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let corpusPath = arg("--corpus")
let parakeetPath = arg("--parakeet")
let label = arg("--label") ?? "current"
let assertMode = args.contains("--assert")
let verbose = args.contains("-v")

func rule(_ term: String, _ heard: String) -> SpellingRule { SpellingRule(term: term, heardAs: heard) }
let rulesA = [rule("Pype", "pipe"), rule("Dhruv", "druv"), rule("Mehra", "mera")]
let rulesAPlus = rulesA + [rule("Pype AI", "PiPai")]
// What the founder's keyboard fixes in the corpus actually teach (Parakeet
// writes "Drove"/"Mera" for him).
let rulesB = [rule("Pype", "pipe"), rule("Dhruv", "Drove"), rule("Mehra", "Mera")]

enum Mode { case noKey, jevYes, jevNo }

/// The dictation path: find → (ask the engine only what needs it) → resolve.
func run(_ text: String, _ rules: [SpellingRule], _ mode: Mode = .noKey) -> String {
    let cands = CandidateFinder.find(in: text, rules: rules, screenTerms: [])
    switch mode {
    case .noKey:
        return VocabularyResolver.resolve(text: text, candidates: cands, answers: nil).text
    case .jevYes, .jevNo:
        var answers: [String: Double] = [:]
        #if NEW
        for c in cands where VocabularyResolver.needsDecision(c, in: text) {
            answers[c.pairKey] = mode == .jevYes ? 0.9 : 0.1
        }
        #else
        for c in cands { answers[c.pairKey] = mode == .jevYes ? 0.9 : 0.1 }
        #endif
        return VocabularyResolver.resolve(text: text, candidates: cands, answers: answers).text
    }
}

var failures: [String] = []
var counts: [String: (pass: Int, total: Int)] = [:]
func check(_ group: String, _ input: String, _ rules: [SpellingRule], _ mode: Mode = .noKey, expect: String) {
    let got = run(input, rules, mode)
    var c = counts[group] ?? (0, 0)
    c.total += 1
    if got == expect { c.pass += 1 } else { failures.append("[\(group)] \(input)  →  \(got)   (want: \(expect))") }
    counts[group] = c
}
func pos(_ group: String, _ input: String, _ expect: String, rules: [SpellingRule] = rulesA, _ mode: Mode = .noKey) {
    check("pos " + group, input, rules, mode, expect: expect)
}
func neg(_ group: String, _ input: String, rules: [SpellingRule] = rulesA, _ mode: Mode = .noKey) {
    check("neg " + group, input, rules, mode, expect: input)
}

// MARK: - Founder acceptance (synthetic text), answers = nil

for rs in [("A", rulesA), ("A+PypeAI", rulesAPlus)] {
    let g = "synthetic/\(rs.0)"
    let r = rs.1
    pos(g, "I work at pipe", "I work at Pype", rules: r)
    pos(g, "I work at pipe now.", "I work at Pype now.", rules: r)
    pos(g, "this is druv mehra", "this is Dhruv Mehra", rules: r)
    pos(g, "this is druv mera", "this is Dhruv Mehra", rules: r)
    pos(g, "This is Druv Mehra.", "This is Dhruv Mehra.", rules: r)
    pos(g, "This is Dhruv Mera.", "This is Dhruv Mehra.", rules: r)
    pos(g, "Pipe's roadmap", "Pype's roadmap", rules: r)
    pos(g, "Pipe\u{2019}s roadmap is ready.", "Pype\u{2019}s roadmap is ready.", rules: r)
    pos(g, "Dhruva said", "Dhruv said", rules: r)
    pos(g, "Druv said yes", "Dhruv said yes", rules: r)
    pos(g, "DRUV said yes", "Dhruv said yes", rules: r)
    pos(g, "druv's laptop is here", "Dhruv's laptop is here", rules: r)
    pos(g, "Ask druv mehra's team", "Ask Dhruv Mehra's team", rules: r)
    pos(g, "Thanks Druv, see you soon.", "Thanks Dhruv, see you soon.", rules: r)
    pos(g, "Mr. Mera joined the call late.", "Mr. Mehra joined the call late.", rules: r)
    pos(g, "Send the invoice to Pipe by Friday.", "Send the invoice to Pype by Friday.", rules: r)
    pos(g, "Join pipe today.", "Join Pype today.", rules: r)
    pos(g, "We met at pipe.", "We met at Pype.", rules: r)
    pos(g, "the pype dashboard", "the Pype dashboard", rules: r)
    pos(g, "Dhruvmehra says hello.", "Dhruv Mehra says hello.", rules: r)
    pos(g, "Mehra ka laptop", "Mehra ka laptop", rules: r)
    pos(g, "druv mera ka laptop", "Dhruv Mehra ka laptop", rules: r)
    pos(g, "Email me at druv@pype.ai, druv.", "Email me at druv@pype.ai, Dhruv.", rules: r)  // protection + fix

    neg(g, "the water pipe burst", rules: r)
    neg(g, "The water pipe burst last night.", rules: r)
    neg(g, "type the password", rules: r)
    neg(g, "Type the password again.", rules: r)
    neg(g, "walk through the door", rules: r)
    neg(g, "he drew a map", rules: r)
    neg(g, "Ask Mr Mehta", rules: r)
    neg(g, "Ask Mr. Mehta about the invoice.", rules: r)
    neg(g, "yeh mera laptop hai", rules: r)
    neg(g, "mera naam Rahul hai", rules: r)
    neg(g, "Mera naam Rahul hai.", rules: r)
    neg(g, "Dhruv mera dost hai.", rules: r)
    neg(g, "Dhruv, mera phone kahan hai?", rules: r)
    neg(g, "He smoked a pipe on the porch.", rules: r)
    neg(g, "Pipe the output to grep.", rules: r)
    neg(g, "Look at pipe sizes before buying.", rules: r)
    neg(g, "The pipe's diameter is small.", rules: r)
    neg(g, "I drove home after work.", rules: r)
    neg(g, "I drove more slowly.", rules: r)
    neg(g, "Tell me more about it.", rules: r)
    neg(g, "Click here for more information.", rules: r)
    neg(g, "The mayor spoke today.", rules: r)
    neg(g, "Can you check the drive folder?", rules: r)
    neg(g, "Open Google Drive.", rules: r)
    neg(g, "The pipeline failed overnight.", rules: r)
    neg(g, "Mira is my cousin.", rules: r)
    neg(g, "This is Dhruv Mehra from Pype.", rules: r)        // already right: untouched
    neg(g, "Email druv@pype.ai or see pype.ai/druv", rules: r)  // emails / URLs never touched
    neg(g, "Call 555 0199 now.", rules: r)
}
// 'Pype AI' and 'Pype' learned together (PP code shared).
pos("synthetic/A+PypeAI", "Have you tried pipe AI yet?", "Have you tried Pype AI yet?", rules: rulesAPlus)
pos("synthetic/A+PypeAI", "I work at pipe now.", "I work at Pype now.", rules: rulesAPlus)
pos("synthetic/A+PypeAI", "Have you tried PiPai yet?", "Have you tried Pype AI yet?", rules: rulesAPlus)
pos("synthetic/A", "Have you tried pipe AI yet?", "Have you tried pipe AI yet?", rules: rulesA)  // never "Pype" eating "AI"

// MARK: - Real Parakeet output (say -o → Parakeet), answers = nil, rules A
// Hand-labelled: what the founder wants from THIS transcript.
let realA: [(String, String)] = [
    ("I work at pipe.", "I work at Pype."),
    ("I work at pipe now.", "I work at Pype now."),
    ("I woke up pipe now.", "I woke up pipe now."),                 // no signal; left for the engine
    ("Join pipe today.", "Join Pype today."),
    ("Join Pipe today.", "Join Pype today."),
    ("This is Drove Mera.", "This is Dhruv Mehra."),
    ("This is Drove Meira.", "This is Dhruv Mehra."),
    ("This is Trouv Mira.", "This is Dhruv Mehra."),
    ("This is Dhruvmehra.", "This is Dhruv Mehra."),
    ("My name is Truvmira.", "My name is Dhruv Mehra."),
    ("Our CEO Dhruvmara says hello.", "Our CEO Dhruv Mehra says hello."),
    ("I spoke to Drove Mera from Pipe today.", "I spoke to Dhruv Mehra from Pype today."),
    ("I spoke to Drove Mayra from Pipe today.", "I spoke to Dhruv Mehra from Pype today."),
    ("Regards, Drove Mera, Pipe.", "Regards, Dhruv Mehra, Pype."),
    ("Drove Mera founded pipe.", "Dhruv Mehra founded Pype."),
    ("Dhruva said yes.", "Dhruv said yes."),
    ("Drova said yes.", "Dhruv said yes."),
    ("Thanks Drov, see you soon.", "Thanks Dhruv, see you soon."),
    ("Druv will review the pull request.", "Dhruv will review the pull request."),
    ("Book a meeting with Droov and the pipe team.", "Book a meeting with Dhruv and the pipe team."),
    ("Dhruvmehra's laptop is here.", "Dhruv Mehra's laptop is here."),
    ("Drev Mahara's laptop is here.", "Dhruv Mehra's laptop is here."),
    ("Drove Mera's laptop is here.", "Dhruv Mehra's laptop is here."),
    ("Mr. Mera joined the call late.", "Mr. Mehra joined the call late."),
    ("Mr. Mara joined the call late.", "Mr. Mehra joined the call late."),
    ("Mr. Mahra joined the call late.", "Mr. Mehra joined the call late."),
    ("Ask Mr. Mayor about it.", "Ask Mr. Mayor about it."),        // MYR ≠ MR: short codes stay exact
    ("Ask Mr. Merrow about it.", "Ask Mr. Mehra about it."),
    ("Please ask Mayra to sign the contract.", "Please ask Mehra to sign the contract."),
    ("My surname is Mayra.", "My surname is Mehra."),
    ("Mayra will join the call.", "Mehra will join the call."),
    ("Mayra drove to work.", "Mehra drove to work."),
    ("Send the invoice to Pipe by Friday.", "Send the invoice to Pype by Friday."),
    ("Book a meeting with Drove and the Pipe Team.", "Book a meeting with Drove and the Pype Team."),
    ("Pipe's new offices in Bangalore.", "Pype's new offices in Bangalore."),
    ("Talk to Drew about Pipe.", "Talk to Drew about Pype."),
]
for (i, e) in realA { pos("parakeet/A", i, e) }
// Same real outputs, rules as the founder's corpus fixes teach them.
let realB: [(String, String)] = [
    ("Email drove about the launch.", "Email drove about the launch."),  // lowercase verb-shaped: engine's call
    ("Call Drove tomorrow morning.", "Call Dhruv tomorrow morning."),
    ("Message Trove on Slack.", "Message Trove on Slack."),       // dictionary word, not the heardAs: engine's call
    ("Thanks Drove. See you soon.", "Thanks Dhruv. See you soon."),
    ("This is Drove Mera.", "This is Dhruv Mehra."),
    ("Rads, Drove Mehra, Pipe.", "Rads, Dhruv Mehra, Pype."),
    ("Mr. Mera joined the call late.", "Mr. Mehra joined the call late."),
    ("I work at pipe.", "I work at Pype."),
]
for (i, e) in realB { pos("parakeet/B", i, e, rules: rulesB) }

// Real negatives (Parakeet output of ordinary speech): never changed.
let realNeg = [
    "The water pipe burst last night.", "The water pipe bust.", "Type the password again.",
    "Pipe the output to grab.", "Fight the output to grab.", "Walk through the door.", "He drew a map of the city.",
    "I drove home after work.", "I drove home off to work.", "Ask Mr. Meta about the invoice.",
    "Ask Mr. Mehitar about the invoice.", "Ask Mr. Mehta about the invoice.", "Ask Mr. Maida about the invoice.",
    "Meera Nam Rahul Hai.", "Mera Nam Rahul Hai.", "Mera Nam Rahul Hir.", "Maranam Rahul High", "Marinam Rahul High",
    "Ye made our lap a top high.", "Ye Miralap Taphe.", "Yeah.", "Yemera laptop high.", "Yeah, Mira Laptop High.",
    "What type of file is this?", "The pipeline failed overnight.", "We drove through the tunnel.",
    "Drew is coming to the party.", "Please type your name here.", "He smoked a pipe on the porch.",
    "Go through the checklist first.", "The kitchen pipe is leaking.", "May Radha Delhi Mayhaya.",
    "Mira Ghar Dili Mehe", "Marigardeli Mine High.", "Merigadeli Main High.", "Can you check the drive folder?",
    "Read through the document.", "This type of error is common.", "Meta and Sun sent the bill.",
    "Mehta and Sun Santa Bill.", "She drew the curtains.", "Mira dustara high.", "Mira dos tarahahe.",
    "Mera Dosto Rah.", "Mara Dust A Rafah.", "Mera dust A Rahai.",
    "I need more time.", "Tell me more about it.", "Click here for more information.", "The mayor spoke today.",
    "Look in the mirror.", "Look at pipe sizes before buying.", "It was built from pipe and wood.",
    "Drive safely tonight.", "Mira is my cousin.", "Mirar is my cousin.", "I drove more slowly.",
    "We drew more attention than expected.", "Fipe it into a file.", "Pipe it into a file.", "Vipe it into a file.",
    "Mary drove to work.", "Mera drove to work.", "Miri Bhangharpehe.", "Mary Van Garpey High.",
    "Mary behind our pay high.", "Tira nam kyahe.", "Tera nam kyahe.", "Mere pastime nahinhe.",
    "Mere past time nahi high.", "Mir pause time nahi high.",
]
for rs in [("A", rulesA), ("A+PypeAI", rulesAPlus), ("B", rulesB)] {
    for n in realNeg { neg("parakeet/" + rs.0, n, rules: rs.1) }
}

// MARK: - With a key: ambiguous spans obey the engine, unmistakable ones don't wait

#if NEW
pos("jev-yes", "the water pipe burst", "the water Pype burst", .jevYes)   // the engine said yes: it decides
neg("jev-no", "the water pipe burst", .jevNo)
pos("jev-no", "I work at pipe", "I work at pipe", .jevNo)                // engine said no beats the slot signal
pos("jev-yes", "I work at pipe", "I work at Pype", .jevYes)
pos("jev-no", "Dhruva said", "Dhruv said", .jevNo)                     // not ordinary: local, no question
pos("jev-no", "druv mera dost hai", "Dhruv mera dost hai", .jevNo)     // name applied, Hindi "mera" kept
pos("jev-yes", "druv mera dost hai", "Dhruv Mehra dost hai", .jevYes)
pos("jev-yes", "Ask Mr. Mehta", "Ask Mr. Mehra", rules: rulesA + [rule("Mehra", "Mehta")], .jevYes)
pos("jev-no", "Ask Mr. Mehta", "Ask Mr. Mehta", rules: rulesA + [rule("Mehra", "Mehta")], .jevNo)
pos("nokey", "Ask Mr. Mehta", "Ask Mr. Mehta", rules: rulesA + [rule("Mehra", "Mehta")])  // exact-only + engine
pos("jev-no", "Dhruvmehra says hi", "Dhruv Mehra says hi", .jevNo)
// Which candidates the dictation path still sends to the engine.
func asked(_ t: String, _ r: [SpellingRule] = rulesA) -> Int {
    CandidateFinder.find(in: t, rules: r, screenTerms: []).filter { VocabularyResolver.needsDecision($0, in: t) }.count
}
let askCases: [(String, Int)] = [("Dhruva said", 0), ("this is druv mehra", 0), ("I work at pipe", 1),
                                  ("the water pipe burst", 1), ("Dhruvmehra's laptop", 0), ("mera naam Rahul hai", 1)]
for (t, n) in askCases {
    let got = asked(t)
    var c = counts["engine questions"] ?? (0, 0); c.total += 1
    if got == n { c.pass += 1 } else { failures.append("[engine questions] \(t): \(got) asked, want \(n)") }
    counts["engine questions"] = c
}
#endif

// MARK: - Corpus metric (scripts/name-eval/corpus.json + parakeet.tsv), before vs after

struct Item { let truth: String; let raw: String; let positive: Bool }
func loadItems() -> [Item] {
    var items: [Item] = []
    if let p = corpusPath, let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let arr = j["items"] as? [[String: Any]] {
        for it in arr {
            guard let role = it["role"] as? String, role.hasPrefix("apply"),
                  let t = it["truth"] as? String, let r = it["raw"] as? String else { continue }
            items.append(Item(truth: t, raw: r, positive: role == "apply_pos"))
        }
    }
    if let p = parakeetPath, let s = try? String(contentsOfFile: p, encoding: .utf8) {
        for line in s.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 else { continue }
            items.append(Item(truth: f[2], raw: f[3], positive: f[0].hasPrefix("p")))
        }
    }
    return items
}
func occurrences(_ term: String, _ s: String) -> Int {
    let re = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b")
    return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
}
let items = loadItems()
var summary: [(String, String)] = []
if !items.isEmpty {
    for (name, rs) in [("A", rulesA), ("A+PypeAI", rulesAPlus), ("B", rulesB)] {
        for mode in [Mode.noKey] {
            var need = 0, got = 0, inserted = 0, right = 0, negChanged = 0, negs = 0, posFull = 0, poss = 0
            for it in items {
                let out = run(it.raw, rs, mode)
                if !it.positive {
                    negs += 1
                    if out != it.raw { negChanged += 1; if verbose { print("   NEG CHANGED [\(name)] \(it.raw) → \(out)") } }
                    continue
                }
                poss += 1
                var full = true
                for t in ["Pype", "Dhruv", "Mehra"] {
                    let want = occurrences(t, it.truth), had = occurrences(t, it.raw), now = occurrences(t, out)
                    let missing = max(0, want - had)
                    need += missing
                    let ins = max(0, now - had)
                    inserted += ins
                    let ok = min(ins, missing)
                    right += ok; got += ok
                    if now < want || ins > missing { full = false }
                    if ins > missing && verbose { print("   WRONG INSERT [\(name)] \(it.raw) → \(out)   (truth: \(it.truth))") }
                }
                if full { posFull += 1 }
            }
            let rec = need == 0 ? 0 : Double(got) / Double(need)
            let prec = inserted == 0 ? 1 : Double(right) / Double(inserted)
            summary.append(("rules \(name) nokey: name recall", String(format: "%.3f (%d/%d)", rec, got, need)))
            summary.append(("rules \(name) nokey: precision", String(format: "%.3f (%d/%d)", prec, right, inserted)))
            summary.append(("rules \(name) nokey: positives fully right", "\(posFull)/\(poss)"))
            summary.append(("rules \(name) nokey: negatives changed", "\(negChanged)/\(negs)"))
        }
    }
}

// MARK: - Timing: 300 words, 50 rules

#if NEW
_ = VocabularyResolver.WordList.words  // warm (the app does this off the dictation path)
#endif
var timingRules = rulesAPlus
let fake = ["Zorvex", "Kalindra", "Brite AI", "Supabase", "Vercel", "Anakshi", "Tamsin", "Quillon", "Ravindra", "Okonkwo"]
for i in 0..<47 { timingRules.append(rule(fake[i % fake.count] + (i < fake.count ? "" : String(UnicodeScalar(65 + i % 26)!)), "x\(i)y")) }
timingRules = Array(timingRules.prefix(50))
let base = "I work at pipe now and this is druv mera from the water pipe team, we drove through the door and type the password again while Mr. Mera said yeh mera laptop hai. "
var long = ""
while long.split(separator: " ").count < 300 { long += base }
long = long.split(separator: " ").prefix(300).joined(separator: " ")
let reps = 200
let t0 = Date()
var sink = 0
for _ in 0..<reps {
    let c = CandidateFinder.find(in: long, rules: timingRules, screenTerms: [])
    sink &+= VocabularyResolver.resolve(text: long, candidates: c, answers: nil).applied
}
let ms = Date().timeIntervalSince(t0) * 1000 / Double(reps)
let t1 = Date()
let w = VocabularyResolver_loadCost()
let loadMs = Date().timeIntervalSince(t1) * 1000

// MARK: - Report

print("== apply-tests [\(label)] ==")
for k in counts.keys.sorted() {
    let c = counts[k]!
    print(String(format: "%-28@ %3d/%-3d", k as NSString, c.pass, c.total))
}
for (k, v) in summary { print(String(format: "%-44@ %@", k as NSString, v as NSString)) }
print(String(format: "timing: find+resolve, 300 words, %d rules: %.3f ms/dictation (%d applied)", timingRules.count, ms, sink / reps))
if w >= 0 { print(String(format: "timing: word list load (once, off the dictation path): %.0f ms, %d words", loadMs, w)) }
if !failures.isEmpty {
    print("-- failures (\(failures.count)):")
    for f in failures { print("   " + f) }
}
let posTotal = counts.filter { $0.key.hasPrefix("pos") }.reduce(0) { $0 + $1.value.total }
let posPass = counts.filter { $0.key.hasPrefix("pos") }.reduce(0) { $0 + $1.value.pass }
let negTotal = counts.filter { $0.key.hasPrefix("neg") }.reduce(0) { $0 + $1.value.total }
let negChangedN = negTotal - counts.filter { $0.key.hasPrefix("neg") }.reduce(0) { $0 + $1.value.pass }
print("TOTAL positives fixed \(posPass)/\(posTotal), negatives changed \(negChangedN)/\(negTotal)")
if assertMode && !failures.isEmpty { exit(1) }

func VocabularyResolver_loadCost() -> Int {
    #if NEW
    return VocabularyResolver.WordList.load().lower.count
    #else
    return -1
    #endif
}
