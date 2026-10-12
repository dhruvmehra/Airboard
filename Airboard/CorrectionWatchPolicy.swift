//
//  CorrectionWatchPolicy.swift
//
//  When to re-read a field after an insertion, and what a reading means.
//  The pure half of CorrectionWatcher: no AX, no clock, no threads — the
//  caller supplies times, field ids and field text. Replayed offline by
//  scripts/watch-eval (timelines + tests).
//
//  - Watches the last `maxWatched` insertions (any field) for `window`
//    seconds. A new dictation does NOT end the watch on earlier ones.
//  - Reads on a front-loaded schedule (every 2s, then 4s, then 6s), plus
//    AX value-changed reads (one at the start of an edit burst, one once
//    it pauses), plus one "flush" read when a recording starts.
//  - Finds OUR text in the field by the text around it (anchors), so the
//    user typing elsewhere, or a later dictation landing next to it,
//    doesn't hide a fix. Two fixes at once are split by word alignment.
//  - A fix is learned only from a SETTLED reading (same text twice, or
//    quiet since the last AX change) — "Bri" half-way to "Brite" is not a
//    lesson — and only if the field was focused at some reading since the
//    last settled one (a field changing while the user is elsewhere —
//    another channel's draft swapped in — isn't them).
//  - Several lessons per insertion; never the same pair twice; never a
//    "heard" word the user already changed by hand.
//  - A watch ends when the window ends, our text is gone from the field
//    (chat sent / deleted), the field is unreadable 3 times running, or
//    newer insertions push it out. Focus moving away does NOT end it.
//  Foundation-only (+ EditDiff, SoundCode): compiles standalone.
//

import Foundation

nonisolated struct CorrectionWatchPolicy {

    struct Config {
        var window: TimeInterval = 60
        var schedule: [TimeInterval] = [2, 4, 6, 8, 10, 14, 18, 22, 26, 30, 36, 42, 48, 54, 60]
        /// Readings are per FIELD, not per insertion, so extra entries in
        /// the same field cost no AX calls — only a string search.
        var maxWatched = 5
        var settle: TimeInterval = 1.0        // AX: quiet this long = settled
        var confirmDelay: TimeInterval = 1.5  // changed but unsettled → read again
        var confirmGrace: TimeInterval = 4    // a confirm read may land after the window
        var maxUnreadable = 3
        var anchorLength = 32
        var maxFieldChars = 250_000           // bigger fields aren't watched
    }

    struct Lesson: Equatable {
        let entryID: Int
        let correction: EditDiff.Correction
        let sentence: String   // our text as it stood before the fix (decision question)
        let fixed: String      // our text after the fix (local gate context)
    }

    enum StopReason: String { case expired, evicted, lost, unreadable, cancelled }

    struct Entry {
        let id: Int
        let fieldID: Int
        let insertedAt: Date
        var text: String              // our insertion as it stands (learned fixes applied)
        var prefix: String            // field text just before it
        var suffix: String            // field text just after it
        var startOffset: Int          // utf16 offset where it began, last seen
        var nextDue = 0               // index into config.schedule
        var fixedWords: Set<String> = []
        var lessons = 0
    }

    struct Found {
        let fixes: [EditDiff.Correction]
        let fixed: String                  // our text with the fixes applied
        let piece: Range<String.Index>     // where our (fixed) text sits in the field
    }

    let config: Config
    private(set) var entries: [Entry] = []
    private var nextID = 0
    private var lastText: [Int: String] = [:]      // fieldID → last reading
    private var seenSince: [Int: Date] = [:]       // fieldID → when lastText was first read
    private var touched: Set<Int> = []             // focused at a reading since the last settled one
    private var lastChange: [Int: Date] = [:]      // fieldID → last AX value-changed
    private var axLive: Set<Int> = []              // fields whose app posts value-changed
    private var axDue: [Int: Date] = [:]
    private var confirmDue: [Int: Date] = [:]
    private var flush: Set<Int> = []
    private var unreadable: [Int: Int] = [:]
    private var taught: Set<String> = []           // pairs already handed out

    init(config: Config = Config()) { self.config = config }

    var watchedFields: Set<Int> { Set(entries.map(\.fieldID)) }

    // MARK: - Events

    /// Our text just landed in `fieldID`, whose full text is `fieldText`.
    /// Returns the new entry id (nil = not watchable: our text isn't
    /// there, or the field is huge) and any entries pushed out.
    mutating func inserted(fieldID: Int, text: String, fieldText: String,
                           at now: Date) -> (id: Int?, evicted: [Int]) {
        let ours = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ours.isEmpty, fieldText.utf16.count <= config.maxFieldChars,
              let r = fieldText.range(of: ours, options: .backwards) else { return (nil, []) }
        nextID += 1
        var e = Entry(id: nextID, fieldID: fieldID, insertedAt: now, text: ours,
                      prefix: "", suffix: "", startOffset: 0)
        Self.anchor(&e, at: r, in: fieldText, length: config.anchorLength)
        entries.append(e)
        lastText[fieldID] = fieldText
        seenSince[fieldID] = now
        touched.insert(fieldID)
        var evicted: [Int] = []
        while entries.count > config.maxWatched {
            evicted.append(entries.removeFirst().id)
        }
        forgetUnwatchedFields()
        return (e.id, evicted)
    }

    /// The app reported an edit in a watched field (AXValueChanged).
    mutating func valueChanged(fieldID: Int, at now: Date) {
        guard watchedFields.contains(fieldID) else { return }
        axLive.insert(fieldID)
        // First change after a quiet spell: read at once (catches a chat
        // field emptied by send before new typing refills it). Later
        // changes in the burst: one read once typing pauses.
        let burstStart = lastChange[fieldID].map { now.timeIntervalSince($0) >= config.settle } ?? true
        lastChange[fieldID] = now
        axDue[fieldID] = burstStart ? now : now.addingTimeInterval(config.settle)
    }

    /// A recording is starting: read every watched field once, now.
    mutating func recordingStarted() { flush = watchedFields }

    mutating func cancelAll() -> [Int] {
        let ids = entries.map(\.id)
        entries = []
        forgetUnwatchedFields()
        return ids
    }

    // MARK: - Schedule

    private func scheduled(_ e: Entry) -> Date? {
        e.nextDue < config.schedule.count ? e.insertedAt.addingTimeInterval(config.schedule[e.nextDue]) : nil
    }

    /// When the caller should next call `fieldsDue`. nil = nothing to do.
    func nextCheck(now: Date) -> Date? {
        if !flush.isEmpty { return now }
        var times = entries.compactMap(scheduled)
        times += Array(axDue.values) + Array(confirmDue.values)
        if let end = entries.map({ $0.insertedAt.addingTimeInterval(config.window + config.confirmGrace) }).min() {
            times.append(end)   // so expiry happens even with nothing else due
        }
        return times.min()
    }

    /// Fields to read now.
    func fieldsDue(at now: Date) -> [Int] {
        var due = flush
        for e in entries where (scheduled(e).map { $0 <= now } ?? false) { due.insert(e.fieldID) }
        for (f, t) in axDue where t <= now { due.insert(f) }
        for (f, t) in confirmDue where t <= now { due.insert(f) }
        return due.filter { watchedFields.contains($0) }.sorted()
    }

    /// Entries whose watch is over. Call after each round of readings.
    mutating func expire(now: Date) -> [Int] {
        let pendingFields = Set(confirmDue.keys).union(axDue.keys)
        let ending = entries.filter { e in
            let hardEnd = now >= e.insertedAt.addingTimeInterval(config.window + config.confirmGrace)
            return hardEnd || (scheduled(e) == nil && !pendingFields.contains(e.fieldID))
        }
        let gone = ending.map(\.id)
        entries.removeAll { gone.contains($0.id) }
        forgetUnwatchedFields()
        return gone
    }

    // MARK: - Readings

    /// One reading of a watched field. `text` nil = unreadable right now.
    /// Returns the lessons it taught and the entries it ended.
    mutating func observe(fieldID: Int, text: String?, focused: Bool,
                          at now: Date) -> (lessons: [Lesson], stopped: [(Int, StopReason)]) {
        flush.remove(fieldID)
        if let t = confirmDue[fieldID], t <= now { confirmDue[fieldID] = nil }
        if let t = axDue[fieldID], t <= now { axDue[fieldID] = nil }
        for i in entries.indices where entries[i].fieldID == fieldID {
            while let t = scheduled(entries[i]), t <= now { entries[i].nextDue += 1 }
        }

        var stopped: [(Int, StopReason)] = []
        guard let text else {
            unreadable[fieldID, default: 0] += 1
            if unreadable[fieldID, default: 0] >= config.maxUnreadable {
                let ids = entries.filter { $0.fieldID == fieldID }.map(\.id)
                entries.removeAll { $0.fieldID == fieldID }
                stopped = ids.map { ($0, .unreadable) }
                forgetUnwatchedFields()
            }
            return ([], stopped)
        }
        unreadable[fieldID] = 0

        // Settled = the same text for `settle` seconds (two readings that
        // far apart agree), or — where the app posts AX changes — no
        // change for that long. (Small slack: timers fire AT the deadline.)
        let settle = config.settle - 0.05
        let quiet = axLive.contains(fieldID)
            && (lastChange[fieldID].map { now.timeIntervalSince($0) >= settle } ?? true)
        if lastText[fieldID] != text { seenSince[fieldID] = now }
        let steady = now.timeIntervalSince(seenSince[fieldID] ?? now) >= settle
        let settled = steady || quiet
        if focused { touched.insert(fieldID) }
        let byUser = touched.contains(fieldID)
        lastText[fieldID] = text

        var lessons: [Lesson] = []
        var lost: [Int] = []
        let n = config.anchorLength
        for i in entries.indices where entries[i].fieldID == fieldID {
            guard let region = locate(entries[i], in: text) else { lost.append(entries[i].id); continue }
            // Unchanged (maybe with text added around it): refresh anchors.
            if let r = text.range(of: entries[i].text, range: region) {
                Self.anchor(&entries[i], at: r, in: text, length: n); continue
            }
            guard let found = Self.corrections(entries[i].text, text[region]) else { continue }
            guard settled else {
                confirmDue[fieldID] = now.addingTimeInterval(config.confirmDelay); continue
            }
            let before = entries[i].text
            entries[i].text = found.fixed
            Self.anchor(&entries[i], at: found.piece, in: text, length: n)
            for fix in found.fixes {
                // Changed while the user was elsewhere: the new baseline,
                // but no lesson. Nor from re-editing a word they already
                // fixed, or from a pair already handed out.
                let key = Self.pairKey(fix)
                let heardWords = Set(fix.heard.lowercased().split(separator: " ").map(String.init))
                let fresh = byUser && !taught.contains(key) && heardWords.isDisjoint(with: entries[i].fixedWords)
                entries[i].fixedWords.formUnion(fix.corrected.lowercased().split(separator: " ").map(String.init))
                guard fresh else { continue }
                taught.insert(key)
                entries[i].lessons += 1
                lessons.append(Lesson(entryID: entries[i].id, correction: fix, sentence: before, fixed: found.fixed))
            }
        }
        if settled && !focused { touched.remove(fieldID) }
        entries.removeAll { lost.contains($0.id) }
        stopped = lost.map { ($0, .lost) }
        forgetUnwatchedFields()
        return (lessons, stopped)
    }

    static func pairKey(_ c: EditDiff.Correction) -> String {
        c.heard.lowercased() + "\u{1F}" + c.corrected
    }

    // MARK: - Finding our text

    private static func anchor(_ e: inout Entry, at r: Range<String.Index>, in text: String, length n: Int) {
        let pStart = text.index(r.lowerBound, offsetBy: -n, limitedBy: text.startIndex) ?? text.startIndex
        let sEnd = text.index(r.upperBound, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
        e.prefix = String(text[pStart..<r.lowerBound])
        e.suffix = String(text[r.upperBound..<sEnd])
        e.startOffset = text.utf16.distance(from: text.startIndex, to: r.lowerBound)
    }

    /// Where our text sits now: between its anchors (the region may also
    /// carry text typed right after ours). If the left anchor was edited
    /// away, our unchanged text nearest its old place will do. nil = gone.
    private func locate(_ e: Entry, in text: String) -> Range<String.Index>? {
        var left: String.Index? = text.startIndex
        if !e.prefix.isEmpty {
            left = (nearest(e.prefix, in: text, to: e.startOffset)
                    ?? nearest(String(e.prefix.suffix(8)), in: text, to: e.startOffset))?.upperBound
        }
        guard var start = left else {
            return nearest(e.text, in: text, to: e.startOffset + e.text.utf16.count)
        }
        var end = text.endIndex
        // Nearest to where our text ended, not the first match: a short
        // anchor (" " typed after us) also occurs inside our own text.
        let expectedEnd = text.utf16.distance(from: text.startIndex, to: start) + e.text.utf16.count
        if !e.suffix.isEmpty,
           let r = nearest(e.suffix, in: text, to: expectedEnd, from: start, byStart: true) { end = r.lowerBound }
        // Whitespace the editor put between anchors is not ours.
        while start < end, text[start].isWhitespace { start = text.index(after: start) }
        while start < end, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        guard start < end else { return nil }
        return start..<end
    }

    /// The occurrence of `needle` whose end (or start, `byStart`) is
    /// closest to utf16 `offset`.
    private func nearest(_ needle: String, in text: String, to offset: Int,
                         from: String.Index? = nil, byStart: Bool = false) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var best: Range<String.Index>?, bestGap = Int.max
        var from = from ?? text.startIndex
        while let r = text.range(of: needle, range: from..<text.endIndex) {
            let gap = abs(text.utf16.distance(from: text.startIndex, to: byStart ? r.lowerBound : r.upperBound) - offset)
            if gap < bestGap { best = r; bestGap = gap }
            from = text.index(after: r.lowerBound)
        }
        return best
    }

    /// Spelling fixes inside our text. The whole region goes to EditDiff
    /// first. Failing that (two fixes at once, or text typed after ours),
    /// a word alignment (LCS) splits the region into changed stretches and
    /// EditDiff judges each alone; words only ADDED are the user's own
    /// text, never a fix.
    static func corrections(_ ours: String, _ region: Substring) -> Found? {
        if let c = EditDiff.correction(before: ours, after: String(region), inserted: ours) {
            return Found(fixes: [c], fixed: String(region), piece: region.startIndex..<region.endIndex)
        }
        let a = words(ours[...]), b = words(region)
        let n = a.count, m = b.count
        guard n > 0, m > 0, n * m <= 40_000 else { return nil }
        // LCS table on exact words.
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = ours[a[i]] == region[b[j]] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // Walk it: stretches (ours i0..<i ↔ region j0..<j) between matches.
        var stretches: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0, i0 = 0, j0 = 0
        var lastJ = -1   // region word holding our last word so far
        while i < n && j < m {
            if ours[a[i]] == region[b[j]] {
                if i > i0 || j > j0 { stretches.append((i0..<i, j0..<j)) }
                lastJ = j; i += 1; j += 1; i0 = i; j0 = j
            } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        // Our trailing words pair with at most as many region words + 1
        // (a split word); anything beyond is typed after us.
        if i0 < n { stretches.append((i0..<n, j0..<min(m, j0 + (n - i0) + 1))) }
        var fixes: [EditDiff.Correction] = []
        var replaced: [(Range<String.Index>, Substring)] = []
        for (oi, rj) in stretches where !oi.isEmpty && !rj.isEmpty {
            let oursSpan = a[oi.lowerBound].lowerBound..<a[oi.upperBound - 1].upperBound
            let newSpan = region[b[rj.lowerBound].lowerBound..<b[rj.upperBound - 1].upperBound]
            var candidate = ours
            candidate.replaceSubrange(oursSpan, with: newSpan)
            guard let c = EditDiff.correction(before: ours, after: candidate, inserted: ours) else { continue }
            fixes.append(c); replaced.append((oursSpan, newSpan))
            lastJ = max(lastJ, rj.upperBound - 1)
        }
        guard !fixes.isEmpty, lastJ >= 0 else { return nil }
        var fixed = ours
        for (span, new) in replaced.reversed() { fixed.replaceSubrange(span, with: new) }
        return Found(fixes: fixes, fixed: fixed, piece: region.startIndex..<b[lastJ].upperBound)
    }

    private static func words(_ s: Substring) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var i = s.startIndex
        var start: String.Index?
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let st = start { out.append(st..<i); start = nil }
            } else if start == nil { start = i }
            i = s.index(after: i)
        }
        if let st = start { out.append(st..<s.endIndex) }
        return out
    }

    private mutating func forgetUnwatchedFields() {
        let live = watchedFields
        for f in Set(lastText.keys).union(axDue.keys).union(confirmDue.keys).union(lastChange.keys)
            where !live.contains(f) {
            lastText[f] = nil; seenSince[f] = nil; lastChange[f] = nil; axDue[f] = nil; confirmDue[f] = nil
            unreadable[f] = nil; axLive.remove(f); touched.remove(f)
        }
        flush.formIntersection(live)
    }

    // MARK: - Keyless gate

    /// Without a decision model, a fix becomes a card only if it is
    /// clearly a NAME the recogniser misheard:
    /// 1. it SOUNDS like what was heard (SoundCode) — not merely a close
    ///    spelling, which also covers typos and grammar ("form" → "from");
    /// 2. every corrected word carries a capital or digit ("Brite AI",
    ///    "iPhone", "GPT4") — ordinary-word fixes are lowercase;
    /// 3. it isn't only common English words ("Their" → "There" at a
    ///    sentence start is capitalised and sounds alike, teaches nothing);
    /// 4. at the start of our text a capital proves nothing, so a lone
    ///    word there that is one letter off the heard word with the same
    ///    first 3 letters reads as a typo fix, not a name.
    static func passesLocalGate(_ c: EditDiff.Correction, fixed: String) -> Bool {
        guard SoundCode.soundsAlike(SoundCode.code(c.heard), SoundCode.code(c.corrected)) else { return false }
        let words = c.corrected.split(separator: " ")
        guard !words.isEmpty,
              words.allSatisfy({ $0.contains { $0.isUppercase || $0.isNumber } }),
              !words.allSatisfy({ commonWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) })
        else { return false }
        if fixed.hasPrefix(c.corrected) && words.count == 1 {
            let w = words[0]
            let innerCap = w.dropFirst().contains { $0.isUppercase || $0.isNumber }
            if !innerCap && w.lowercased().prefix(3) == c.heard.lowercased().prefix(3)
                && SoundCode.editDistance(w.lowercased(), c.heard.lowercased()) <= 1 { return false }
        }
        return true
    }

    /// Common words and the homophones people fix for grammar, not
    /// vocabulary. Lowercase.
    static let commonWords: Set<String> = [
        "a", "about", "accept", "except", "affect", "effect", "after", "all", "allowed", "aloud", "also",
        "an", "and", "any", "are", "our", "hour", "as", "at", "ate", "eight", "be", "bee", "been",
        "but", "buy", "by", "bye", "can", "cant", "cannot", "come", "could", "day", "do", "dew", "due",
        "even", "for", "four", "fore", "from", "form", "get", "go", "good", "had", "has", "have", "he",
        "hear", "here", "her", "him", "his", "how", "i", "if", "in", "inn", "into", "is", "it", "its",
        "it's", "just", "know", "no", "now", "knew", "new", "like", "look", "made", "maid", "make",
        "may", "me", "meet", "meat", "mine", "more", "most", "my", "not", "knot", "of", "off", "on",
        "one", "won", "only", "or", "ore", "other", "out", "over", "passed", "past", "peace", "piece",
        "people", "plain", "plane", "principal", "principle", "right", "write", "rite", "road", "rode",
        "said", "see", "sea", "she", "so", "sew", "some", "sum", "son", "sun", "than", "then", "that",
        "the", "their", "there", "they're", "them", "these", "they", "thing", "think", "this", "those",
        "threw", "through", "time", "to", "too", "two", "up", "us", "use", "very", "wait", "weight",
        "want", "was", "way", "weigh", "we", "wear", "where", "ware", "weather", "whether", "week",
        "weak", "well", "were", "we're", "what", "when", "which", "witch", "who", "whose", "who's",
        "will", "with", "would", "wood", "year", "yes", "you", "your", "you're", "yore", "hi", "high",
        "hello", "thanks", "okay", "ok", "sure", "great", "sent", "cent", "scent",
        "kind", "lead", "led", "loose", "lose", "quiet", "quite", "role", "roll", "sight", "site",
        "cite", "stationary", "stationery", "tail", "tale", "wine", "whine", "morning", "mourning",
        "flour", "flower", "break", "brake", "steal", "steel", "waste", "waist", "board", "bored",
    ]
}
