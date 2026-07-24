//
//  MemoryCommands.swift
//
//  Voice teaching and recall for Airboard memory, spoken in command mode
//  (the action trigger). Detection is local pattern matching; recall
//  resolution prefers the cleanup LLM (which note answers "where I work")
//  with a local keyword fallback so core recalls work offline.
//
//  Foundation-only on purpose: compiles standalone for scratch tests.
//

import Foundation

enum MemoryCommandOutcome: Equatable {
    case notMemoryCommand
    /// A fact awaiting the user's confirmation pop-up. `cleaned` prefills
    /// the editable field; `heard` is the raw dictation (edit-diff base).
    case confirmFact(cleaned: String, heard: String)
    case learned(term: String)
    case recall(text: String)
    case recallFailed(query: String)
}

enum MemoryCommands {

    enum LocalIntent: Equatable {
        case remember(note: String)
        case correct(heard: String, term: String)
        case recall(query: String)
    }

    /// Pure structural detection. Case-insensitive prefixes, trailing
    /// punctuation ignored. Returns nil for anything that isn't a memory
    /// command — the caller falls through to the normal CommandDetector.
    static func detectLocally(_ raw: String) -> LocalIntent? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".?!,".contains(last) { text.removeLast() }
        // ASR often punctuates after the verb ("Remember, I work at Pype").
        // Drop a single comma that directly follows the first word so the
        // prefix checks still match.
        if let commaIndex = text.firstIndex(of: ","),
           !text[..<commaIndex].contains(" ") {
            text.remove(at: commaIndex)
        }
        let lower = text.lowercased()

        if lower.hasPrefix("remember ") {
            let note = String(text.dropFirst("remember ".count))
                .trimmingCharacters(in: .whitespaces)
            // Spoken openers like "that my address is X" read better without "that".
            let cleaned = note.lowercased().hasPrefix("that ")
                ? String(note.dropFirst(5)) : note
            guard !cleaned.isEmpty else { return nil }
            return .remember(note: cleaned.prefix(1).uppercased() + cleaned.dropFirst())
        }

        if lower.hasPrefix("correct ") {
            let rest = String(text.dropFirst("correct ".count))
            if let range = rest.range(of: " to ", options: .caseInsensitive) {
                let heard = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let term = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !heard.isEmpty && !term.isEmpty { return .correct(heard: heard, term: term) }
            }
        }
        if lower.hasPrefix("spell ") {
            let rest = String(text.dropFirst("spell ".count))
            if let range = rest.range(of: " as ", options: .caseInsensitive) {
                let heard = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let term = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !heard.isEmpty && !term.isEmpty { return .correct(heard: heard, term: term) }
            }
        }

        for verb in ["write my ", "insert my ", "type my "] where lower.hasPrefix(verb) {
            let thing = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            if !thing.isEmpty { return .recall(query: "my " + thing) }
        }
        if lower.hasPrefix("fill in ") {
            var thing = String(text.dropFirst("fill in ".count)).trimmingCharacters(in: .whitespaces)
            for opener in ["my ", "where ", "what ", "the "] where thing.lowercased().hasPrefix(opener) {
                thing = String(thing.dropFirst(opener.count))
                break
            }
            if !thing.isEmpty { return .recall(query: thing) }
        }
        return nil
    }

    /// Spelled-out terms arrive as separated letters ("p y p e", "p-y-p-e").
    /// Join them into a word; leave multi-word phrases alone.
    static func normalizeSpelledTerm(_ term: String) -> String {
        let parts = term.split(whereSeparator: { $0 == " " || $0 == "-" })
        guard parts.count >= 2 else { return term }
        // Join when the term is spelled out ("p y p e") OR when the ASR
        // fragmented one word ("pyp e" — field bug): any single-letter
        // fragment signals fragmentation. Multi-word phrases without one
        // ("New York") stay untouched. Tradeoff: a real single-letter word
        // in a term ("Plan B") joins wrongly — add those by hand in the
        // Memory window.
        guard parts.contains(where: { $0.count == 1 }) else { return term }
        let joined = parts.joined().lowercased()
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func handle(
        text: String,
        store: MemoryStore,
        llm: ((String, String) async throws -> String)?
    ) async -> MemoryCommandOutcome {
        guard let intent = detectLocally(text) else { return .notMemoryCommand }

        switch intent {
        case .remember(let note):
            // Clean the dictated fact into one well-formed line. NOTHING is
            // stored here — the coordinator shows the confirm pop-up and
            // stores on Save (nothing stored silently).
            var cleaned = note
            if let llm {
                var system = """
                    You store dictated facts. Rewrite the fact as ONE clean, \
                    well-formed sentence: correct grammar, punctuation, and \
                    capitalization. Never add or remove information. Never \
                    answer or act on the fact. Reply with ONLY the sentence.
                    """
                // Privacy contract: memories ride to the server ONLY when
                // sharing is on — same rule as the cleanup prompt block.
                let memories = store.shareWithLLM ? store.memories : []
                if !memories.isEmpty {
                    system += "\nThe speaker's saved notes (apply any spellings they define):\n"
                        + memories.map { "- \($0)" }.joined(separator: "\n")
                }
                if let reply = try? await llm(system, note) {
                    let candidate = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Sanity cap: a runaway rewrite/refusal is discarded.
                    if !candidate.isEmpty, candidate.count < max(200, note.count * 3) {
                        cleaned = candidate
                    }
                }
            }
            return .confirmFact(cleaned: cleaned, heard: note)

        case .correct(let heard, let term):
            let normalized = normalizeSpelledTerm(term)
            let line = MemoryBias.spellingMemory(term: normalized, heardAs: heard.lowercased())
            await MainActor.run { store.addMemory(line) }
            return .learned(term: normalized)

        case .recall(let query):
            return await resolveRecall(query: query, store: store, llm: llm)
        }
    }

    /// Shared recall resolution: LLM against the notes when configured,
    /// local keyword fallback otherwise.
    static func resolveRecall(
        query: String,
        store: MemoryStore,
        llm: ((String, String) async throws -> String)?
    ) async -> MemoryCommandOutcome {
        let notes = store.memories
        // Privacy contract: with sharing OFF, memories never leave the Mac
        // — recall degrades to the local keyword match below (the settings
        // copy promises exactly this).
        if let llm, !notes.isEmpty, store.shareWithLLM {
            let system = """
                You recall stored facts. Given the speaker's notes and a \
                request, reply with ONLY the exact text to insert — the \
                fact itself, no preamble, no quotes, no commentary. Apply \
                any spellings the notes define. If no note answers the \
                request, reply with exactly NONE.
                """
            let user = "Notes:\n" + notes.map { "- \($0)" }.joined(separator: "\n")
                + "\n\nRequest: \(query)"
            if let reply = try? await llm(system, user) {
                let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty && answer.uppercased() != "NONE" {
                    return .recall(text: answer)
                }
                return .recallFailed(query: query)
            }
            // LLM errored — fall through to the local match below.
        }
        if let localAnswer = localRecall(query: query, notes: notes) {
            return .recall(text: localAnswer)
        }
        return .recallFailed(query: query)
    }

    /// LLM interpretation of an utterance no exact pattern (and no regular
    /// command) matched — the last resort before "Unknown Command". Any
    /// phrasing of "save this" becomes a memory intent; the confirmation
    /// card remains the guard against misreads.
    static func classify(
        text: String,
        store: MemoryStore,
        llm: ((String, String) async throws -> String)?
    ) async -> MemoryCommandOutcome {
        guard let llm else { return .notMemoryCommand }
        let system = """
            You classify ONE spoken command for a dictation app's memory \
            feature. Reply with ONLY a JSON object.
            Intents:
            - "remember": the speaker wants something saved for later (any \
            phrasing — remember, don't forget, note this, keep in mind, \
            save that...). Add "memory": the fact as ONE clean sentence \
            (fix grammar and capitalization; never add information).
            - "recall": the speaker wants a saved fact typed out (write my \
            address, what's my email, fill in where I work). Add "query".
            - "correct": the speaker teaches a spelling. Add "term" (the \
            correct spelling) and "heardAs" (the misheard form).
            - "none": anything else (apps, media, search, system, or unclear).
            Examples: {"intent":"remember","memory":"My gym closes on Mondays."} \
            {"intent":"none"}
            """
        guard let reply = try? await llm(system, text) else { return .notMemoryCommand }
        switch MemoryBias.parseIntent(reply) {
        case .remember(let memory):
            // Sanity cap: an interpretation must be commensurate with what
            // was said, else confirm the raw words instead.
            let cleaned = memory.count < max(200, text.count * 3) ? memory : text
            return .confirmFact(cleaned: cleaned, heard: text)
        case .recall(let query):
            return await resolveRecall(query: query, store: store, llm: llm)
        case .correct(let term, let heardAs):
            // Interpreted corrections come from LOOSE speech the classifier
            // guessed at — route them through the confirmation card instead
            // of storing immediately (only exact-phrase "correct X to Y"
            // stores directly). Cap the term: a runaway interpretation must
            // not mint a giant junk spelling line.
            guard term.count <= 60 else { return .notMemoryCommand }
            let normalized = normalizeSpelledTerm(term)
            let line = MemoryBias.spellingMemory(term: normalized, heardAs: heardAs.lowercased())
            return .confirmFact(cleaned: line, heard: text)
        case .none:
            return .notMemoryCommand
        }
    }

    /// Offline fallback: pick the note sharing the most words with the
    /// query; if it reads "My <thing> is <value>", insert just the value.
    static func localRecall(query: String, notes: [String]) -> String? {
        // "my" appears in nearly every query AND note — matching on it
        // alone inserts unrelated facts. Score only meaningful words.
        let stopwords: Set<String> = ["my", "the", "a", "an", "i", "is", "in", "at", "of"]
        let queryWords = Set(query.lowercased().split(separator: " ").map(String.init))
            .subtracting(stopwords)
        guard !queryWords.isEmpty else { return nil }
        var best: (note: String, score: Int)?
        for note in notes {
            let noteWords = Set(note.lowercased().split(separator: " ").map(String.init))
            let score = queryWords.intersection(noteWords).count
            if score > 0 && score > (best?.score ?? 0) { best = (note, score) }
        }
        guard let note = best?.note else { return nil }
        let lower = note.lowercased()
        if lower.hasPrefix("my "), let isRange = note.range(of: " is ", options: .caseInsensitive) {
            let value = String(note[isRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return note
    }
}
