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
        case correct      // (composite part only) already the term: "Dhruv" in "Dhruv mera"
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
    static func find(in text: String, rules: [SpellingRule], screenTerms: [String]) -> [Candidate] {
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
            func hits(_ code: String) -> [String] {
                guard !code.isEmpty else { return [] }
                var out: [String] = []
                if byCode[code] != nil { out.append(code) }
                for c in byStripped[SoundCode.withoutHalfVowels(code)] ?? [] where c != code && SoundCode.sameSound(code, c) {
                    out.append(c)
                }
                let n = code.count
                if n >= 3 {
                    for len in (n - 1)...(n + 1) where min(len, n) >= 4 {
                        for c in byLength[len] ?? [] where !out.contains(c) && SoundCode.withinOneEdit(code, c) {
                            out.append(c)
                        }
                    }
                }
                return out
            }
            var i = 0
            while i < words.count {
                guard usable[i], !taken[i] else { i += 1; continue }
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

                // rank: 3 exact rule / learned names side by side, 2 same code, 1 one sound off
                typealias Best = (cand: Candidate, width: Int, rank: Int, fits: Bool)
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
                       let (term, parts) = learnedNames(window: i, width: width) {
                        if normalize(term) != key && !alreadyCorrect(term)
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
                    for hit in hits(code) {
                        let same = SoundCode.sameSound(hit, code)
                        let rank = same ? 2 : 1
                        let ok = byCode[hit]?.filter {
                            normalize($0) != key && !alreadyCorrect($0)
                                && fitsWidth(term: $0, window: i, width: width, range: range)
                        } ?? []
                        guard let term = ok.first(where: { wordCount($0) == width }) ?? ok.first else { continue }
                        // A multi-word term heard word for word ("pipe AI" →
                        // "Pype AI") outranks a one-word exact inside it.
                        let whole = same && width >= 2 && wordCount(term) == width
                        offer((Candidate(range: range, span: span, term: term, source: source, exact: false,
                                         match: same ? .sameSound : .near),
                               width, whole ? 3 : rank, wordCount(term) == width))
                    }
                }
                guard let b = best else { i += 1; continue }
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
