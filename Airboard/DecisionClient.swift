//
//  DecisionClient.swift
//
//  Calls the OpenRouter Decisions API (Jev first, Mercury Decide if Jev
//  errors with time left). Hard deadline: returns nil when the answer
//  can't arrive in time — the caller then falls back. Never throws.
//  The key is passed in (read from the Keychain by the caller); it is
//  never logged. Foundation-only: compiles standalone for scratch tests.
//

import Foundation

nonisolated struct DecisionClient: Sendable {
    let apiKey: String
    var models: [String] = ["typesafe/jev-1.13", "inception/mercury-decide:free"]
    var session: URLSession = .shared

    /// Probability of "yes" per question id, or nil on timeout/failure.
    func ask(state: [String: String], questions: [DecisionQuestion], deadline: TimeInterval) async -> [String: Double]? {
        guard !questions.isEmpty, !apiKey.isEmpty else { return nil }
        let start = Date()
        return await withTaskGroup(of: [String: Double]?.self) { group in
            group.addTask {
                for model in models {
                    let left = deadline - Date().timeIntervalSince(start)
                    guard left > 0.05 else { return nil }
                    if let answers = await call(model: model, state: state, questions: questions, timeout: left),
                       !answers.isEmpty {
                        return answers
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func call(model: String, state: [String: String], questions: [DecisionQuestion],
                      timeout: TimeInterval) async -> [String: Double]? {
        guard let body = DecisionWire.body(model: model, state: state, questions: questions) else { return nil }
        var req = URLRequest(url: DecisionWire.endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://github.com/dhruvmehra/Airboard", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Airboard", forHTTPHeaderField: "X-Title")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return DecisionWire.parse(data)
    }
}
