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

    /// "Did you mean" suggestions from the CURRENT dictation, waiting for
    /// its insertion. Cleared at every new recording and on failed
    /// insertion so they can never attach to unrelated text.
    private var pendingSuggestions: [VocabularyCard] = []
    private var queue = VocabularyCardQueue()

    /// Where a "Did you mean" card's word lives: the field we typed into,
    /// what we typed, and when. "Yes" fixes in place only inside that
    /// text, only in that field, and only soon after.
    private struct SuggestionContext {
        let element: AXUIElement
        let inserted: String
        let at: Date
    }
    private var suggestionContext: [String: SuggestionContext] = [:]  // pairKey
    static let inPlaceFixWindow: TimeInterval = 20

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { CorrectionWatcher.shared.cancel() }
        start()
    }

    /// Launch, toggle, and key changes all land here. Screen harvesting
    /// runs only with the feature on AND a key set — without a key nothing
    /// can be judged, so nothing is read.
    func start() {
        if isEnabled && client() != nil {
            VocabularyHarvester.shared.start()
        } else {
            VocabularyHarvester.shared.stop()
        }
    }

    /// The OpenRouter key was saved or cleared in Settings.
    func keyChanged() { start() }

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
        // One request per sentence, each carrying only that sentence (the
        // spec's privacy promise; extra context also degrades Jev). One
        // question per distinct (span, term) in it. Requests run
        // concurrently under the same 350ms deadline.
        var bySentence: [String: [Candidate]] = [:]
        for c in candidates {
            bySentence[CandidateFinder.sentence(containing: c.range, in: text), default: []].append(c)
        }
        let groups = bySentence.map { sentence, cands -> (String, [Candidate]) in
            var seen = Set<String>()
            return (sentence, cands.filter { seen.insert($0.pairKey).inserted })
        }
        let answers: [String: Double]? = await withTaskGroup(of: [String: Double]?.self) { group in
            for (sentence, unique) in groups {
                group.addTask {
                    let qs = unique.enumerated().map {
                        DecisionQuestion.applyTerm(id: "q\($0.offset)", sentence: sentence,
                                                   span: $0.element.span, term: $0.element.term)
                    }
                    guard let a = await client.ask(state: ["sentence": sentence], questions: qs,
                                                   deadline: Self.deadline) else { return nil }
                    var byPair: [String: Double] = [:]
                    for (i, c) in unique.enumerated() { if let p = a["q\(i)"] { byPair[c.pairKey] = p } }
                    return byPair
                }
            }
            // Any sentence that timed out → treat the whole dictation as
            // unanswered (offline rules) rather than half-applying.
            var merged: [String: Double] = [:]
            for await part in group {
                guard let part else { group.cancelAll(); return nil }
                // Same pair in two sentences: the more cautious answer wins.
                merged.merge(part) { min($0, $1) }
            }
            return merged
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: answers)
        pendingSuggestions = r.suggestions.map { VocabularyCard(kind: .didYouMean, heard: $0.span, term: $0.term) }
        let outcome = answers == nil ? "timeout" : (r.applied > 0 ? "applied" : "ok")
        print("🧠 Vocab: \(candidates.count) candidate(s), \(r.applied) applied, \(r.suggestions.count) suggested, \(outcome) in \(ms)ms")
        return VocabOutcome(text: r.text, ms: ms, outcome: outcome)
    }

    // MARK: - After insertion

    func recordingStarted() {
        // Earlier insertions stay watched — back-to-back dictation is the
        // norm, and people fix names after re-reading.
        CorrectionWatcher.shared.recordingStarted()
        VocabularyHarvester.shared.abortWalk()
        pendingSuggestions = []
    }

    /// The text never landed — its suggestions must not attach elsewhere.
    func insertionFailed() {
        pendingSuggestions = []
    }

    func didInsert(_ text: String, pid: pid_t) {
        guard isEnabled else { print("🧠 Learn: vocabulary learning is off — not watching"); return }
        if !pendingSuggestions.isEmpty, let field = AXText.focusedElement(pid: pid) {
            for card in pendingSuggestions {
                suggestionContext[VocabularyCacheData.pairKey(heard: card.heard, term: card.term)] =
                    SuggestionContext(element: field, inserted: text, at: Date())
                queue.enqueue(card)
            }
        }
        pendingSuggestions = []
        showNextCard()
        // Watched with or without a key: without one, the stricter local
        // gate in considerEdit decides.
        CorrectionWatcher.shared.observe(inserted: text, pid: pid) { lesson in
            VocabularyLearning.shared.considerEdit(lesson.correction, sentence: lesson.sentence, fixed: lesson.fixed)
        }
    }

    private func considerEdit(_ c: EditDiff.Correction, sentence: String, fixed: String) {
        guard isEnabled else { return }
        guard !VocabularyCache.shared.data.isBlocked(heard: c.heard, term: c.corrected, now: Date()) else {
            print("🧠 Learn: pair was rejected/snoozed before — no card"); return
        }
        let known = SpellingRule.rules(from: MemoryStore.shared.memories).contains {
            CandidateFinder.normalize($0.heardAs) == CandidateFinder.normalize(c.heard) && $0.term == c.corrected
        }
        guard !known else { print("🧠 Learn: already a confirmed rule — no card"); return }
        guard let client = client() else {
            // No decision model: only an unmistakable name fix (sounds
            // alike + capitalised + not a common word) becomes a card.
            guard CorrectionWatchPolicy.passesLocalGate(c, fixed: fixed) else {
                print("🧠 Learn: no key — local gate said not a name fix"); return
            }
            print("🧠 Learn: no key — local gate passed")
            queue.enqueue(VocabularyCard(kind: .learned, heard: c.heard, term: c.corrected))
            showNextCard()
            return
        }
        Task {
            let q = DecisionQuestion.spellingFix(id: "q0", sentence: sentence, heard: c.heard, corrected: c.corrected)
            let a = await client.ask(state: q.state, questions: [q], deadline: Self.backgroundDeadline)
            guard let p = a?["q0"] else { print("🧠 Learn: decision engine gave no answer (timeout/error)"); return }
            print("🧠 Learn: spelling-fix confidence \(String(format: "%.2f", p)) (needs ≥ \(VocabularyResolver.suggestThreshold))")
            guard p >= VocabularyResolver.suggestThreshold else { return }
            await MainActor.run {
                self.queue.enqueue(VocabularyCard(kind: .learned, heard: c.heard, term: c.corrected))
                self.showNextCard()
            }
        }
    }

    // MARK: - Cards

    private func showNextCard() {
        guard let card = queue.next(now: Date(), isRecording: TranscriptionCoordinator.shared.isRecording) else {
            if !queue.pending.isEmpty { print("🧠 Cards: \(queue.pending.count) waiting (one showing, recording, or hourly limit)") }
            return
        }
        print("🧠 Cards: showing \(card.kind == .learned ? "Learned" : "Did you mean") card")
        VocabularyCardPresenter.shared.show(card) { [weak self] choice in
            self?.resolve(card, choice)
        }
    }

    private func resolve(_ card: VocabularyCard, _ choice: VocabularyCardChoice) {
        queue.dismissed()
        let rule = SpellingRule(term: card.term, heardAs: card.heard)
        let key = VocabularyCacheData.pairKey(heard: card.heard, term: card.term)
        defer { suggestionContext[key] = nil }
        switch (card.kind, choice) {
        case (.learned, .primary), (.learned, .ignored):
            MemoryStore.shared.addMemory(rule.memoryLine)
        case (.learned, .secondary), (.didYouMean, .secondary):
            VocabularyCache.shared.update { $0.reject(heard: card.heard, term: card.term) }
        case (.didYouMean, .primary):
            MemoryStore.shared.addMemory(rule.memoryLine)
            // Fix the word in place only inside OUR insertion, in the same
            // field, and only soon after — otherwise the rule just applies
            // from the next dictation on.
            if let ctx = suggestionContext[key],
               Date().timeIntervalSince(ctx.at) < Self.inPlaceFixWindow {
                AXText.replaceInsertedSpan(span: card.heard, with: card.term,
                                           inserted: ctx.inserted, in: ctx.element)
            }
        case (.didYouMean, .ignored):
            VocabularyCache.shared.update { $0.snooze(heard: card.heard, term: card.term, now: Date()) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showNextCard() }
    }
}
