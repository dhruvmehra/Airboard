//
//  EditDiffBaseline.swift
//
//  Frozen copy of EditDiff v1 (one common-prefix/suffix changed region,
//  commit 2ecd24a) — the baseline the correction eval compares against.
//  Eval-only; not part of the app target.
//

import Foundation

nonisolated enum EditDiffBaseline {

    static let maxWords = 3

    static func correction(before: String, after: String, inserted: String) -> EditDiff.Correction? {
        guard before != after,
              let insRange = before.range(of: inserted, options: .backwards) else { return nil }
        let b = Array(before), a = Array(after)

        var p = 0
        while p < b.count && p < a.count && b[p] == a[p] { p += 1 }
        var s = 0
        while s < b.count - p && s < a.count - p && b[b.count - 1 - s] == a[a.count - 1 - s] { s += 1 }

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" }
        var bStart = p, aStart = p
        while bStart > 0 && isWordChar(b[bStart - 1]) { bStart -= 1; aStart -= 1 }
        var bEnd = b.count - s, aEnd = a.count - s
        while bEnd < b.count && isWordChar(b[bEnd]) { bEnd += 1; aEnd += 1 }

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

        let hw = heard.lowercased().split(separator: " "), cw = corrected.lowercased().split(separator: " ")
        func contains(_ big: [Substring], _ small: [Substring]) -> Bool {
            guard small.count < big.count else { return false }
            return (0...(big.count - small.count)).contains { Array(big[$0..<($0 + small.count)]) == small }
        }
        if contains(hw, cw) || contains(cw, hw) { return nil }

        let soundsSame = SoundCode.soundsAlike(SoundCode.code(heard), SoundCode.code(corrected))
        let spellingClose = SoundCode.editDistance(heard.lowercased(), corrected.lowercased())
            <= max(2, heard.count / 3)
        guard soundsSame || spellingClose else { return nil }
        return EditDiff.Correction(heard: heard, corrected: corrected)
    }
}
