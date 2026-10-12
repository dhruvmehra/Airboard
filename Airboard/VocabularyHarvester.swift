//
//  VocabularyHarvester.swift
//
//  Every ~30s — only when vocabulary learning is on AND a key is set —
//  reads the frontmost app's window text (never secure fields, never
//  Airboard itself, never while recording) and counts candidate terms into
//  VocabularyCache. The Accessibility walk runs OFF the main thread with a
//  100ms per-call timeout and aborts when a recording starts, so it can
//  never delay a hotkey press. Terms seen 3+ times get one decision-engine
//  check ("real name/term, or junk?"), cached.
//

import AppKit

final class VocabularyHarvester {
    static let shared = VocabularyHarvester()

    static let interval: TimeInterval = 30
    static let judgePerTick = 5
    private var timer: Timer?
    private var judging = false
    private var walking = false
    private let walkQueue = DispatchQueue(label: "com.pype.airboard.vocab-harvest", qos: .utility)

    /// Set on the main thread, read by the background walk.
    private let stopFlag = AbortFlag()

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopFlag.set(true)
    }

    /// A recording is starting: abandon any walk in flight.
    func abortWalk() { stopFlag.set(true) }

    private func tick() {
        guard !walking,
              VocabularyLearning.shared.isEnabled,
              VocabularyLearning.shared.client() != nil,
              !TranscriptionCoordinator.shared.isRecording,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        // Electron apps hide their text until asked (once per process; the
        // first walk may still see little — the next tick will not).
        AXText.enableWebAccessibility(for: app)
        walking = true
        let flag = stopFlag
        flag.set(false)
        walkQueue.async { [weak self] in
            let text = AXText.windowText(pid: pid, shouldStop: { flag.value })
            let terms = flag.value ? [] : TermExtractor.terms(in: text)
            DispatchQueue.main.async {
                guard let self else { return }
                self.walking = false
                if !terms.isEmpty {
                    VocabularyCache.shared.update { $0.addSightings(terms, now: Date()) }
                }
                self.judgePending()
            }
        }
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

/// A thread-safe boolean the off-main walk polls.
nonisolated final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}
