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
}

nonisolated enum CandidateFinder {

    static let maxCandidates = 5
    static let maxWindow = 3

    /// Left-to-right, non-overlapping, at most 5. At each word: a confirmed
    /// exact phrase wins; else an identical sound code beats a one-sound-off
    /// code; ties go to the longest span. A span the text already spells
    /// correctly (any case) is skipped.
    static func find(in text: String, rules: [SpellingRule], screenTerms: [String]) -> [Candidate] {
        let words = wordRanges(in: text)
        guard !words.isEmpty else { return [] }

        var ruleByHeard: [String: SpellingRule] = [:]
        var byCode: [String: [(term: String, source: Candidate.Source)]] = [:]
        for r in rules {
            ruleByHeard[normalize(r.heardAs)] = r
            byCode[SoundCode.code(r.term), default: []].append((r.term, .rule))
        }
        let ruleTerms = Set(rules.map { $0.term.lowercased() })
        for t in screenTerms where !ruleTerms.contains(t.lowercased()) {
            byCode[SoundCode.code(t), default: []].append((t, .screen))
        }
        let codes = Array(byCode.keys)
        // Never touch emails, URLs, paths, file names: a word that sits in a
        // larger non-space chunk ("bright@brite.com", "~/bright/notes") or
        // contains a dot ("bright.io") is not a candidate.
        let embedded = words.map { isEmbedded($0, in: text) }

        var out: [Candidate] = []
        var i = 0
        while i < words.count && out.count < maxCandidates {
            if embedded[i] { i += 1; continue }
            var maxWidth = min(maxWindow, words.count - i)
            while maxWidth > 1 && embedded[i + maxWidth - 1] { maxWidth -= 1 }
            let rest = text[words[i].lowerBound...].lowercased()
            // The text already continues with the correct term here.
            func alreadyCorrect(_ term: String) -> Bool { rest.hasPrefix(term.lowercased()) }

            var best: (cand: Candidate, width: Int, rank: Int)?  // rank: 2 exact rule, 1 same code, 0 one edit
            for width in stride(from: maxWidth, through: 1, by: -1) {
                let range = words[i].lowerBound..<words[i + width - 1].upperBound
                let span = String(text[range])
                let key = normalize(span)
                if let r = ruleByHeard[key] {
                    best = (Candidate(range: range, span: span, term: r.term, source: .rule, exact: true), width, 2)
                    break  // a confirmed exact phrase always wins
                }
                let code = SoundCode.code(span)
                for hit in codes where SoundCode.soundsAlike(code, hit) {
                    let rank = hit == code ? 1 : 0
                    guard best == nil || rank > best!.rank,
                          let entry = byCode[hit]?.first(where: { normalize($0.term) != key && !alreadyCorrect($0.term) })
                    else { continue }
                    best = (Candidate(range: range, span: span, term: entry.term,
                                      source: entry.source, exact: false), width, rank)
                }
            }
            if let b = best {
                out.append(b.cand)
                i += b.width
            } else {
                i += 1
            }
        }
        return out
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
