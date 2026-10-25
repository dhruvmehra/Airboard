//
//  RuleLearning.swift
//
//  Turns ONE correction (a keyboard fix the CorrectionWatcher saw, or a
//  spelled-out pair from RedictationLearner) into the SpellingRule(s) a
//  Keep on the Learned card writes, and decides whether that card needs
//  the decision model first. VocabularyLearning only calls this; the
//  offline evals call the exact same code.
//
//  ── API for eval glue ──────────────────────────────────────────────────
//
//    let ordinary = RuleLearning.loadOrdinaryWords()        // once; /usr/share/dict/words
//    let isOrdinary: (String) -> Bool = { ordinary.contains($0) }
//
//    // Keyboard fix (CorrectionWatchPolicy.Lesson: correction + fixed):
//    let p = RuleLearning.propose(lesson.correction, fixed: lesson.fixed,
//                                 source: .keyboard, existing: rules,
//                                 hasKey: client != nil, isOrdinaryWord: isOrdinary)
//    // Spelled letters (LearnedPair with strength ≥ directCardStrength):
//    let p = RuleLearning.propose(EditDiff.Correction(heard: pair.heard, corrected: pair.corrected),
//                                 fixed: pair.sentence, source: .spelled, existing: rules,
//                                 hasKey: client != nil, isOrdinaryWord: isOrdinary)
//
//    switch p.gate {
//    case .reject:           nothing (p.reason says why)
//    case .learnDirect:      Learned card for p.card; Keep/ignore → write every p.rules line
//    case .askDecisionModel: ask DecisionQuestion.spellingFix(sentence, heard: p.card.heardAs,
//                            corrected: p.card.term); then
//                            RuleLearning.learns(p, decision: answerOrNil) → card as above
//    }
//
//  Gate semantics:
//  - spelled (the user said the letters): learnDirect, key or not.
//  - keyboard, NO key: learnDirect iff keylessGate passes (capitalised, not
//    only common words, and sounds alike — or, when every changed word is
//    not an ordinary dictionary word, a 1–2 letter fix with the same first
//    letter: "Mehta" → "Mehra") or it is a name extension ("Drew" → "Dhruv",
//    isNameExtension); else reject.
//  - keyboard, WITH key: learnDirect for an unmistakable name fix (keyless
//    gate passes AND every changed corrected word is not an ordinary word:
//    "pipe" → "Pype", "druv" → "Dhruv") or a new mishearing of a term the
//    user already confirmed ("Mehta" → "Mehra" once Mehra is a rule, or
//    "Drew" → "Dhruv" once Dhruv is). Everything else → askDecisionModel;
//    it learns at ≥ VocabularyResolver.suggestThreshold, and on NO answer
//    (timeout/error) falls back to the keyless gate (`fallbackLearn`).
//  - keyboard, key or not — "new-name" (2026-10-13): ONE word replaced by
//    a capitalised name in no dictionary (not a word, not a dictionary
//    proper noun, not Hinglish) that does NOT sound like it: "Python" →
//    "Pype (now)", "Fight" → "Pype". EditDiff(newNames) reports it only
//    when it is the one unexplained change in our text. Refused: a heard
//    word that is itself a capitalised non-dictionary name (a rename:
//    "Priya" → "Zoya"; "Mehta" → "Mehra" goes through the near-spelling
//    gate), a pronoun or everyday function word ("him", "through"),
//    anything not letters (URL, e-mail, number). The rule is
//    term ← heard; heard sounds unlike the term, so the apply side uses it
//    only with the decision model — what it teaches offline is the TERM.
//  - keyboard re-case ("pype" → "Pype", "recase"): learned when the word is
//    a confirmed term or a new name (as above); "the" → "The", "pipe" →
//    "Pipe" never. Writes the case-only rule Pype ← pype.
//  - Never: Hinglish words ("Mira" → "Meri", "hindi-word"); a dictionary
//    word whose only capital is the sentence start ("Drove" → "Drive",
//    keyless "sentence-start"); an unlike swap that is not a new name
//    ("unlike" — never sent to the decision model); a fix whose rules are
//    all already confirmed ("known").
//  "through" → "Dhruv" stays unlearned: a rule "Dhruv" ← "through" would be
//  a candidate in every "through the door", and nothing local can tell the
//  two apart.
//
//  Rules (rules(for:)): possessives stripped ("druv's" → "Dhruv's" teaches
//  Dhruv ← druv; ’ too), a multi-word fix whose words line up one-to-one
//  ALSO yields one rule per changed word that is itself a name fix
//  ("druv mera" → "Dhruv Mehra" gives Dhruv ← druv, Mehra ← mera, plus the
//  phrase rule, which the keyless apply path uses as an exact match), and
//  rules already confirmed (same heard, same term ignoring case) dropped.
//
//  Pure, Foundation-only (+ SoundCode, EditDiff, SpellingRule,
//  CandidateFinder.normalize, CorrectionWatchPolicy.commonWords,
//  VocabularyResolver.WordList/isHindiWord). Never prints user text.
//

import Foundation

nonisolated enum RuleLearning {

    enum Source: Equatable { case keyboard, spelled }
    enum Gate: String, Equatable { case learnDirect, askDecisionModel, reject }

    struct Proposal: Equatable {
        /// What the Learned card shows (possessive stripped).
        let card: SpellingRule
        /// What Keep writes — new rules only, card's pair first if new.
        let rules: [SpellingRule]
        let gate: Gate
        /// Stage label for logs — never user text.
        let reason: String
        /// askDecisionModel only: learn anyway if the model gives NO answer.
        let fallbackLearn: Bool
    }

    // MARK: - Entry point

    static func propose(_ c: EditDiff.Correction, fixed: String, source: Source,
                        existing: [SpellingRule], hasKey: Bool,
                        isOrdinaryWord: (String) -> Bool) -> Proposal {
        let c = trimTypedOn(c)
        let k = core(c)
        let card = SpellingRule(term: k.corrected, heardAs: k.heard)
        let new = rules(for: c, existing: existing, isOrdinaryWord: isOrdinaryWord)
        func make(_ g: Gate, _ why: String, fallback: Bool = false) -> Proposal {
            Proposal(card: card, rules: new, gate: g, reason: why, fallbackLearn: fallback)
        }
        guard k.heard != k.corrected else { return make(.reject, "no-change") }
        // Only re-cased ("pype" → "Pype"): a name the user owns, or a word
        // no dictionary knows — never a sentence start ("the" → "The").
        if k.heard.lowercased() == k.corrected.lowercased() {
            guard !new.isEmpty else { return make(.reject, "known") }
            let confirmed = existing.contains { $0.term == k.corrected }
            return confirmed || isNewName(k.corrected, isOrdinaryWord: isOrdinaryWord)
                ? make(.learnDirect, "recase") : make(.reject, "case-only")
        }
        guard !new.isEmpty else { return make(.reject, "known") }
        guard !isSuffixChange(k.heard, k.corrected) else { return make(.reject, "suffix") }
        // Hinglish words are not names, whatever their capital: "Mira" →
        // "Meri" at a sentence start is mera → meri (my), grammar.
        guard !changedWordsAreHindi(k) else { return make(.reject, "hindi-word") }
        if source == .spelled { return make(.learnDirect, "spelled") }

        if isConfirmedVariant(heard: k.heard, corrected: k.corrected, rules: existing) {
            return make(.learnDirect, "confirmed-variant")
        }
        if let parts = split(k, isOrdinaryWord: isOrdinaryWord), !parts.isEmpty,
           parts.allSatisfy({ isConfirmedVariant(heard: $0.heard, corrected: $0.corrected, rules: existing) }) {
            return make(.learnDirect, "confirmed-variant")
        }
        // A dictionary word whose only capital is the sentence start ("Drove
        // to the office." → "Drive to …"): the capital proves nothing.
        let startOnly = isSentenceStartWord(k, fixed: fixed, isOrdinaryWord: isOrdinaryWord)
        let gate = !startOnly && keylessGate(k, fixed: fixed, isOrdinaryWord: isOrdinaryWord)
        let ext = !gate && isNameExtension(k, isOrdinaryWord: isOrdinaryWord)
        // A word replaced by a name no dictionary knows, sound unlike
        // ("Python" → "Pype"): the user typed it on purpose. Learned with or
        // without a key — what it teaches is the TERM (later "pipe", "Pipe's"
        // match it by sound); its heardAs stays exact-only and, sounding
        // unlike its term, decision-model-only on the apply side.
        if !gate && !ext && isNewNameSwap(k, isOrdinaryWord: isOrdinaryWord) {
            return make(.learnDirect, "new-name")
        }
        // Reported only by EditDiff's newNames path (no sound-alike) and not
        // a new name: a content edit ("Priya" → "Zoya", "him" → "Priya") —
        // never worth a decision-model call.
        if !EditDiff.isSoundFix(c) { return make(.reject, "unlike") }
        if startOnly && !hasKey { return make(.reject, "sentence-start") }
        if hasKey {
            if gate && changedWordsAreNovel(k, isOrdinaryWord: isOrdinaryWord) {
                return make(.learnDirect, "name-fix")
            }
            return make(.askDecisionModel, gate ? "ordinary-word" : "ambiguous", fallback: gate || ext)
        }
        if gate { return make(.learnDirect, "keyless-gate") }
        return ext ? make(.learnDirect, "name-extension") : make(.reject, "keyless-gate")
    }

    // MARK: - New names (unlike-sounding or re-cased)

    /// A name the user introduces: one word, letters only, 3+ letters,
    /// capitalised, and in no dictionary — not as a word ("Pipe", "Mark"),
    /// not as a proper noun ("Tuesday", "Mira"), not Hinglish ("Meri").
    static func isNewName(_ w: String, isOrdinaryWord: (String) -> Bool) -> Bool {
        guard w.count >= 3, w.allSatisfy({ $0.isLetter }), let f = w.first, f.isUppercase,
              w.contains(where: { $0.isLowercase }) else { return false }
        return !isOrdinary(w, isOrdinaryWord) && !VocabularyResolver.WordList.isKnownName(w)
            && !VocabularyResolver.isHindiWord(w)
    }

    /// Words that a misheard name never comes out as: replacing one is
    /// a content edit ("call him" → "call Priya").
    static let pronouns: Set<String> = [
        "i", "me", "you", "he", "him", "she", "her", "it", "we", "us", "they", "them", "this", "that",
        "someone", "somebody", "everyone", "everybody", "anyone", "anybody", "nobody", "my", "your",
        "his", "its", "our", "their", "here", "there",
    ]

    /// The gate for a sound-UNLIKE fix (key or not): one word → a new name
    /// (isNewName). Refused: a heard word that is itself a capitalised
    /// non-dictionary name — a rename ("Mehta" → "Mehra" learns only through
    /// the near-spelling gate; "Monday" → "Tuesday", "Priya" → "Zoya" not at
    /// all); a pronoun ("him" → "Priya") or everyday function word
    /// ("through"); anything but letters (URL, e-mail, number). EditDiff
    /// (newNames) has already checked it was the only unexplained change in
    /// our text — not a rewrite.
    static func isNewNameSwap(_ c: EditDiff.Correction, isOrdinaryWord: (String) -> Bool) -> Bool {
        let h = c.heard, w = c.corrected
        guard !h.contains(" "), !w.contains(" "), h.count >= 2, h.allSatisfy({ $0.isLetter }),
              isNewName(w, isOrdinaryWord: isOrdinaryWord),
              !pronouns.contains(h.lowercased()),
              // An everyday function word ("walk through the door" → "walk
              // Dhruv the door") is a content edit as often as a mishearing,
              // and a rule heard as "through" would be a candidate in every
              // "through the door". Not learned (as before 2026-10-12).
              !CorrectionWatchPolicy.commonWords.contains(h.lowercased()),
              !EditDiff.isCommonWord(h) else { return false }
        if let f = h.first, f.isUppercase,
           !isOrdinary(h, isOrdinaryWord) || VocabularyResolver.WordList.isKnownName(h) { return false }
        return true
    }

    /// One dictionary word fixed into another dictionary word whose capital
    /// comes only from standing first in a sentence of `fixed`.
    static func isSentenceStartWord(_ c: EditDiff.Correction, fixed: String,
                                    isOrdinaryWord: (String) -> Bool) -> Bool {
        let w = c.corrected
        guard !w.contains(" "), !w.dropFirst().contains(where: { $0.isUppercase || $0.isNumber }),
              isOrdinary(w, isOrdinaryWord) else { return false }
        let f = fixed.trimmingCharacters(in: .whitespaces)
        if f.hasPrefix(w) { return true }
        return [". ", "! ", "? ", "\n"].contains { f.contains($0 + w) }
    }

    /// "Python" → "Pype now": the user typed on after fixing our last word.
    /// One heard word, the fix plus one short common word → just the fix.
    static func trimTypedOn(_ c: EditDiff.Correction) -> EditDiff.Correction {
        let cw = c.corrected.split(separator: " ").map(String.init)
        guard !c.heard.contains(" "), cw.count == 2,
              CorrectionWatchPolicy.commonWords.contains(trimEdges(cw[1]).lowercased()),
              !CorrectionWatchPolicy.commonWords.contains(trimEdges(cw[0]).lowercased()) else { return c }
        return EditDiff.Correction(heard: c.heard, corrected: trimEdges(cw[0]))
    }

    /// Every word the user changed is a Hinglish word ("Meri", "Mera").
    static func changedWordsAreHindi(_ c: EditDiff.Correction) -> Bool {
        let edge = CharacterSet(charactersIn: ".,!?;:\"“”‘()[]{}…")
        let heard = Set(c.heard.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: edge) })
        let changed = c.corrected.split(separator: " ").map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty && !heard.contains($0.lowercased()) }
        return !changed.isEmpty && changed.allSatisfy { VocabularyResolver.isHindiWord($0) }
    }

    /// After asking the decision model (askDecisionModel only). nil = no answer.
    static func learns(_ p: Proposal, decision: Double?, threshold: Double = 0.7) -> Bool {
        switch p.gate {
        case .learnDirect: return true
        case .reject: return false
        case .askDecisionModel:
            guard let decision else { return p.fallbackLearn }
            return decision >= threshold
        }
    }

    // MARK: - Rules

    /// The new rules a correction teaches (see header). Order: the card's
    /// own pair, then per-word pairs. Already-confirmed ones dropped.
    static func rules(for c: EditDiff.Correction, existing: [SpellingRule],
                      isOrdinaryWord: (String) -> Bool) -> [SpellingRule] {
        let k = core(trimTypedOn(c))
        guard !k.heard.isEmpty, !k.corrected.isEmpty, k.heard != k.corrected else { return [] }
        var out = [SpellingRule(term: k.corrected, heardAs: k.heard)]
        for p in split(k, isOrdinaryWord: isOrdinaryWord) ?? [] {
            out.append(SpellingRule(term: p.corrected, heardAs: p.heard))
        }
        var seen = Set<String>()
        return out.filter { r in
            seen.insert(CandidateFinder.normalize(r.heardAs) + "→" + r.term.lowercased()).inserted
                && !isKnown(heard: r.heardAs, term: r.term, in: existing)
        }
    }

    /// Same heard (normalized) and same term ignoring case: nothing new.
    static func isKnown(heard: String, term: String, in rules: [SpellingRule]) -> Bool {
        let h = CandidateFinder.normalize(heard), t = term.lowercased()
        return rules.contains { CandidateFinder.normalize($0.heardAs) == h && $0.term.lowercased() == t }
    }

    /// The fix minus a possessive both sides share: "druv's" → "Dhruv's"
    /// is Dhruv ← druv; "druvs" → "Dhruv's" too. Straight or curly '.
    static func core(_ c: EditDiff.Correction) -> EditDiff.Correction {
        func strip(_ s: String) -> String? {
            let n = s.replacingOccurrences(of: "\u{2019}", with: "'")
            return n.lowercased().hasSuffix("'s") && n.count > 3 ? String(s.dropLast(2)) : nil
        }
        guard let corr = strip(c.corrected) else { return c }
        let h = c.heard.replacingOccurrences(of: "\u{2019}", with: "'")
        var heard: String?
        if let s = strip(c.heard) { heard = s }
        // ASR wrote the possessive without the apostrophe: "druvs".
        else if h.lowercased().hasSuffix("s"), !h.lowercased().hasSuffix("ss"), h.count > 2 { heard = String(c.heard.dropLast()) }
        guard let heard, heard != corr else { return c }
        return EditDiff.Correction(heard: heard, corrected: corr)
    }

    /// One-to-one word pairs of a multi-word fix, the changed ones only —
    /// nil unless word counts match and EVERY changed pair is a name fix
    /// on its own (else the phrase is one lesson, e.g. "a lisha" → "Alisha").
    static func split(_ c: EditDiff.Correction, isOrdinaryWord: (String) -> Bool) -> [EditDiff.Correction]? {
        let hw = c.heard.split(separator: " ").map(String.init)
        let cw = c.corrected.split(separator: " ").map(String.init)
        guard hw.count >= 2, hw.count == cw.count else { return nil }
        var out: [EditDiff.Correction] = []
        for (h, w) in zip(hw, cw) where h.lowercased() != w.lowercased() {
            let pair = core(EditDiff.Correction(heard: trimEdges(h), corrected: trimEdges(w)))
            guard isWordNameFix(pair, isOrdinaryWord: isOrdinaryWord) else { return nil }
            out.append(pair)
        }
        return out.isEmpty ? nil : out
    }

    private static func trimEdges(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"“”‘()[]{}…"))
    }

    /// One word → one word that is clearly the same name respelled.
    static func isWordNameFix(_ p: EditDiff.Correction, isOrdinaryWord: (String) -> Bool) -> Bool {
        let w = p.corrected
        guard !p.heard.isEmpty, w.contains(where: { $0.isUppercase || $0.isNumber }),
              !CorrectionWatchPolicy.commonWords.contains(w.lowercased()),
              !isSuffixChange(p.heard, w) else { return false }
        if SoundCode.soundsAlike(SoundCode.code(p.heard), SoundCode.code(w)) { return true }
        return !isOrdinary(w, isOrdinaryWord) && closeSpelling(p.heard, w)
    }

    // MARK: - Gates

    /// The keyless gate: CorrectionWatchPolicy.passesLocalGate with the
    /// dictionary, so a non-dictionary name one letter off ("Mehta" →
    /// "Mehra") counts like a sound-alike one.
    static func keylessGate(_ c: EditDiff.Correction, fixed: String, isOrdinaryWord: (String) -> Bool) -> Bool {
        withoutActuallyEscaping(isOrdinaryWord) {
            CorrectionWatchPolicy.passesLocalGate(c, fixed: fixed, isOrdinaryWord: $0)
        }
    }

    /// A fix landing on a term the user ALREADY confirmed, from a heard
    /// form that sounds or spells like it — same lesson, new mishearing
    /// (ported from the 2026-10-07 field fix: the decision engine can't
    /// know the term is the user's and scored these 0.49–0.67). Also
    /// accepts one letter off anywhere ("type" → "Pype") and one sound
    /// added/dropped at the end with the same first letter ("Drew" TR →
    /// "Dhruv" TRF) — only for a confirmed term.
    static func isConfirmedVariant(heard: String, corrected: String, rules: [SpellingRule]) -> Bool {
        let t = corrected.lowercased()
        guard rules.contains(where: { $0.term.lowercased() == t }) else { return false }
        let hc = SoundCode.code(heard), cc = SoundCode.code(corrected)
        if SoundCode.soundsAlike(hc, cc) { return true }
        let hl = lettersOnly(heard), cl = lettersOnly(corrected)
        // One letter off, any position: "type" → "Pype".
        if hl.count >= 4, SoundCode.editDistance(hl, cl) <= 1 { return true }
        guard !hl.isEmpty, hl.first == cl.first else { return false }
        if closeSpelling(heard, corrected) { return true }
        let (s, l) = hc.count < cc.count ? (hc, cc) : (cc, hc)
        if s.count >= 2 && l.count == s.count + 1 && l.hasPrefix(s) { return true }
        // The last sound swapped in a 3+ sound name: "Drum" TRM → "Dhruv" TRF.
        return hc.count >= 3 && hc.count == cc.count && hc.dropLast() == cc.dropLast()
    }

    /// "Drew" → "Dhruv" (TR → TRF): one word, same first letter, the fix
    /// keeps every heard sound and adds one at the end, and the corrected
    /// word is a capitalised name no dictionary knows. The user typed it, so
    /// it is learned even with no key. Safe offline: VocabularyResolver
    /// never applies a heardAs that doesn't sound like its term ("Drew is
    /// coming" stays) without the decision model — what the rule adds
    /// offline is the TERM, so "Druv", "Dhruva", "Drove Meira" are
    /// recognised on later dictations.
    static func isNameExtension(_ c: EditDiff.Correction, isOrdinaryWord: (String) -> Bool) -> Bool {
        let h = c.heard, w = c.corrected
        guard !h.contains(" "), !w.contains(" "), let f = w.first, f.isUppercase,
              w.allSatisfy({ $0.isLetter }), h.allSatisfy({ $0.isLetter }),
              h.lowercased().first == w.lowercased().first,
              !isOrdinary(w, isOrdinaryWord) else { return false }
        let hc = SoundCode.code(h), cc = SoundCode.code(w)
        return hc.count >= 2 && cc.count == hc.count + 1 && cc.hasPrefix(hc)
    }

    static func changedWordsAreNovel(_ c: EditDiff.Correction, isOrdinaryWord: (String) -> Bool) -> Bool {
        CorrectionWatchPolicy.changedWordsAreNovel(c, isOrdinaryWord: isOrdinaryWord)
    }

    static func isOrdinary(_ word: String, _ isOrdinaryWord: (String) -> Bool) -> Bool {
        CorrectionWatchPolicy.isOrdinary(word, isOrdinaryWord)
    }

    static func closeSpelling(_ a: String, _ b: String) -> Bool { CorrectionWatchPolicy.closeSpelling(a, b) }

    /// "pipe" → "pipes", "Priya" → "Priya's": grammar, not spelling.
    static func isSuffixChange(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let y = b.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let (s, l) = x.count < y.count ? (x, y) : (y, x)
        return l.hasPrefix(s) && ["s", "es", "'s", "'"].contains(String(l.dropFirst(s.count)))
    }

    static func lettersOnly(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter }) }

    // MARK: - Dictionary

    /// Lowercase entries of the system word list (proper nouns there are
    /// capitalised and skipped, so "Mark" the name doesn't count but
    /// "mark" does). Empty set if the file is missing — then only the
    /// sound-alike gate applies, as before.
    static func loadOrdinaryWords(path: String = "/usr/share/dict/words") -> Set<String> {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out = Set<String>()
        out.reserveCapacity(240_000)
        for line in s.split(separator: "\n") {
            let w = line.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty, w == w.lowercased() { out.insert(w) }
        }
        return out
    }
}
