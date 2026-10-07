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
        // Snapshot once the insertion has landed (paste restores the
        // clipboard at 0.5s; typed text is already there).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, gen == self.generation,
                  let field = AXText.focusedElement(pid: pid), !AXText.isSecure(field),
                  let before = AXText.string(field, kAXValueAttribute),
                  before.contains(inserted) else { return }
            for delay in Self.checkDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, gen == self.generation,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                          !TranscriptionCoordinator.shared.isRecording,
                          let now = AXText.focusedElement(pid: pid), CFEqual(now, field),
                          let after = AXText.string(field, kAXValueAttribute) else { return }
                    if let c = EditDiff.correction(before: before, after: after, inserted: inserted) {
                        self.generation += 1   // one lesson per insertion
                        onCorrection(c)
                    }
                }
            }
        }
    }
}
