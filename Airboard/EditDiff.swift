//
//  EditDiff.swift
//
//  Spots a small word fix the user made inside text Airboard just
//  inserted: "bright AI is hiring" -> "Brite AI is hiring" gives
//  (heard: "bright", corrected: "Brite"). Handles 2-words-to-1
//  ("a lisha" -> "Alisha"). Anything bigger than a 3-word swap,
//  or outside our insertion, teaches nothing.
//  Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated enum EditDiff {

    struct Correction: Equatable {
        let heard: String      // what Airboard typed
        let corrected: String  // what the user changed it to
    }

    static let maxWords = 3

    /// - before: the field's full text right after our insertion
    /// - after:  the field's full text now
    /// - inserted: the text we inserted (must appear in `before`)
    static func correction(before: String, after: String, inserted: String) -> Correction? {
        guard before != after,
              let insRange = before.range(of: inserted, options: .backwards) else { return nil }
        let b = Array(before), a = Array(after)

        // Common prefix / suffix, in characters.
        var p = 0
        while p < b.count && p < a.count && b[p] == a[p] { p += 1 }
        var s = 0
        while s < b.count - p && s < a.count - p && b[b.count - 1 - s] == a[a.count - 1 - s] { s += 1 }

        // Expand the changed region outward to whole words on both sides.
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" }
        var bStart = p, aStart = p
        while bStart > 0 && isWordChar(b[bStart - 1]) { bStart -= 1; aStart -= 1 }
        var bEnd = b.count - s, aEnd = a.count - s
        while bEnd < b.count && isWordChar(b[bEnd]) { bEnd += 1; aEnd += 1 }

        // The change must sit inside what we inserted.
        let insStart = before.distance(from: before.startIndex, to: insRange.lowerBound)
        let insEnd = before.distance(from: before.startIndex, to: insRange.upperBound)
        guard bStart >= insStart, bEnd <= insEnd, aStart <= aEnd else { return nil }

        let heard = String(b[bStart..<bEnd]).trimmingCharacters(in: .whitespaces)
        let corrected = String(a[aStart..<aEnd]).trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !corrected.isEmpty,
              heard.lowercased() != corrected.lowercased() else { return nil }

        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " .'-"))
        func ok(_ t: String) -> Bool {
            t.unicodeScalars.allSatisfy { allowed.contains($0) }
                && t.split(separator: " ").count <= maxWords
                && t.contains(where: { $0.isLetter })
        }
        guard ok(heard), ok(corrected) else { return nil }

        // Whole words added or removed ("a very big dog" -> "a big dog")
        // is an edit of content, not a spelling fix.
        let hw = heard.lowercased().split(separator: " "), cw = corrected.lowercased().split(separator: " ")
        func contains(_ big: [Substring], _ small: [Substring]) -> Bool {
            guard small.count < big.count else { return false }
            return (0...(big.count - small.count)).contains { Array(big[$0..<($0 + small.count)]) == small }
        }
        if contains(hw, cw) || contains(cw, hw) { return nil }
        return Correction(heard: heard, corrected: corrected)
    }
}
