//
//  EditDiff.swift
//
//  Spots small word fixes the user made inside text Airboard just
//  inserted: "bright AI is hiring" -> "Brite AI is hiring" gives
//  (heard: "bright", corrected: "Brite"). Handles 2-words-to-1
//  ("a lisha" -> "Alisha"), symbol names ("AT and T" -> "AT&T"), several
//  fixes in one dictation, and the user typing on before or after our
//  text. Each fix must be a 1-3 word swap inside our insertion that sounds
//  like what was heard; rewrites, synonyms, grammar fixes and edits
//  outside our insertion teach nothing.
//  Foundation-only: compiles standalone (scripts/correction-eval).
//

import Foundation

nonisolated enum EditDiff {

    struct Correction: Equatable {
        let heard: String      // what Airboard typed
        let corrected: String  // what the user changed it to
    }

    static let maxWords = 3
    /// More sound-alike swaps than this in one insertion is a rewrite.
    static let maxCorrections = 3
    /// Alignment budget (tokens × tokens) after trimming the unchanged
    /// head and tail — a huge field edited far from us is skipped.
    static let maxAlignCells = 250_000

    /// First fix only — kept for callers that learn one lesson at a time.
    static func correction(before: String, after: String, inserted: String) -> Correction? {
        corrections(before: before, after: after, inserted: inserted).first
    }

    /// - before: the field's full text right after our insertion
    /// - after:  the field's full text now
    /// - inserted: the text we inserted (must appear in `before`)
    static func corrections(before: String, after: String, inserted: String) -> [Correction] {
        guard before != after, !inserted.isEmpty,
              let ins = before.range(of: inserted, options: .backwards) else { return [] }
        let b = tokens(before), a = tokens(after)
        // Our insertion, as before-token indices (whole tokens only).
        let insIdx = b.indices.filter { b[$0].range.lowerBound >= ins.lowerBound && b[$0].range.upperBound <= ins.upperBound }
        guard let insLo = insIdx.first, let insHi = insIdx.last,
              let (matched, hunks) = align(b.map(\.key), a.map(\.key)) else { return [] }

        var found: [Correction] = []
        var fixedTokens = 0
        for hunk in hunks where !hunk.b.isEmpty && !hunk.a.isEmpty {
            // Words only added or only removed are content edits; a change
            // reaching outside our insertion is the user's own text.
            guard hunk.b.lowerBound >= insLo, hunk.b.upperBound - 1 <= insHi else { continue }
            for part in splitAtClauses(hunk, b, a) {
                if let c = bestFix(part, b, a, atStart: part.b.lowerBound == insLo, atEnd: part.b.upperBound - 1 == insHi),
                   !found.contains(c) {
                    found.append(c)
                    fixedTokens += part.b.count
                }
            }
        }
        guard !found.isEmpty, found.count <= maxCorrections else { return [] }
        // Most of the words the user didn't fix must still be there. A
        // chat box cleared after send and new text typed keeps a "the" or
        // two by chance — not enough to trust a sound-alike in it.
        let kept = insIdx.filter { matched[$0] }.count
        guard kept * 2 >= insIdx.count - fixedTokens else { return [] }
        return found
    }

    /// Where `span` sits inside OUR insertion in the field: the last
    /// occurrence of `inserted`, then `span` as whole words within it. nil
    /// if the insertion is gone or the span only appears inside a word —
    /// so a "Did you mean" fix can never edit the user's other text
    /// ("kate" in "skate").
    static func spanRange(span: String, inserted: String, field: String) -> Range<String.Index>? {
        guard !span.isEmpty, let ins = field.range(of: inserted, options: .backwards) else { return nil }
        var searchEnd = ins.upperBound
        while let r = field.range(of: span, options: [.backwards, .caseInsensitive], range: ins.lowerBound..<searchEnd) {
            let beforeOK = r.lowerBound == field.startIndex || !isWordChar(field[field.index(before: r.lowerBound)])
            let afterOK = r.upperBound == field.endIndex || !isWordChar(field[r.upperBound])
            if beforeOK && afterOK { return r }
            searchEnd = r.lowerBound
        }
        return nil
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" }

    // MARK: - Tokens and alignment

    private struct Token {
        let raw: String
        let key: String                    // raw minus edge punctuation: "AI." matches "AI"
        let range: Range<String.Index>
        var endsClause: Bool { raw.last.map { ",;:.!?".contains($0) } ?? false }
    }

    private struct Hunk { let b: Range<Int>; let a: Range<Int> }

    private static let leadPunct = "\"“‘'([{"
    private static let trailPunct = ".,!?;:\"”’')]}…"

    private static func stripEdges(_ s: Substring) -> String {
        var t = s
        while let c = t.last, trailPunct.contains(c) { t.removeLast() }
        while let c = t.first, leadPunct.contains(c) { t.removeFirst() }
        return String(t)
    }

    /// Whitespace-separated tokens; punctuation stays attached so
    /// "AT&T", "C++", "Node.js" and "@dhruv" are one token each.
    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard !s[i].isWhitespace else { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex && !s[j].isWhitespace { j = s.index(after: j) }
            let raw = s[i..<j]
            let key = stripEdges(raw)
            out.append(Token(raw: String(raw), key: key.isEmpty ? String(raw) : key, range: i..<j))
            i = j
        }
        return out
    }

    /// Word-level LCS of before vs after (unchanged head and tail trimmed
    /// first). Returns which before-tokens survived, and the changed
    /// stretches between survivors.
    private static func align(_ b: [String], _ a: [String]) -> ([Bool], [Hunk])? {
        var p = 0
        while p < b.count && p < a.count && b[p] == a[p] { p += 1 }
        var s = 0
        while s < b.count - p && s < a.count - p && b[b.count - 1 - s] == a[a.count - 1 - s] { s += 1 }
        let n = b.count - p - s, m = a.count - p - s
        guard n * m <= maxAlignCells else { return nil }

        // lcs[i * w + j] = LCS length of b[p+i...] and a[p+j...] (middle only).
        let w = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * w + j] = b[p + i] == a[p + j] ? lcs[(i + 1) * w + j + 1] + 1
                    : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var matched = [Bool](repeating: false, count: b.count)
        for k in 0..<p { matched[k] = true }
        for k in (b.count - s)..<b.count { matched[k] = true }
        var hunks: [Hunk] = []
        var i = 0, j = 0, hb = 0, ha = 0
        func flush() {
            if hb < i || ha < j { hunks.append(Hunk(b: (p + hb)..<(p + i), a: (p + ha)..<(p + j))) }
        }
        while i < n || j < m {
            if i < n && j < m && b[p + i] == a[p + j] {
                flush()
                matched[p + i] = true
                i += 1; j += 1; hb = i; ha = j
            } else if j >= m || (i < n && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
                i += 1
            } else {
                j += 1
            }
        }
        flush()
        return (matched, hunks)
    }

    /// Two neighbouring fixes with nothing unchanged between them arrive as
    /// one stretch ("Shrea, a sheesh" -> "Shreya, Ashish"). Split it where
    /// both sides break at the same number of commas / clause marks.
    private static func splitAtClauses(_ h: Hunk, _ b: [Token], _ a: [Token]) -> [Hunk] {
        let bCuts = h.b.dropLast().filter { b[$0].endsClause }
        let aCuts = h.a.dropLast().filter { a[$0].endsClause }
        guard !bCuts.isEmpty, bCuts.count == aCuts.count else { return [h] }
        var out: [Hunk] = []
        var bs = h.b.lowerBound, aStart = h.a.lowerBound
        for (bc, ac) in zip(bCuts, aCuts) {
            out.append(Hunk(b: bs..<(bc + 1), a: aStart..<(ac + 1)))
            bs = bc + 1; aStart = ac + 1
        }
        out.append(Hunk(b: bs..<h.b.upperBound, a: aStart..<h.a.upperBound))
        return out
    }

    /// The fix in one changed stretch, if any. At the edges of our insertion
    /// the user may have typed on ("Brite AI. Let's set up a call…") or
    /// typed in front ("FYI — Brite AI"), so there the corrected words may
    /// be just the near end of the new text.
    private static func bestFix(_ h: Hunk, _ b: [Token], _ a: [Token], atStart: Bool, atEnd: Bool) -> Correction? {
        guard h.b.count <= maxWords else { return nil }
        let heard = phrase(b[h.b])
        let k = h.b.count
        let reach = min(h.a.count, maxWords)
        var windows: [Range<Int>] = [h.a]
        if atEnd && reach > 0 { windows += (1...reach).map { h.a.lowerBound..<(h.a.lowerBound + $0) } }
        if atStart && reach > 0 { windows += (1...reach).map { (h.a.upperBound - $0)..<h.a.upperBound } }
        if atStart && atEnd && h.a.count > reach {
            for len in 1...reach { for lo in h.a.lowerBound...(h.a.upperBound - len) { windows.append(lo..<(lo + len)) } }
        }
        // The whole stretch first, then windows closest in size to what was
        // heard (bigger first on a tie: "Brite AI" over "Brite").
        let ordered = windows.enumerated().sorted { x, y in
            let rx = x.offset == 0 ? -1 : abs(x.element.count - k), ry = y.offset == 0 ? -1 : abs(y.element.count - k)
            return rx != ry ? rx < ry : x.element.count > y.element.count
        }
        var tried = Set<Int>()
        for (_, win) in ordered where tried.insert(win.lowerBound * 10_000 + win.upperBound).inserted {
            // A window may not run across a sentence or clause break, nor
            // start or end on a bare "-" / "—" the user typed next to it.
            guard !win.dropLast().contains(where: { a[$0].endsClause }),
                  hasAlnum(a[win.lowerBound].raw), hasAlnum(a[win.upperBound - 1].raw) else { continue }
            let corrected = phrase(a[win])
            if isSpellingFix(heard: heard, corrected: corrected, heardWords: k, correctedWords: win.count) {
                return Correction(heard: heard, corrected: corrected)
            }
        }
        return nil
    }

    private static func hasAlnum(_ s: String) -> Bool { s.contains { $0.isLetter || $0.isNumber } }

    private static func phrase(_ toks: ArraySlice<Token>) -> String {
        stripEdges(Substring(toks.map(\.raw).joined(separator: " ")))
    }

    // MARK: - Is it a spelling fix?

    private static let allowed = CharacterSet.letters.union(.decimalDigits)
        .union(CharacterSet(charactersIn: " .'’-&+/@#_"))

    /// Everyday words. A "fix" made only of these is grammar or a rewrite
    /// ("their" -> "they're", "can't" -> "can"), never a name to learn.
    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "than", "so", "to", "too", "two", "of", "in",
        "on", "at", "by", "for", "from", "with", "about", "as", "into", "onto", "over", "under", "up",
        "down", "out", "off", "is", "am", "are", "was", "were", "be", "been", "being", "have", "has",
        "had", "do", "does", "did", "done", "can", "can't", "cannot", "could", "will", "would", "won't",
        "shall", "should", "may", "might", "must", "it", "its", "it's", "this", "that", "these", "those",
        "there", "their", "they're", "they", "them", "we", "we're", "us", "our", "you", "your", "you're",
        "he", "him", "his", "she", "her", "i", "i'm", "me", "my", "mine", "who", "whom", "whose", "who's",
        "what", "which", "where", "when", "why", "how", "not", "no", "yes", "all", "any", "some", "each",
        "every", "very", "just", "also", "only", "more", "most", "less", "much", "many", "few", "here",
        "now", "well", "good", "great", "lose", "loose", "affect", "effect", "accept", "except",
        "weather", "whether", "know", "new", "knew", "right", "write", "see", "sea", "one", "won",
        "hear", "buy", "bye", "week", "weak", "lead", "led", "past", "passed",
    ]

    private static func isSpellingFix(heard: String, corrected: String, heardWords: Int, correctedWords: Int) -> Bool {
        guard !heard.isEmpty, !corrected.isEmpty,
              heard.lowercased() != corrected.lowercased() else { return false }
        func ok(_ t: String) -> Bool {
            t.unicodeScalars.allSatisfy { allowed.contains($0) }
                && t.split(separator: " ").count <= maxWords
                && t.contains(where: { $0.isLetter })
        }
        guard ok(heard), ok(corrected) else { return false }

        // Whole words added or removed ("a very big dog" -> "a big dog")
        // is an edit of content, not a spelling fix.
        let hw = heard.lowercased().split(separator: " "), cw = corrected.lowercased().split(separator: " ")
        func contains(_ big: [Substring], _ small: [Substring]) -> Bool {
            guard small.count < big.count else { return false }
            return (0...(big.count - small.count)).contains { Array(big[$0..<($0 + small.count)]) == small }
        }
        if contains(hw, cw) || contains(cw, hw) { return false }

        // Same word, new ending: "Priya" -> "Priya's", "API" -> "APIs".
        // Grammar, not spelling.
        let hl = heard.lowercased().replacingOccurrences(of: "’", with: "'")
        let cl = corrected.lowercased().replacingOccurrences(of: "’", with: "'")
        let (short, long) = hl.count < cl.count ? (hl, cl) : (cl, hl)
        if long.hasPrefix(short), ["s", "es", "'s", "'"].contains(String(long.dropFirst(short.count))) { return false }

        // A learnable term looks like one: a capital, digit or symbol
        // ("Brite", "Web3", "user_id"), or words merged ("cube cuttle" ->
        // "kubectl"). Lowercase everyday swaps ("run" -> "runs", "send me"
        // -> "sent you") are grammar or rewording.
        let termLike = corrected.contains { $0.isUppercase || $0.isNumber || "&+#@/_.".contains($0) }
            || correctedWords < heardWords
        guard termLike else { return false }
        guard !cw.allSatisfy({ commonWords.contains(String($0).replacingOccurrences(of: "’", with: "'")) }) else { return false }

        // A real spelling fix sounds like what was heard ("bright" -> "Brite",
        // "a lisha" -> "Alisha", "C plus plus" -> "C++"). Unrelated words
        // replacing ours are not a fix.
        let hf = spokenForms(heard), cf = spokenForms(corrected)
        for h in hf {
            let hc = SoundCode.code(h)
            for c in cf {
                if SoundCode.soundsAlike(hc, SoundCode.code(c)) { return true }
                if SoundCode.editDistance(h, c) <= max(2, h.count / 3) { return true }
            }
        }
        return false
    }

    /// How a name is said: symbols dropped, or read out ("AT&T" -> "at and
    /// t", "C#" -> "c sharp", "Web3" -> "web three"). Accents folded so
    /// "José" codes like "Jose".
    private static let spoken: [Character: [String]] = [
        "&": ["and"], "+": ["plus"], "#": ["sharp", "hash"], "@": ["at"], "/": ["slash"],
        ".": ["dot"], "_": ["underscore"], "-": ["dash"],
        "0": ["zero"], "1": ["one"], "2": ["two"], "3": ["three"], "4": ["four"],
        "5": ["five"], "6": ["six"], "7": ["seven"], "8": ["eight"], "9": ["nine"],
    ]

    private static func spokenForms(_ t: String) -> [String] {
        let s = t.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var dropped = "", first = "", second = ""
        for c in s {
            if let w = spoken[c] {
                dropped += " "; first += " \(w[0]) "; second += " \(w[w.count - 1]) "
            } else {
                dropped.append(c); first.append(c); second.append(c)
            }
        }
        var out: [String] = []
        for f in [dropped, first, second] {
            let norm = f.split(separator: " ").joined(separator: " ")
            if !norm.isEmpty && !out.contains(norm) { out.append(norm) }
        }
        return out
    }
}
