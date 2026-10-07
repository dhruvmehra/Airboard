//
//  VocabularyCacheData.swift
//
//  The hidden, non-user-facing learning state: harvested screen terms,
//  per-term "is this a real term?" verdicts, and pairs the user rejected.
//  Pure value type (Codable); VocabularyCache persists it. Confirmed
//  rules never live here — they live in memory.md.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct VocabularyCacheData: Codable, Equatable {
    var termCounts: [String: Int] = [:]     // term as seen -> sightings
    var termVerdicts: [String: Bool] = [:]  // lowercased term -> real term?
    var rejected: Set<String> = []          // pairKey: Undo / No — never ask again
    var snoozedUntil: [String: Date] = [:]  // pairKey: ignored "Did you mean"

    static let maxTerms = 500
    static let minSightings = 3
    static let snooze: TimeInterval = 7 * 24 * 3600

    static func pairKey(heard: String, term: String) -> String {
        CandidateFinder.normalize(heard) + "→" + CandidateFinder.normalize(term)
    }

    mutating func addSightings(_ terms: [String]) {
        for t in terms { termCounts[t, default: 0] += 1 }
        guard termCounts.count > Self.maxTerms else { return }
        let keep = termCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.maxTerms)
        termCounts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// Seen often enough and judged a real term.
    var screenTerms: [String] {
        termCounts.filter { $0.value >= Self.minSightings && termVerdicts[$0.key.lowercased()] == true }
            .sorted { $0.value > $1.value }.map(\.key)
    }

    /// Seen often enough, not yet judged — the harvester asks about these.
    func unjudged(limit: Int) -> [String] {
        Array(termCounts.filter { $0.value >= Self.minSightings && termVerdicts[$0.key.lowercased()] == nil }
            .sorted { $0.value > $1.value }.map(\.key).prefix(limit))
    }

    func isBlocked(heard: String, term: String, now: Date) -> Bool {
        let k = Self.pairKey(heard: heard, term: term)
        if rejected.contains(k) { return true }
        if let until = snoozedUntil[k], until > now { return true }
        return false
    }

    mutating func reject(heard: String, term: String) {
        rejected.insert(Self.pairKey(heard: heard, term: term))
    }

    mutating func snooze(heard: String, term: String, now: Date) {
        snoozedUntil[Self.pairKey(heard: heard, term: term)] = now.addingTimeInterval(Self.snooze)
    }
}
