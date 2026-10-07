//
//  VocabularyHarvester.swift
//
//  Every ~30s, reads the frontmost app's window text (never secure
//  fields, never Airboard itself, never while recording) and counts
//  candidate terms into VocabularyCache. Terms seen 3+ times get one
//  decision-engine check ("real name/term, or junk?"), cached forever.
//  Everything stays on this Mac except that one word per check.
//

import AppKit

final class VocabularyHarvester {
    static let shared = VocabularyHarvester()

    static let interval: TimeInterval = 30
    static let judgePerTick = 5
    private var timer: Timer?
    private var judging = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard VocabularyLearning.shared.isEnabled,
              !TranscriptionCoordinator.shared.isRecording,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let text = AXText.windowText(pid: app.processIdentifier)
        let terms = TermExtractor.terms(in: text)
        if !terms.isEmpty {
            VocabularyCache.shared.update { $0.addSightings(terms) }
        }
        judgePending()
    }

    private func judgePending() {
        guard !judging, let client = VocabularyLearning.shared.client() else { return }
        let pending = VocabularyCache.shared.data.unjudged(limit: Self.judgePerTick)
        guard !pending.isEmpty else { return }
        judging = true
        Task {
            // One request per term: different contexts never share a state.
            var verdicts: [String: Bool] = [:]
            await withTaskGroup(of: (String, Double?).self) { group in
                for term in pending {
                    group.addTask {
                        let q = DecisionQuestion.isTerm(id: "q0", term: term)
                        let a = await client.ask(state: q.state, questions: [q], deadline: 5)
                        return (term, a?["q0"])
                    }
                }
                for await (term, p) in group {
                    if let p { verdicts[term.lowercased()] = p >= VocabularyResolver.suggestThreshold }
                }
            }
            await MainActor.run {
                VocabularyCache.shared.update { d in
                    for (k, v) in verdicts { d.termVerdicts[k] = v }
                }
                self.judging = false
            }
        }
    }
}
