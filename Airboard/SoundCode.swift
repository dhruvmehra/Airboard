//
//  SoundCode.swift
//
//  "How it sounds" codes for candidate finding (original Metaphone,
//  Lawrence Philips 1990). Two spellings with the same code probably
//  sound alike: "bright AI" = "Brite AI" = BRT, "for sell" = "Vercel" = FRSL.
//  A matching code makes a CANDIDATE; whether it is replaced is
//  VocabularyResolver's call (locally for a confirmed rule heard as a
//  non-dictionary word, else the decision engine or a strong local
//  signal). Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated enum SoundCode {

    /// Code for a word or phrase. Spaces and non-letters are dropped first,
    /// so "a lisha" encodes the same as "Alisha".
    static func code(_ text: String) -> String {
        let letters = Array(text.lowercased().unicodeScalars
            .filter { $0.value >= 97 && $0.value <= 122 }
            .map { Character($0) })
        guard !letters.isEmpty else { return "" }

        var s = letters
        // Silent first letters.
        if s.count >= 2 {
            let pair = String(s[0...1])
            if ["kn", "gn", "pn", "wr", "ae"].contains(pair) { s.removeFirst() }
        }
        if s.first == "x" { s[0] = "s" }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        func at(_ i: Int) -> Character? { i >= 0 && i < s.count ? s[i] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { vowels.contains($0) } ?? false }

        var out = ""
        var i = 0
        while i < s.count {
            let c = s[i]
            let next = at(i + 1)
            let next2 = at(i + 2)

            // Doubled letters sound once (except "cc": "accept" = AKSPT).
            if c == at(i - 1) && c != "c" { i += 1; continue }

            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { out.append("A") }  // only a leading vowel counts
            case "b":
                // Silent in a trailing "mb" ("thumb").
                if !(at(i - 1) == "m" && next == nil) { out.append("B") }
            case "c":
                if at(i - 1) == "s" && next == "h" { out.append("K"); i += 1 }  // "school"
                else if next == "i" && next2 == "a" { out.append("X") }
                else if next == "h" { out.append("X"); i += 1 }
                else if next == "i" || next == "e" || next == "y" { out.append("S") }
                else { out.append("K") }
            case "d":
                if next == "g", let n2 = next2, "eiy".contains(n2) { out.append("J"); i += 1 }
                else { out.append("T") }
            case "g":
                if next == "h" && !isVowel(next2) && next2 != nil { i += 1 }        // "night"
                else if next == "n" && (next2 == nil || (next2 == "e" && at(i + 3) == "d")) { } // "sign", "signed"
                else if let n = next, "eiy".contains(n) { out.append("J") }
                else { out.append("K") }
            case "h":
                // Sounded only before a vowel and not after one.
                if isVowel(next) && !isVowel(at(i - 1)) { out.append("H") }
            case "k":
                if at(i - 1) != "c" { out.append("K") }
            case "p":
                if next == "h" { out.append("F"); i += 1 } else { out.append("P") }
            case "q":
                out.append("K")
            case "s":
                if next == "h" { out.append("X"); i += 1 }
                else if next == "i", let n2 = next2, "oa".contains(n2) { out.append("X") }
                else { out.append("S") }
            case "t":
                if next == "i", let n2 = next2, "oa".contains(n2) { out.append("X") }
                else if next == "h" { out.append("0"); i += 1 }
                else if !(next == "c" && next2 == "h") { out.append("T") }
            case "v":
                out.append("F")
            case "w", "y":
                if isVowel(next) { out.append(c == "w" ? "W" : "Y") }
            case "x":
                out.append("KS")
            case "z":
                out.append("S")
            default:  // f j l m n r
                out.append(Character(c.uppercased()))
            }
            i += 1
        }
        return out
    }

    /// The same sound: identical codes, or identical once half-vowels
    /// (Y/W/H) are ignored with 3+ sounds left. Half-vowels drift with how
    /// a word is split: "Bright Eye" = BRTY (the y of "eye" is consonantal)
    /// but "Brite AI" = BRT (all-vowel words add nothing) — field bug
    /// 2026-10-07. Short codes stay exact ("Pype" PP, "Mehra" MR).
    static func sameSound(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // Allocation only when a half-vowel is present — this runs for
        // every window × term in the candidate scan.
        let half: (Character) -> Bool = { $0 == "Y" || $0 == "W" || $0 == "H" }
        guard a.contains(where: half) || b.contains(where: half) else { return false }
        let sa = a.filter { !half($0) }, sb = b.filter { !half($0) }
        return sa.count >= 3 && sa == sb
    }

    /// The same sound, or — for codes of 4+ sounds — one sound apart
    /// ("super base" SPRBS ~ "Supabase" SPBS). Short codes must match
    /// exactly: one edit on "PP" would match nearly anything.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        if sameSound(a, b) { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let la = a.count, lb = b.count
        // One edit apart needs lengths within 1 — skip the DP otherwise
        // (the candidate scan calls this for every window × every term).
        guard min(la, lb) >= 4, abs(la - lb) <= 1 else { return false }
        return withinOneEdit(a, b)
    }

    /// editDistance(a, b) <= 1, without the DP or allocation (codes are
    /// ASCII; the candidate scan calls this for many window × term pairs).
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = a.utf8, y = b.utf8
        let (s, l) = x.count <= y.count ? (x, y) : (y, x)
        guard l.count - s.count <= 1 else { return false }
        var i = s.startIndex, j = l.startIndex, edits = 0
        while i < s.endIndex && j < l.endIndex {
            if s[i] == l[j] { i = s.index(after: i); j = l.index(after: j); continue }
            edits += 1
            if edits > 1 { return false }
            if s.count == l.count { i = s.index(after: i) }  // substitution
            j = l.index(after: j)                            // (or insertion in the longer)
        }
        return edits + l.distance(from: j, to: l.endIndex) + s.distance(from: i, to: s.endIndex) <= 1
    }

    /// The code with half-vowels (Y/W/H) removed — sameSound's key.
    static func withoutHalfVowels(_ code: String) -> String {
        code.contains(where: { $0 == "Y" || $0 == "W" || $0 == "H" })
            ? code.filter { $0 != "Y" && $0 != "W" && $0 != "H" } : code
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        // Two reused rows (hot: the candidate scan and learning gates).
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
