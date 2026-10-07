//
//  VocabularyResolver.swift
//
//  Turns decision-engine answers into the final text. Pure: no I/O.
//  answers == nil means the engine was unreachable (no key, timeout,
//  error): only confirmed EXACT, MULTI-WORD rules apply then ("bright AI",
//  "a lisha") — a single common word ("bright") needs context, so it stays
//  as spoken rather than turning "a bright idea" into "a Brite idea".
//  Foundation-only: compiles standalone for scratch tests.
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

    /// answers are keyed by candidate index ("q0", "q1", …).
    static func resolve(text: String, candidates: [Candidate], answers: [String: Double]?) -> Result {
        var replacements: [(Range<String.Index>, String)] = []
        var suggestions: [Candidate] = []
        for (i, c) in candidates.enumerated() {
            guard let answers else {
                if c.source == .rule && c.exact && c.span.split(separator: " ").count >= 2 {
                    replacements.append((c.range, c.term))
                }
                continue
            }
            let p = answers["q\(i)"] ?? 0
            switch c.source {
            case .rule where p >= applyThreshold:
                replacements.append((c.range, c.term))
            case .screen where p >= suggestThreshold:
                suggestions.append(c)
            default:
                break
            }
        }
        var out = text
        // Back to front so earlier ranges stay valid.
        for (range, term) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: term)
        }
        return Result(text: out, applied: replacements.count, suggestions: suggestions)
    }
}
