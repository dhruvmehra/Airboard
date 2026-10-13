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
//        from the name AFTER it ("Drove Mehra" yes, "druv more often" no),
//        and a Hinglish word never next to Hindi context ("Dhruv mera dost
//        hai" stays);
//      · for the rule's exact heardAs only: capitalised mid-sentence
//        ("send it to Pipe by Friday"), or a company slot — after
//        at/join/called/named/founded, followed by the end of the clause or
//        a small word ("I work at pipe now", but not "look at pipe sizes").
//  - A heardAs that doesn't sound like its term ("Mehta" → Mehra, "Drew" →
//    Dhruv) or a one-sound-off match: decision engine only. Mehta is a real
//    surname; local evidence can't tell them apart.
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

    private struct Context {
        let text: String
        let words: [Range<String.Index>]
        init(_ text: String) { self.text = text; words = CandidateFinder.wordRanges(in: text) }

        /// Index of the first word starting at or after `i`.
        func index(atOrAfter i: String.Index) -> Int {
            var lo = 0, hi = words.count
            while lo < hi { let m = (lo + hi) / 2; if words[m].lowerBound < i { lo = m + 1 } else { hi = m } }
            return lo
        }
        /// The word right before `i`, only if nothing but spaces (and a
        /// title's dot) separates them.
        func wordBefore(_ i: String.Index, allowDot: Bool = false) -> String? {
            let k = index(atOrAfter: i) - 1
            guard k >= 0 else { return nil }
            let gap = text[words[k].upperBound..<i]
            guard gap.allSatisfy({ $0 == " " || (allowDot && $0 == ".") }) else { return nil }
            return String(text[words[k]]).lowercased()
        }
        /// What follows `i` (past a possessive suffix): nil = end of clause
        /// (end of text or punctuation), else the next word, lowercased.
        func next(after i: String.Index) -> String? {
            var j = i
            if text[j...].hasPrefix("'s") || text[j...].hasPrefix("\u{2019}s") { j = text.index(j, offsetBy: 2) }
            let rest = text[j...].drop(while: { $0 == " " })
            guard let f = rest.first, f.isLetter || f.isNumber else { return nil }
            let k = index(atOrAfter: rest.startIndex)
            return k < words.count ? String(text[words[k]]).lowercased() : nil
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
        let before = ctx.wordBefore(c.range.lowerBound)
        let hindiAround = after.map(hindiFollow.contains) == true || before.map(hinglish.contains) == true

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
                if ctx.capitalisedMidSentence(pieces[i].0) { verdicts[i] = .signal; continue }
                if pieces.count == 1, let b = before, slotBefore.contains(b),
                   after == nil || slotAfter.contains(after!) { verdicts[i] = .signal; continue }
                // "Pipe's roadmap": a possessive with no determiner before it
                // is a name ("the pipe's diameter" stays).
                if i == pieces.count - 1, ctx.possessive(after: c.range.upperBound),
                   !(before.map(determiners.contains) ?? false) { verdicts[i] = .signal; continue }
            }
        }
        // Pass 2: support from the other learned name in the span.
        if aligned {
            func anchors(_ j: Int) -> Bool {
                pieces.indices.contains(j) && usable[j] && (!changed[j] || kinds[j] == .name)
            }
            func ambiguousOK(_ j: Int) -> Bool {   // a Hinglish/first-name word that may move
                pieces.indices.contains(j) && changed[j] && usable[j] && kinds[j] == .soft && !hindiAround
            }
            for i in pieces.indices where changed[i] && usable[i] && verdicts[i] == .ask {
                switch kinds[i] {
                case .word:  // English word: only before the name ("Drove Meira", not "druv more")
                    if anchors(i + 1) || ambiguousOK(i + 1) { verdicts[i] = .signal }
                case .soft:
                    if !hindiAround && (anchors(i - 1) || anchors(i + 1)) { verdicts[i] = .signal }
                    else if ambiguousOK(i) && i == 1 && kinds[0] == .word && changed[0] && usable[0] {
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
    /// "I work at pipe", "join pipe", "a startup called pipe".
    static let slotBefore: Set<String> = ["at", "join", "joined", "joining", "joins", "called", "named", "founded", "cofounded"]
    /// …followed by the end of the clause or one of these.
    static let slotAfter: Set<String> = ["now", "today", "tomorrow", "yesterday", "since", "as", "and", "or", "but",
                                         "in", "on", "for", "too", "again", "so", "because", "where", "which",
                                         "who", "with", "this", "last", "next", "full", "anymore", "is", "was"]
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
