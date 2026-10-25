//
//  SpellingRule.swift
//
//  The one memory line that is applied locally: a confirmed spelling.
//  Format:
//    "Brite AI" is the correct spelling — often heard as "bright AI".
//  Every other memory line is NOT a rule and stays LLM-only.
//  Term and heard differ — possibly only in case ("Pype" ← "pype").
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct SpellingRule: Equatable, Hashable {
    let term: String     // correct spelling, e.g. "Brite AI"
    let heardAs: String  // how Parakeet writes it, e.g. "bright AI"

    /// The memory line for this rule — the one phrasing parse() reads back.
    var memoryLine: String {
        "\"\(term)\" is the correct spelling — often heard as \"\(heardAs)\"."
    }

    /// Lenient: em dash, en dash, or hyphen; optional trailing period;
    /// straight or curly quotes (hand edits in TextEdit curl them).
    static func parse(_ line: String) -> SpellingRule? {
        let normalized = line
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .trimmingCharacters(in: .whitespaces)
        let pattern = #"^"([^"]+)" is the correct spelling\s*[—–-]\s*often heard as "([^"]+)"\.?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let t = Range(m.range(at: 1), in: normalized),
              let h = Range(m.range(at: 2), in: normalized) else { return nil }
        let term = normalized[t].trimmingCharacters(in: .whitespaces)
        let heard = normalized[h].trimmingCharacters(in: .whitespaces)
        // A case-only rule ("Pype" ← "pype": the user re-cased a name) is a
        // rule too; only an identical pair teaches nothing. (Before
        // 2026-10-12 case-only lines were dropped here — none were ever
        // written, so older memory.md files read back exactly as before.)
        guard !term.isEmpty, !heard.isEmpty, term != heard else { return nil }
        return SpellingRule(term: term, heardAs: heard)
    }

    static func rules(from memories: [String]) -> [SpellingRule] {
        var seen = Set<SpellingRule>()
        return memories.compactMap(parse).filter { seen.insert($0).inserted }
    }
}
