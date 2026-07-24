//
//  MemoryBias.swift
//
//  Pure logic for the memory confirm pop-up: edit-diff learning — when the
//  user corrects a word in the confirmation card, the correction becomes a
//  spelling memory. Foundation-only on purpose: compiles standalone for
//  scratch tests.
//

import Foundation

enum MemoryBias {

    /// Single-token substitutions between the heard fact and the saved
    /// fact become spelling corrections: "reparty" -> "Ashish". Insertions,
    /// deletions, or restructures teach nothing (token counts must match).
    static func editDiffPairs(heard: String, saved: String) -> [(term: String, heardAs: String)] {
        let heardTokens = tokens(heard)
        let savedTokens = tokens(saved)
        guard heardTokens.count == savedTokens.count, !heardTokens.isEmpty else { return [] }
        var pairs: [(String, String)] = []
        for (h, s) in zip(heardTokens, savedTokens) where h.lowercased() != s.lowercased() {
            // Only word-like tokens teach; both sides must be letters.
            guard h.allSatisfy({ $0.isLetter }), s.allSatisfy({ $0.isLetter }) else { continue }
            pairs.append((s, h.lowercased()))
            if pairs.count == 3 { break }  // a save teaches at most 3 pairs
        }
        return pairs
    }

    /// The memory line a spelling correction is stored as — one shared
    /// phrasing so voice teaching and card edits produce identical lines.
    static func spellingMemory(term: String, heardAs: String) -> String {
        "\"\(term)\" is the correct spelling — often heard as \"\(heardAs)\"."
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
