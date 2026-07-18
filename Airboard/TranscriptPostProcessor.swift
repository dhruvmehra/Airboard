//
//  TranscriptPostProcessor.swift
//
//  Seam for a future LLM cleanup stage (filler removal, grammar, tone per
//  app context). Currently a pass-through — see
//  docs/superpowers/specs/2026-07-18-parakeet-swap-design.md
//

import Foundation

enum TranscriptPostProcessor {
    /// Applied to every transcript before command detection / insertion.
    static func process(_ text: String, context: AppContext?) -> String {
        return text
    }
}
