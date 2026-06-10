//
//  TypingActivityMonitor.swift
//  Airboard
//
//  Watches global typing activity and pulses the floating icon when the user
//  has been typing for a long stretch — a gentle reminder that dictation exists.
//

import AppKit

final class TypingActivityMonitor {
    static let shared = TypingActivityMonitor()

    private var monitor: Any?
    private var sessionStart: Date?
    private var lastKeystroke: Date?
    private var keystrokeCount = 0
    private var lastNudge: Date?

    // Tunables
    private let maxGap: TimeInterval = 3.0              // pause that ends a typing session
    private let sessionThreshold: TimeInterval = 45.0   // sustained typing required...
    private let keystrokeThreshold = 120                // ...and at least this many keys
    private let cooldown: TimeInterval = 30 * 60        // at most one nudge per 30 min

    private init() {}

    func start() {
        guard monitor == nil else { return }
        // Global monitors only receive events from OTHER apps, so Airboard's own
        // windows never count. Requires Accessibility (already granted for insertion).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeystroke(event)
        }
        print("⌨️ Typing activity monitor started")
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKeystroke(_ event: NSEvent) {
        // Ignore shortcut chords — only count real typing
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return
        }

        let now = Date()

        // A long pause resets the session
        if let last = lastKeystroke, now.timeIntervalSince(last) > maxGap {
            sessionStart = now
            keystrokeCount = 0
        }
        if sessionStart == nil {
            sessionStart = now
        }
        lastKeystroke = now
        keystrokeCount += 1

        guard let start = sessionStart,
              now.timeIntervalSince(start) >= sessionThreshold,
              keystrokeCount >= keystrokeThreshold else { return }

        if let last = lastNudge, now.timeIntervalSince(last) < cooldown { return }

        let coordinator = TranscriptionCoordinator.shared
        guard !coordinator.isRecording, !coordinator.isTranscribing else { return }

        lastNudge = now
        sessionStart = nil
        keystrokeCount = 0

        print("💡 Long typing detected — pulsing icon to suggest dictation")
        NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
    }
}
