//
//  FillerRules.swift
//
//  Deterministic cleanup of spoken-language artifacts: filler words only.
//  Runs on every transcript in every mode — no ML, no async, no failure
//  modes, works offline. The optional LLM stage
//  (TranscriptRefiner) handles grammar and structure; this handles the
//  closed-vocabulary junk.
//

import Foundation

enum FillerRules {

    /// Standalone filler tokens, with an optional trailing comma/period.
    private static let fillerPattern = "\\b(um+|uh+|ah+|er+|hmm+|mhm+)\\b[,.]?"

    /// "you know" / "like" only when set off by commas — elsewhere they are
    /// often real words ("you know the answer", "I like it").
    private static let youKnowPattern = "(?:, ?)you know(?=,|\\.|$)"
    private static let likePattern = ", ?like,"

    static func clean(_ text: String) -> String {
        var cleaned = text

        cleaned = cleaned.replacingOccurrences(
            of: fillerPattern, with: "",
            options: [.regularExpression, .caseInsensitive])

        cleaned = cleaned.replacingOccurrences(
            of: youKnowPattern, with: "",
            options: [.regularExpression, .caseInsensitive])

        cleaned = cleaned.replacingOccurrences(
            of: likePattern, with: ",",
            options: [.regularExpression, .caseInsensitive])

        // Tidy artifacts left by removals
        cleaned = cleaned.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: " ([,.!?])", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^[ ,.]+", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Never return nothing: if rules ate everything, fall back to input.
        guard !cleaned.isEmpty else { return text }
        return capitalizeFirst(cleaned)
    }

    // NOTE: phrase-based self-correction ("no wait", "I mean", "scratch
    // that" → keep only what follows) was REMOVED 2026-10-06: it scanned
    // the whole transcript, so one conversational "I mean" in a long
    // dictation silently deleted every sentence before it. Don't re-add a
    // phrase list — correction detection needs a model that understands
    // intent, not string matching.

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
