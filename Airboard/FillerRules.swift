//
//  FillerRules.swift
//
//  Deterministic cleanup of spoken-language artifacts: filler words and
//  self-corrections. Runs on every transcript in every mode — no ML, no
//  async, no failure modes, works offline. The optional LLM stage
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

    /// Correction markers: keep what comes AFTER the marker when it is
    /// substantial (>= 2 words) — "2 burgers no wait 1 burger" → "1 burger".
    private static let correctionMarkers = [
        "no no", "no wait", "wait no", "wait wait", "scratch that", "i mean"
    ]

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

        cleaned = collapseSelfCorrection(cleaned)

        // Tidy artifacts left by removals
        cleaned = cleaned.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: " ([,.!?])", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^[ ,.]+", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Never return nothing: if rules ate everything, fall back to input.
        guard !cleaned.isEmpty else { return text }
        return capitalizeFirst(cleaned)
    }

    /// Keeps only the text after the LAST correction marker, when what
    /// follows is substantial. Case-insensitive; preserves original casing.
    private static func collapseSelfCorrection(_ text: String) -> String {
        let lowered = text.lowercased()
        var bestUpperBound: String.Index?

        for marker in correctionMarkers {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: marker, range: searchRange) {
                // Require word boundaries around the marker
                let beforeOK = range.lowerBound == lowered.startIndex
                    || !lowered[lowered.index(before: range.lowerBound)].isLetter
                let afterOK = range.upperBound == lowered.endIndex
                    || !lowered[range.upperBound].isLetter
                if beforeOK && afterOK {
                    if bestUpperBound == nil || range.upperBound > bestUpperBound! {
                        bestUpperBound = range.upperBound
                    }
                }
                searchRange = range.upperBound..<lowered.endIndex
            }
        }

        guard let upperBound = bestUpperBound else { return text }
        let after = String(text[upperBound...])
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        guard after.split(separator: " ").count >= 2 else { return text }
        return after
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
