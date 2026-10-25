//
//  VocabStats.swift
//
//  Daily counters for "is name learning working for me?": names Airboard
//  fixed by itself vs names the user still had to fix by hand. Numbers
//  only — never a word of text. Local file in App Support
//  (vocab-stats.json), last 90 days. Read with scripts/vocab-stats.sh.
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

struct VocabDay: Codable, Equatable {
    var dictations = 0     // dictations with learning on
    var autoFixed = 0      // learned names Airboard wrote correctly by itself
    var handFixed = 0      // name fixes the user typed (seen by the watcher)
    var spelled = 0        // names the user spelled out loud
    var cardsKept = 0
    var cardsUndone = 0
}

final class VocabStats {
    static let shared = VocabStats()

    enum Event { case dictation, autoFixed(Int), handFixed, spelled(Int), cardKept, cardUndone }

    private let fileURL: URL
    private let keepDays = 90
    private let queue = DispatchQueue(label: "com.pype.airboard.vocabstats")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("vocab-stats.json")
        }
    }

    /// Never blocks the caller; a failed write is a dropped stat.
    func record(_ event: Event, now: Date = Date()) {
        queue.async { [self] in
            var days = load()
            let key = Self.dayKey(now)
            var d = days[key] ?? VocabDay()
            switch event {
            case .dictation: d.dictations += 1
            case .autoFixed(let n): d.autoFixed += n
            case .handFixed: d.handFixed += 1
            case .spelled(let n): d.spelled += n
            case .cardKept: d.cardsKept += 1
            case .cardUndone: d.cardsUndone += 1
            }
            days[key] = d
            for k in days.keys.sorted().dropLast(keepDays) { days[k] = nil }
            if let data = try? JSONEncoder().encode(days) { try? data.write(to: fileURL, options: .atomic) }
        }
    }

    func days() -> [String: VocabDay] { queue.sync { load() } }

    private func load() -> [String: VocabDay] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: VocabDay].self, from: data)) ?? [:]
    }

    /// Local calendar day, "2026-10-13".
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
