//
//  VocabularyLearning.swift
//
//  The self-learning vocabulary feature, in one place:
//  - process(): dictation path. Finds candidates, asks the decision
//    engine once (350ms hard limit), applies confirmed spellings in
//    context. +0ms when the text holds no candidate.
//  - didInsert(): queues "Did you mean" cards and starts the
//    CorrectionWatcher on the field we just typed into.
//  - cards: Keep/Undo (Learned; ignored = Keep), Yes/No (Did you mean;
//    ignored = snoozed). Keep/Yes write a SpellingRule line to memory.md.
//  Spec: docs/superpowers/specs/2026-10-07-self-learning-vocabulary-design.md
//

import AppKit

struct VocabOutcome {
    let text: String
    let ms: Int?          // nil when the engine wasn't called
    let outcome: String   // off | none | nokey | ok | applied | timeout
}

enum VocabularyCardChoice { case primary, secondary, ignored }

final class VocabularyLearning {
    static let shared = VocabularyLearning()

    static let enabledKey = "vocabLearningEnabled"
    static let deadline: TimeInterval = 0.35
    static let backgroundDeadline: TimeInterval = 5

    private var pendingSuggestions: [VocabularyCard] = []
    private var queue = VocabularyCardQueue()
    private var lastInsertPID: pid_t?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            VocabularyHarvester.shared.start()
        } else {
            VocabularyHarvester.shared.stop()
            CorrectionWatcher.shared.cancel()
        }
    }

    /// Call once at launch.
    func start() {
        if isEnabled { VocabularyHarvester.shared.start() }
    }

    /// BYOK: the OpenRouter key the Assistant already uses. nil = no key.
    func client() -> DecisionClient? {
        guard let key = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return DecisionClient(apiKey: key)
    }

    // MARK: - Dictation path

    /// useEngine=false (hands-free chunks): exact confirmed rules only,
    /// no network — live chunks must stay instant.
    func process(_ text: String, useEngine: Bool) async -> VocabOutcome {
        guard isEnabled else { return VocabOutcome(text: text, ms: nil, outcome: "off") }
        let rules = SpellingRule.rules(from: MemoryStore.shared.memories)
        let client = useEngine ? client() : nil
        let now = Date()
        let screen = client == nil ? [] : VocabularyCache.shared.data.screenTerms
        let candidates = CandidateFinder.find(in: text, rules: rules, screenTerms: screen).filter {
            !($0.source == .screen && VocabularyCache.shared.data.isBlocked(heard: $0.span, term: $0.term, now: now))
        }
        guard !candidates.isEmpty else { return VocabOutcome(text: text, ms: nil, outcome: "none") }

        guard let client else {
            let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: nil)
            return VocabOutcome(text: r.text, ms: nil, outcome: "nokey")
        }
        let start = Date()
        let questions = candidates.enumerated().map {
            DecisionQuestion.applyTerm(id: "q\($0.offset)", sentence: text, span: $0.element.span, term: $0.element.term)
        }
        let answers = await client.ask(state: ["sentence": text], questions: questions, deadline: Self.deadline)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: answers)
        pendingSuggestions = r.suggestions.map { VocabularyCard(kind: .didYouMean, heard: $0.span, term: $0.term) }
        let outcome = answers == nil ? "timeout" : (r.applied > 0 ? "applied" : "ok")
        print("🧠 Vocab: \(candidates.count) candidate(s), \(r.applied) applied, \(r.suggestions.count) suggested, \(outcome) in \(ms)ms")
        return VocabOutcome(text: r.text, ms: ms, outcome: outcome)
    }

    // MARK: - After insertion

    func recordingStarted() {
        CorrectionWatcher.shared.cancel()
    }

    func didInsert(_ text: String, pid: pid_t) {
        guard isEnabled else { return }
        lastInsertPID = pid
        for card in pendingSuggestions { queue.enqueue(card) }
        pendingSuggestions = []
        showNextCard()
        guard client() != nil else { return }
        CorrectionWatcher.shared.observe(inserted: text, pid: pid) { [weak self] correction in
            self?.considerEdit(correction, sentence: text)
        }
    }

    private func considerEdit(_ c: EditDiff.Correction, sentence: String) {
        guard !VocabularyCache.shared.data.isBlocked(heard: c.heard, term: c.corrected, now: Date()),
              let client = client() else { return }
        let known = SpellingRule.rules(from: MemoryStore.shared.memories).contains {
            CandidateFinder.normalize($0.heardAs) == CandidateFinder.normalize(c.heard) && $0.term == c.corrected
        }
        guard !known else { return }
        Task {
            let q = DecisionQuestion.spellingFix(id: "q0", sentence: sentence, heard: c.heard, corrected: c.corrected)
            let a = await client.ask(state: q.state, questions: [q], deadline: Self.backgroundDeadline)
            guard let p = a?["q0"], p >= VocabularyResolver.suggestThreshold else { return }
            await MainActor.run {
                self.queue.enqueue(VocabularyCard(kind: .learned, heard: c.heard, term: c.corrected))
                self.showNextCard()
            }
        }
    }

    // MARK: - Cards

    private func showNextCard() {
        guard let card = queue.next(now: Date(), isRecording: TranscriptionCoordinator.shared.isRecording) else { return }
        VocabularyCardPresenter.shared.show(card) { [weak self] choice in
            self?.resolve(card, choice)
        }
    }

    private func resolve(_ card: VocabularyCard, _ choice: VocabularyCardChoice) {
        queue.dismissed()
        let rule = SpellingRule(term: card.term, heardAs: card.heard)
        switch (card.kind, choice) {
        case (.learned, .primary), (.learned, .ignored):
            MemoryStore.shared.addMemory(rule.memoryLine)
        case (.learned, .secondary), (.didYouMean, .secondary):
            VocabularyCache.shared.update { $0.reject(heard: card.heard, term: card.term) }
        case (.didYouMean, .primary):
            MemoryStore.shared.addMemory(rule.memoryLine)
            if let pid = lastInsertPID {
                AXText.replaceInFocusedField(span: card.heard, with: card.term, pid: pid)
            }
        case (.didYouMean, .ignored):
            VocabularyCache.shared.update { $0.snooze(heard: card.heard, term: card.term, now: Date()) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showNextCard() }
    }
}
