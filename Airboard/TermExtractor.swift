//
//  TermExtractor.swift
//
//  Pulls candidate names/terms out of on-screen text for the harvester:
//  capitalized words not starting a sentence, name-shaped CamelCase
//  ("TypeScript", "iPhone"), and runs of 2-3 such words ("Claude Code").
//  Never digits, dotted names, or secret-like strings — every harvested
//  term may be sent to the decision model. Over-collects on purpose — the decision engine filters
//  junk before anything is suggested. Foundation-only.
//

import Foundation

nonisolated enum TermExtractor {

    static let maxTermsPerRead = 200

    static func terms(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ t: String) {
            guard t.count >= 3, t.count <= 40, seen.insert(t).inserted else { return }
            out.append(t)
        }
        for line in text.components(separatedBy: .newlines) {
            let ranges = CandidateFinder.wordRanges(in: line)
            var run: [String] = []
            var runStartsSentence = false
            func flush() {
                if run.count >= 2 { add(run.prefix(3).joined(separator: " ")) }
                // "Ask Claude Code" → also "Claude Code": a sentence-initial
                // word may just be an ordinary capitalized word.
                if runStartsSentence && run.count >= 3 { add(run.dropFirst().prefix(3).joined(separator: " ")) }
                run = []
                runStartsSentence = false
            }
            for (i, r) in ranges.enumerated() {
                let w = String(line[r])
                let sentenceStart = i == 0 || line[..<r.lowerBound]
                    .trimmingCharacters(in: .whitespaces).last.map { ".!?:".contains($0) } ?? true
                if isTechy(w) {
                    add(w); run.append(w)
                } else if isCapitalized(w) && !sentenceStart {
                    add(w); run.append(w)
                } else if isCapitalized(w) {
                    flush()
                    run = [w]       // may still start a multi-word name
                    runStartsSentence = true
                } else {
                    flush()
                }
            }
            flush()
            if out.count >= maxTermsPerRead { break }
        }
        return Array(out.prefix(maxTermsPerRead))
    }

    static func isCapitalized(_ w: String) -> Bool {
        guard let f = w.first, f.isUppercase, w.count > 1, w.count <= maxTermLength else { return false }
        return w.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" }
    }

    /// Longer than this is a sentence fragment, path, or secret — not a name.
    static let maxTermLength = 20

    /// CamelCase with a name-like shape: "TypeScript", "GitHub", "iPhone",
    /// "OpenAI". Never harvested (they'd be sent to the decision model):
    /// anything with digits or symbols, dotted names (files, domains —
    /// "layoffs.xlsx"), and secret-like strings whose case pattern breaks
    /// into many fragments ("wJalrXUtnFEMI").
    static func isTechy(_ w: String) -> Bool {
        guard w.count >= 3, w.count <= maxTermLength,
              w.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        let innerUpper = w.dropFirst().contains(where: \.isUppercase)
        guard innerUpper, w.contains(where: \.isLowercase) else { return false }
        // Split into case pieces: "Type|Script", "i|Phone", "Open|AI".
        var pieces: [String] = []
        var cur = ""
        let chars = Array(w)
        for (i, c) in chars.enumerated() {
            let prevLower = i > 0 && chars[i - 1].isLowercase
            let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
            let prevUpper = i > 0 && chars[i - 1].isUppercase
            if c.isUppercase && (prevLower || (prevUpper && nextLower)) && !cur.isEmpty {
                pieces.append(cur); cur = ""
            }
            cur.append(c)
        }
        if !cur.isEmpty { pieces.append(cur) }
        // Name-like: 2-3 pieces; only the first may be a single letter
        // ("iPhone"); an all-caps piece is an acronym of 2-4 letters ("AI").
        guard (2...3).contains(pieces.count) else { return false }
        for (i, p) in pieces.enumerated() {
            if p.count == 1 && i > 0 { return false }
            if p.allSatisfy(\.isUppercase) && p.count > 4 { return false }
        }
        return true
    }
}
