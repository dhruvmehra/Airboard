//
//  VocabularyPipeline.swift
//
//  The decision glue of VocabularyLearning, pure so the app and the
//  offline evals (scripts/name-eval) run the SAME code:
//  - apply(): the dictation path after CandidateFinder — which candidates
//    the decision engine is asked about (only the ones it can change), one
//    request per sentence under one deadline, then VocabularyResolver.
//  - learnDecision(): whether a RuleLearning proposal becomes a Learned
//    card (asks the engine only when the gate says so).
//  VocabularyLearning keeps the I/O (Keychain, AX, cards, memory.md).
//  Foundation-only (+ DecisionClient). Never prints user text.
//

import Foundation

nonisolated enum VocabularyPipeline {

    struct Applied {
        let result: VocabularyResolver.Result
        /// none | nokey | local | ok | applied | timeout — stage label only.
        let outcome: String
        /// Whether the engine was called (ms is meaningful only then).
        let askedEngine: Bool
    }

    /// One group per sentence (the only context sent off-device), one
    /// question per distinct (span, term) in it — and only for candidates
    /// whose outcome the engine can change: an unmistakable learned name
    /// ("Druv", "Dhruvmehra") applies locally without waiting on the network.
    static func questionGroups(text: String, candidates: [Candidate],
                               isOrdinaryWord: (String) -> Bool = VocabularyResolver.WordList.isOrdinaryWord,
                               isKnownName: (String) -> Bool = VocabularyResolver.WordList.isKnownName)
        -> [(sentence: String, candidates: [Candidate])] {
        var order: [String] = []
        var bySentence: [String: [Candidate]] = [:]
        var seen = Set<String>()
        for c in candidates where VocabularyResolver.needsDecision(c, in: text, isOrdinaryWord: isOrdinaryWord,
                                                                    isKnownName: isKnownName) {
            let s = CandidateFinder.sentence(containing: c.range, in: text)
            guard seen.insert(s + "\u{1}" + c.pairKey).inserted else { continue }
            if bySentence[s] == nil { order.append(s) }
            bySentence[s, default: []].append(c)
        }
        return order.map { ($0, bySentence[$0]!) }
    }

    /// Every sentence asked concurrently under one deadline. nil when any
    /// sentence got no answer — the whole dictation then falls back to the
    /// local policy rather than half-applying.
    static func ask(_ client: DecisionClient, groups: [(sentence: String, candidates: [Candidate])],
                    deadline: TimeInterval) async -> [String: Double]? {
        await withTaskGroup(of: [String: Double]?.self) { group in
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
                // Same pair in two sentences: the more cautious answer wins.
                merged.merge(part) { min($0, $1) }
            }
            return merged
        }
    }

    /// Candidates → final text. No client (no key, hands-free chunk) or
    /// nothing worth asking: local policy only, no network.
    static func apply(text: String, candidates: [Candidate], client: DecisionClient?,
                      deadline: TimeInterval,
                      isOrdinaryWord: (String) -> Bool = VocabularyResolver.WordList.isOrdinaryWord,
                      isKnownName: (String) -> Bool = VocabularyResolver.WordList.isKnownName) async -> Applied {
        guard !candidates.isEmpty else {
            return Applied(result: .init(text: text, applied: 0, suggestions: []), outcome: "none", askedEngine: false)
        }
        func local(_ outcome: String) -> Applied {
            let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: nil,
                                               isOrdinaryWord: isOrdinaryWord, isKnownName: isKnownName)
            return Applied(result: r, outcome: outcome, askedEngine: false)
        }
        guard let client else { return local("nokey") }
        let groups = questionGroups(text: text, candidates: candidates,
                                    isOrdinaryWord: isOrdinaryWord, isKnownName: isKnownName)
        guard !groups.isEmpty else { return local("local") }
        let answers = await ask(client, groups: groups, deadline: deadline)
        let r = VocabularyResolver.resolve(text: text, candidates: candidates, answers: answers,
                                           isOrdinaryWord: isOrdinaryWord, isKnownName: isKnownName)
        return Applied(result: r, outcome: answers == nil ? "timeout" : (r.applied > 0 ? "applied" : "ok"),
                       askedEngine: true)
    }

    /// Whether a proposal becomes a Learned card. `answer` is the engine's
    /// confidence when it was asked and answered (for logs: a number only).
    static func learnDecision(_ p: RuleLearning.Proposal, sentence: String, client: DecisionClient?,
                              deadline: TimeInterval) async -> (learn: Bool, answer: Double?, asked: Bool) {
        switch p.gate {
        case .reject: return (false, nil, false)
        case .learnDirect: return (true, nil, false)
        case .askDecisionModel:
            guard let client else { return (RuleLearning.learns(p, decision: nil), nil, false) }
            let q = DecisionQuestion.spellingFix(id: "q0", sentence: sentence,
                                                 heard: p.card.heardAs, corrected: p.card.term)
            let a = await client.ask(state: q.state, questions: [q], deadline: deadline)
            let ans = a?["q0"]
            return (RuleLearning.learns(p, decision: ans, threshold: VocabularyResolver.suggestThreshold), ans, true)
        }
    }
}
