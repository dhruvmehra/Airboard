//
//  VocabularyCache.swift
//
//  Persists VocabularyCacheData as JSON in App Support
//  (vocabulary-cache.json). Hidden learning state only — clearing it just
//  resets suggestions; confirmed rules live in memory.md.
//

import Foundation

final class VocabularyCache {
    static let shared = VocabularyCache()

    private(set) var data: VocabularyCacheData
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(VocabularyCacheData.self, from: raw) {
            data = decoded
        } else {
            data = VocabularyCacheData()
        }
    }

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary-cache.json")
    }

    func update(_ change: (inout VocabularyCacheData) -> Void) {
        change(&data)
        do {
            try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ vocabulary cache save failed: \(error.localizedDescription)")
        }
    }
}
