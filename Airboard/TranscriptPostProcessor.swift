//
//  TranscriptPostProcessor.swift
//
//  Transcript post-processing, fully local except for decision calls:
//  FillerRules (um/uh) always, then VocabularyLearning's learned spellings
//  (decision engine for dictation; exact confirmed rules for hands-free;
//  nothing for command mode, which needs verbatim text). Every failure path
//  returns the text as heard — dictated words are never lost. The cloud
//  rewrite pass (AI Cleanup / TranscriptRefiner) was removed 2026-10-07:
//  Airboard is heading fully local, with decision models as the rails.
//

import Foundation

enum ProcessingMode {
    case dictation        // fillers + learned spellings (decision engine, ≤350ms)
    case handsFreeChunk   // fillers + exact confirmed spellings: live chunks stay instant
    case command          // fillers only: command parser needs verbatim text
}

/// What processing did to the transcript — the text plus the timing and
/// outcome the metrics funnel records (fixed enum strings, never free text).
struct ProcessOutcome {
    let text: String
    let llmMs: Int?           // always nil since AI Cleanup's removal; kept so logs/telemetry decode
    let llmOutcome: String    // always "off"
    var vocabMs: Int? = nil   // decision-engine time; nil = not called
    var vocabOutcome: String = "off"  // off | none | nokey | ok | applied | timeout
}

enum TranscriptPostProcessor {

    static func process(_ text: String, context: AppContext?, mode: ProcessingMode) async -> ProcessOutcome {
        let ruled = FillerRules.clean(text)
        guard mode != .command else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "off")
        }
        let vocab = await VocabularyLearning.shared.process(ruled, useEngine: mode == .dictation)
        return ProcessOutcome(text: vocab.text, llmMs: nil, llmOutcome: "off",
                              vocabMs: vocab.ms, vocabOutcome: vocab.outcome)
    }
}
