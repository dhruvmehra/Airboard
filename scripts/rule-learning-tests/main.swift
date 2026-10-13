// Scratch tests: RuleLearning (correction → rules → gate) and spelled
// letters on real Parakeet output. Run: scripts/rule-learning-tests/run.sh
import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL  \(name)  \(detail())") }
}

func r(_ term: String, _ heard: String) -> SpellingRule { SpellingRule(term: term, heardAs: heard) }
func show(_ rs: [SpellingRule]) -> String { rs.map { "\($0.heardAs)→\($0.term)" }.joined(separator: ", ") }

@main struct RuleLearningTests {
    static func main() {
        let dict = RuleLearning.loadOrdinaryWords()
        check(dict.count > 100_000, "dictionary loads", "\(dict.count) words")
        let ord: (String) -> Bool = { dict.contains($0) }

        /// Keyboard fix through the REAL detector: EditDiff on the field,
        /// then RuleLearning — as CorrectionWatcher → considerEdit does.
        func keyboard(_ before: String, _ after: String, existing: [SpellingRule] = [],
                      hasKey: Bool) -> [RuleLearning.Proposal] {
            EditDiff.corrections(before: before, after: after, inserted: before, newNames: true).map {
                RuleLearning.propose($0, fixed: after, source: .keyboard, existing: existing,
                                     hasKey: hasKey, isOrdinaryWord: ord)
            }
        }
        func expectLearn(_ name: String, _ before: String, _ after: String, rules want: [SpellingRule],
                         existing: [SpellingRule] = [], keyless: RuleLearning.Gate = .learnDirect,
                         keyed: RuleLearning.Gate = .learnDirect) {
            for (hasKey, gate) in [(false, keyless), (true, keyed)] {
                let ps = keyboard(before, after, existing: existing, hasKey: hasKey)
                let tag = "\(name) [\(hasKey ? "key" : "no key")]"
                guard ps.count == 1, let p = ps.first else {
                    check(false, tag, "expected 1 correction, got \(ps.count)"); continue
                }
                check(p.gate == gate, tag + " gate", "got \(p.gate.rawValue) (\(p.reason)), want \(gate.rawValue)")
                check(p.rules == want, tag + " rules", "got [\(show(p.rules))], want [\(show(want))]")
            }
        }
        func expectNothing(_ name: String, _ before: String, _ after: String, existing: [SpellingRule] = []) {
            for hasKey in [false, true] {
                let ps = keyboard(before, after, existing: existing, hasKey: hasKey)
                let learned = ps.filter { RuleLearning.learns($0, decision: nil) && $0.gate == .learnDirect }
                check(learned.isEmpty, "\(name) [\(hasKey ? "key" : "no key")] learns nothing directly",
                      ps.map { "\($0.gate.rawValue):\(show($0.rules))" }.joined(separator: "; "))
                if !hasKey {
                    check(ps.allSatisfy { !RuleLearning.learns($0, decision: nil) }, "\(name) [no key] no card")
                }
            }
        }

        // MARK: Pype / Dhruv / Mehra keyboard fixes
        expectLearn("pipe→Pype", "I work at pipe and we are hiring.", "I work at Pype and we are hiring.",
                    rules: [r("Pype", "pipe")])
        expectLearn("Pipe→Pype at start", "Pipe is growing fast.", "Pype is growing fast.",
                    rules: [r("Pype", "Pipe")])
        expectLearn("druv→Dhruv", "My name is druv.", "My name is Dhruv.", rules: [r("Dhruv", "druv")])
        expectLearn("Dhruva→Dhruv at start", "Dhruva will send it.", "Dhruv will send it.",
                    rules: [r("Dhruv", "Dhruva")])
        expectLearn("Mera→Mehra", "Mr Mera called.", "Mr Mehra called.", rules: [r("Mehra", "Mera")])
        // Short codes must match exactly (MT vs MR): only the dictionary
        // path learns this one.
        expectLearn("Mehta→Mehra (keyless via dictionary)", "My surname is Mehta, not Sharma.",
                    "My surname is Mehra, not Sharma.", rules: [r("Mehra", "Mehta")])
        expectLearn("Mehta→Mehra at sentence start", "Mehta is my surname.", "Mehra is my surname.",
                    rules: [r("Mehra", "Mehta")])
        expectLearn("Meyra→Mehra", "Mr Meyra will join.", "Mr Mehra will join.", rules: [r("Mehra", "Meyra")])
        // Two names in one edit: per-word rules + the phrase.
        expectLearn("druv mera→Dhruv Mehra", "this is druv mera from sales", "this is Dhruv Mehra from sales",
                    rules: [r("Dhruv Mehra", "druv mera"), r("Dhruv", "druv"), r("Mehra", "mera")])
        expectLearn("Druv Mera at end", "Thanks, Druv Mera", "Thanks, Dhruv Mehra",
                    rules: [r("Dhruv Mehra", "Druv Mera"), r("Dhruv", "Druv"), r("Mehra", "Mera")])
        // Possessives, straight and curly.
        expectLearn("druv's→Dhruv's", "Send it to druv's inbox.", "Send it to Dhruv's inbox.",
                    rules: [r("Dhruv", "druv")])
        expectLearn("druv’s→Dhruv’s", "Send it to druv’s inbox.", "Send it to Dhruv’s inbox.",
                    rules: [r("Dhruv", "druv")])
        expectLearn("pipe's→Pype's", "We love pipe's culture.", "We love Pype's culture.",
                    rules: [r("Pype", "pipe")])
        check(RuleLearning.core(.init(heard: "straw man's", corrected: "strawman's")) == .init(heard: "straw man", corrected: "strawman"),
              "strawman's ← straw man's stripped")
        check(RuleLearning.core(.init(heard: "druvs", corrected: "Dhruv's")) == .init(heard: "druv", corrected: "Dhruv"),
              "druvs → Dhruv's stripped")
        // Brite AI: phrase + the one changed word.
        expectLearn("bright AI→Brite AI", "bright AI is hiring", "Brite AI is hiring",
                    rules: [r("Brite", "bright")])  // EditDiff reports the one changed word

        // MARK: Already confirmed
        let pype = [r("Pype", "pipe")]
        for hasKey in [false, true] {
            let p = keyboard("I work at pipe.", "I work at Pype.", existing: pype, hasKey: hasKey)
            check(p.count == 1 && p[0].gate == .reject && p[0].reason == "known", "known pair → no card")
            let q = keyboard("I work at Pipe.", "I work at Pype.", existing: pype, hasKey: hasKey)
            check(q.count == 1 && q[0].gate == .reject, "known pair, different case of heard → no card")
        }
        // Same term, new heard form: learns the new form, no Jev needed.
        let mehra = [r("Mehra", "Mera")]
        expectLearn("confirmed Mehra, new heard Mehta", "Mr Mehta called.", "Mr Mehra called.",
                    rules: [r("Mehra", "Mehta")], existing: mehra)
        let dhruv = [r("Dhruv", "druv")]
        // "Drew" (TR) → "Dhruv" (TRF): an everyday word, one sound short,
        // fixed to a non-dictionary name (isNameExtension). Unknown term:
        // keyless learns (the rule never applies to "Drew" without Jev —
        // it teaches the TERM), keyed asks Jev. Confirmed term: learn.
        expectLearn("Drew→Dhruv, Dhruv not confirmed", "My name is Drew.", "My name is Dhruv.",
                    rules: [r("Dhruv", "Drew")], keyless: .learnDirect, keyed: .askDecisionModel)
        expectLearn("Drew→Dhruv, Dhruv confirmed", "My name is Drew.", "My name is Dhruv.",
                    rules: [r("Dhruv", "Drew")], existing: dhruv)
        // Possessives (real Parakeet, name-eval lk_poss): the stem is the lesson.
        expectLearn("Drew's→Dhruv's", "Drew's laptop is here.", "Dhruv's laptop is here.",
                    rules: [r("Dhruv", "Drew")], keyless: .learnDirect, keyed: .askDecisionModel)
        expectLearn("Drum's→Dhruv's, Dhruv confirmed", "Drum's laptop is here.", "Dhruv's laptop is here.",
                    rules: [r("Dhruv", "Drum")], existing: dhruv)
        expectLearn("Drugs→Dhruv's, Dhruv confirmed", "Drugs laptop is here.", "Dhruv's laptop is here.",
                    rules: [r("Dhruv", "Drug")], existing: dhruv)
        // Nothing confirmed: still a word fixed INTO a new name (2026-10-12
        // gate "new-name") — the term is learned; "Drum" sounds unlike
        // Dhruv, so the apply side uses that heard form only with Jev.
        expectLearn("Drum's→Dhruv's, nothing confirmed", "Drum's laptop is here.", "Dhruv's laptop is here.",
                    rules: [r("Dhruv", "Drum")])
        expectNothing("Drew→Drawn (ordinary word)", "Drew a diagram of the flow.", "Drawn a diagram of the flow.")
        expectNothing("drugs→drums (ordinary words)", "The drugs were approved.", "The drums were approved.")
        expectLearn("druv mera→Dhruv Mehra, half known", "this is druv mera", "this is Dhruv Mehra",
                    rules: [r("Dhruv Mehra", "druv mera"), r("Mehra", "mera")], existing: dhruv)
        // "type" → "Pype" (TP vs PP): a word fixed into a new name — learned
        // (new-name), key or not; confirmed: learn.
        expectLearn("type→Pype, unknown", "I work at type.", "I work at Pype.",
                    rules: [r("Pype", "type")])
        expectLearn("type→Pype, Pype confirmed", "I work at type.", "I work at Pype.",
                    rules: [r("Pype", "type")], existing: pype)

        // MARK: (a) A word fixed into a NEW name that sounds unlike it
        // (real Parakeet, name-eval lk_pype-Aman / lk_full-Aman).
        expectLearn("Python→Pype now (typed on)", "I work at Python.", "I work at Pype now.",
                    rules: [r("Pype", "Python")])
        expectLearn("Fight→Pype", "This is Dhruv Mehra from Fight.", "This is Dhruv Mehra from Pype.",
                    rules: [r("Pype", "Fight")])
        do {
            let ps = keyboard("This is Druv from Fight.", "This is Dhruv from Pype.", hasKey: false)
            check(ps.count == 2 && ps.allSatisfy { $0.gate == .learnDirect }, "Druv→Dhruv + Fight→Pype: both learned",
                  ps.map { "\($0.gate.rawValue):\(show($0.rules))" }.joined(separator: "; "))
        }
        expectLearn("python's→Pype's", "Send python's deck.", "Send Pype's deck.", rules: [r("Pype", "python")])
        // …but never a rewrite, a dictionary word, a rename, a pronoun, a URL/e-mail/number.
        expectNothing("rewrite around a new name", "Let us meet on Monday.", "Can we meet at Pype instead?")
        expectNothing("two words changed + a name", "The cafe is closed.", "The Pype office is closed.")
        expectNothing("Monday→Tuesday", "Let us meet on Monday.", "Let us meet on Tuesday.")
        expectNothing("Python→Google-like dictionary word", "I work at Python.", "I work at Apple.")
        expectNothing("into a dictionary word", "I work at home.", "I work at Office.")
        expectNothing("rename Priya→Zoya", "Ask Priya to call.", "Ask Zoya to call.")
        expectNothing("rename Mehta→Pype", "Ask Mehta to call.", "Ask Pype to call.")
        expectNothing("pronoun him→Priya", "I will call him later.", "I will call Priya later.")
        expectNothing("pronoun you→Priya", "I will call you later.", "I will call Priya later.")
        expectNothing("URL", "Visit our site today.", "Visit pype.ai today.")
        expectNothing("e-mail", "Mail me today.", "Mail dhruv@pype.ai today.")
        expectNothing("number", "I will be there at five.", "I will be there at 5.")
        expectNothing("Hinglish meri at start", "Mira Ghari Kahan Hai", "Meri Ghari Kahan Hai")
        expectNothing("Hinglish Mera→Meri", "Mera Gari Kahan Hip", "Meri Gari Kahan Hip")
        expectNothing("half-typed new name", "I work at Python.", "I work at Py.")
        expectNothing("new sentence typed after", "I work at Python.", "I work at Python. Pype is next.")

        // MARK: (c) Ordinary edits never become rules
        expectNothing("pipe→pipes", "The pipe bust again.", "The pipes bust again.")
        expectNothing("burst→broke", "The pipe burst in the kitchen.", "The pipe broke in the kitchen.")
        expectNothing("drove→drive", "I drove to the office.", "I drive to the office.")
        expectNothing("Drove→Drive at start", "Drove to the office.", "Drive to the office.")
        expectNothing("through→thorough", "We did a through review of the code.", "We did a thorough review of the code.")
        expectNothing("mera→meri", "yeh mera gaadi hai", "yeh meri gaadi hai")
        expectNothing("added comma", "Yes I can do that.", "Yes, I can do that.")
        expectNothing("sentence start capitalised", "the pipe burst again.", "The pipe burst again.")
        expectNothing("Mehta kept, bill→invoice", "Ask Mehta to send the bill.", "Ask Mehta to send the invoice.")
        expectNothing("Meta kept, call→email", "Meta and sons will call you.", "Meta and sons will email you.")
        expectNothing("word added", "Type the name again.", "Type the full name again.")

        // MARK: (d) Case-only fixes of a name
        expectLearn("pype→Pype (new name)", "I work at pype now.", "I work at Pype now.", rules: [r("Pype", "pype")])
        expectLearn("dhruv→Dhruv (new name)", "Ask dhruv to call.", "Ask Dhruv to call.", rules: [r("Dhruv", "dhruv")])
        expectLearn("pype→Pype, Pype confirmed", "I work at pype now.", "I work at Pype now.",
                    rules: [r("Pype", "pype")], existing: pype)
        expectNothing("pipe→Pipe (dictionary word)", "Use a pipe here.", "Use a Pipe here.")
        expectNothing("mira→Mira (known name)", "Ask mira to call.", "Ask Mira to call.")
        expectNothing("meri→Meri (Hinglish)", "yeh meri gaadi", "yeh Meri gaadi")
        do {
            let known = keyboard("I work at pype now.", "I work at Pype now.", existing: [r("Pype", "pype")], hasKey: false)
            check(known.count == 1 && known[0].gate == .reject && known[0].reason == "known", "pype→Pype already a rule → no card")
        }
        // SpellingRule: a case-only line now round-trips; older lines unchanged.
        let caseRule = r("Pype", "pype")
        check(SpellingRule.parse(caseRule.memoryLine) == caseRule, "case-only rule round-trips through memory.md")
        check(SpellingRule.parse(#""Pype" is the correct spelling — often heard as "Pype"."#) == nil, "identical pair is not a rule")
        check(SpellingRule.parse(#""Brite AI" is the correct spelling — often heard as "bright AI"."#) == r("Brite AI", "bright AI"),
              "old line still parses")
        check(SpellingRule.parse("“Mehra” is the correct spelling - often heard as “Mera”") == r("Mehra", "Mera"),
              "old curly/hyphen line still parses")
        check(SpellingRule.rules(from: [caseRule.memoryLine, r("Pype", "pipe").memoryLine]).count == 2,
              "case-only rule and sound rule coexist")
        let caseFound = CandidateFinder.find(in: "I work at pype now.", rules: [caseRule], screenTerms: []).map(\.term)
        check(caseFound == ["Pype"], "case-only rule reaches the apply side", "\(caseFound)")

        // MARK: Decision model outcomes
        let ask = RuleLearning.propose(.init(heard: "Drew", corrected: "Dhruv"), fixed: "My name is Dhruv.",
                                       source: .keyboard, existing: [], hasKey: true, isOrdinaryWord: ord)
        check(ask.gate == .askDecisionModel, "Drew→Dhruv asks")
        check(RuleLearning.learns(ask, decision: 0.8), "Jev yes → learn")
        check(!RuleLearning.learns(ask, decision: 0.3), "Jev no → no")
        check(RuleLearning.learns(ask, decision: nil), "Jev timeout → name extension learns (as keyless)")
        let marc = RuleLearning.propose(.init(heard: "Mark", corrected: "Marc"), fixed: "I met Marc.",
                                        source: .keyboard, existing: [], hasKey: true, isOrdinaryWord: ord)
        check(marc.gate == .askDecisionModel && marc.fallbackLearn, "Mark→Marc (ordinary word) asks, keyless fallback")
        check(RuleLearning.learns(marc, decision: nil), "Jev timeout → keyless gate decides (learn)")
        let marcNoKey = RuleLearning.propose(.init(heard: "Mark", corrected: "Marc"), fixed: "I met Marc.",
                                             source: .keyboard, existing: [], hasKey: false, isOrdinaryWord: ord)
        check(marcNoKey.gate == .learnDirect, "Mark→Marc keyless: old sound-alike gate still passes")

        // MARK: Negatives (keyboard)
        expectNothing("their→there", "their car is here", "there car is here")
        expectNothing("Their→There at start", "Their team is ready.", "There team is ready.")
        expectNothing("rewrite", "send me the file tomorrow", "share the deck with Ashish today")
        expectNothing("pipe→pipes", "the water pipe burst", "the water pipes burst")
        expectNothing("pipe→Pipe at sentence start", "pipe the output into grep", "Pipe the output into grep")
        // "through" → "Dhruv": an everyday word replaced — not learned,
        // even though Parakeet sometimes writes Dhruv as "through" (a rule
        // heard as "through" would hit every "through the door").
        expectNothing("through→Dhruv", "walk through the door", "walk Dhruv the door")
        expectNothing("through→Dhruv, Dhruv confirmed", "walk through the door", "walk Dhruv the door", existing: dhruv)
        expectNothing("Mark→Mike real-word swap", "I met Mark yesterday.", "I met Mike yesterday.")
        expectNothing("Sam→Pam different person", "Thanks Sam, see you.", "Thanks Pam, see you.")
        expectNothing("Drew→Drawn grammar at start", "Drew a diagram of the flow.", "Drawn a diagram of the flow.")
        expectNothing("form→from typo", "Form the team page", "From the team page")
        expectNothing("bright→Bri half-typed", "bright AI is hiring", "Bri AI is hiring")
        // Direct correction-level negatives (whatever a detector hands over).
        for (h, c) in [("pipe", "pipes"), ("pipe", "Pipe"), ("their", "there"), ("mera", "meri"),
                       ("Mehra", "Mehra's")] {
            for hasKey in [false, true] {
                let p = RuleLearning.propose(.init(heard: h, corrected: c), fixed: c, source: .keyboard,
                                             existing: [], hasKey: hasKey, isOrdinaryWord: ord)
                check(p.gate != .learnDirect, "\(h)→\(c) [\(hasKey ? "key" : "no key")] not learned directly",
                      "\(p.gate.rawValue) \(p.reason) \(show(p.rules))")
            }
        }

        // MARK: Spelled letters — real Parakeet output (probe 2026-10-12)
        let spelled: [(String, [String: String], String?)] = [
            ("My company is pipe, PYPE.", ["pipe": "Pype"], "My company is Pype."),
            ("My company is pipe, p yp.", ["pipe": "Pype"], "My company is Pype."),
            ("My company is Pipe. PYPE.", ["Pipe": "Pype"], "My company is Pype."),
            ("I work at pipe, that's spelled PYPE.", ["pipe": "Pype"], "I work at Pype."),
            ("I work at pipe, that's spelled PYP.", ["pipe": "Pype"], "I work at Pype."),
            ("It's pipe, P-Y-P-E, not pipe.", ["pipe": "Pype"], nil),
            ("It's pipe, p yp, not pipe.", ["pipe": "Pype"], nil),
            ("It's pipe, p yp, not fipe.", ["pipe": "Pype"], nil),
            ("Pipe, spelled PYP.", ["Pipe": "Pype"], "Pype."),
            ("My soname is MER, M-E-H-R-A.", ["MER": "Mehra"], "My soname is Mehra."),
            ("My surname is Mera M-E-H-R-A.", ["Mera": "Mehra"], "My surname is Mehra."),
            ("My surname is Mira, M-E-H-R-A.", ["Mira": "Mehra"], "My surname is Mehra."),
            ("Mer M-E-H-R-A.", ["Mer": "Mehra"], "Mehra."),
            ("Mayra, M E H R A", ["Mayra": "Mehra"], "Mehra"),
            ("My name is Druf, D-H-R-U-V.", ["Druf": "Dhruv"], "My name is Dhruv."),
            ("My name is Drew, DHRUV.", ["Drew": "Dhruv"], "My name is Dhruv."),
            ("My name is Drove, DHRUV.", ["Drove": "Dhruv"], "My name is Dhruv."),
            ("I'm Dhruvmehra, D-H-R-U-V, M-E-H-R-A.", ["Dhruvmehra": "Dhruv Mehra"], "I'm Dhruv Mehra."),
            ("Ein Druffmer, D-H-R-U-V, M-E-H-R-A.", ["Druffmer": "Dhruv Mehra"], "Ein Dhruv Mehra."),
            // Spelled right already: letters dropped, nothing learned.
            ("My surname is Mehra, M-E-H-R-A.", [:], "My surname is Mehra."),
            ("My name is Dhruv, D H R U V.", [:], "My name is Dhruv."),
            // "Dhruv" here is Parakeet's rendering of the spelled DHRUV —
            // must NOT teach Dhruv → Mehra.
            ("I'm Drew Meira, Dhruv, M E H R A.", [:], nil),
            ("I'm Drovmara, Dhruv, M-E-H-R-A.", [:], nil),
            // Not spellings.
            ("The water pipe burst, call a plumber.", [:], "The water pipe burst, call a plumber."),
            ("Plan A B C is the fallback.", [:], "Plan A B C is the fallback."),
            ("Use the AWS SDK, then the GCP API.", [:], "Use the AWS SDK, then the GCP API."),
            ("I hm, ok.", [:], "I hm, ok."),
        ]
        for (text, want, wantText) in spelled {
            let rw = RedictationLearner.spelledRewrite(text)
            var got: [String: String] = [:]
            for p in rw.pairs { got[p.heard] = p.corrected }
            check(got == want, "spelled: \(text)", "got \(got) want \(want)")
            if let wantText { check(rw.text == wantText, "spelled text: \(text)", "got \"\(rw.text)\"") }
            for p in rw.pairs {
                let prop = RuleLearning.propose(.init(heard: p.heard, corrected: p.corrected), fixed: p.sentence,
                                                source: .spelled, existing: [], hasKey: false, isOrdinaryWord: ord)
                check(prop.gate == .learnDirect, "spelled pair learns directly: \(text)")
            }
        }
        // (b) Letters with no sound-alike target: the one name in the
        // sentence(s) before them (real Parakeet, Aman: "My son name is Mana."
        // then "That's spelled M-E-H-R-A.").
        func follow(_ cur: String, _ prev: String) -> [String] {
            let now = Date()
            return RedictationLearner.detect(current: TranscriptTurn(text: cur, at: now, pid: 1),
                                             previous: [TranscriptTurn(text: prev, at: now.addingTimeInterval(-5), pid: 1)])
                .filter { $0.kind == .spelled && $0.strength >= RedictationLearner.directCardStrength }
                .map { "\($0.heard)→\($0.corrected)" }
        }
        check(follow("That's spelled M-E-H-R-A.", "My son name is Mana.") == ["Mana→Mehra"],
              "Mana + spelled M-E-H-R-A (next dictation) → Mehra", "\(follow("That's spelled M-E-H-R-A.", "My son name is Mana."))")
        check(follow("That's spelled M-E-H-R-A.", "My surname is Mana.") == ["Mana→Mehra"], "surname is Mana → Mehra")
        check(follow("That's spelled M-E-H-R-A.", "I met Priyar and Mana today.").isEmpty, "two candidate names → nothing")
        check(follow("That's spelled M-E-H-R-A.", "The weather is nice today.").isEmpty, "no name → nothing")
        check(follow("That's spelled M-E-H-R-A.", "Mana is a word.").isEmpty, "sentence-start dictionary word → nothing")
        check(follow("That's spelled M-E-H-R-A.", "I met Mana, Dhruv, and Ashish.").isEmpty, "aside between commas is not used")
        check(follow("That's spelled P Y P E.", "I work at Fight.").isEmpty, "dictionary word, sound unlike → nothing")
        for (text, want, wantText) in [
            ("My son name is Mana. That's spelled M-E-H-R-A.", ["Mana": "Mehra"], "My son name is Mehra."),
            ("I work at Zentrix. It is spelled P-Y-P-E.", ["Zentrix": "Pype"], "I work at Pype."),
            // The word right before the cue is the existing adjacent target.
            ("I met Priyar and Mana. That's spelled M-E-H-R-A.", ["Mana": "Mehra"], nil),
            ("My son name is Mana today. That's spelled M-E-H-R-A.", ["Mana": "Mehra"], "My son name is Mehra today."),
            ("I met Priyar and Mana today. That's spelled M-E-H-R-A.", [:], nil),
            // A trailing word the letters don't spell stays (real Parakeet).
            ("I met Priyar and Mehra today, that's spelled M-E-H-R-A.", [:], "I met Priyar and Mehra today."),
            ("Call Meta and Mare tomorrow. That's spelled M-E-H-R-A.", ["Mare": "Mehra"], "Call Meta and Mehra tomorrow."),
        ] as [(String, [String: String], String?)] {
            let rw = RedictationLearner.spelledRewrite(text)
            var got: [String: String] = [:]
            for p in rw.pairs where p.strength >= RedictationLearner.directCardStrength { got[p.heard] = p.corrected }
            check(got == want, "spelled (name target): \(text)", "got \(got) want \(want)")
            if let wantText { check(rw.text == wantText, "spelled text (name target): \(text)", "got \"\(rw.text)\"") }
        }
        // Spelled pair with two words splits per word too.
        let two = RuleLearning.propose(.init(heard: "Druv Mera", corrected: "Dhruv Mehra"), fixed: "",
                                       source: .spelled, existing: [], hasKey: false, isOrdinaryWord: ord)
        check(two.rules == [r("Dhruv Mehra", "Druv Mera"), r("Dhruv", "Druv"), r("Mehra", "Mera")],
              "spelled two-name pair → per-word rules", show(two.rules))

        // MARK: The founder's loop: rules reach the apply side
        let learned = [r("Pype", "pipe"), r("Dhruv", "druv"), r("Mehra", "mera"), r("Dhruv Mehra", "druv mera")]
        for (text, terms) in [("I work at pipe", ["Pype"]), ("this is druv mera", ["Dhruv Mehra"])] {
            let found = CandidateFinder.find(in: text, rules: learned, screenTerms: []).map(\.term)
            check(found == terms, "candidates for \"\(text)\"", "\(found)")
        }
        // Apply side (CandidateFinder, owned elsewhere): a possessive of a
        // learned word. Reported, not asserted here.
        let poss = CandidateFinder.find(in: "druv's laptop", rules: learned, screenTerms: []).map(\.term)
        print("NOTE  apply side: candidates for \"druv's laptop\" = \(poss)\(poss.isEmpty ? "  (possessive not matched)" : "")")

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
