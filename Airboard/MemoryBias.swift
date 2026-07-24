//
//  MemoryBias.swift
//
//  Pure logic for the memory confirm pop-up: storage-LLM extraction-JSON
//  parsing, edit-diff glossary learning, and name reconciliation against
//  the user's saved text. (The acoustic watch-list helpers that lived here
//  were removed with the vocabulary-biasing layer, 2026-07-25.)
//
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

enum MemoryBias {

    /// Parse the storage LLM's reply: {"sentence": "...", "names": ["..."]}.
    /// Anything malformed degrades to (fallback-or-raw-reply, no names) —
    /// extraction is an enhancement, never a gate.
    static func parseFactExtraction(_ reply: String, fallback: String) -> (sentence: String, names: [String]) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap JSON in code fences — strip one layer.
        let unfenced = trimmed
            .replacingOccurrences(of: "^```(json)?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = unfenced.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let sentence = obj["sentence"] as? String,
              !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Not JSON: treat a plausible plain-sentence reply as the
            // cleaned sentence; anything empty falls back to the raw note.
            let plain = trimmed
            if !plain.isEmpty && !plain.hasPrefix("{") && plain.count < max(200, fallback.count * 3) {
                return (plain, [])
            }
            return (fallback, [])
        }
        let names = (obj["names"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (sentence.trimmingCharacters(in: .whitespacesAndNewlines), names)
    }

    /// Single-token substitutions between the heard fact and the saved
    /// fact become glossary pairs: "reparty" -> "Ashish". Insertions,
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

    /// Names must exist in the user's SAVED text to survive — the pre-edit
    /// garble never reaches the watch-list.
    static func reconcile(names: [String], savedText: String) -> [String] {
        let lower = savedText.lowercased()
        return names.filter { lower.contains($0.lowercased()) }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
