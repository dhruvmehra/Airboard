//
//  RedictationLearner.swift
//
//  Learns name spellings from Airboard's OWN transcripts — no field
//  reading — so it also works in terminals, Electron apps, Google Docs,
//  and when the user sends before fixing. Three signals:
//  - spelled:     "Tell Inakshi, I N A K S H I, that…" (one dictation) or
//                 "that's spelled B R I T E" right after "bright AI is…"
//  - followUp:    "sorry, Vercel, not for sell" / "I meant Brite AI" / "*Brite"
//  - redictation: "talk to Anakshi tomorrow" → scratch that →
//                 "talk to Inakshi tomorrow"
//  Only `spelled` is ground truth: the user said the letters. followUp and
//  redictation compare ASR output with ASR output — the "corrected" side
//  is the recognizer's second guess (probe 2026-10-12: "Sorry, Vercel, not
//  for sell" came back "Sorry, versile, not for sell"), so they only
//  nominate a pair for the decision model; strength stays below
//  `directCardStrength`.
//
//  How Parakeet writes spelled letters (probe 2026-10-12, TDT 0.6B v3,
//  macOS TTS, 46 utterances): spaced "S H R E Y A"; hyphenated
//  "Z-E-N-T-R-I-X"; merged caps "DHRUV", "ASHISH"; partly merged
//  "I Nak S H I"; truncated "B-R-I-T-" (trailing hyphen = cut off). Spoken
//  acronyms come back merged ("API", "USA", "SDK") — so a merged caps word
//  counts as a spelling only right after a sound-alike word.
//
//  Pure, Foundation-only: compiles standalone for the offline eval.
//

import Foundation

/// One dictation Airboard inserted. In memory only — never written to disk.
nonisolated struct TranscriptTurn: Equatable {
    let text: String
    let at: Date
    let pid: Int32
    var scratched = false   // the user erased it by voice ("scratch that", "delete …") right after
}

nonisolated struct LearnedPair: Equatable {
    enum Kind: String, CaseIterable { case spelled, followUp, redictation }
    let heard: String       // as Airboard wrote it, e.g. "Anakshi"
    let corrected: String   // e.g. "Inakshi"
    let kind: Kind
    let strength: Double    // 0…1; ≥ directCardStrength = no decision model needed
    let sentence: String    // the sentence holding `heard` (decision-model context)
}

nonisolated enum RedictationLearner {

    /// Spelled-out letters are ground truth → straight to a Keep/Undo card.
    static let directCardStrength = 0.9
    /// Cross-turn signals only count within this window, in the same app.
    static let window: TimeInterval = 90
    static let minLetters = 3
    static let maxWords = 3

    // MARK: - Spelled letters inside one dictation

    /// "Tell Anakshi, I Nak S H I, that the meeting moved."
    ///   → text "Tell Inakshi that the meeting moved.", pair Anakshi → Inakshi.
    /// When the letters already match the word ("Shreya, S H R E Y A") the
    /// letters are dropped and no pair is learned. Letters with no target in
    /// this dictation ("That's spelled B R I T E") are left alone — detect()
    /// matches them against the previous dictation.
    static func spelledRewrite(_ text: String) -> (text: String, pairs: [LearnedPair]) {
        let toks = tokens(text)
        var edits: [(range: Range<String.Index>, with: String)] = []
        var pairs: [LearnedPair] = []
        for run in runs(toks, in: text).reversed() {
            guard let hit = inlineTarget(for: run, toks: toks, text: text) else { continue }
            // Never overlap an edit already planned (runs are right-to-left).
            if let last = edits.last, hit.deleteRange.upperBound > last.range.lowerBound { continue }
            edits.append((hit.deleteRange, ""))
            edits.append((hit.spanRange, hit.replacement))
            if let pair = hit.pair { pairs.append(pair) }
        }
        guard !edits.isEmpty else { return (text, []) }
        // Rebuild left-to-right from the original — edits never overlap.
        var out = ""
        var cursor = text.startIndex
        for e in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            out += text[cursor..<e.range.lowerBound]
            out += e.with
            cursor = e.range.upperBound
        }
        out += text[cursor...]
        return (out, pairs.reversed())
    }

    // MARK: - Across dictations

    /// Pairs taught by `current` about the dictation just before it (same
    /// app, within `window`). At most one: spelled > followUp > redictation.
    static func detect(current: TranscriptTurn, previous: [TranscriptTurn]) -> [LearnedPair] {
        guard let prev = previous.last, prev.pid == current.pid,
              current.at.timeIntervalSince(prev.at) >= 0,
              current.at.timeIntervalSince(prev.at) <= window else { return [] }
        if let p = spelledFollowUp(current.text, previous: prev.text) { return [p] }
        if let p = followUp(current.text, previous: prev.text) { return [p] }
        if let p = redictation(prev, current) { return [p] }
        return []
    }

    // MARK: - Tokens

    struct Token {
        let range: Range<String.Index>
        let text: String
        var lower: String { text.lowercased() }
        var isLetter: Bool { text.count == 1 && text.first!.isLetter }
        var isCaps: Bool {
            text.count >= 2 && text.allSatisfy { $0.isLetter && $0.isUppercase }
        }
        var hasDigit: Bool { text.contains(where: { $0.isNumber }) }
    }

    /// Words: letters/digits with inner apostrophes ("that's").
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            let inner = (c == "'" || c == "\u{2019}") && start != nil
                && next < text.endIndex && text[next].isLetter
            if c.isLetter || c.isNumber || inner {
                if start == nil { start = i }
            } else if let s = start {
                out.append(Token(range: s..<i, text: String(text[s..<i]))); start = nil
            }
            i = next
        }
        if let s = start { out.append(Token(range: s..<text.endIndex, text: String(text[s...]))) }
        return out
    }

    /// Text between token i-1 and token i (before the first token for i = 0).
    static func gap(_ toks: [Token], _ i: Int, in text: String) -> Substring {
        let lo = i == 0 ? text.startIndex : toks[i - 1].range.upperBound
        let hi = i < toks.count ? toks[i].range.lowerBound : text.endIndex
        return text[lo..<hi]
    }

    // MARK: - Letter runs

    struct Run {
        let first: Int, last: Int   // token indices
        let letters: String         // lowercased
        let merged: Bool            // one caps word ("DHRUV") — acronym-shaped
    }

    /// Spelled-letter runs. Spaced/hyphenated: 2+ single letters, interior
    /// short chunks ("I Nak S H I") and caps pieces allowed. Merged: a lone
    /// caps word of 3+ letters. A run ending in a dangling hyphen
    /// ("B-R-I-T-") was cut off and is dropped.
    static func runs(_ toks: [Token], in text: String) -> [Run] {
        var out: [Run] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            guard !t.hasDigit, t.isLetter || t.isCaps else { i += 1; continue }
            var j = i
            var members = [i]
            while j + 1 < toks.count {
                let sep = gap(toks, j + 1, in: text).trimmingCharacters(in: .whitespaces)
                guard sep.isEmpty || sep == "-" || sep == "," else { break }
                let n = toks[j + 1]
                if n.hasDigit { break }
                // A comma joins single letters only ("I, N, A"), never a
                // trailing caps word ("S H R E Y A, CEO of …").
                if sep == "," && !(n.isLetter && toks[j].isLetter) { break }
                if n.isLetter || n.isCaps {
                    members.append(j + 1); j += 1; continue
                }
                // A short chunk ("Nak") only between letters, never across a comma.
                if n.text.count <= 3, n.text.allSatisfy({ $0.isLetter }), j + 2 < toks.count {
                    let sep2 = gap(toks, j + 2, in: text).trimmingCharacters(in: .whitespaces)
                    let n2 = toks[j + 2]
                    if (sep2.isEmpty || sep2 == "-"), n2.isLetter || n2.isCaps, !n2.hasDigit {
                        members.append(j + 1); j += 1; continue
                    }
                }
                break
            }
            let singles = members.filter { toks[$0].isLetter }.count
            let letters = members.map { toks[$0].lower }.joined()
            let after = text[toks[members.last!].range.upperBound...]
            let truncated = after.hasPrefix("-")
            if !truncated, letters.count >= minLetters {
                if singles >= 2 {
                    out.append(Run(first: members.first!, last: members.last!, letters: letters, merged: false))
                } else if members.count == 1, toks[i].isCaps {
                    out.append(Run(first: i, last: i, letters: letters, merged: true))
                }
            }
            i = members.last! + 1
        }
        return out
    }

    // MARK: - Matching

    static func lettersOnly(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter })
    }

    /// Distance between spelled letters and a heard span, if the span is
    /// plausibly what was spelled. nil = not a match.
    static func spellingDistance(letters: String, span: String, loose: Bool) -> Int? {
        let s = lettersOnly(span)
        guard !s.isEmpty else { return nil }
        if s == letters { return 0 }
        let d = SoundCode.editDistance(s, letters)
        let cs = SoundCode.code(span), cl = SoundCode.code(letters)
        if SoundCode.soundsAlike(cs, cl), d <= max(3, letters.count / 2) { return d }
        // Same 3+-sound code, spelled very differently: "for sell" = "vercel" (FRSL).
        if cs == cl, cs.count >= 3, d <= letters.count * 2 / 3 { return d }
        if d <= max(1, letters.count / 3), s.first == letters.first { return d }
        if loose, s.first == letters.first, cs.count >= 2, cl.count >= 2,
           cs.hasPrefix(cl) || cl.hasPrefix(cs) || d <= letters.count / 2 { return d }
        return nil
    }

    static let inlineCues: Set<String> = [
        "that's", "thats", "that is", "it's", "its", "it is", "spelled", "spelt",
        "that's spelled", "thats spelled", "that spelled", "that is spelled",
        "it's spelled", "its spelled", "it is spelled", "spelled as", "spelt as",
        "the spelling is", "spelling is", "spelling", "that's spelt", "it's spelt",
    ]

    struct InlineHit {
        let spanRange: Range<String.Index>
        let replacement: String
        let deleteRange: Range<String.Index>
        let pair: LearnedPair?
    }

    private static func normalizedCue(_ toks: [Token], _ lo: Int, _ hi: Int) -> String {
        guard lo < hi else { return "" }
        return toks[lo..<hi].map { $0.lower.replacingOccurrences(of: "\u{2019}", with: "'") }.joined(separator: " ")
    }

    /// The span a run spells, inside the same dictation. Adjacent ("Name,
    /// L E T T E R S" / "Name, that's L E T T E R S") or, with an explicit
    /// cue, anywhere earlier in the dictation.
    static func inlineTarget(for run: Run, toks: [Token], text: String) -> InlineHit? {
        guard run.first > 0 else { return nil }
        // Cue words right before the run (up to 3 tokens).
        var cueStart = run.first
        for k in stride(from: min(3, run.first), through: 1, by: -1) {
            if inlineCues.contains(normalizedCue(toks, run.first - k, run.first)) { cueStart = run.first - k; break }
        }
        let hasCue = cueStart < run.first
        guard cueStart > 0 else { return nil }
        let gapBefore = gap(toks, cueStart, in: text)
        let punct = gapBefore.contains(",") || gapBefore.contains(".") || gapBefore.contains(":")
        // Merged caps ("DHRUV") look like acronyms — need a comma or cue.
        // Spaced letters may follow the word directly ("Dhruv D H R U V").
        if run.merged && !punct && !hasCue { return nil }
        if gapBefore.contains("!") || gapBefore.contains("?") { return nil }

        // Adjacent windows: 1…3 words ending right before the cue/run.
        var best: (lo: Int, d: Int)?
        let end = cueStart   // exclusive
        for w in 1...maxWords where end - w >= 0 {
            let lo = end - w
            // Don't let a window cross a sentence end or a comma.
            if w > 1, (lo + 1..<end).contains(where: { gap(toks, $0, in: text).contains(where: { ",.!?;:".contains($0) }) }) { break }
            let span = String(text[toks[lo].range.lowerBound..<toks[end - 1].range.upperBound])
            if toks[lo..<end].contains(where: { $0.hasDigit }) { continue }
            if let d = spellingDistance(letters: run.letters, span: span, loose: punct || hasCue),
               best == nil || d < best!.d {
                best = (lo, d)
            }
        }
        var spanLo = best?.lo, spanHi = end
        var adjacentFallback = false
        if spanLo == nil, !run.merged, punct || hasCue {
            // "Tell Chavon, S-I-O-B-H-A-N" — clearly spelled letters right
            // after a word the recognizer capitalized as a name.
            let w = toks[end - 1]
            let sentenceStart = end - 1 == 0
                || gap(toks, end - 1, in: text).contains(where: { ".!?".contains($0) })
            if run.letters.count >= 4, !w.hasDigit, w.text.first!.isUppercase, !sentenceStart,
               w.text.count >= 3, !w.isCaps {
                spanLo = end - 1; adjacentFallback = true
            }
        }
        if spanLo == nil, hasCue {
            // "Tell bright about it, that's spelled B R I T E": nearest
            // sound-alike window earlier in the dictation.
            var far: (lo: Int, hi: Int, d: Int)?
            for hi in stride(from: end, through: 1, by: -1) {
                for w in 1...maxWords where hi - w >= 0 {
                    let lo = hi - w
                    let span = String(text[toks[lo].range.lowerBound..<toks[hi - 1].range.upperBound])
                    if let d = spellingDistance(letters: run.letters, span: span, loose: false),
                       far == nil || d < far!.d { far = (lo, hi, d) }
                }
                if far != nil { break }
            }
            if let far { spanLo = far.lo; spanHi = far.hi }
        }
        guard let lo = spanLo else { return nil }

        let spanRange = toks[lo].range.lowerBound..<toks[spanHi - 1].range.upperBound
        let span = String(text[spanRange])
        let corrected = spelledForm(letters: run.letters, heard: span)

        // Delete from the end of the word before the cue/run through the run,
        // plus the comma closing a ", L E T T E R S," aside.
        let delLo = toks[cueStart - 1].range.upperBound
        var delHi = toks[run.last].range.upperBound
        let rest = text[delHi...]
        if gapBefore.contains(","), rest.hasPrefix(",") { delHi = text.index(after: delHi) }
        // ". I N A K S H I." — keep exactly one terminator.
        let deleteRange = delLo..<delHi

        let sameLetters = lettersOnly(span) == run.letters
        let sameSplit = CandidateFinder.normalize(span) == CandidateFinder.normalize(corrected)
        let replacement = sameLetters && sameSplit ? span : corrected
        var pair: LearnedPair?
        if !sameSplit {
            let sentence = CandidateFinder.sentence(containing: spanRange, in: text)
            pair = LearnedPair(heard: span, corrected: corrected, kind: .spelled,
                               strength: adjacentFallback ? directCardStrength : 0.95, sentence: sentence)
        }
        return InlineHit(spanRange: spanRange, replacement: replacement, deleteRange: deleteRange, pair: pair)
    }

    /// "brite" for heard "bright AI" → "Brite AI": a trailing acronym the
    /// letters don't cover (or also end with) is kept as written; otherwise
    /// the letters are the whole word ("in akshi" → "Inakshi",
    /// "super base" → "Supabase").
    static func spelledForm(letters: String, heard: String) -> String {
        let words = heard.split(separator: " ").map(String.init)
        let acronym: (String) -> Bool = { w in w.count >= 2 && w.allSatisfy { $0.isLetter && $0.isUppercase } }
        if words.count > 1, acronym(words.last!) {
            for k in stride(from: words.count - 1, through: 1, by: -1) where words.suffix(k).allSatisfy(acronym) {
                let tail = words.suffix(k)
                let tl = lettersOnly(tail.joined())
                if letters.hasSuffix(tl), letters.count > tl.count {
                    let head = String(letters.dropLast(tl.count))
                    return ([capitalized(head)] + tail).joined(separator: " ")
                }
            }
            // Letters spell only the head ("bright AI" + "B R I T E").
            let head = words.prefix(words.count - 1)
            if lettersOnly(head.joined()) != "",
               spellingDistance(letters: letters, span: head.joined(separator: " "), loose: false) != nil,
               !letters.hasSuffix(lettersOnly(words.last!)) {
                return ([capitalized(letters)] + [words.last!]).joined(separator: " ")
            }
        }
        return capitalized(letters)
    }

    static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst().lowercased()
    }

    // MARK: - Spelled follow-up ("That's spelled B R I T E")

    static let followUpFiller: Set<String> = [
        "i", "meant", "mean", "sorry", "no", "oops", "correction", "the", "name", "is",
        "it's", "its", "that's", "thats", "that", "it", "spelled", "spelt", "spelling",
        "as", "actually", "with", "a", "an",
    ]

    static func spelledFollowUp(_ text: String, previous: String) -> LearnedPair? {
        let toks = tokens(text)
        let rs = runs(toks, in: text)
        guard rs.count == 1, let run = rs.first else { return nil }
        let others = toks.indices.filter { $0 < run.first || $0 > run.last }
        guard others.count <= 5,
              others.allSatisfy({ followUpFiller.contains(toks[$0].lower.replacingOccurrences(of: "\u{2019}", with: "'")) })
        else { return nil }
        // A lone caps word ("USA.") is an acronym, not a spelling — unless cued.
        if run.merged && !others.contains(where: { ["spelled", "spelt", "spelling"].contains(toks[$0].lower) }) { return nil }
        guard let hit = bestWindow(in: previous, matching: { spellingDistance(letters: run.letters, span: $0, loose: false) })
        else { return nil }
        let corrected = spelledForm(letters: run.letters, heard: hit.span)
        guard CandidateFinder.normalize(hit.span) != CandidateFinder.normalize(corrected) else { return nil }
        return LearnedPair(heard: hit.span, corrected: corrected, kind: .spelled, strength: 0.9,
                           sentence: CandidateFinder.sentence(containing: hit.range, in: previous))
    }

    /// Best 1…3-word window in `text` by the scorer (lowest distance; ties →
    /// latest, then shortest).
    static func bestWindow(in text: String, matching score: (String) -> Int?) -> (span: String, range: Range<String.Index>, d: Int)? {
        let toks = tokens(text)
        var best: (String, Range<String.Index>, Int)?
        for lo in toks.indices {
            for w in 1...maxWords where lo + w <= toks.count {
                let hi = lo + w
                if (lo + 1..<hi).contains(where: { gap(toks, $0, in: text).contains(where: { ",.!?;:".contains($0) }) }) { break }
                if toks[lo..<hi].contains(where: { $0.hasDigit }) { continue }
                let r = toks[lo].range.lowerBound..<toks[hi - 1].range.upperBound
                let span = String(text[r])
                guard let d = score(span) else { continue }
                if best == nil || d <= best!.2 { best = (span, r, d) }
            }
        }
        return best.map { (span: $0.0, range: $0.1, d: $0.2) }
    }

    // MARK: - Follow-up correction ("sorry, Vercel, not for sell")

    private static let lead = #"(?:(?:sorry|oops|no|correction|actually)[,:]?\s+)?"#
    private static let patterns: [(String, x: Int, y: Int, strength: Double)] = [
        (#"^\*\s*([^*]+?)\s*\*?$"#, 1, 0, 0.8),
        (#"^"# + lead + #"(?:i meant to say|i meant|i mean|meant)\s+(.+?)(?:,?\s+not\s+(.+))?$"#, 1, 2, 0.55),
        (#"^"# + lead + #"not\s+(.+?),\s*(?:it's\s+|it is\s+)?(.+)$"#, 2, 1, 0.7),
        (#"^"# + lead + #"(?:it's\s+|it is\s+|that's\s+|that should be\s+)?(.+?),?\s+not\s+(.+)$"#, 1, 2, 0.7),
        (#"^(?:sorry|oops|correction)[,:]?\s+(.+)$"#, 1, 0, 0.45),
    ]

    static func followUp(_ text: String, previous: String) -> LearnedPair? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let l = t.last, ".!?".contains(l) { t.removeLast() }
        guard !t.isEmpty else { return nil }
        let ns = NSRange(t.startIndex..., in: t)
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p.0, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: t, range: ns) else { continue }
            func group(_ i: Int) -> String? {
                guard i > 0, i < m.numberOfRanges, let r = Range(m.range(at: i), in: t) else { return nil }
                let s = t[r].trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;\"'*"))
                return s.isEmpty ? nil : s
            }
            guard let x = group(p.x), shortPhrase(x) else { continue }
            // The new form must look like a name ("Vercel", "GitHub"):
            // "sorry, at one" after "at noon" is a content change.
            guard looksLikeName(x) else { return nil }
            let y = group(p.y)
            if let y, !shortPhrase(y) { continue }
            if let y {
                // The "not Y" side must be in the previous dictation and
                // sound like X — else it's a content change ("Tuesday, not Monday").
                guard let hit = bestWindow(in: previous, matching: {
                    CandidateFinder.normalize($0) == CandidateFinder.normalize(y) ? 0 : nil }),
                      soundClose(x, y) else { return nil }
                guard CandidateFinder.normalize(hit.span) != CandidateFinder.normalize(x) else { return nil }
                return LearnedPair(heard: hit.span, corrected: x, kind: .followUp, strength: p.strength,
                                   sentence: CandidateFinder.sentence(containing: hit.range, in: previous))
            }
            guard let hit = bestWindow(in: previous, matching: { span in
                CandidateFinder.normalize(span) == CandidateFinder.normalize(x) ? nil
                    : (soundClose(span, x)
                        // A span with fewer words than X loses ties: "bright eye",
                        // not "bright", for "bright AI". More words is fine (merges).
                        ? SoundCode.editDistance(lettersOnly(span), lettersOnly(x))
                            + 2 * max(0, x.split(separator: " ").count - span.split(separator: " ").count)
                        : nil)
            }) else { return nil }
            // X written exactly as before = the same mishearing; nothing to learn.
            if previous.lowercased().contains(x.lowercased()) { return nil }
            return LearnedPair(heard: hit.span, corrected: x, kind: .followUp, strength: p.strength,
                               sentence: CandidateFinder.sentence(containing: hit.range, in: previous))
        }
        return nil
    }

    private static func shortPhrase(_ s: String) -> Bool {
        let ws = s.split(separator: " ")
        return !ws.isEmpty && ws.count <= maxWords && s.contains(where: { $0.isLetter })
            && !s.contains(where: { $0.isNumber })
    }

    /// Capitalized like the recognizer writes names. Days, months and the
    /// pronoun are capitalized but are ordinary words.
    static let capitalizedCommon: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    static func isNameWord(_ t: Token) -> Bool {
        t.text.first!.isUppercase && !capitalizedCommon.contains(t.lower)
    }

    static func looksLikeName(_ s: String) -> Bool {
        tokens(s).contains(where: isNameWord)
    }

    /// The same sound-alike test EditDiff uses for a keyboard fix.
    static func soundClose(_ a: String, _ b: String) -> Bool {
        let la = lettersOnly(a), lb = lettersOnly(b)
        guard !la.isEmpty, !lb.isEmpty, la != lb || CandidateFinder.normalize(a) != CandidateFinder.normalize(b) else { return false }
        return SoundCode.soundsAlike(SoundCode.code(a), SoundCode.code(b))
            || SoundCode.editDistance(la, lb) <= max(2, la.count / 3)
    }

    // MARK: - Re-dictation

    /// Two dictations that differ only in one short sound-alike span. The
    /// later one must look MORE like a name (a capitalized word mid-sentence,
    /// or words merged: "in akshi" → "Inakshi") — homophones of ordinary
    /// words ("write" / "right") teach nothing.
    static func redictation(_ prev: TranscriptTurn, _ cur: TranscriptTurn) -> LearnedPair? {
        let a = tokens(prev.text), b = tokens(cur.text)
        guard a.count >= 3, b.count >= 3 else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p].lower == b[p].lower { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s].lower == b[b.count - 1 - s].lower { s += 1 }
        let am = p..<(a.count - s), bm = p..<(b.count - s)
        guard !am.isEmpty, !bm.isEmpty, am.count <= maxWords, bm.count <= maxWords else { return nil }
        let shared = p + s
        guard shared >= 2, Double(shared) >= 0.5 * Double(max(a.count, b.count)) else { return nil }
        guard !a[am].contains(where: { $0.hasDigit }), !b[bm].contains(where: { $0.hasDigit }) else { return nil }
        let heardRange = a[am.lowerBound].range.lowerBound..<a[am.upperBound - 1].range.upperBound
        let corrRange = b[bm.lowerBound].range.lowerBound..<b[bm.upperBound - 1].range.upperBound
        let heard = String(prev.text[heardRange]), corrected = String(cur.text[corrRange])
        guard soundClose(heard, corrected) else { return nil }

        let merged = bm.count < am.count && lettersOnly(heard) == lettersOnly(corrected)
        let nameLike = bm.contains { i in
            guard isNameWord(b[i]), !b[i].isCaps || b[i].text.count > 3 else { return false }
            let sentenceStart = i == 0 || gap(b, i, in: cur.text).contains(where: { ".!?".contains($0) })
            return !sentenceStart
        }
        // The earlier version already looked like a name and the later one
        // doesn't: the recognizer got worse, not the user clearer.
        guard merged || nameLike else { return nil }
        var strength = 0.45
        if prev.scratched { strength += 0.15 }
        if merged { strength += 0.1 }
        return LearnedPair(heard: heard, corrected: corrected, kind: .redictation, strength: strength,
                           sentence: CandidateFinder.sentence(containing: heardRange, in: prev.text))
    }
}
