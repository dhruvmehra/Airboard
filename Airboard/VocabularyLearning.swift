//
//  VocabularyLearning.swift
//
//  The self-learning vocabulary feature, in one place:
//  - process(): dictation path. Finds candidates, asks the decision
//    engine once (350ms hard limit), applies confirmed spellings in
//    context. +0ms when the text holds no candidate.
//  - didInsert(): queues "Did you mean" cards and starts the
//    CorrectionWatcher on the field we just typed into.
//  - learnFromTranscripts(): learning that needs no field reading
//    (RedictationLearner) — spelled-out letters, follow-up corrections,
//    re-dictation — from the last few transcripts, kept in memory only.
//  - cards: Keep/Undo (Learned; ignored = Keep), Yes/No (Did you mean;
//    ignored = snoozed). Keep/Yes write SpellingRule line(s) to memory.md.
//    WHICH rules a correction teaches and whether it needs the decision
//    model is RuleLearning (pure, shared with the offline evals).
//  Spec: docs/superpowers/specs/2026-10-07-self-learning-vocabulary-design.md
//

import AppKit

struct VocabOutcome {
    let text: String
    let ms: Int?          // nil when the engine wasn't called
    let outcome: String   // off | none | nokey | local | ok | applied | timeout
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

    /// Spelled-letter pairs from the CURRENT dictation, waiting for its
    /// insertion (same lifecycle as pendingSuggestions).
    private var pendingLearned: [LearnedPair] = []
    /// The last few inserted transcripts, for cross-dictation learning.
    /// Memory only — never written to disk, never logged.
    private var recentTurns: [TranscriptTurn] = []
    static let maxRecentTurns = 4

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

    /// Learned card pairKey → every rule its Keep writes (the card's own
    /// pair plus per-word rules: "druv mera" → "Dhruv Mehra" also teaches
    /// Dhruv ← druv and Mehra ← mera).
    private var cardRules: [String: [SpellingRule]] = [:]
    /// Learned cards not yet resolved survive a quit (they used to be lost
    /// when the hourly limit or a recording held them back). Same data
    /// memory.md gets on Keep; never logged.
    static let pendingCardsKey = "vocabPendingLearnedCards"
    private var restoredPending = false
    private var cardRetry: DispatchWorkItem?

    /// Lowercase system dictionary (/usr/share/dict/words) for the learning
    /// gate — the same set the apply side uses (held once). The first call
    /// loads it (60-300ms): call off main, or warm it in start().
    nonisolated static func ordinaryWords() -> Set<String> { VocabularyResolver.WordList.words.lower }

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
        // Warm the word list off the dictation path (the first dictation
        // with a candidate would otherwise pay the load).
        if isEnabled { DispatchQueue.global(qos: .utility).async { _ = Self.ordinaryWords() } }
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

    /// useEngine=false (hands-free chunks): no network — live chunks must
    /// stay instant; confirmed rules still apply by the local policy
    /// (VocabularyResolver: unmistakable names always, ordinary words only
    /// on a strong signal).
    func process(_ raw: String, useEngine: Bool) async -> VocabOutcome {
        guard isEnabled else { return VocabOutcome(text: raw, ms: nil, outcome: "off") }
        // "Tell Anakshi, I N A K S H I, that…" → "Tell Inakshi that…": the
        // user spelled it, so this dictation gets the spelling now (local,
        // ~0ms). Learning the rule still waits for the Keep/Undo card.
        let spelled = RedictationLearner.spelledRewrite(raw)
        pendingLearned = spelled.pairs
        let text = spelled.text
        let rules = SpellingRule.rules(from: MemoryStore.shared.memories)
        let client = useEngine ? client() : nil
        let now = Date()
        let screen = client == nil ? [] : VocabularyCache.shared.data.screenTerms
        let candidates = CandidateFinder.find(in: text, rules: rules, screenTerms: screen).filter {
            !($0.source == .screen && VocabularyCache.shared.data.isBlocked(heard: $0.span, term: $0.term, now: now))
        }
        guard !candidates.isEmpty else { return VocabOutcome(text: text, ms: nil, outcome: "none") }

        // VocabularyPipeline (pure, shared with scripts/name-eval): an
        // unmistakable learned name applies locally; only candidates the
        // engine can change are asked — one request per sentence, each
        // carrying only that sentence, all under the same 350ms deadline.
        let start = Date()
        let a = await VocabularyPipeline.apply(text: text, candidates: candidates, client: client,
                                               deadline: Self.deadline)
        let ms = a.askedEngine ? Int(Date().timeIntervalSince(start) * 1000) : nil
        let r = a.result
        pendingSuggestions = r.suggestions.map { VocabularyCard(kind: .didYouMean, heard: $0.span, term: $0.term) }
        print("🧠 Vocab: \(candidates.count) candidate(s), \(r.applied) applied, \(r.suggestions.count) suggested, \(a.outcome)\(ms.map { " in \($0)ms" } ?? "")")
        return VocabOutcome(text: r.text, ms: ms, outcome: a.outcome)
    }

    // MARK: - After insertion

    func recordingStarted() {
        // Earlier insertions stay watched — back-to-back dictation is the
        // norm, and people fix names after re-reading.
        CorrectionWatcher.shared.recordingStarted()
        VocabularyHarvester.shared.abortWalk()
        pendingSuggestions = []
        pendingLearned = []
        // The dictation target is in front now: ask an Electron app to expose
        // its text while the user speaks (it takes ~2s), so the watcher can
        // read the field after insertion. Async, once per process.
        if isEnabled, let app = NSWorkspace.shared.frontmostApplication {
            AXText.enableWebAccessibility(for: app)
        }
    }

    /// The text never landed — its suggestions must not attach elsewhere.
    func insertionFailed() {
        pendingSuggestions = []
        pendingLearned = []
    }

    func didInsert(_ text: String, pid: pid_t) {
        guard isEnabled else { print("🧠 Learn: vocabulary learning is off — not watching"); return }
        restorePendingCards()
        DispatchQueue.global(qos: .utility).async { _ = Self.ordinaryWords() }
        if !pendingSuggestions.isEmpty, let field = AXText.focusedElement(pid: pid) {
            for card in pendingSuggestions {
                suggestionContext[VocabularyCacheData.pairKey(heard: card.heard, term: card.term)] =
                    SuggestionContext(element: field, inserted: text, at: Date())
                queue.enqueue(card)
            }
        }
        pendingSuggestions = []
        showNextCard()
        learnFromTranscripts(text, pid: pid)
        // Watched with or without a key: without one, the stricter local
        // gate in considerEdit decides.
        CorrectionWatcher.shared.observe(inserted: text, pid: pid) { lesson in
            VocabularyLearning.shared.considerEdit(lesson.correction, sentence: lesson.sentence, fixed: lesson.fixed)
        }
    }

    /// Spelled letters ("Inakshi, I N A K S H I" or "that's spelled B R I
    /// T E" right after): ground truth from the user's own voice, so it
    /// works where the field can't be read. Follow-ups and re-dictation
    /// are detected but not learned from — Parakeet mishears the name
    /// again on the second try (scripts/redictation-eval).
    private func learnFromTranscripts(_ text: String, pid: pid_t) {
        let now = Date()
        let turn = TranscriptTurn(text: text, at: now, pid: pid)
        let pairs = (pendingLearned + RedictationLearner.detect(current: turn, previous: recentTurns))
            .filter { $0.kind == .spelled && $0.strength >= RedictationLearner.directCardStrength }
        pendingLearned = []
        recentTurns = Array((recentTurns.filter { now.timeIntervalSince($0.at) <= RedictationLearner.window } + [turn])
            .suffix(Self.maxRecentTurns))
        guard !pairs.isEmpty else { return }
        print("🧠 Learn: \(pairs.count) spelled pair(s) from transcripts")
        for p in pairs {
            consider(EditDiff.Correction(heard: p.heard, corrected: p.corrected), sentence: p.sentence,
                     fixed: p.sentence, source: .spelled)
        }
    }

    private func considerEdit(_ c: EditDiff.Correction, sentence: String, fixed: String) {
        guard isEnabled else { return }
        consider(c, sentence: sentence, fixed: fixed, source: .keyboard)
    }

    /// RuleLearning decides the rules and the gate; this only does I/O.
    /// Nothing is learned until the Keep/Undo card resolves.
    private func consider(_ c: EditDiff.Correction, sentence: String, fixed: String, source: RuleLearning.Source) {
        let client = source == .keyboard ? client() : nil
        let existing = SpellingRule.rules(from: MemoryStore.shared.memories)
        // The first call loads the system dictionary (~60-300ms): off main.
        DispatchQueue.global(qos: .userInitiated).async {
            let words = Self.ordinaryWords()
            let p = RuleLearning.propose(c, fixed: fixed, source: source, existing: existing,
                                         hasKey: client != nil, isOrdinaryWord: { words.contains($0) })
            DispatchQueue.main.async { self.act(on: p, source: source, sentence: sentence, client: client) }
        }
    }

    private func act(on p: RuleLearning.Proposal, source: RuleLearning.Source, sentence: String, client: DecisionClient?) {
        print("🧠 Learn: \(source == .spelled ? "spelled" : "edit") → \(p.gate.rawValue) (\(p.reason)), \(p.rules.count) rule(s)")
        switch p.gate {
        case .reject:
            return
        case .learnDirect:
            enqueueLearned(p)
        case .askDecisionModel:
            guard client != nil else { return }
            Task {
                // VocabularyPipeline.learnDecision: shared with scripts/name-eval.
                let d = await VocabularyPipeline.learnDecision(p, sentence: sentence, client: client,
                                                               deadline: Self.backgroundDeadline)
                if let ans = d.answer {
                    print("🧠 Learn: spelling-fix confidence \(String(format: "%.2f", ans)) (needs ≥ \(VocabularyResolver.suggestThreshold))")
                } else {
                    print("🧠 Learn: decision engine gave no answer — keyless gate \(d.learn ? "passed" : "failed")")
                }
                guard d.learn else { return }
                await MainActor.run { self.enqueueLearned(p) }
            }
        }
    }

    /// One Learned card per correction; its Keep writes every rule.
    private func enqueueLearned(_ p: RuleLearning.Proposal) {
        let now = Date()
        let card = VocabularyCard(kind: .learned, heard: p.card.heardAs, term: p.card.term)
        guard !VocabularyCache.shared.data.isBlocked(heard: card.heard, term: card.term, now: now) else {
            print("🧠 Learn: pair was rejected/snoozed before — no card"); return
        }
        // A per-word rule the user already turned down stays out.
        let rules = p.rules.filter { !VocabularyCache.shared.data.isBlocked(heard: $0.heardAs, term: $0.term, now: now) }
        guard !rules.isEmpty else { print("🧠 Learn: every rule was rejected before — no card"); return }
        cardRules[VocabularyCacheData.pairKey(heard: card.heard, term: card.term)] = rules
        queue.enqueue(card)
        savePendingCards()
        showNextCard()
    }

    // MARK: - Cards

    private func showNextCard() {
        cardRetry?.cancel(); cardRetry = nil
        let now = Date()
        let recording = TranscriptionCoordinator.shared.isRecording
        guard let card = queue.next(now: now, isRecording: recording) else {
            guard !queue.pending.isEmpty, queue.showing == nil else { return }
            // Held back by a recording or the hourly limit: try again then,
            // instead of waiting for the next dictation to come along.
            let oldest = queue.shownAt.filter { now.timeIntervalSince($0) < 3600 }.min()
            let delay = recording ? 3 : max(1, (oldest?.addingTimeInterval(3600).timeIntervalSince(now) ?? 1) + 1)
            print("🧠 Cards: \(queue.pending.count) waiting (\(recording ? "recording" : "hourly limit")) — retry in \(Int(delay))s")
            let work = DispatchWorkItem { [weak self] in self?.showNextCard() }
            cardRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        let rules = card.kind == .learned ? (cardRules[key] ?? [rule]) : [rule]
        defer {
            suggestionContext[key] = nil
            if card.kind == .learned { cardRules[key] = nil; savePendingCards() }
        }
        switch (card.kind, choice) {
        case (.learned, .primary), (.learned, .ignored):
            for r in rules { MemoryStore.shared.addMemory(r.memoryLine) }
            print("🧠 Cards: kept — \(rules.count) rule(s) written")
        case (.learned, .secondary):
            VocabularyCache.shared.update { c in for r in rules { c.reject(heard: r.heardAs, term: r.term) } }
        case (.didYouMean, .secondary):
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

    // MARK: - Pending Learned cards (survive quit)

    private func savePendingCards() {
        var list: [[String]] = []
        for card in ([queue.showing].compactMap { $0 } + queue.pending) where card.kind == .learned {
            let key = VocabularyCacheData.pairKey(heard: card.heard, term: card.term)
            let rules = cardRules[key] ?? [SpellingRule(term: card.term, heardAs: card.heard)]
            list.append([card.heard, card.term] + rules.flatMap { [$0.heardAs, $0.term] })
        }
        UserDefaults.standard.set(list, forKey: Self.pendingCardsKey)
    }

    private func restorePendingCards() {
        guard !restoredPending else { return }
        restoredPending = true
        guard let list = UserDefaults.standard.array(forKey: Self.pendingCardsKey) as? [[String]], !list.isEmpty else { return }
        let existing = SpellingRule.rules(from: MemoryStore.shared.memories)
        var restored = 0
        for e in list where e.count >= 4 && e.count % 2 == 0 {
            let card = VocabularyCard(kind: .learned, heard: e[0], term: e[1])
            let rules = stride(from: 2, to: e.count, by: 2).map { SpellingRule(term: e[$0 + 1], heardAs: e[$0]) }
                .filter { !RuleLearning.isKnown(heard: $0.heardAs, term: $0.term, in: existing) }
            guard !rules.isEmpty else { continue }
            cardRules[VocabularyCacheData.pairKey(heard: card.heard, term: card.term)] = rules
            queue.enqueue(card)
            restored += 1
        }
        print("🧠 Cards: restored \(restored) unresolved Learned card(s) from last run")
        savePendingCards()
    }
}
