//
//  CorrectionWatcher.swift
//
//  After an insertion, re-reads the SAME field at ~2s, 5s and 10s. If the
//  user fixed a word or two inside what we typed, hands the correction to
//  VocabularyLearning. Stops on app switch, focus moving to another field
//  (a chat box cleared after send is not "a fix"), a new recording, a
//  learned correction, or an unreadable/secure field (terminals: nothing).
//

import AppKit

final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    private var generation = 0
    static let checkDelays: [TimeInterval] = [2, 5, 10]

    func cancel() { generation += 1 }

    func observe(inserted: String, pid: pid_t, onCorrection: @escaping (EditDiff.Correction) -> Void) {
        generation += 1
        let gen = generation
        // Usually already done at recording start; a no-op after the first call.
        if let app = NSRunningApplication(processIdentifier: pid) { AXText.enableWebAccessibility(for: app) }
        // Snapshot once the insertion has landed (paste restores the
        // clipboard at 0.5s; typed text is already there).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, gen == self.generation else { return }
            // Diagnostics: stage names and sizes only — never the user's text.
            guard let field = AXText.focusedElement(pid: pid) else {
                print("👀 Watcher: no focused field readable — skipping"); return
            }
            guard !AXText.isSecure(field) else { print("👀 Watcher: secure field — skipping"); return }
            guard let before = AXText.string(field, kAXValueAttribute) else {
                print("👀 Watcher: field has no readable text (app hides it) — skipping"); return
            }
            guard before.contains(inserted) else {
                print("👀 Watcher: our text not found in field (\(before.count) chars) — skipping"); return
            }
            print("👀 Watcher: watching field (\(before.count) chars) for a fix")
            for delay in Self.checkDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    let t = Int(delay)
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        print("👀 Watcher @\(t)s: app switched — stopped"); return
                    }
                    guard !TranscriptionCoordinator.shared.isRecording else {
                        print("👀 Watcher @\(t)s: recording — stopped"); return
                    }
                    guard let now = AXText.focusedElement(pid: pid), CFEqual(now, field) else {
                        print("👀 Watcher @\(t)s: focus moved to another field — stopped"); return
                    }
                    guard let after = AXText.string(field, kAXValueAttribute) else {
                        print("👀 Watcher @\(t)s: field unreadable"); return
                    }
                    if after == before { print("👀 Watcher @\(t)s: no change yet"); return }
                    if let c = EditDiff.correction(before: before, after: after, inserted: inserted) {
                        print("👀 Watcher @\(t)s: correction found (\(c.heard.split(separator: " ").count)→\(c.corrected.split(separator: " ").count) words)")
                        self.generation += 1   // one lesson per insertion
                        onCorrection(c)
                    } else {
                        print("👀 Watcher @\(t)s: field changed, but not a small sound-alike fix inside our text")
                    }
                }
            }
        }
    }
}
