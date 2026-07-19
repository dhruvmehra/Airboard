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

enum TranscriptPostProcessor {

    static let llmTimeoutSeconds: Double = 4

    /// Short dictations (quick replies, search queries) don't need grammar,
    /// paragraphs, or lists — the 1–3s LLM round-trip would be pure perceived
    /// lag on the snippets people dictate most. Rules-only below this.
    static let llmMinimumWords = 12

    /// Absent key = enabled (default on).
    static var aiCleanupEnabled: Bool {
        UserDefaults.standard.object(forKey: "aiCleanupEnabled") as? Bool ?? true
    }

    static func process(_ text: String, context: AppContext?, mode: ProcessingMode) async -> String {
        let ruled = FillerRules.clean(text)

        guard mode == .dictation,
              aiCleanupEnabled,
              ruled.split(separator: " ").count >= llmMinimumWords,
              TranscriptRefiner.shared.isConfigured else {
            return ruled
        }

        do {
            let startTime = Date()
            let refined = try await withTimeout(seconds: llmTimeoutSeconds) {
                try await TranscriptRefiner.shared.refine(ruled)
            }
            print("⏱️ LLM cleanup: \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
            return refined
        } catch {
            print("⚠️ Cleanup LLM skipped (\(error.localizedDescription)); inserting rules-cleaned text")
            return ruled
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
