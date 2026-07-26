//
//  PerformanceLog.swift
//
//  Local, persistent per-dictation timing log (JSON Lines). Powers the
//  Performance window's "Recent dictations" list. LOCAL ONLY — the
//  preview text never leaves this Mac; telemetry sends numbers only.
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

struct DictationRecord: Codable {
    var ts: Date
    var mode: String          // dictation | command | handsfree
    var audioSeconds: Double
    var sttMs: Int
    var llmMs: Int?           // nil when the LLM didn't run
    var llmOutcome: String    // ok | timeout | error | guarded | skipped | off
    var words: Int
    var preview: String       // first 40 chars of the final text
}

final class PerformanceLog {
    static let shared = PerformanceLog()

    private let fileURL: URL
    private let maxLines = 1000
    private let queue = DispatchQueue(label: "com.pype.airboard.perflog")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("performance.jsonl")
        }
    }

    /// Append one record. Never blocks the caller; never throws — a
    /// failed write is a silently dropped stat, not a problem.
    func append(_ record: DictationRecord) {
        queue.async { [fileURL, maxLines] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8) else { return }

            var lines = (try? String(contentsOf: fileURL, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Newest-first. Malformed lines are skipped, never fatal.
    func recent(_ count: Int) -> [DictationRecord] {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n")
                .reversed()
                .prefix(count * 2)  // headroom for malformed lines
                .compactMap { line in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(DictationRecord.self, from: data)
                }
                .prefix(count)
                .map { $0 }
        }
    }
}
