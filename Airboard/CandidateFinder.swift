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
    let range: Range<String.Index>  // span in the transcript
    let span: String                // the text as heard, e.g. "bright AI"
    let term: String                // what it might be, e.g. "Brite AI"
    let source: Source
    let exact: Bool                 // span equals a confirmed rule's heardAs

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
    /// screen junk can never crowd out a learned word. At each word: a
    /// confirmed exact phrase wins; else an identical sound code beats a
    /// one-sound-off code; ties go to the longest span. Never a candidate:
    /// a window containing a word with no a–z sound (numbers, non-Latin
    /// script) — it would be silently deleted on replacement; a window
    /// containing an email/URL/path/dotted word; a span with fewer words
    /// than its term ("bright" alone for "Brite AI" would duplicate "AI");
    /// a span the text already spells correctly.
    static func find(in text: String, rules: [SpellingRule], screenTerms: [String]) -> [Candidate] {
        let words = wordRanges(in: text)
        guard !words.isEmpty else { return [] }
        // A word may join a window only if it has a Latin sound code and
        // isn't part of an email/URL/path.
        let usable = words.map { !isEmbedded($0, in: text) && !SoundCode.code(String(text[$0])).isEmpty }

        var ruleByHeard: [String: SpellingRule] = [:]
        var ruleCodes: [String: [String]] = [:]
        for r in rules {
            ruleByHeard[normalize(r.heardAs)] = r
            ruleCodes[SoundCode.code(r.term), default: []].append(r.term)
        }
        let ruleTerms = Set(rules.map { $0.term.lowercased() })
        var screenCodes: [String: [String]] = [:]
        for t in screenTerms where !ruleTerms.contains(t.lowercased()) {
            let c = SoundCode.code(t)
            if c.count >= minScreenCodeLength { screenCodes[c, default: []].append(t) }
        }

        var taken = Array(repeating: false, count: words.count)
        var out: [(index: Int, cand: Candidate)] = []
        var questions = Set<String>()

        func scan(source: Candidate.Source, byCode: [String: [String]], exactRules: Bool) {
            let codes = Array(byCode.keys)
            var i = 0
            while i < words.count {
                guard usable[i], !taken[i] else { i += 1; continue }
                var maxWidth = 0
                while maxWidth < maxWindow, i + maxWidth < words.count,
                      usable[i + maxWidth], !taken[i + maxWidth] { maxWidth += 1 }
                let start = words[i].lowerBound
                // Does the text already continue with the correct term here?
                // Compares only term-length characters (linear, not O(n²)).
                func alreadyCorrect(_ term: String) -> Bool {
                    text[start...].prefix(term.count).lowercased() == term.lowercased()
                }

                var best: (cand: Candidate, width: Int, rank: Int)?  // 2 exact rule, 1 same code, 0 one edit
                for width in stride(from: maxWidth, through: 1, by: -1) {
                    let range = words[i].lowerBound..<words[i + width - 1].upperBound
                    let span = String(text[range])
                    let key = normalize(span)
                    if exactRules, let r = ruleByHeard[key] {
                        best = (Candidate(range: range, span: span, term: r.term, source: source, exact: true), width, 2)
                        break  // a confirmed exact phrase always wins
                    }
                    let code = SoundCode.code(span)
                    for hit in codes where SoundCode.soundsAlike(code, hit) {
                        let rank = hit == code ? 1 : 0
                        guard best == nil || rank > best!.rank,
                              let term = byCode[hit]?.first(where: {
                                  normalize($0) != key
                                      && !alreadyCorrect($0)
                                      && width >= $0.split(separator: " ").count
                              })
                        else { continue }
                        best = (Candidate(range: range, span: span, term: term, source: source, exact: false), width, rank)
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
        scan(source: .rule, byCode: ruleCodes, exactRules: true)
        scan(source: .screen, byCode: screenCodes, exactRules: false)
        return out.sorted { $0.index < $1.index }.map(\.cand)
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

    /// Ranges of word-like tokens (letters/digits, inner apostrophes and dots kept:
    /// "I'm", "CLAUDE.md").
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var idx = text.startIndex
        while idx < text.endIndex {
            let c = text[idx]
            let next = text.index(after: idx)
            let inner = (c == "'" || c == ".") && start != nil
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
