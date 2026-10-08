//
//  MemoryStore.swift
//
//  The on-disk store for what Airboard has learned about you: a flat list
//  of plain-language "- " lines in a human-editable markdown file. Today
//  that's confirmed spellings — lines in the exact SpellingRule shape
//  ("X" is the correct spelling — often heard as "Y".), applied by
//  VocabularyLearning when a decision model agrees in context (or as an
//  exact multi-word match when it can't be reached). Lines from the
//  retired Memory feature (voice facts, removed 2026-10-07) are kept
//  untouched and ignored.
//
//  File: ~/Library/Application Support/<bundle id>/memory.md
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation
import Combine

final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// The memories, verbatim — displayed and stored exactly as written.
    @Published private(set) var memories: [String] = []

    private let fileURL: URL

    /// Pass a custom URL in tests; nil = the real per-bundle location.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.memories = Self.load(from: url)
    }

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.md")
    }

    // MARK: - Mutations (main thread; UI observes)

    /// Add a memory line. Exact-duplicate lines (case-insensitive) are
    /// dropped silently. Interior newlines collapse to spaces — a memory
    /// is ONE line; a multi-line value would silently lose its tail on
    /// the next load (parse only reads "- "-prefixed lines).
    func addMemory(_ line: String) {
        let trimmed = line
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !memories.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        memories.append(trimmed)
        save()
    }

    func removeMemory(at index: Int) {
        guard memories.indices.contains(index) else { return }
        memories.remove(at: index)
        save()
    }

    // MARK: - Markdown persistence (the file IS the memory, as-is)

    private static func load(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(markdown: text)
    }

    private func save() {
        do {
            try Self.markdown(from: memories).write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ memory.md save failed: \(error.localizedDescription)")
        }
    }

    static func markdown(from memories: [String]) -> String {
        var lines = [
            "# Airboard Memory",
            "",
            "One memory per \"- \" line. Airboard reads this file as-is — edit freely.",
            "",
        ]
        lines += memories.map { "- \($0)" }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Every `- ` line anywhere in the file is a memory, verbatim. Headers
    /// and prose are ignored — a hand-edited (or legacy sectioned) file can
    /// never wipe memory. A legacy Settings share line migrates itself to
    /// UserDefaults instead of becoming a memory.
    static func parse(markdown text: String) -> [String] {
        var out: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let lower = item.lowercased()
            // A legacy settings line (AI Cleanup sharing, retired) is not
            // a memory.
            if lower.hasPrefix("share memory with ai cleanup:") { continue }
            if !out.contains(where: { $0.lowercased() == item.lowercased() }) {
                out.append(item)
            }
        }
        return out
    }
}
