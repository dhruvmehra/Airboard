//
//  CorrectionWatcher.swift
//
//  After an insertion, keeps an eye on the field we typed into for ~60s
//  and hands any name fix the user makes inside OUR text to
//  VocabularyLearning. All timing/lifecycle decisions live in the pure
//  CorrectionWatchPolicy; this file only does the Accessibility I/O:
//
//  - Every AX call runs on a private utility queue with a 100ms messaging
//    timeout — never on the main thread, so a slow or hung app can't
//    delay a hotkey press. The main thread only enqueues events.
//  - Readings: the policy's schedule (≈20 per insertion), each = one
//    AXValue read + one focused-element read. Fields are read once per
//    tick however many insertions they hold.
//  - Where the app posts AXValueChanged (Cocoa, WebKit; Chromium/Electron
//    often doesn't), an AXObserver makes edits visible within ~1s; its
//    callback does nothing but enqueue. Where it doesn't, polling alone.
//  - Secure fields are never watched. Logs carry stages and sizes only —
//    never the user's text.
//

import AppKit
import ApplicationServices

nonisolated final class CorrectionWatcher: @unchecked Sendable {
    static let shared = CorrectionWatcher()

    typealias Lesson = CorrectionWatchPolicy.Lesson

    private let queue = DispatchQueue(label: "com.pype.airboard.correction-watch", qos: .utility)

    // Touched only on `queue`.
    private var policy = CorrectionWatchPolicy()
    private var fields: [Int: (element: AXUIElement, pid: pid_t)] = [:]
    private var nextFieldID = 0
    private var timer: DispatchSourceTimer?
    private var timerFiresAt: Date?
    private var onLesson: (@MainActor @Sendable (Lesson) -> Void)?
    private var observers: [pid_t: AXObserver] = [:]

    // Frontmost app, kept current from the main thread.
    private let frontLock = NSLock()
    private var frontPID: pid_t = 0

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            CorrectionWatcher.shared.setFront(app?.processIdentifier ?? 0)
        }
    }

    // MARK: - Events (any thread; cheap)

    /// Our text just landed in app `pid` (frontmost). The field is
    /// captured 0.3s later, once a paste has settled.
    func observe(inserted: String, pid: pid_t, onLesson: @escaping @MainActor @Sendable (Lesson) -> Void) {
        setFront(pid)
        queue.asyncAfter(deadline: .now() + 0.3) { [self] in
            self.onLesson = onLesson
            start(inserted: inserted, pid: pid)
        }
    }

    /// A recording is starting: earlier insertions stay watched; each
    /// watched field gets one read now (a fix made just before this
    /// dictation is already there).
    func recordingStarted() {
        queue.async { [self] in policy.recordingStarted(); reschedule() }
    }

    /// Feature turned off: stop everything.
    func cancel() {
        queue.async { [self] in
            let ids = policy.cancelAll()
            if !ids.isEmpty { print("👀 Watcher: cancelled \(ids.count) watch(es)") }
            prune(); reschedule()
        }
    }

    // MARK: - Queue work

    private func start(inserted: String, pid: pid_t) {
        guard let el = AXText.focusedElement(pid: pid) else {
            print("👀 Watcher: no focused field readable — skipping"); return
        }
        AXUIElementSetMessagingTimeout(el, AXText.messagingTimeout)
        guard !AXText.isSecure(el) else { print("👀 Watcher: secure field — skipping"); return }
        guard let text = AXText.string(el, kAXValueAttribute) else {
            print("👀 Watcher: field has no readable text (app hides it) — skipping"); return
        }
        let fid = fieldID(for: el, pid: pid)
        let r = policy.inserted(fieldID: fid, text: inserted, fieldText: text, at: Date())
        guard r.id != nil else {
            print("👀 Watcher: our text not found in field (\(text.count) chars) or field too large — skipping")
            prune(); return
        }
        if !r.evicted.isEmpty { print("👀 Watcher: \(r.evicted.count) older watch(es) pushed out") }
        print("👀 Watcher: watching \(policy.entries.count) insertion(s) in \(policy.watchedFields.count) field(s) for \(Int(policy.config.window))s (field \(text.count) chars)")
        watchValueChanges(fid)
        prune(); reschedule()
    }

    private func tick() {
        timerFiresAt = nil
        let now = Date()
        for fid in policy.fieldsDue(at: now) {
            guard let f = fields[fid] else { continue }
            let text = AXText.string(f.element, kAXValueAttribute)
            var focused = false
            if front() == f.pid, let el = AXText.focusedElement(pid: f.pid) { focused = CFEqual(el, f.element) }
            let r = policy.observe(fieldID: fid, text: text, focused: focused, at: now)
            for (_, why) in r.stopped { print("👀 Watcher: watch ended (\(why.rawValue))") }
            for lesson in r.lessons {
                let c = lesson.correction
                print("👀 Watcher: correction found (\(c.heard.split(separator: " ").count)→\(c.corrected.split(separator: " ").count) words)")
                if let cb = onLesson { Task { @MainActor in cb(lesson) } }
            }
        }
        let gone = policy.expire(now: now)
        if !gone.isEmpty { print("👀 Watcher: \(gone.count) watch(es) ended (window over)") }
        prune(); reschedule()
    }

    /// One timer for the next thing the policy wants. Kept when an earlier
    /// one is already set (AX events arrive per keystroke).
    private func reschedule() {
        guard let next = policy.nextCheck(now: Date()) else {
            timer?.cancel(); timer = nil; timerFiresAt = nil; return
        }
        if let at = timerFiresAt, timer != nil, at <= next { return }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(0, next.timeIntervalSinceNow), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        timerFiresAt = next
    }

    private func fieldID(for el: AXUIElement, pid: pid_t) -> Int {
        if let known = fields.first(where: { $0.value.pid == pid && CFEqual($0.value.element, el) }) { return known.key }
        nextFieldID += 1
        fields[nextFieldID] = (el, pid)
        return nextFieldID
    }

    // MARK: - AX value-changed (best effort)

    private func watchValueChanges(_ fid: Int) {
        guard let f = fields[fid] else { return }
        if observers[f.pid] == nil {
            var created: AXObserver?
            let made = AXObserverCreate(f.pid, { _, _, _, refcon in
                // Main run loop: just enqueue. refcon carries the field id.
                guard let refcon else { return }
                CorrectionWatcher.shared.valueChanged(fieldID: Int(bitPattern: refcon))
            }, &created)
            guard made == .success, let created else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            observers[f.pid] = created
        }
        guard let obs = observers[f.pid] else { return }
        let err = AXObserverAddNotification(obs, f.element, kAXValueChangedNotification as CFString,
                                            UnsafeMutableRawPointer(bitPattern: fid))
        if err != .success && err != .notificationAlreadyRegistered {
            print("👀 Watcher: app doesn't post edit events (\(err.rawValue)) — polling only")
        }
    }

    private func valueChanged(fieldID: Int) {
        queue.async { [self] in
            guard fields[fieldID] != nil else { return }
            policy.valueChanged(fieldID: fieldID, at: Date())
            reschedule()
        }
    }

    /// Forget fields no insertion lives in any more; drop their observers.
    private func prune() {
        let live = policy.watchedFields
        for (fid, f) in fields where !live.contains(fid) {
            if let obs = observers[f.pid] {
                AXObserverRemoveNotification(obs, f.element, kAXValueChangedNotification as CFString)
            }
            fields[fid] = nil
        }
        let livePIDs = Set(fields.values.map(\.pid))
        for (pid, obs) in observers where !livePIDs.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = nil
        }
    }

    // MARK: - Frontmost app

    private func setFront(_ pid: pid_t) { frontLock.lock(); frontPID = pid; frontLock.unlock() }
    private func front() -> pid_t { frontLock.lock(); defer { frontLock.unlock() }; return frontPID }
}
