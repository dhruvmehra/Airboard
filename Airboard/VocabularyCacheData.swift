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
    var lastSeen: [String: Date] = [:]      // term as seen -> last sighting
    var termVerdicts: [String: Bool] = [:]  // lowercased term -> real term?
    var rejected: Set<String> = []          // pairKey: Undo / No — never ask again
    var snoozedUntil: [String: Date] = [:]  // pairKey: ignored "Did you mean"

    static let maxTerms = 500
    static let maxVerdicts = 2000
    static let minSightings = 3
    static let snooze: TimeInterval = 7 * 24 * 3600

    init() {}

    /// Tolerant decoding: a field added later never wipes the cache.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        termCounts = try c.decodeIfPresent([String: Int].self, forKey: .termCounts) ?? [:]
        lastSeen = try c.decodeIfPresent([String: Date].self, forKey: .lastSeen) ?? [:]
        termVerdicts = try c.decodeIfPresent([String: Bool].self, forKey: .termVerdicts) ?? [:]
        rejected = try c.decodeIfPresent(Set<String>.self, forKey: .rejected) ?? []
        snoozedUntil = try c.decodeIfPresent([String: Date].self, forKey: .snoozedUntil) ?? [:]
    }

    static func pairKey(heard: String, term: String) -> String {
        CandidateFinder.normalize(heard) + "→" + CandidateFinder.normalize(term)
    }

    /// Count sightings. Over the cap, evict judged junk first, then the
    /// least recently seen — so a full cache keeps learning new terms
    /// instead of freezing on whatever filled it first.
    mutating func addSightings(_ terms: [String], now: Date) {
        for t in terms {
            termCounts[t, default: 0] += 1
            lastSeen[t] = now
        }
        if termCounts.count > Self.maxTerms {
            let fresh = Set(terms)
            let order = termCounts.keys.sorted { a, b in
                let ja = termVerdicts[a.lowercased()] == false, jb = termVerdicts[b.lowercased()] == false
                if ja != jb { return ja }                       // junk first
                let fa = fresh.contains(a), fb = fresh.contains(b)
                if fa != fb { return !fa }                      // just-seen last
                let la = lastSeen[a] ?? .distantPast, lb = lastSeen[b] ?? .distantPast
                if la != lb { return la < lb }                  // oldest first
                return a < b
            }
            for k in order.prefix(termCounts.count - Self.maxTerms) {
                termCounts[k] = nil
                lastSeen[k] = nil
            }
        }
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        if termVerdicts.count > Self.maxVerdicts {
            let live = Set(termCounts.keys.map { $0.lowercased() })
            termVerdicts = termVerdicts.filter { live.contains($0.key) }
        }
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
