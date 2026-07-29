//
//  TelemetryService.swift
//
//  Anonymous performance telemetry via TelemetryDeck. HARD GATES — all
//  must hold or every call is a no-op:
//    1. production bundle (com.pype.airboard) — dev builds never send
//    2. "Share anonymous performance stats" toggle on (default true)
//    3. a real App ID in Info.plist (TelemetryDeckAppID != UNSET/empty)
//  Never any transcript text: signals carry numbers and fixed enum
//  strings only. signal() enqueues to the SDK's disk-backed batch queue
//  off-thread — telemetry cannot delay a dictation by construction.
//

import Foundation
import TelemetryDeck

final class TelemetryService {
    static let shared = TelemetryService()

    static let shareKey = "shareAnalytics"

    var sharingEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.shareKey) as? Bool ?? true
    }
    func setSharingEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.shareKey)
    }

    private let active: Bool
    private let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    private init() {
        let isProd = Bundle.main.bundleIdentifier == "com.pype.airboard"
        let appID = Bundle.main.infoDictionary?["TelemetryDeckAppID"] as? String ?? ""
        let configured = !appID.isEmpty && appID != "UNSET"
        active = isProd && configured
        guard active else { return }
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    private func send(_ name: String, parameters: [String: String] = [:], floatValue: Double? = nil) {
        guard active, sharingEnabled else { return }
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }

    func appLaunched() {
        send("app.launched", parameters: [
            "appVersion": appVersion,
            "modelVersion": "parakeet-tdt-0.6b-v3",
        ])
    }

    func dictationCompleted(record: DictationRecord) {
        send("dictation.stt",
             parameters: ["mode": record.mode,
                          "llmOutcome": record.llmOutcome,
                          "appVersion": appVersion],
             floatValue: Double(record.sttMs))
        if let llmMs = record.llmMs {
            send("dictation.llm",
                 parameters: ["llmOutcome": record.llmOutcome,
                              "appVersion": appVersion],
                 floatValue: Double(llmMs))
        }
    }

    func assistantAsked(durationMs: Int, outcome: String) {
        send("assistant.ask",
             parameters: ["outcome": outcome, "appVersion": appVersion],
             floatValue: Double(durationMs))
    }
}
