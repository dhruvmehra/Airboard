//
//  TermExtractor.swift
//
//  Pulls candidate names/terms out of on-screen text for the harvester:
//  capitalized words not starting a sentence, CamelCase ("TypeScript",
//  "iPhone"), dotted tech names ("CLAUDE.md"), and runs of 2-3 such words
//  ("Claude Code"). Over-collects on purpose — the decision engine filters
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
        guard let f = w.first, f.isUppercase, w.count > 1 else { return false }
        return w.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" }
    }

    /// CamelCase / inner capitals ("TypeScript", "iPhone") or dotted ("CLAUDE.md").
    static func isTechy(_ w: String) -> Bool {
        let letters = w.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        if w.contains(".") { return true }
        let innerUpper = w.dropFirst().contains(where: \.isUppercase)
        let hasLower = w.contains(where: \.isLowercase)
        return innerUpper && hasLower
    }
}
