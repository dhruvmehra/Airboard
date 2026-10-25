//
//  VocabularyCardQueue.swift
//
//  Which confirm card to show next: one at a time, never while
//  recording, at most 4 per rolling hour, no duplicate pairs queued.
//  Pure: the caller supplies the clock. Foundation-only.
//

import Foundation

nonisolated struct VocabularyCard: Equatable {
    enum Kind: Equatable { case learned, didYouMean }
    let kind: Kind
    let heard: String     // "bright AI"
    let term: String      // "Brite AI"
}

nonisolated struct VocabularyCardQueue {
    static let maxPerHour = 4
    private(set) var pending: [VocabularyCard] = []
    private(set) var shownAt: [Date] = []
    private(set) var showing: VocabularyCard?

    mutating func enqueue(_ card: VocabularyCard) {
        let key = VocabularyCacheData.pairKey(heard: card.heard, term: card.term)
        let dup = (pending + (showing.map { [$0] } ?? []))
            .contains { VocabularyCacheData.pairKey(heard: $0.heard, term: $0.term) == key }
        if !dup { pending.append(card) }
    }

    /// The card to present now, or nil. Marks it as showing.
    mutating func next(now: Date, isRecording: Bool) -> VocabularyCard? {
        guard showing == nil, !isRecording, !pending.isEmpty else { return nil }
        shownAt = shownAt.filter { now.timeIntervalSince($0) < 3600 }
        guard shownAt.count < Self.maxPerHour else { return nil }
        let card = pending.removeFirst()
        shownAt.append(now)
        showing = card
        return card
    }

    mutating func dismissed() { showing = nil }
}
