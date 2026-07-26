//
//  EditCommands.swift
//
//  Voice text-editing intents for command mode: "delete all", "delete
//  last two words", "delete last sentence", "scratch that". Parsing and
//  sentence math are pure; execution lives in TextInserter (it owns the
//  keystroke machinery).
//
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

enum EditIntent: Equatable {
    case deleteAll
    case deleteWords(Int)
    case deleteSentences(Int)
    case deleteLastInsertion   // "scratch that" — erase what Airboard just typed
}

enum EditCommands {

    private static let numberWords: [String: Int] = [
        "one": 1, "a": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    /// Exact-pattern detection (no LLM): nil = not an edit command.
    static func detect(_ raw: String) -> EditIntent? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = text.last, ".?!,".contains(last) { text.removeLast() }

        switch text {
        case "delete all", "delete everything", "clear all", "clear everything":
            return .deleteAll
        case "delete that", "scratch that", "delete last dictation", "undo that":
            return .deleteLastInsertion
        default:
            break
        }

        // "delete [the] last [N] word(s)/sentence(s)"
        var tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 2, tokens[0] == "delete" || tokens[0] == "remove" else { return nil }
        tokens.removeFirst()
        if tokens.first == "the" { tokens.removeFirst() }
        guard tokens.first == "last" else { return nil }
        tokens.removeFirst()

        var count = 1
        if let first = tokens.first {
            if let n = Int(first) { count = n; tokens.removeFirst() }
            else if let n = numberWords[first] { count = n; tokens.removeFirst() }
        }
        guard count >= 1, count <= 50, let unit = tokens.first, tokens.count == 1 else { return nil }

        switch unit {
        case "word", "words":
            return .deleteWords(count)
        case "sentence", "sentences", "line", "lines":
            return .deleteSentences(count)
        default:
            return nil
        }
    }

    /// How many characters to erase to remove the last `count` sentences
    /// from `textBeforeCursor`. A sentence boundary is a terminator
    /// (. ! ? …) followed by whitespace or end. Fewer boundaries than
    /// requested = erase everything before the cursor. Capped for safety.
    static func sentenceDeletionLength(textBeforeCursor: String, count: Int, cap: Int = 2000) -> Int {
        let chars = Array(textBeforeCursor)
        guard !chars.isEmpty else { return 0 }

        // Ignore trailing whitespace — the cursor often sits after a space.
        var end = chars.count
        while end > 0, chars[end - 1].isWhitespace { end -= 1 }
        guard end > 0 else { return chars.count }

        let terminators: Set<Character> = [".", "!", "?", "…"]
        var boundariesFound = 0
        var deleteFrom = 0  // default: delete everything before the cursor

        var i = end - 1
        // Skip the terminator of the current/last sentence itself.
        if terminators.contains(chars[i]) { i -= 1 }
        while i > 0 {
            if terminators.contains(chars[i]),
               i + 1 < chars.count, chars[i + 1].isWhitespace {
                boundariesFound += 1
                if boundariesFound == count {
                    // Delete from just after this terminator's whitespace run.
                    var start = i + 1
                    while start < chars.count, chars[start].isWhitespace { start += 1 }
                    deleteFrom = start
                    break
                }
            }
            i -= 1
        }

        return min(chars.count - deleteFrom, cap)
    }
}
