// README — KEEP IN SYNC WITH Airboard/VocabularyLearning.swift.
//
// VocabularyLearning is AppKit (AX, cards, Keychain), so it can't be
// compiled standalone. Its DECISIONS now live in pure files this replay
// calls directly — the same code the app runs:
//   apply:  CandidateFinder.find → VocabularyPipeline.apply (which
//           candidates to ask, the engine call, VocabularyResolver)
//   learn:  RuleLearning.propose (rules + gate) → VocabularyPipeline.learnDecision
//   dictionary: VocabularyResolver.WordList (one set, both sides)
// What is still copied here is only the I/O orchestration around them:
// the order of process()/didInsert()/learnFromTranscripts()/consider()/
// enqueueLearned()/resolve() and the card queue with its retry timer. When
// those change in VocabularyLearning, change this file the same way.
//
// GlueBaseline.swift is the frozen copy for rev 3504715 (run.sh --rev 3504715).
//
// What the app does that this replay leaves out (none of it changes the
// founder's loop): screen-term harvesting / "Did you mean" cards (needs the
// harvester; screenTerms = []), the reject/snooze cache (the eval user never
// presses Undo), and AX I/O (the field is a string we control).

import Foundation

final class GlueApp {
    // MemoryStore.memories — only the lines this replay adds.
    private(set) var memories: [String] = []
    let client: DecisionClient?
    let applyDeadline: TimeInterval     // VocabularyLearning.deadline (0.35)
    let learnDeadline: TimeInterval     // VocabularyLearning.backgroundDeadline (5)
    var trace: [String] = []            // learn-path decisions, for -v

    private var queue = VocabularyCardQueue()
    private var showing: (card: VocabularyCard, resolveAt: Date)?
    private var showAgainAt: Date?
    static let cardIgnoreAfter: TimeInterval = 8   // VocabularyCardView: ignored for 8s → .ignored

    private var pendingLearned: [LearnedPair] = []
    private var recentTurns: [TranscriptTurn] = []
    static let maxRecentTurns = 4

    private var watch = CorrectionWatchPolicy()
    /// fieldID → what the field holds: our insertion until `editAt`, then `after`.
    private var fields: [Int: (before: String, after: String?, editAt: Date)] = [:]
    private var nextField = 0
    private var lessonsWaiting: [CorrectionWatchPolicy.Lesson] = []

    private(set) var now = Date(timeIntervalSince1970: 2_000_000_000)

    init(client: DecisionClient?, applyDeadline: TimeInterval, learnDeadline: TimeInterval) {
        self.client = client
        self.applyDeadline = applyDeadline
        self.learnDeadline = learnDeadline
    }

    var rules: [SpellingRule] { SpellingRule.rules(from: memories) }

    /// MemoryStore.addMemory: trimmed, case-insensitive duplicate lines dropped.
    func addMemory(_ line: String) {
        let trimmed = line.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !memories.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        memories.append(trimmed)
    }

    // MARK: - Dictation path (TranscriptPostProcessor .dictation + VocabularyLearning.process)

    func dictate(_ raw: String) async -> (text: String, outcome: String) {
        let ruled = FillerRules.clean(raw)
        let spelled = RedictationLearner.spelledRewrite(ruled)
        pendingLearned = spelled.pairs
        let text = spelled.text
        let rules = SpellingRule.rules(from: memories)
        let candidates = CandidateFinder.find(in: text, rules: rules, screenTerms: [])
        guard !candidates.isEmpty else { return (text, "none") }
        let a = await VocabularyPipeline.apply(text: text, candidates: candidates, client: client,
                                               deadline: applyDeadline)
        return (a.result.text, a.outcome)
    }

    // MARK: - Recording / insertion

    /// VocabularyLearning.recordingStarted: the watcher flushes (one read of
    /// every watched field now); pending per-dictation state is cleared.
    func recordingStarted() async {
        watch.recordingStarted()
        await runWatcher(upTo: now)
        pendingLearned = []
    }

    /// VocabularyLearning.didInsert: learnFromTranscripts, then the watcher
    /// starts on the field (0.3s later, once the paste settled).
    func didInsert(_ text: String, pid: Int32) async -> Int? {
        await learnFromTranscripts(text, pid: pid)
        nextField += 1
        let fid = nextField
        let at = now.addingTimeInterval(0.3)
        await advance(to: at)
        let r = watch.inserted(fieldID: fid, text: text, fieldText: text, at: now)
        guard r.id != nil else { trace.append("watch: not watchable"); return nil }
        fields[fid] = (text, nil, .distantFuture)
        return fid
    }

    /// The user edits the field (keyboard fix) at `at`; the watcher sees it
    /// on its next readings.
    func userEdits(field: Int, to after: String, at: Date) {
        guard let f = fields[field] else { return }
        fields[field] = (f.before, after, at)
    }

    private func learnFromTranscripts(_ text: String, pid: Int32) async {
        let turn = TranscriptTurn(text: text, at: now, pid: pid)
        let pairs = (pendingLearned + RedictationLearner.detect(current: turn, previous: recentTurns))
            .filter { $0.kind == .spelled && $0.strength >= RedictationLearner.directCardStrength }
        pendingLearned = []
        recentTurns = Array((recentTurns.filter { now.timeIntervalSince($0.at) <= RedictationLearner.window } + [turn])
            .suffix(Self.maxRecentTurns))
        guard !pairs.isEmpty else { return }
        for p in pairs {
            trace.append("spelled pair \"\(p.heard)\" → \"\(p.corrected)\"")
            await consider(EditDiff.Correction(heard: p.heard, corrected: p.corrected), sentence: p.sentence,
                           fixed: p.sentence, source: .spelled)
        }
    }

    private func considerEdit(_ c: EditDiff.Correction, sentence: String, fixed: String) async {
        trace.append("edit \"\(c.heard)\" → \"\(c.corrected)\"")
        await consider(c, sentence: sentence, fixed: fixed, source: .keyboard)
    }

    /// VocabularyLearning.consider + act: RuleLearning decides, the
    /// pipeline asks the engine when the gate says so.
    private func consider(_ c: EditDiff.Correction, sentence: String, fixed: String,
                          source: RuleLearning.Source) async {
        let client = source == .keyboard ? self.client : nil
        let p = RuleLearning.propose(c, fixed: fixed, source: source, existing: rules,
                                     hasKey: client != nil, isOrdinaryWord: VocabularyResolver.WordList.isOrdinaryWord)
        trace.append("  → \(p.gate.rawValue) (\(p.reason)): " + p.rules.map { "\($0.term)←\"\($0.heardAs)\"" }.joined(separator: ", "))
        switch p.gate {
        case .reject: return
        case .learnDirect: enqueueLearned(p)
        case .askDecisionModel:
            guard client != nil else { return }
            let d = await VocabularyPipeline.learnDecision(p, sentence: sentence, client: client, deadline: learnDeadline)
            trace.append("  decision \(d.answer.map { String(format: "p=%.2f", $0) } ?? "no answer") → \(d.learn ? "learn" : "no")")
            if d.learn { enqueueLearned(p) }
        }
    }

    /// One Learned card per correction; its Keep writes every rule.
    /// (VocabularyCache isBlocked: the eval user never presses Undo.)
    private func enqueueLearned(_ p: RuleLearning.Proposal) {
        let card = VocabularyCard(kind: .learned, heard: p.card.heardAs, term: p.card.term)
        cardRules[VocabularyCacheData.pairKey(heard: card.heard, term: card.term)] = p.rules
        queue.enqueue(card)
        showNextCard()
    }

    // MARK: - Cards (ignored after 8s = Keep)

    private var cardRules: [String: [SpellingRule]] = [:]
    /// VocabularyLearning.showNextCard's retry timer (hourly limit).
    private var retryAt: Date?

    private func showNextCard() {
        retryAt = nil
        guard let card = queue.next(now: now, isRecording: false) else {
            guard !queue.pending.isEmpty, queue.showing == nil else { return }
            let oldest = queue.shownAt.filter { now.timeIntervalSince($0) < 3600 }.min()
            retryAt = now.addingTimeInterval(max(1, (oldest?.addingTimeInterval(3600).timeIntervalSince(now) ?? 1) + 1))
            return
        }
        showing = (card, now.addingTimeInterval(Self.cardIgnoreAfter))
    }

    private func resolveShowing() {
        guard let s = showing else { return }
        queue.dismissed()
        showing = nil
        // (.learned, .ignored) == Keep: every rule of the card.
        let key = VocabularyCacheData.pairKey(heard: s.card.heard, term: s.card.term)
        let rules = cardRules[key] ?? [SpellingRule(term: s.card.term, heardAs: s.card.heard)]
        cardRules[key] = nil
        for r in rules { addMemory(r.memoryLine); trace.append("card kept: \(r.term)←\"\(r.heardAs)\"") }
        showAgainAt = now.addingTimeInterval(0.5)
    }

    var cardsWaiting: Int { queue.pending.count + (showing == nil ? 0 : 1) }

    // MARK: - Clock

    /// Runs watcher readings and card timers up to `target`.
    func advance(to target: Date) async {
        while true {
            var next: [Date] = []
            if let t = watch.nextCheck(now: now) { next.append(max(t, now)) }
            if let s = showing { next.append(s.resolveAt) }
            if let t = showAgainAt { next.append(t) }
            if let t = retryAt { next.append(t) }
            guard let t = next.min(), t <= target else { break }
            now = t
            if let s = showing, s.resolveAt <= now { resolveShowing() }
            if let a = showAgainAt, a <= now { showAgainAt = nil; showNextCard() }
            if let r = retryAt, r <= now { showNextCard() }
            await runWatcher(upTo: now)
        }
        if target > now { now = target }
    }

    private func runWatcher(upTo t: Date) async {
        for fid in watch.fieldsDue(at: t) {
            guard let f = fields[fid] else { continue }
            let text = (f.after != nil && t >= f.editAt) ? f.after! : f.before
            let r = watch.observe(fieldID: fid, text: text, focused: true, at: t)
            lessonsWaiting += r.lessons
        }
        _ = watch.expire(now: t)
        for (fid, _) in fields where !watch.watchedFields.contains(fid) { fields[fid] = nil }
        let lessons = lessonsWaiting
        lessonsWaiting = []
        for l in lessons { await considerEdit(l.correction, sentence: l.sentence, fixed: l.fixed) }
    }

    /// The user keeps using the app: hours pass, every waiting card shows
    /// (the hourly cap lifts) and is ignored = Keep.
    func drainCards() async {
        for _ in 0..<50 {
            if showing == nil && queue.pending.isEmpty { break }
            await advance(to: now.addingTimeInterval(3600))
            showNextCard()
        }
    }
}
