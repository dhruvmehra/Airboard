//
//  VocabularyResolver.swift
//
//  Turns candidates (+ decision-engine answers, when there are any) into
//  the final text. Pure: no I/O except the lazily loaded system word list.
//  Foundation-only: compiles standalone for scratch tests.
//
//  Apply policy for a CONFIRMED rule (the user already taught it), word by
//  word of the heard span:
//
//  - Not an ordinary word ("Druv", "Dhruva", "Meyra", fused "Dhruvmehra",
//    "pipe's" → stem) and it matched by exact heardAs or the same sound
//    code: applied locally — no decision engine, key or not, never waits on
//    the network ("unmistakable").
//  - An ordinary word ("pipe", "drove", "more"), a Hinglish word ("mera"),
//    or a dictionary first name ("Mira", "Mary", "Drew"): ambiguous. With an
//    answer from the decision engine, the engine decides (≥ applyThreshold).
//    With NO answer (no key, timeout, hands-free) it applies only on a
//    strong local signal:
//      · a title right before it ("Mr. Mera", "Mister Mayor");
//      · it sits next to another learned name in the same span ("druv mera",
//        "Drove Meira" → "Dhruv Mehra"). An English word only takes support
//        from the name AFTER it, and only in a NAME SLOT: the start of a
//        clause, after a preposition, "is", a greeting, a verb that takes a
//        person, a Hinglish opener, or "<Name> and" ("This is Drove Mera",
//        "spoke to Drove Mera", "Regards, Drove Mera") — never after a
//        subject or a noun ("I drove Mehra to the airport", "Dad drove Mera
//        home", "Mary drove Mehra") or before an object ("drove the car").
//        A Hinglish word never moves next to Hindi context ("Dhruv mera dost
//        hai" stays);
//      · for the rule's exact heardAs only: capitalised mid-sentence ("send
//        it to Pipe by Friday") unless it reads as a verb ("He Drove the
//        car"), follows "at" ("Look at Pipe now") or starts a place name
//        ("at Pipe Street"); a company slot — join/called/named/founded, or
//        "at" after a workplace word (work/met/team/engineer…), then the end
//        of the clause or a small word ("I work at pipe now", not "Look at
//        pipe now"; "at pipe and I…", not "at pipe and fittings"); a
//        company suffix after it ("Pipe AI ships");
//      · a person slot — after email/message/call/tell/ask/thanks…, then the
//        end of the clause or a small word ("Email drove about the launch"):
//        the exact heardAs, or the same sound for a 3+ sound name;
//      · a Hinglish exact heardAs capitalised mid-sentence in a sentence
//        with no Hindi word ("Please ask Mera to sign"), never a dictionary
//        first name ("Mira");
//      · the user's own learned heard form that doesn't sound like its term,
//        right before the other learned name, in a name slot ("Drew Mehra" →
//        "Dhruv Mehra");
//      · a non-dictionary learned name with one glued-on sound ("Dhruvan the
//        team", Candidate.Match.extended) — not a glued Hindi particle
//        ("Dhruvji" stays);
//      · a learned name + an unknown lowercase word ("Dhruvmehra", "Dhruv
//        mehra" with only Dhruv learned → "Dhruv Mehra"; "Drovera"),
//        Candidate.Match.tail — not in a Hindi sentence.
//    Anything else ambiguous waits for the decision engine and stays as
//    heard without one.
//  - A heardAs that doesn't sound like its term ("Mehta" → Mehra, "Drew" →
//    Dhruv) or a one-sound-off match: decision engine only (except the
//    name-anchor and glued-sound cases above). Mehta is a real surname;
//    local evidence can't tell them apart.
//  - A confirmed exact MULTI-word heardAs ("bright AI"): applied locally
//    (unchanged from before).
//  Screen terms are only ever suggestions, decision engine only.
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

    /// Per heard word of a candidate.
    enum Verdict: Equatable {
        case apply   // unmistakable: applied with or without an answer
        case signal  // applied with no answer; the engine decides when it answers
        case ask     // engine only
    }

    /// answers are keyed by Candidate.pairKey — one answer covers every
    /// occurrence of that (span, term) pair. A pair with no answer (nil
    /// answers, or a pair that wasn't asked) falls back to the local policy.
    static func resolve(text: String, candidates: [Candidate], answers: [String: Double]?,
                        isOrdinaryWord: (String) -> Bool = WordList.isOrdinaryWord,
                        isKnownName: (String) -> Bool = WordList.isKnownName) -> Result {
        var replacements: [(Range<String.Index>, String)] = []
        var suggestions: [Candidate] = []
        let ctx = candidates.contains { $0.source == .rule } ? Context(text) : nil
        for c in candidates {
            let p = answers?[c.pairKey]
            switch c.source {
            case .screen:
                if let p, p >= suggestThreshold { suggestions.append(c) }
            case .rule:
                if let p, p >= applyThreshold {
                    replacements.append((c.range, c.term)); continue
                }
                guard let ctx else { continue }
                let units = Self.units(c, ctx, isOrdinaryWord, isKnownName)
                let applied = units.filter { $0.verdict == .apply || ($0.verdict == .signal && p == nil) }
                if applied.count == units.count && !units.isEmpty {
                    replacements.append((c.range, c.term))
                } else {
                    for u in applied { replacements.append((u.range, u.term)) }
                }
            }
        }
        var out = text
        // Back to front so earlier ranges stay valid.
        for (range, term) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: term)
        }
        return Result(text: out, applied: replacements.count, suggestions: suggestions)
    }

    /// Whether the decision engine has anything to add for this candidate:
    /// false when every heard word applies locally anyway — the dictation
    /// path then skips the network for it.
    static func needsDecision(_ c: Candidate, in text: String,
                              isOrdinaryWord: (String) -> Bool = WordList.isOrdinaryWord,
                              isKnownName: (String) -> Bool = WordList.isKnownName) -> Bool {
        guard c.source == .rule else { return true }
        return units(c, Context(text), isOrdinaryWord, isKnownName).contains { $0.verdict != .apply }
    }

    // MARK: - Word-level policy

    struct Unit {
        let range: Range<String.Index>
        let term: String
        let verdict: Verdict
    }

    private enum Kind { case name, word, soft }  // not a word / English word / Hinglish or first name

    private final class Context {
        let text: String
        let words: [Range<String.Index>]
        init(_ text: String) { self.text = text; words = CandidateFinder.wordRanges(in: text) }
        /// Per word: its sentence number; per sentence: holds a Hindi word.
        /// Built once, only when a Hinglish candidate needs it.
        private lazy var sentences: (of: [Int], hindi: [[String]]) = {
            var of: [Int] = [], hindi: [[String]] = [[]]
            var prevEnd = text.startIndex
            for w in words {
                if text[prevEnd..<w.lowerBound].contains(where: { ".!?\n".contains($0) }) { hindi.append([]) }
                let l = String(text[w]).lowercased()
                if VocabularyResolver.hinglish.contains(l) || VocabularyResolver.hindiFollow.contains(l) {
                    hindi[hindi.count - 1].append(l)
                }
                of.append(hindi.count - 1)
                prevEnd = w.upperBound
            }
            return (of, hindi)
        }()

        /// Index of the first word starting at or after `i`.
        func index(atOrAfter i: String.Index) -> Int {
            var lo = 0, hi = words.count
            while lo < hi { let m = (lo + hi) / 2; if words[m].lowerBound < i { lo = m + 1 } else { hi = m } }
            return lo
        }
        /// The word right before `i`, only if nothing but spaces (and a
        /// title's dot) separates them.
        func wordBefore(_ i: String.Index, allowDot: Bool = false) -> String? {
            rangeBefore(i, allowDot: allowDot).map { String(text[$0]).lowercased() }
        }
        /// Range of that word (nil at the start of a clause).
        func rangeBefore(_ i: String.Index, allowDot: Bool = false) -> Range<String.Index>? {
            let k = index(atOrAfter: i) - 1
            guard k >= 0 else { return nil }
            let gap = text[words[k].upperBound..<i]
            guard gap.allSatisfy({ $0 == " " || (allowDot && $0 == ".") }) else { return nil }
            return words[k]
        }
        /// What follows `i` (past a possessive suffix): nil = end of clause
        /// (end of text or punctuation), else the next word, lowercased.
        func next(after i: String.Index) -> String? {
            nextRange(after: i).map { String(text[$0]).lowercased() }
        }
        func nextRange(after i: String.Index) -> Range<String.Index>? {
            var j = i
            if text[j...].hasPrefix("'s") || text[j...].hasPrefix("\u{2019}s") { j = text.index(j, offsetBy: 2) }
            let rest = text[j...].drop(while: { $0 == " " })
            guard let f = rest.first, f.isLetter || f.isNumber else { return nil }
            let k = index(atOrAfter: rest.startIndex)
            return k < words.count ? words[k] : nil
        }
        /// Any Hindi/Hinglish word in the sentence around `r` (other than
        /// the word itself).
        func hindiInSentence(around r: Range<String.Index>, ignoring: Set<String> = []) -> Bool {
            let k = index(atOrAfter: r.lowerBound)
            guard k < words.count else { return false }
            let me = String(text[r]).lowercased()
            var found = sentences.hindi[sentences.of[k]]
            if let i = found.firstIndex(of: me) { found.remove(at: i) }
            return found.contains { !ignoring.contains($0) }
        }
        /// End of the first word at or after `i` (`i` itself when none).
        func wordEnd(after i: String.Index) -> String.Index {
            let k = index(atOrAfter: i)
            return k < words.count ? words[k].upperBound : i
        }
        func possessive(after i: String.Index) -> Bool {
            text[i...].hasPrefix("'s") || text[i...].hasPrefix("\u{2019}s")
        }
        /// Capital letter in the middle of a sentence (not the first word,
        /// not after . ! ? : or a line break, unless a title's dot).
        func capitalisedMidSentence(_ r: Range<String.Index>) -> Bool {
            guard let f = text[r].first, f.isUppercase else { return false }
            let before = text[..<r.lowerBound].reversed().drop(while: { $0 == " " || $0 == "\"" || $0 == "\u{201C}" })
            guard let p = before.first else { return false }
            if ".!?:\n".contains(p) { return p == "." && wordBefore(r.lowerBound, allowDot: true).map(VocabularyResolver.titles.contains) == true }
            return true
        }
    }

    private static func units(_ c: Candidate, _ ctx: Context,
                              _ isOrdinaryWord: (String) -> Bool, _ isKnownName: (String) -> Bool) -> [Unit] {
        let text = ctx.text
        let first = ctx.index(atOrAfter: c.range.lowerBound)
        var spanWords: [Range<String.Index>] = []
        var k = first
        while k < ctx.words.count, ctx.words[k].lowerBound < c.range.upperBound {
            let w = ctx.words[k]
            spanWords.append(w.lowerBound..<min(w.upperBound, c.range.upperBound))
            k += 1
        }
        let termWords = c.term.split(separator: " ").map(String.init)
        // A learned name + an unknown word ("Dhruvmehra", "Dhruv mehra",
        // "Drovera"): the learned part as usual (a non-dictionary heard form
        // applies), the unknown word with no answer only outside a Hindi
        // sentence ("Dhruv mehra" yes; a Hindi word nobody listed, no).
        if c.parts.last == .tail {
            let veto = ctx.hindiInSentence(around: c.range, ignoring: postpositions)
            let tailVerdict: Verdict = veto ? .ask : .signal
            if spanWords.count == 1 { return [Unit(range: c.range, term: c.term, verdict: tailVerdict)] }
            guard spanWords.count == 2, termWords.count == 2 else { return [] }
            var out: [Unit] = []
            if String(text[spanWords[0]]) != termWords[0] {
                out.append(Unit(range: spanWords[0], term: termWords[0], verdict: .apply))
            }
            out.append(Unit(range: spanWords[1], term: termWords[1], verdict: tailVerdict))
            return out
        }
        // Confirmed exact multi-word phrase: as before, applied as a whole.
        if c.exact && spanWords.count >= 2 {
            return [Unit(range: c.range, term: c.term, verdict: .apply)]
        }
        let aligned = spanWords.count == termWords.count && spanWords.count > 1
        let pieces: [(Range<String.Index>, String, Candidate.Match)] = aligned
            ? spanWords.indices.map { (spanWords[$0], termWords[$0], c.parts.indices.contains($0) ? c.parts[$0] : c.match) }
            : [(c.range, c.term, c.match)]

        func kind(_ r: Range<String.Index>) -> Kind {
            let ws = CandidateFinder.normalize(String(text[r])).split(separator: " ").map(String.init)
            var kinds = ws.map { w -> Kind in
                if hinglish.contains(w) { return .soft }
                if isOrdinaryWord(w) || inflected(w, isOrdinaryWord) { return .word }
                if isKnownName(w) { return .soft }
                return .name
            }
            if kinds.isEmpty { kinds = [.word] }
            // A multi-word piece is a name only if no word in it is ordinary.
            if kinds.allSatisfy({ $0 == .name }) { return .name }
            return kinds.contains(.word) ? .word : .soft
        }
        let changed = pieces.map { String(text[$0.0]) != $0.1 }
        let kinds = pieces.map { kind($0.0) }
        let usable = pieces.map { $0.2 == .exact || $0.2 == .sameSound || $0.2 == .correct }
        let narrower = !aligned && spanWords.count < termWords.count

        // Context around the whole span.
        let title = ctx.wordBefore(c.range.lowerBound, allowDot: true).map(titles.contains) ?? false
        let after = ctx.next(after: c.range.upperBound)
        let beforeRange = ctx.rangeBefore(c.range.lowerBound)
        let before = beforeRange.map { String(text[$0]).lowercased() }
        let hindiAround = after.map(hindiFollow.contains) == true || before.map(hinglish.contains) == true

        // Syntax around the span, for an ORDINARY word moving with no
        // answer ("drove", "pipe"): it moves only where it reads as a name.
        /// A subject right before it makes it a verb: "I drove", "He Drove",
        /// "Mary drove", "Rahul drove", "will pipe".
        func subjectBefore() -> Bool {
            guard let br = beforeRange, let b = before else { return false }
            if subjects.contains(b) || auxiliaries.contains(b) { return true }
            // A capitalised name or first name right before (not a title,
            // not a Hinglish opener like "Main"/"Ye").
            // (Only before a lowercase span: "Dhruv Pipe", "Mary Mehra" read
            // as one longer name.)
            let w = text[br]
            guard text[c.range].first?.isLowercase == true,
                  w.first?.isUppercase == true, w.contains(where: { $0.isLowercase }),  // not "CEO"
                  !titles.contains(b), !roleNouns.contains(b), !hinglish.contains(b),
                  !hindiIntro.contains(b) else { return false }
            return isKnownName(b) || !(isOrdinaryWord(b) || inflected(b, isOrdinaryWord))
        }
        /// …and so does an object right after it: "Drove the car", "Pipe it".
        /// (A lowercase one: "Pipe A yet" is not "Pipe a".)
        let objectAfter = !ctx.possessive(after: c.range.upperBound)
            && ctx.nextRange(after: c.range.upperBound).map {
                text[$0].first?.isLowercase == true
                    && (determiners.contains(text[$0].lowercased()) || objects.contains(text[$0].lowercased()))
            } == true
        let placeAfter = after.map(placeNouns.contains) == true
        let verbReading = subjectBefore() || objectAfter
        /// Where a name goes: the start of a clause, after a preposition,
        /// "is", a greeting or a verb that takes a person ("This is Drove
        /// Mera", "spoke to Drove Mera", "Regards, Drove Mera"), a Hinglish
        /// opener ("Main drove Mayor hoon"), or in a list of names ("Rahul
        /// and Drove Mera"). Never after a subject or a noun: "I drove
        /// Mehra", "Dad drove Mera home", "The mayor drove Mehra home".
        func nameSlot() -> Bool {
            if verbReading { return false }
            guard let br = beforeRange, let b = before else { return true }
            if titles.contains(b) || nameIntro.contains(b) || personBefore.contains(b)
                || hinglish.contains(b) || hindiIntro.contains(b) { return true }
            if b == "and" || b == "or" {
                guard let pr = ctx.rangeBefore(br.lowerBound) else { return false }
                let p = String(text[pr])
                return p.first?.isUppercase == true && !subjects.contains(p.lowercased())
            }
            // "Our CEO Drove Mera" (or Parakeet's "RCU Drove Mara"): a
            // role or an acronym, then a capitalised span.
            let w = text[br]
            if roleNouns.contains(b) || (w.count >= 2 && w.allSatisfy({ $0.isUppercase })) {
                return text[c.range].first?.isUppercase == true
            }
            return false
        }
        /// "I work at pipe", "We met at pipe", "join pipe": "at" only after
        /// a word about a workplace — not "Look at pipe now", "Stop at pipe
        /// and fittings".
        func companySlot() -> Bool {
            guard let br = beforeRange, let b = before, slotBefore.contains(b), !placeAfter else { return false }
            if b == "at" {
                let pb = ctx.wordBefore(br.lowerBound)
                // "…to Dhruv at pipe." ends the clause: a place of work
                // unless something is being looked or aimed at.
                if after == nil { return !(pb.map(lookAt.contains) ?? false) }
                guard let pb, workAt.contains(pb) else { return false }
            }
            guard let a = after else { return true }
            guard slotAfter.contains(a) else { return false }
            // "at pipe and fittings" is a list of materials; "at pipe and
            // I love it" starts a new clause.
            if a == "and" || a == "or" || a == "but" {
                return ctx.next(after: ctx.wordEnd(after: c.range.upperBound)).map(subjects.contains) == true
            }
            return true
        }

        var verdicts = [Verdict](repeating: .ask, count: pieces.count)
        // Pass 1: unmistakable, and signals that don't depend on neighbours.
        for i in pieces.indices where changed[i] && usable[i] {
            if kinds[i] == .name {
                // Two names fused into one word, then Hindi ("Drvmera dost
                // hai"): the "mera" half is likely "my" — let the engine say.
                let fusedPair = !aligned && c.parts.count == 2
                verdicts[i] = fusedPair && hindiAround ? .ask : .apply
                continue
            }
            if narrower { continue }
            if i == 0 && title { verdicts[i] = .signal; continue }
            if pieces[i].2 == .exact && kinds[i] == .word {
                // Capitalised mid-sentence, unless it reads as a verb ("He
                // Drove the car") or part of a place ("at Pipe Street").
                // After "at" only in a company slot ("Look at Pipe now" is
                // ambiguous).
                if pieces.count == 1, !verbReading, !placeAfter, before != "at",
                   ctx.capitalisedMidSentence(pieces[i].0) { verdicts[i] = .signal; continue }
                if pieces.count == 1, companySlot() { verdicts[i] = .signal; continue }
                // A company suffix right after it: "Pipe AI ships voice
                // agents", "pipe Labs" (as written: "AI", not "ai").
                if pieces.count == 1, !subjectBefore(), let nr = ctx.nextRange(after: c.range.upperBound),
                   !ctx.possessive(after: c.range.upperBound), brandSuffixes.contains(String(text[nr])) {
                    verdicts[i] = .signal; continue
                }
                // "Pipe's roadmap": a possessive with no determiner before it
                // is a name ("the pipe's diameter" stays).
                if i == pieces.count - 1, ctx.possessive(after: c.range.upperBound), !subjectBefore(),
                   !(before.map(determiners.contains) ?? false) { verdicts[i] = .signal; continue }
            }
            // A person slot: "Email drove", "Call drove tomorrow", "Message
            // drove on Slack" — an ordinary word right after a verb that
            // takes a person, then the end of the clause or a small word.
            // The rule's exact heardAs, or the same sound for a 3+ sound
            // name (never a 2-sound one: "Call Mary" must not become Mehra).
            if pieces.count == 1, kinds[i] == .word, let b = before, personBefore.contains(b),
               after == nil || personAfter.contains(after!), !placeAfter,
               pieces[i].2 == .exact || SoundCode.code(pieces[i].1).count >= 3 {
                verdicts[i] = .signal; continue
            }
            // A Hinglish word that is the rule's exact heardAs, capitalised
            // mid-sentence in a sentence with no Hindi in it: "Please ask
            // Mera to sign" (Parakeet capitalises Hinglish words too, so
            // any Hindi word in the sentence vetoes). Never a dictionary
            // first name ("Mira", "Mara"): those may be real people.
            if pieces[i].2 == .exact, kinds[i] == .soft, !isKnownName(String(text[pieces[i].0])),
               ctx.capitalisedMidSentence(pieces[i].0), !ctx.hindiInSentence(around: pieces[i].0) {
                verdicts[i] = .signal; continue
            }
        }
        // A non-dictionary word that is a learned name plus one glued-on
        // sound ("Dhruvan the team", "to Drovat Pype"), same first letter:
        // applied with no answer; the engine decides when it answers. Not
        // when the glued sound is a Hindi particle ("Dhruvji", "Drovka":
        // replacing would delete the "ji"/"ka").
        if pieces.count == 1, changed[0], kinds[0] == .name, pieces[0].2 == .extended,
           let h = text[pieces[0].0].lowercased().first, h == pieces[0].1.lowercased().first,
           !gluedParticles.contains(where: { text[pieces[0].0].lowercased().hasSuffix($0) }) {
            verdicts[0] = .signal
        }
        // Pass 2: support from the other learned name in the span.
        if aligned {
            func anchors(_ j: Int) -> Bool {
                pieces.indices.contains(j) && usable[j] && (!changed[j] || kinds[j] == .name)
            }
            func ambiguousOK(_ j: Int) -> Bool {   // a Hinglish/first-name word that may move
                pieces.indices.contains(j) && changed[j] && usable[j] && kinds[j] == .soft && !hindiAround
            }
            for i in pieces.indices where changed[i] && verdicts[i] == .ask {
                // The user's own learned heard form that doesn't sound like
                // its term ("Drew" for Dhruv) moves only right before the
                // other learned name: "Drew Mehra" → "Dhruv Mehra".
                // An English word moves only in a name slot: "This is Drove
                // Mera", never "I drove Mehra to the airport".
                // (A brand phrase heard word for word — "tried pipe AI" for
                // "Pype AI" — is one term, not two names: no slot needed.)
                let slot = i == 0 && (c.parts.isEmpty || nameSlot())
                if pieces[i].2 == .exactUnlike, kinds[i] == .word, slot, anchors(i + 1) { verdicts[i] = .signal; continue }
                guard usable[i] else { continue }
                switch kinds[i] {
                case .word:  // English word: only before the name ("Drove Meira", not "druv more")
                    if slot && (anchors(i + 1) || ambiguousOK(i + 1)) { verdicts[i] = .signal }
                case .soft:
                    if !hindiAround && (anchors(i - 1) || anchors(i + 1)) { verdicts[i] = .signal }
                    else if ambiguousOK(i) && i == 1 && kinds[0] == .word && changed[0] && usable[0]
                                && verdicts[0] == .signal {
                        verdicts[i] = .signal  // "Drove Mera": both move together
                    }
                case .name: break
                }
            }
        }
        return pieces.indices.compactMap { i in
            changed[i] ? Unit(range: pieces[i].0, term: pieces[i].1, verdict: verdicts[i]) : nil
        }
    }

    /// "pipes", "typed", "driving": an inflection of a dictionary word
    /// (the system list has few plurals).
    private static func inflected(_ w: String, _ isOrdinaryWord: (String) -> Bool) -> Bool {
        for (suffix, repl) in [("ies", "y"), ("es", ""), ("s", ""), ("ed", ""), ("ed", "e"), ("ing", ""), ("ing", "e")]
            where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            if isOrdinaryWord(String(w.dropLast(suffix.count)) + repl) { return true }
        }
        return false
    }

    static var titles: Set<String> { CandidateFinder.titles }
    static let determiners: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "our", "your",
                                           "his", "her", "its", "their", "every", "each", "one", "no", "any", "some"]
    /// A subject (or an auxiliary) right before an ordinary word makes it a
    /// verb: "I drove", "who drove", "will pipe".
    static let subjects: Set<String> = ["i", "you", "he", "she", "we", "they", "it", "who", "that", "which",
                                        "somebody", "someone", "everyone", "everybody", "nobody", "anyone",
                                        "anybody", "i'd", "we'd", "he'd", "she'd", "they'd", "you'd"]
    static let auxiliaries: Set<String> = ["will", "would", "can", "could", "should", "must", "might", "did",
                                           "didn't", "never", "just", "also", "then", "always", "already",
                                           "finally", "really", "still", "only", "even", "once", "nearly",
                                           "almost", "quickly", "slowly", "probably", "actually", "usually"]
    /// An object pronoun right after it: "drove him", "pipe it".
    static let objects: Set<String> = ["me", "him", "us", "them", "it", "you", "her", "myself", "himself",
                                       "herself", "themselves", "ourselves", "yourself", "everyone"]
    /// Words a name follows (besides personBefore, titles and Hinglish).
    static let nameIntro: Set<String> = ["to", "with", "from", "for", "by", "about", "of", "via", "than", "like",
                                         "as", "is", "was", "am", "are", "be", "been", "it's", "meet", "met",
                                         "meeting", "introduce", "introducing", "welcome", "hi", "hello", "hey",
                                         "dear", "regards", "cheers", "sincerely", "congrats", "congratulations",
                                         "namaste", "named", "called", "including", "per", "cc"]
    /// "Main drove Mayor hoon", "Yeah drove Merikar laptop": Parakeet's
    /// renderings of Hindi sentence openers.
    static let hindiIntro: Set<String> = ["main", "yeah", "ye", "yeh"]
    /// "Our CEO Drove Mera" (only with a capitalised span).
    static let roleNouns: Set<String> = ["ceo", "cto", "coo", "cfo", "founder", "cofounder", "co-founder", "boss",
                                         "manager", "colleague", "teammate", "friend", "mentor", "investor"]
    /// "<word> at pipe" that names a workplace.
    static let workAt: Set<String> = ["work", "works", "worked", "working", "job", "jobs", "intern", "interning",
                                      "internship", "engineer", "engineers", "designer", "developer", "founder",
                                      "cofounder", "ceo", "cto", "coo", "cfo", "pm", "manager", "lead", "head",
                                      "employee", "employees", "team", "colleague", "colleagues", "friends",
                                      "folks", "people", "everyone", "someone", "met", "meet", "meeting", "here",
                                      "role", "position", "hired", "hiring", "joined", "started", "start",
                                      "starting", "interview", "interviewed", "interviewing", "offer", "day",
                                      "days", "year", "years", "stint", "tenure", "build", "building", "builds"]
    /// Written right after a company name: "Pipe AI", "pipe Labs".
    static let brandSuffixes: Set<String> = ["AI", "HQ", "Labs", "Inc", "Inc.", "Ltd", "LLC", "Technologies",
                                             "Pvt", "Corp", "GmbH"]
    /// "<word> at pipe." that is about the thing, not a workplace.
    static let lookAt: Set<String> = ["look", "looks", "looked", "looking", "stare", "stares", "stared", "staring",
                                      "glance", "glanced", "glancing", "point", "points", "pointed", "pointing",
                                      "aim", "aimed", "aiming", "laugh", "laughed", "shout", "shouted", "yell",
                                      "yelled", "good", "bad", "better", "best", "great", "expert", "hit", "throw",
                                      "threw", "swing", "swung", "grab", "grabbed", "pull", "pulled", "tug"]
    /// "at Pipe Street", "Pipe Junction": part of a place name.
    static let placeNouns: Set<String> = ["street", "st", "road", "rd", "lane", "avenue", "ave", "junction",
                                          "station", "square", "park", "nagar", "colony", "marg", "bridge",
                                          "river", "lake", "hill", "hills", "valley", "tower", "towers", "mall",
                                          "market", "chowk", "circle", "cross", "gate", "plaza", "center",
                                          "centre", "drive", "way", "place", "terrace", "court", "village"]
    /// "I work at pipe", "join pipe", "a startup called pipe".
    static let slotBefore: Set<String> = ["at", "join", "joined", "joining", "joins", "called", "named", "founded", "cofounded"]
    /// …followed by the end of the clause or one of these.
    static let slotAfter: Set<String> = ["now", "today", "tomorrow", "yesterday", "since", "as", "and", "or", "but",
                                         "in", "on", "for", "too", "again", "so", "because", "where", "which",
                                         "who", "with", "this", "last", "next", "full", "anymore", "is", "was"]
    /// "Email drove", "Call drove tomorrow": verbs that take a person…
    static let personBefore: Set<String> = ["email", "emailed", "emailing", "message", "messaged", "call", "ping",
                                            "pinged", "text", "texted", "tell", "told", "ask", "asked", "thank",
                                            "thanks", "cc", "invite", "invited", "remind", "reminded", "dm"]
    /// …followed by the end of the clause or one of these.
    static let personAfter: Set<String> = slotAfter.union(["about", "on", "to", "tomorrow", "tonight", "later",
                                                           "please", "back", "asap", "re"])
    /// Common Hindi/Hinglish words as Parakeet writes them — ordinary, so a
    /// learned "Mehra" ← "mera" never fires in "mera naam Rahul hai".
    /// Includes Parakeet's renderings of "mera" (meera, mira, mara).
    static let hinglish: Set<String> = [
        "mera", "meri", "mere", "meera", "mira", "miri", "mara", "tera", "teri", "tere", "apna", "apni", "apne",
        "uska", "uski", "unka", "hamara", "humara", "tumhara", "aapka", "yeh", "ye", "woh", "wo", "voh",
        "hai", "hain", "tha", "thi", "ho", "hoon", "hun", "kya", "kaun", "kahan", "kab", "kyun", "kaise",
        "nahi", "nahin", "haan", "aur", "bhi", "toh", "ka", "ki", "ke", "ko", "se", "ne", "mein", "pe", "par",
        "dost", "bhai", "behen", "behan", "didi", "ghar", "naam", "nam", "kaam", "paas", "liye", "wala", "wali",
        "raha", "rahi", "rahe", "gaya", "gayi", "karo", "karna", "kar", "kal", "aaj", "abhi", "bahut",
        "accha", "acha", "theek", "chalo", "dekho", "bolo", "suno", "ji", "yaar", "arre",
    ]
    /// Hindi kinship words and honorifics Parakeet writes after a name
    /// ("Dhruv bhaiya", "Dhruvji") — never a surname to capitalise.
    static let honorifics: Set<String> = ["bhaiya", "bhaiyya", "bhaiyaa", "bhaisahab", "sahab", "saab", "sahib",
                                          "jee", "dada", "kaka", "chacha", "chachu", "mama", "mamu", "mausi",
                                          "nana", "nani", "dadi", "bhabhi", "jiju", "beta", "babu", "bhaiji",
                                          "uncle", "aunty", "auntie", "sir", "madam", "maam", "bro", "bhaijaan",
                                          "wala", "wali", "wale", "waala", "waali", "kaa", "kii", "kee", "koo"]
    static func isHindiWord(_ w: String) -> Bool {
        let l = w.lowercased()
        return hinglish.contains(l) || hindiFollow.contains(l) || honorifics.contains(l)
    }
    /// Hindi particles Parakeet glues onto a name: "Dhruvji", "Drovka".
    static let gluedParticles: [String] = ["ji", "jee", "ka", "ki", "ke", "ko", "se", "ne", "kaa", "wala", "wali"]
    /// "Dhruv Mehra ka laptop" is a name: these don't make a sentence Hindi.
    static let postpositions: Set<String> = ["ka", "ki", "ke", "ko", "se", "ne", "ji"]
    /// After a "mera": Hindi context (it means "my"). Postpositions are NOT
    /// here — "Mehra ka laptop" is a name. "dust"/"high" are how Parakeet
    /// writes "dost"/"hai".
    static let hindiFollow: Set<String> = hinglish
        .subtracting(["ka", "ki", "ke", "ko", "se", "ne", "ji", "mera", "meri", "mere", "meera", "mira", "miri", "mara"])
        .union(["dust", "high"])

    // MARK: - System word list

    /// /usr/share/dict/words (present on every Mac), loaded once, lazily —
    /// warm it off the dictation path with `_ = VocabularyResolver.WordList.words`.
    enum WordList {
        /// Lowercase entries ("pipe", "drove", "more").
        static let words: (lower: Set<String>, names: Set<String>) = load()

        static func isOrdinaryWord(_ w: String) -> Bool { words.lower.contains(w.lowercased()) }
        /// Capitalised-only entries, lowercased ("mira", "mara") — first
        /// names the user may really mean.
        static func isKnownName(_ w: String) -> Bool { words.names.contains(w.lowercased()) }

        static func load(path: String = "/usr/share/dict/words") -> (lower: Set<String>, names: Set<String>) {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return ([], []) }
            var lower = Set<String>(), names = Set<String>()
            lower.reserveCapacity(240_000)
            for line in s.split(separator: "\n") {
                let w = String(line).trimmingCharacters(in: .whitespaces)
                guard !w.isEmpty else { continue }
                let l = w.lowercased()
                if w == l { lower.insert(w) } else { names.insert(l) }
            }
            names.subtract(lower)
            return (lower, names)
        }
    }
}
