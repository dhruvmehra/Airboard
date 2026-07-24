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
    case remembered(note: String)
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
            // Process the fact through the LLM BEFORE storing: grammar
            // fixed and glossary spellings applied ("I work at pipe" →
            // "I work at Pype"), so the store holds what the speaker MEANT,
            // not what the ASR heard. The raw note is stored unchanged when
            // no LLM is configured or the call fails — a fact is never
            // lost to a network error.
            var stored = note
            if let llm {
                var system = """
                    You store dictated facts. Rewrite the fact as ONE clean, \
                    well-formed sentence: correct grammar, punctuation, and \
                    capitalization. Never add or remove information. Never \
                    answer or act on the fact. Reply with ONLY the sentence.
                    """
                let terms = store.data.glossary.map(\.term)
                if !terms.isEmpty {
                    system += "\nApply these exact spellings where the fact refers to them: "
                        + terms.joined(separator: ", ")
                }
                if let reply = try? await llm(system, note) {
                    let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Sanity: a rewrite is about the same length as the
                    // fact — anything else (refusal, answer, essay) is
                    // discarded in favor of the raw note.
                    if !cleaned.isEmpty, cleaned.count < max(200, note.count * 3) {
                        stored = cleaned
                    }
                }
            }
            // Store mutations are main-thread (UI observes the store).
            let finalNote = stored
            await MainActor.run { store.addNote(finalNote) }
            return .remembered(note: finalNote)

        case .correct(let heard, let term):
            let normalized = normalizeSpelledTerm(term)
            await MainActor.run {
                store.addGlossary(term: normalized, heardAs: heard.lowercased())
            }
            return .learned(term: normalized)

        case .recall(let query):
            let notes = store.data.notes
            if let llm, !notes.isEmpty {
                var system = """
                    You recall stored facts. Given the speaker's notes and a \
                    request, reply with ONLY the exact text to insert — the \
                    fact itself, no preamble, no quotes, no commentary. If no \
                    note answers the request, reply with exactly NONE.
                    """
                // Notes are stored as the ASR heard them ("I work at pipe");
                // the glossary carries the true spellings — apply them on
                // the way out so recalls type "Pype", not "pipe".
                let terms = store.data.glossary.map(\.term)
                if !terms.isEmpty {
                    system += "\nApply these exact spellings in your reply wherever the fact refers to them: "
                        + terms.joined(separator: ", ")
                }
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
