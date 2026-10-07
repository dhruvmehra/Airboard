//
//  DecisionTypes.swift
//
//  Yes/no questions for a decision model, and the wire format of the
//  OpenRouter Decisions API (Jev, Mercury Decide share it). Pure: builds
//  request bodies and parses replies; no networking here.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct DecisionQuestion: Equatable {
    let id: String                  // unique within one request, e.g. "q0"
    let state: [String: String]     // minimal context (Jev degrades with noise)
    let instructions: String
    let yesMeans: String
    let noMeans: String

    /// "Did the speaker mean <term> where it says <span>?" The prior ("a
    /// name this user often says") matters: without it Jev scored "email
    /// bright AI" → Brite AI at 0.40 (probe 2026-10-07); it doesn't know the
    /// term exists. Never send what the term IS — only that it's theirs.
    static func applyTerm(id: String, sentence: String, span: String, term: String) -> DecisionQuestion {
        DecisionQuestion(
            id: id,
            state: ["sentence": sentence],
            instructions: "Speech recognition transcribed this sentence. \"\(term)\" is a name or term this user often says, and the recognizer often mishears it. Did the speaker actually mean \"\(term)\" where it says \"\(span)\"?",
            yesMeans: "\"\(span)\" is a mishearing of the name or term \"\(term)\".",
            noMeans: "\"\(span)\" is meant literally as an ordinary word, not \"\(term)\".")
    }

    /// "Is <heard> -> <corrected> a spelling fix of the same word/name?"
    static func spellingFix(id: String, sentence: String, heard: String, corrected: String) -> DecisionQuestion {
        DecisionQuestion(
            id: id,
            state: ["sentence": sentence, "edit": "\"\(heard)\" -> \"\(corrected)\""],
            instructions: "The user edited words in text produced by speech recognition. Is the edit a spelling fix of the same intended word or name (the recognizer misheard it), rather than a change to a different word or meaning?",
            yesMeans: "Same intended word or name, corrected spelling.",
            noMeans: "A different word, value, or meaning.")
    }

    /// "Is <term> a real name or product/technical term?" (harvest filter)
    static func isTerm(id: String, term: String) -> DecisionQuestion {
        DecisionQuestion(
            id: id,
            state: ["word": term],
            instructions: "This word was seen on a computer screen. Is it a proper name, brand, product, or technical term that a speech recognizer could misspell — not a common English word, UI label, or ordinary capitalized word?",
            yesMeans: "A specific name, brand, product, or technical term.",
            noMeans: "A common word, menu/UI label, or ordinary capitalized word.")
    }
}

nonisolated enum DecisionWire {
    static let endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    /// One request = ONE shared context. Callers batch only questions about
    /// the same sentence (the dictation path always does); different
    /// contexts go in separate, concurrent requests — merging unrelated
    /// sentences into one state measurably hurt accuracy (probe 2026-10-07:
    /// "bright AI is hiring" fell from yes to 0.50 when batched with 4 others).
    static func body(model: String, state: [String: String], questions: [DecisionQuestion]) -> Data? {
        var qs: [String: Any] = [:]
        for q in questions {
            qs[q.id] = [
                "type": "noul",
                "instructions": q.instructions,
                "criteria": ["true": q.yesMeans, "false": q.noMeans],
            ]
        }
        return try? JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": qs])
    }

    /// Probability of "yes" per question id. Missing/malformed → absent
    /// (callers treat absent as "no").
    static func parse(_ data: Data) -> [String: Double] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (id, raw) in answers {
            if let a = raw as? [String: Any], let p = (a["noul"] as? NSNumber)?.doubleValue, (0...1).contains(p) {
                out[id] = p
            }
        }
        return out
    }
}
