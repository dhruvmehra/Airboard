// README — KEEP IN SYNC WITH Airboard/VocabularyLearning.swift.
//
// VocabularyLearning is AppKit (AX, cards, Keychain), so it can't be
// compiled standalone. This file replays its learn/apply glue on top of the
// REAL pure units (FillerRules, RedictationLearner, SpellingRule,
// CandidateFinder, VocabularyResolver, EditDiff, CorrectionWatchPolicy,
// VocabularyCardQueue, DecisionClient), copying the gating and ordering
// exactly — no improvements. When VocabularyLearning's process(),
// didInsert(), learnFromTranscripts(), considerEdit(), considerPair() or
// resolve() change, change this file the same way. If app code moves glue
// into a pure Foundation-only file, delete the copy here and have the eval
// call that file instead (add it to run.sh's PURE list).
//
// THIS FILE (GlueBaseline.swift) is the FROZEN copy matching rev 3504715 — do not
// edit it; edit Glue.swift (the working-tree copy) instead.
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
        let client = self.client
        let candidates = CandidateFinder.find(in: text, rules: rules, screenTerms: [])
        guard !candidates.isEmpty else { return (text, "none") }

        guard let client else {
            let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: nil)
            return (r.text, "nokey")
        }
        var bySentence: [String: [Candidate]] = [:]
        for c in candidates {
            bySentence[CandidateFinder.sentence(containing: c.range, in: text), default: []].append(c)
        }
        let groups = bySentence.map { sentence, cands -> (String, [Candidate]) in
            var seen = Set<String>()
            return (sentence, cands.filter { seen.insert($0.pairKey).inserted })
        }
        let deadline = applyDeadline
        let answers: [String: Double]? = await withTaskGroup(of: [String: Double]?.self) { group in
            for (sentence, unique) in groups {
                group.addTask {
                    let qs = unique.enumerated().map {
                        DecisionQuestion.applyTerm(id: "q\($0.offset)", sentence: sentence,
                                                   span: $0.element.span, term: $0.element.term)
                    }
                    guard let a = await client.ask(state: ["sentence": sentence], questions: qs,
                                                   deadline: deadline) else { return nil }
                    var byPair: [String: Double] = [:]
                    for (i, c) in unique.enumerated() { if let p = a["q\(i)"] { byPair[c.pairKey] = p } }
                    return byPair
                }
            }
            var merged: [String: Double] = [:]
            for await part in group {
                guard let part else { group.cancelAll(); return nil }
                merged.merge(part) { min($0, $1) }
            }
            return merged
        }
        let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: answers)
        let outcome = answers == nil ? "timeout" : (r.applied > 0 ? "applied" : "ok")
        return (r.text, outcome)
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
            await considerPair(heard: p.heard, corrected: p.corrected, sentence: p.sentence,
                               groundTruth: true, localGate: { true })
        }
    }

    private func considerEdit(_ c: EditDiff.Correction, sentence: String, fixed: String) async {
        trace.append("edit \"\(c.heard)\" → \"\(c.corrected)\"")
        await considerPair(heard: c.heard, corrected: c.corrected, sentence: sentence, groundTruth: false,
                           localGate: { CorrectionWatchPolicy.passesLocalGate(c, fixed: fixed) })
    }

    private func considerPair(heard: String, corrected: String, sentence: String, groundTruth: Bool,
                              localGate: () -> Bool) async {
        // (VocabularyCache isBlocked: nothing is ever rejected in the eval.)
        let known = SpellingRule.rules(from: memories).contains {
            CandidateFinder.normalize($0.heardAs) == CandidateFinder.normalize(heard) && $0.term == corrected
        }
        guard !known else { trace.append("  already a rule"); return }
        if groundTruth {
            queue.enqueue(VocabularyCard(kind: .learned, heard: heard, term: corrected))
            trace.append("  card (spelled)")
            showNextCard()
            return
        }
        guard let client else {
            guard localGate() else { trace.append("  no key — local gate said no"); return }
            trace.append("  no key — local gate passed → card")
            queue.enqueue(VocabularyCard(kind: .learned, heard: heard, term: corrected))
            showNextCard()
            return
        }
        let q = DecisionQuestion.spellingFix(id: "q0", sentence: sentence, heard: heard, corrected: corrected)
        let a = await client.ask(state: q.state, questions: [q], deadline: learnDeadline)
        guard let p = a?["q0"] else { trace.append("  decision: no answer (timeout/error)"); return }
        trace.append("  decision p=\(String(format: "%.2f", p)) (needs ≥ \(VocabularyResolver.suggestThreshold))")
        guard p >= VocabularyResolver.suggestThreshold else { return }
        queue.enqueue(VocabularyCard(kind: .learned, heard: heard, term: corrected))
        showNextCard()
    }

    // MARK: - Cards (ignored after 8s = Keep)

    private func showNextCard() {
        guard showing == nil, let card = queue.next(now: now, isRecording: false) else { return }
        showing = (card, now.addingTimeInterval(Self.cardIgnoreAfter))
    }

    private func resolveShowing() {
        guard let s = showing else { return }
        queue.dismissed()
        showing = nil
        // (.learned, .ignored) == Keep
        let rule = SpellingRule(term: s.card.term, heardAs: s.card.heard)
        addMemory(rule.memoryLine)
        trace.append("card kept: \(rule.memoryLine)")
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
            guard let t = next.min(), t <= target else { break }
            now = t
            if let s = showing, s.resolveAt <= now { resolveShowing() }
            if let a = showAgainAt, a <= now { showAgainAt = nil; showNextCard() }
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
