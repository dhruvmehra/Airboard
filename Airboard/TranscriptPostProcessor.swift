//
//  TranscriptPostProcessor.swift
//
//  Two-pass transcript cleanup orchestrator: FillerRules always, then the
//  optional remote LLM (TranscriptRefiner) for normal dictation when the
//  toggle is on AND a server is configured. Every failure path returns the
//  rules-cleaned text — dictated words are never lost and never delayed
//  beyond the timeout. No network request is made unless configured.
//  See docs/superpowers/specs/2026-07-19-transcript-cleanup-design.md
//

import Foundation

enum ProcessingMode {
    case dictation        // rules + remote LLM (when enabled and configured)
    case handsFreeChunk   // rules only: live chunks must stay instant
    case command          // rules only: command parser needs verbatim text
}

/// What processing did to the transcript — the text plus the timing and
/// outcome the metrics funnel records (fixed enum strings, never free text).
struct ProcessOutcome {
    let text: String
    let llmMs: Int?           // nil when the LLM didn't run
    let llmOutcome: String    // ok | timeout | error | guarded | skipped | off
}

enum TranscriptPostProcessor {

    static let llmTimeoutSeconds: Double = 4

    /// Very short dictations (quick replies, search queries) don't need
    /// grammar, paragraphs, or lists — the LLM round-trip would be pure
    /// perceived lag on the snippets people dictate most. Rules-only below
    /// this. (Lowered from 12 once fast providers like Cerebras made the
    /// round-trip ~0.5s.)
    static let llmMinimumWords = 6

    /// Absent key = disabled. Default OFF: a fresh install has no server
    /// configured, and an on-looking toggle for a feature that silently does
    /// nothing misleads users. Flipping it on with no server opens setup.
    static var aiCleanupEnabled: Bool {
        UserDefaults.standard.object(forKey: "aiCleanupEnabled") as? Bool ?? false
    }

    static func process(_ text: String, context: AppContext?, mode: ProcessingMode) async -> ProcessOutcome {
        let ruled = FillerRules.clean(text)

        guard mode == .dictation else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "off")
        }
        guard aiCleanupEnabled, TranscriptRefiner.shared.isConfigured else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "off")
        }
        guard ruled.split(separator: " ").count >= llmMinimumWords else {
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: "skipped")
        }

        do {
            let startTime = Date()
            let refined = try await withTimeout(seconds: llmTimeoutSeconds) {
                try await TranscriptRefiner.shared.refine(ruled)
            }
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            print("⏱️ LLM cleanup: \(ms)ms")
            return ProcessOutcome(text: refined, llmMs: ms, llmOutcome: "ok")
        } catch {
            let outcome: String
            switch error {
            case TranscriptRefiner.RefineError.degenerateOutput:
                outcome = "guarded"
            case TranscriptRefiner.RefineError.timeout:
                outcome = "timeout"
            default:
                outcome = "error"
            }
            print("⚠️ Cleanup LLM skipped (\(error.localizedDescription)); inserting rules-cleaned text (\(outcome))")
            return ProcessOutcome(text: ruled, llmMs: nil, llmOutcome: outcome)
        }
    }

    private static func withTimeout(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TranscriptRefiner.RefineError.timeout
            }
            // First finisher wins; the loser is cancelled (URLSession observes
            // cancellation, so the HTTP request is actually torn down).
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
