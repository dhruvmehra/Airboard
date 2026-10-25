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
    /// How the span matched its term — VocabularyResolver decides from this
    /// (plus how ordinary the heard words are) whether it may apply with no
    /// decision engine.
    enum Match: Equatable {
        case exact        // a confirmed rule's heardAs that sounds like its term ("druv")
        case exactUnlike  // a confirmed heardAs that does NOT sound like its term ("Mehta" for Mehra)
        case sameSound    // identical sound code ("Dhruva", "Pipe's", "DRUV")
        case near         // one sound off (4+ sound codes only)
        case extended     // the term's sounds plus ONE at the end, 3+ sound
                          // term ("Dhruvan"/"Drovat" for Dhruv: ASR glued
                          // the next word on)
        case correct      // (composite part only) already the term: "Dhruv" in "Dhruv mera"
        case tail         // (composite part only) an unknown word glued to or right after a
                          // learned name, as heard: "Dhruvmehra" / "Dhruv mehra" with only
                          // Dhruv learned ("Mehra", capitalised), or the swallowed tail of
                          // another learned name ("Drovera" → Dhruv Mehra)
    }
    let range: Range<String.Index>  // span in the transcript (a possessive's stem only)
    let span: String                // the text as heard, e.g. "bright AI"
    let term: String                // what it might be, e.g. "Brite AI"
    let source: Source
    let exact: Bool                 // span equals a confirmed rule's heardAs
    var match: Match = .near
    /// Two learned one-word names heard side by side ("druv mera" →
    /// "Dhruv Mehra", or fused "Dhruvmehra"): how each matched its term
    /// word. Empty for ordinary candidates.
    var parts: [Match] = []

    /// One decision per distinct (span, term): duplicates share an answer.
    var pairKey: String { CandidateFinder.normalize(span) + "→" + CandidateFinder.normalize(term) }
}

nonisolated enum CandidateFinder {

    /// Cap on DISTINCT questions per dictation (confirmed rules first).
    /// Repeated occurrences of one (span, term) pair don't count against it.
    static let maxQuestions = 5
    static let maxWindow = 3
    /// Screen terms need a code of 3+ sounds to be sound-alike sources —
    /// shorter codes match common words ("got"/"good" ~ "Cait", KT).
    static let minScreenCodeLength = 3

    /// All candidates, left-to-right, non-overlapping. Two passes: confirmed
    /// rules first (every occurrence), then screen terms in what's left, so
    /// screen junk can never crowd out a learned word.
    ///
    /// At each word the best window wins, by (1) how it matched: a confirmed
    /// exact heardAs, or two learned one-word names side by side ("druv
    /// mera", fused "Dhruvmehra" → "Dhruv Mehra"), beat an identical sound
    /// code, which beats a one-sound-off code; (2) a span with as many words
    /// as its term ("pipe" → "Pype", not "Pype AI", when both are learned);
    /// (3) the longer span. Case never matters ("PIPE", "Druv"). A
    /// possessive matches by its stem and keeps its suffix: "Pipe's" →
    /// "Pype's".
    ///
    /// Never a candidate: a window containing a word with no a–z sound
    /// (numbers, non-Latin script) — it would be silently deleted on
    /// replacement; a window containing an email/URL/path/dotted word; a
    /// span wider than its term with a word that adds no sound ("pipe AI" →
    /// "Pype" would delete "AI"); a span narrower than its term whose
    /// remaining words already follow ("bright AI's" → "Brite AI AI's" —
    /// a fused "Brightai" is fine); a span the text already spells
    /// correctly.
    static func find(in text: String, rules: [SpellingRule], screenTerms: [String],
                     isOrdinaryWord: (String) -> Bool = VocabularyResolver.WordList.isOrdinaryWord,
                     isKnownName: (String) -> Bool = VocabularyResolver.WordList.isKnownName) -> [Candidate] {
        let words = wordRanges(in: text)
        guard !words.isEmpty else { return [] }
        // A word may join a window only if it has a Latin sound code and
        // isn't part of an email/URL/path.
        let usable = words.map {
            !isEmbedded($0, in: text) && !SoundCode.code(String(text[$0])).isEmpty
                && !titles.contains(text[$0].lowercased())
        }
        // "pipe's" / "Pipe’s" match as "pipe"; the suffix stays in the text.
        let stems = words.map { possessiveStem($0, in: text) }
        // normalize() per word, once (a window's key is these joined).
        let normWords = words.map { normalize(String(text[$0])) }
        let normStems = stems.indices.map { stems[$0] == words[$0] ? normWords[$0] : normalize(String(text[stems[$0]])) }

        var ruleByHeard: [String: SpellingRule] = [:]
        var ruleCodes: [String: [String]] = [:]
        // One-word learned terms, for names heard side by side.
        var singleByCode: [String: String] = [:]
        var singleByHeard: [String: (term: String, match: Candidate.Match)] = [:]
        var singleByTerm: [String: String] = [:]
        // Code of a one-word learned heard form → its term ("Drew" TR →
        // Dhruv): only for splitting a fused word ("Droomer" = TR + MR).
        var singleByHeardCode: [String: String] = [:]
        var multiByTerm: [String: String] = [:]
        for r in rules {
            let heard = normalize(r.heardAs)
            if ruleByHeard[heard] == nil { ruleByHeard[heard] = r }
            let tc = SoundCode.code(r.term)
            if !(ruleCodes[tc]?.contains(r.term) ?? false) { ruleCodes[tc, default: []].append(r.term) }
            if r.term.contains(" ") { multiByTerm[normalize(r.term)] = r.term }
            guard !r.term.contains(" "), !tc.isEmpty else { continue }
            if singleByCode[tc] == nil { singleByCode[tc] = r.term }
            singleByTerm[normalize(r.term)] = r.term
            if !heard.contains(" "), singleByHeard[heard] == nil {
                singleByHeard[heard] = (r.term, soundsLike(r.heardAs, r.term) ? .exact : .exactUnlike)
                let hc = SoundCode.code(r.heardAs)
                if hc.count >= 2, singleByHeardCode[hc] == nil { singleByHeardCode[hc] = r.term }
            }
        }
        // A learned full name ("Dhruv Mehra" ← "Dhruvmara") also teaches its
        // words as names: "Druv" alone, or "Drove Meira", then match like a
        // learned one-word term. Only when EVERY word is name-like (3+
        // letters, capitalised, not a dictionary word) — "Brite AI",
        // "Claude Code" and "Visual Studio" teach nothing on their own.
        for r in rules where r.term.contains(" ") {
            let ws = r.term.split(separator: " ").map(String.init)
            guard ws.allSatisfy({ isNameWord($0, isOrdinaryWord) }) else { continue }
            for w in ws where singleByTerm[normalize(w)] == nil {
                let tc = SoundCode.code(w)
                singleByTerm[normalize(w)] = w
                if singleByCode[tc] == nil { singleByCode[tc] = w }
                if !(ruleCodes[tc]?.contains(w) ?? false) { ruleCodes[tc, default: []].append(w) }
            }
        }
        let ruleTerms = Set(rules.map { $0.term.lowercased() })
        var screenCodes: [String: [String]] = [:]
        for t in screenTerms where !ruleTerms.contains(t.lowercased()) {
            let c = SoundCode.code(t)
            if c.count >= minScreenCodeLength { screenCodes[c, default: []].append(t) }
        }

        /// A window never crosses punctuation ("Drove, Mera" are two
        /// things; replacing across it would delete the comma).
        func spaced(_ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
            text[a.upperBound..<b.lowerBound].allSatisfy { $0 == " " }
        }

        /// One span word as one learned one-word name (cached per word index).
        var partCache: [Int: (term: String, match: Candidate.Match)?] = [:]
        func part(at k: Int, stem: Bool) -> (term: String, match: Candidate.Match)? {
            let key = stem ? -k - 1 : k
            if let hit = partCache[key] { return hit }
            let p = part(String(text[stem ? stems[k] : words[k]]))
            partCache[key] = p
            return p
        }
        func part(_ word: String) -> (term: String, match: Candidate.Match)? {
            let k = normalize(word)
            if let t = singleByTerm[normalize(k)] { return (t, .correct) }
            if let h = singleByHeard[k] { return h }
            if let t = singleByCode[SoundCode.code(word)] { return (t, .sameSound) }
            return nil
        }

        var taken = Array(repeating: false, count: words.count)
        var out: [(index: Int, cand: Candidate)] = []
        var questions = Set<String>()

        func scan(source: Candidate.Source, byCode: [String: [String]], learned: Bool) {
            guard !byCode.isEmpty else { return }
            // Buckets so each window checks only codes that can match: the
            // same code, the same code without half-vowels, or (4+ sounds)
            // a length within one — not every term (300 words × 50 rules).
            var byStripped: [String: [String]] = [:]
            var byLength: [Int: [String]] = [:]
            for c in byCode.keys {
                byStripped[SoundCode.withoutHalfVowels(c), default: []].append(c)
                byLength[c.count, default: []].append(c)
            }
            func hits(_ code: String, oneWord: Bool) -> [String] {
                guard !code.isEmpty else { return [] }
                var out: [String] = []
                if byCode[code] != nil { out.append(code) }
                for c in byStripped[SoundCode.withoutHalfVowels(code)] ?? [] where c != code && SoundCode.sameSound(code, c) {
                    out.append(c)
                }
                let n = code.count
                // The term plus one trailing sound, one word only:
                // "Dhruvan" TRFN ⊃ TRF (never "Drove in" → "Dhruv").
                if oneWord, n >= 4, byCode[String(code.dropLast())] != nil { out.append(String(code.dropLast())) }
                if n >= 3 {
                    for len in (n - 1)...(n + 1) where min(len, n) >= 4 {
                        for c in byLength[len] ?? [] where !out.contains(c) && SoundCode.withinOneEdit(code, c) {
                            out.append(c)
                        }
                    }
                }
                return out
            }
            // rank: 3 exact rule / learned names side by side, 2 same code, 1 one sound off
            typealias Best = (cand: Candidate, width: Int, rank: Int, fits: Bool)
            /// The best window starting at word i (nil: none). Memoized:
            /// a lookahead result stays valid — words are only ever taken
            /// at or before the scan position.
            var memo: [Int: Best?] = [:]
            func bestAt(_ i: Int) -> Best? {
                if let m = memo[i] { return m }
                let b = computeBest(i)
                memo[i] = b
                return b
            }
            func computeBest(_ i: Int) -> Best? {
                guard usable[i], !taken[i] else { return nil }
                var maxWidth = 0
                while maxWidth < maxWindow, i + maxWidth < words.count,
                      usable[i + maxWidth], !taken[i + maxWidth],
                      maxWidth == 0 || spaced(words[i + maxWidth - 1], words[i + maxWidth]) { maxWidth += 1 }
                let start = words[i].lowerBound
                // Does the text already continue with the correct term here?
                // Compares only term-length characters (linear, not O(n²)).
                func alreadyCorrect(_ term: String) -> Bool {
                    let head = text[start...].prefix(term.count)
                    guard head.lowercased() == term.lowercased() else { return false }
                    // …as a whole word: "Dhruva" is not "Dhruv".
                    guard head.endIndex < text.endIndex else { return true }
                    let next = text[head.endIndex]
                    return !(next.isLetter || next.isNumber)
                }

                var best: Best?
                func offer(_ b: Best) {
                    guard let cur = best else { best = b; return }
                    if (b.rank, b.fits ? 1 : 0, b.width) > (cur.rank, cur.fits ? 1 : 0, cur.width) { best = b }
                }
                for width in stride(from: maxWidth, through: 1, by: -1) {
                    let range = words[i].lowerBound..<stems[i + width - 1].upperBound
                    let span = String(text[range])
                    let key = width == 1 ? normStems[i]
                        : (normWords[i..<(i + width - 1)] + [normStems[i + width - 1]]).joined(separator: " ")
                    if learned, let r = ruleByHeard[key] {
                        let m: Candidate.Match = width >= 2 || soundsLike(r.heardAs, r.term) ? .exact : .exactUnlike
                        offer((Candidate(range: range, span: span, term: r.term, source: source, exact: true, match: m),
                               width, 3, width == wordCount(r.term)))
                    }
                    if learned, width <= 2,
                       let (term, parts) = learnedNames(window: i, width: width) ?? nameTail(window: i, width: width) {
                        // (A tail capitalises: "Dhruv mehra" is not yet "Dhruv Mehra".)
                        let correct = parts.last == .tail ? span == term : normalize(term) == key || alreadyCorrect(term)
                        if !correct
                            && !duplicatesTail(term: term, spanWords: width, after: range.upperBound, in: text) {
                            let m: Candidate.Match = parts.contains(.exactUnlike) ? .exactUnlike : .sameSound
                            offer((Candidate(range: range, span: span, term: term, source: source, exact: false,
                                             match: m, parts: parts),
                                   width, 3, width == 2))
                        }
                    }
                    // Right letters, wrong case: "pype" / "dhruv mehra" → the
                    // learned capitals (an all-caps "PYPE" is left alone).
                    if learned, let t = singleByTerm[key] ?? multiByTerm[key], t != span,
                       !span.contains(where: { $0.isUppercase }) {
                        offer((Candidate(range: range, span: span, term: t, source: source, exact: false,
                                         match: .sameSound), width, 2, width == wordCount(t)))
                    }
                    // A learned term as written is never a mishearing of
                    // another one ("Pype" stays, even with "Pype AI" learned).
                    if learned && (singleByTerm[key] != nil || multiByTerm[key] != nil) { continue }
                    let code = SoundCode.code(span)
                    for hit in hits(code, oneWord: width == 1) {
                        let same = SoundCode.sameSound(hit, code)
                        let rank = same ? 2 : 1
                        let ext = width == 1 && !same && hit.count == code.count - 1 && code.hasPrefix(hit)
                        let ok = byCode[hit]?.filter {
                            normalize($0) != key && !alreadyCorrect($0)
                                && fitsWidth(term: $0, window: i, width: width, range: range)
                        } ?? []
                        guard let term = ok.first(where: { wordCount($0) == width }) ?? ok.first else { continue }
                        // A multi-word term heard word for word ("pipe AI" →
                        // "Pype AI") outranks a one-word exact inside it.
                        let whole = same && width >= 2 && wordCount(term) == width
                        offer((Candidate(range: range, span: span, term: term, source: source, exact: false,
                                         match: same ? .sameSound : ext ? .extended : .near),
                               width, whole ? 3 : rank, wordCount(term) == width))
                    }
                }
                return best
            }
            var i = 0
            while i < words.count {
                guard let b = bestAt(i) else { i += 1; continue }
                // A wider window must not swallow a better match that starts
                // inside it: "to Dhruvmara" is one sound off "Dhruv Mehra",
                // but "Dhruvmara" alone is the learned heard form.
                if b.width > 1, ((i + 1)..<(i + b.width)).contains(where: { (bestAt($0)?.rank ?? 0) > b.rank }) {
                    i += 1; continue
                }
                let isNew = !questions.contains(b.cand.pairKey)
                if isNew && questions.count >= maxQuestions { i += 1; continue }
                questions.insert(b.cand.pairKey)
                out.append((i, b.cand))
                for k in i..<(i + b.width) { taken[k] = true }
                i += b.width
            }
        }

        /// Two learned one-word names side by side — "druv mera", "Drove
        /// Mehra" (one already right), or fused into one word ("Dhruvmara",
        /// split on its sound code) — become one candidate for the full
        /// name, so the pair is decided together.
        func learnedNames(window i: Int, width: Int) -> (String, [Candidate.Match])? {
            guard !singleByCode.isEmpty else { return nil }
            if width == 2 {
                guard let a = part(at: i, stem: false), let b = part(at: i + 1, stem: true),
                      a.term != b.term, !(a.match == .correct && b.match == .correct) else { return nil }
                return (a.term + " " + b.term, [a.match, b.match])
            }
            // One word whose sound is two learned names back to back.
            guard part(at: i, stem: true) == nil else { return nil }
            let code = Array(SoundCode.code(String(text[stems[i]])))
            guard code.count >= 2 else { return nil }
            for k in 1..<code.count {
                if let a = singleByCode[String(code[..<k])], let b = singleByCode[String(code[k...])], a != b {
                    return (a + " " + b, [.sameSound, .sameSound])
                }
            }
            // Either half may sound like a learned HEARD form instead
            // ("Droomer" = "Drew" + "Mera" for Dhruv Mehra).
            for k in 1..<code.count {
                let x = String(code[..<k]), y = String(code[k...])
                guard let a = singleByCode[x] ?? singleByHeardCode[x],
                      let b = singleByCode[y] ?? singleByHeardCode[y], a != b else { continue }
                return (a + " " + b, [.sameSound, .sameSound])
            }
            return nil
        }

        /// A learned person name with an unknown word glued on or right
        /// after it, as Parakeet writes a full name it only half knows:
        /// "Dhruvmehra" / "Dhruv mehra" (only Dhruv learned) → "Dhruv
        /// Mehra"; or a fused name whose second half lost its start
        /// ("Drovera" → "Dhruv Mehra", Mehra learned). The unknown word must
        /// be lowercase, 4+ letters, not a dictionary word (or an inflection
        /// of one), a first name, a Hindi word ("Dhruv bhai", "Dhruvji",
        /// "Dhruv mera" stay) or a word newer than the dictionary ("Dhruv
        /// laptop"). Two words: only at the end of the clause or before a
        /// word that follows a name ("Dhruv mehra from Pype", "druv mehra's
        /// team"). VocabularyResolver still vetoes it in a Hindi sentence.
        func nameTail(window i: Int, width: Int) -> (String, [Candidate.Match])? {
            guard !singleByTerm.isEmpty else { return nil }
            func unknownWord(_ w: String) -> Bool {
                let l = w.lowercased()
                guard l.count >= 4, l.allSatisfy({ $0.isLetter && $0.isASCII }), !isOrdinaryWord(l), !isKnownName(l),
                      !VocabularyResolver.isHindiWord(l), !modernWords.contains(l),
                      !englishSuffixes.contains(where: { l.hasSuffix($0) && l.count > $0.count + 2 }) else { return false }
                for (suffix, repl) in [("s", ""), ("es", ""), ("ed", ""), ("ed", "e"), ("ing", ""), ("ing", "e"), ("ies", "y")]
                    where l.hasSuffix(suffix) && isOrdinaryWord(String(l.dropLast(suffix.count)) + repl) { return false }
                return true
            }
            /// A learned one-word person name this word IS: as written, or
            /// as heard / with its sound (not an ordinary, Hindi or first
            /// name word: "mera laptop" is not a name).
            func name(_ w: String) -> (term: String, match: Candidate.Match)? {
                let k = normalize(w)
                if let t = singleByTerm[k] { return isNameWord(t, isOrdinaryWord) ? (t, .correct) : nil }
                guard !isOrdinaryWord(k), !isKnownName(k), !VocabularyResolver.isHindiWord(k) else { return nil }
                if let h = singleByHeard[k], h.match == .exact, isNameWord(h.term, isOrdinaryWord) { return h }
                if k.count >= 4, let t = singleByCode[SoundCode.code(k)], isNameWord(t, isOrdinaryWord) {
                    return (t, .sameSound)
                }
                return nil
            }
            func capitalised(_ w: String) -> String { w.prefix(1).uppercased() + w.dropFirst() }
            if width == 2 {
                let second = String(text[stems[i + 1]])
                guard second.first?.isLowercase == true, part(at: i + 1, stem: true) == nil, unknownWord(second),
                      let a = name(String(text[words[i]])) else { return nil }
                // End of the clause, a possessive, or a word that follows a name.
                let j = i + 2
                let endsHere = stems[i + 1] != words[i + 1] || j >= words.count || !spaced(words[i + 1], words[j])
                guard endsHere || afterName.contains(normWords[j]) else { return nil }
                return (a.term + " " + capitalised(second), [a.match, .tail])
            }
            let w = String(text[stems[i]])
            let lw = w.lowercased()
            guard lw.count >= 6, w.allSatisfy({ $0.isLetter }), !isOrdinaryWord(lw) else { return nil }
            for n in stride(from: lw.count - 2, through: 3, by: -1) {
                let head = String(lw.prefix(n)), rest = String(lw.dropFirst(n))
                // "Dhruvmehra": the learned name exactly as spelled, then an unknown word.
                if let t = singleByTerm[head], isNameWord(t, isOrdinaryWord), unknownWord(rest) {
                    return (t + " " + capitalised(rest), [.correct, .tail])
                }
                // "Drovera": a learned name (as spelled, heard, or by its
                // sound), then the tail of another learned name.
                let a: String? = singleByTerm[head] ?? singleByHeard[head].map(\.term)
                    ?? (head.count >= 4 ? singleByCode[SoundCode.code(head)] : nil)
                guard let a, isNameWord(a, isOrdinaryWord) else { continue }
                if rest.count >= 2, let b = singleByTerm.values.sorted().first(where: {
                    $0 != a && isNameWord($0, isOrdinaryWord) && $0.count > rest.count + 1
                        && $0.lowercased().hasSuffix(rest)
                }) {
                    return (a + " " + b, [.sameSound, .tail])
                }
            }
            return nil
        }

        /// A span wider than its term must not swallow a word that adds no
        /// sound ("pipe AI" is PP like "Pype" — replacing it deletes "AI");
        /// a narrower one must not duplicate the term's tail.
        func fitsWidth(term: String, window i: Int, width: Int, range: Range<String.Index>) -> Bool {
            let n = wordCount(term)
            if width < n { return !duplicatesTail(term: term, spanWords: width, after: range.upperBound, in: text) }
            guard width > n else { return true }
            let code = SoundCode.code(String(text[range]))
            let withoutFirst = SoundCode.code(String(text[words[i + 1].lowerBound..<range.upperBound]))
            let withoutLast = SoundCode.code(String(text[words[i].lowerBound..<words[i + width - 2].upperBound]))
            return withoutFirst != code && withoutLast != code
        }

        scan(source: .rule, byCode: ruleCodes, learned: true)
        scan(source: .screen, byCode: screenCodes, learned: false)
        return out.sorted { $0.index < $1.index }.map(\.cand)
    }

    /// A span with fewer words than its term is fine ("Brightai" for
    /// "Brite AI") UNLESS the text right after it already holds the term's
    /// remaining words ("bright AI's": "bright" -> "Brite AI" would give
    /// "Brite AI AI's").
    static func duplicatesTail(term: String, spanWords: Int, after: String.Index, in text: String) -> Bool {
        let termWords = term.split(separator: " ")
        guard spanWords < termWords.count else { return false }
        let tail = termWords[spanWords...].joined(separator: " ").lowercased()
        let following = text[after...].drop(while: { $0 == " " }).lowercased()
        return following.hasPrefix(tail)
    }

    /// "pipe's" / "Pipe’s" → the range of "pipe"; any other word unchanged.
    static func possessiveStem(_ word: Range<String.Index>, in text: String) -> Range<String.Index> {
        let w = text[word]
        guard w.count > 2, let s = w.last, s == "s" || s == "S" else { return word }
        let apo = w[w.index(w.endIndex, offsetBy: -2)]
        guard apo == "'" || apo == "\u{2019}" else { return word }
        return word.lowerBound..<w.index(w.endIndex, offsetBy: -2)
    }

    /// A word of a learned multi-word term that stands as a name on its own.
    static func isNameWord(_ w: String, _ isOrdinaryWord: (String) -> Bool) -> Bool {
        let letters = w.filter { $0.isLetter }
        guard letters.count >= 3, letters.count == w.count, let f = w.first, f.isUppercase,
              w.dropFirst().contains(where: { $0.isLowercase }) else { return false }
        return !isOrdinaryWord(w.lowercased())
    }

    /// Words that follow a full name: "Dhruv mehra from Pype", "… says hello".
    static let afterName: Set<String> = ["from", "of", "at", "and", "here", "says", "said", "is", "was", "will",
                                         "has", "had", "who", "joined", "founded", "wrote", "sent", "ka", "ki",
                                         "ke", "ko", "se", "ne", "ji", "speaking", "calling", "this", "please"]
    /// Common words newer than the system word list (1934 Webster) — never
    /// taken for an unknown surname ("Dhruv laptop").
    static let modernWords: Set<String> = ["okay", "laptop", "laptops", "email", "emails", "emailed", "emailing",
                                           "online", "offline", "app", "apps", "startup", "startups", "website",
                                           "websites", "internet", "smartphone", "iphone", "ipad", "android",
                                           "google", "googled", "whatsapp", "slack", "zoom", "linkedin", "github",
                                           "wifi", "bluetooth", "blog", "blogs", "podcast", "selfie", "inbox",
                                           "login", "logout", "signup", "username", "download", "downloads",
                                           "upload", "uploads", "chatgpt", "youtube", "instagram", "twitter",
                                           "facebook", "uber", "ola", "zomato", "swiggy", "paytm", "gmail",
                                           "dashboard", "backend", "frontend", "devops", "fintech", "saas",
                                           "webinar", "standup", "onboarding", "screenshot", "hackathon",
                                           "repo", "repos", "codebase", "workflow", "workflows", "ok", "yeah"]
    /// English endings: an unknown word with one is a word, not a surname.
    static let englishSuffixes: [String] = ["ed", "ing", "ly", "ers", "est", "tion", "sion", "ment", "ness",
                                            "able", "ible", "ful", "less", "ize", "ise", "ized", "ised", "izes",
                                            "ous", "ive", "ity", "ship", "ism", "ist", "ists", "ware"]

    /// Titles are never a name themselves ("Mr" sounds like "Mehra", MR).
    static let titles: Set<String> = ["mr", "mrs", "ms", "mister", "miss", "dr", "doctor", "shri", "sri", "smt"]

    static func wordCount(_ s: String) -> Int { s.split(separator: " ").count }

    /// Heard form and term sound alike (the rule is a mishearing, not a
    /// different word the user swapped in: "Mehta" → "Mehra").
    static func soundsLike(_ heard: String, _ term: String) -> Bool {
        SoundCode.soundsAlike(SoundCode.code(heard), SoundCode.code(term))
    }

    /// The sentence around a span — the only context sent off-device.
    static func sentence(containing range: Range<String.Index>, in text: String) -> String {
        let enders: Set<Character> = [".", "!", "?", "\n"]
        var lo = range.lowerBound
        while lo > text.startIndex {
            let prev = text.index(before: lo)
            if enders.contains(text[prev]) { break }
            lo = prev
        }
        var hi = range.upperBound
        while hi < text.endIndex {
            let c = text[hi]
            hi = text.index(after: hi)
            if enders.contains(c) { break }
        }
        return text[lo..<hi].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ranges of word-like tokens (letters/digits, inner apostrophes — straight
    /// or curly — and dots kept: "I'm", "Pipe’s", "CLAUDE.md").
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var idx = text.startIndex
        while idx < text.endIndex {
            let c = text[idx]
            let next = text.index(after: idx)
            let inner = (c == "'" || c == "\u{2019}" || c == ".") && start != nil
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
