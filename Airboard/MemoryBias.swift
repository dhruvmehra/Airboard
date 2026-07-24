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

    /// A classified command-mode intent from the LLM interpreter.
    enum ClassifiedIntent: Equatable {
        case remember(memory: String)
        case recall(query: String)
        case correct(term: String, heardAs: String)
        case none
    }

    /// Parse the intent-classifier reply: {"intent": "...", ...fields}.
    /// Lenient (fence-stripping, whitelisted intents, missing fields →
    /// .none) — a malformed reply degrades to "not a memory command",
    /// never to a wrong action.
    static func parseIntent(_ reply: String) -> ClassifiedIntent {
        let unfenced = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```(json)?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = unfenced.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intent = obj["intent"] as? String else { return .none }
        func field(_ key: String) -> String? {
            guard let v = obj[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch intent.lowercased() {
        case "remember":
            guard let memory = field("memory") else { return .none }
            return .remember(memory: memory)
        case "recall":
            guard let query = field("query") else { return .none }
            return .recall(query: query)
        case "correct":
            guard let term = field("term"), let heardAs = field("heardAs") else { return .none }
            return .correct(term: term, heardAs: heardAs)
        default:
            return .none
        }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
