//
//  AXText.swift
//
//  Read-only-by-default Accessibility helpers for vocabulary learning:
//  the focused field's text, a bounded walk of the focused window's text
//  (off-main, 100ms per-call timeout), and one in-place word replacement
//  that restores the user's cursor. Secure (password) fields are
//  never read. Uses the Accessibility permission Airboard already holds —
//  no keystroke capture.
//

import AppKit
import ApplicationServices

enum AXText {

    /// Every AX call to another app waits at most this long — a hung app
    /// can't stall Airboard (the system default is ~6s).
    nonisolated static let messagingTimeout: Float = 0.1

    nonisolated static func appElement(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    nonisolated static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = appElement(pid: pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    nonisolated static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// The focused field's full text; nil if unreadable or secure.
    static func focusedFieldText(pid: pid_t) -> String? {
        guard let el = focusedElement(pid: pid), !isSecure(el) else { return nil }
        return string(el, kAXValueAttribute)
    }

    /// Replace `span` inside the text WE inserted (whole words only, via
    /// EditDiff.spanRange) in the given element, then put the user's cursor
    /// back where it was. Returns false and leaves the field untouched when
    /// the insertion is gone or the app refuses.
    @discardableResult
    static func replaceInsertedSpan(span: String, with term: String, inserted: String,
                                    in el: AXUIElement) -> Bool {
        guard !isSecure(el),
              let text = string(el, kAXValueAttribute),
              let r = EditDiff.spanRange(span: span, inserted: inserted, field: text) else { return false }
        // Remember the user's cursor/selection.
        var original: CFTypeRef?
        let hadRange = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &original) == .success
        func restore(shiftBy delta: Int) {
            guard hadRange, let original, CFGetTypeID(original) == AXValueGetTypeID() else { return }
            var cf = CFRange()
            guard AXValueGetValue(original as! AXValue, .cfRange, &cf) else { return }
            if delta != 0 && cf.location > NSRange(r, in: text).location { cf.location += delta }
            if let v = AXValueCreate(.cfRange, &cf) {
                AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
            }
        }
        let ns = NSRange(r, in: text)
        var cf = CFRange(location: ns.location, length: ns.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success
        else { return false }
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, term as CFString) == .success else {
            restore(shiftBy: 0)   // never leave the word selected for the next keystroke to delete
            return false
        }
        restore(shiftBy: (term as NSString).length - ns.length)
        return true
    }

    /// Visible text of the focused window: a breadth-first walk collecting
    /// AXValue/AXTitle/AXDescription strings, skipping secure fields.
    /// Bounded (nodes and characters) so a huge web page can't stall us.
    /// Safe to call OFF the main thread (the harvester does). `shouldStop`
    /// is polled per node so a starting recording aborts the walk.
    nonisolated static func windowText(pid: pid_t, maxNodes: Int = 1500, maxChars: Int = 20_000,
                                       shouldStop: () -> Bool = { false }) -> String {
        let app = appElement(pid: pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return "" }
        var queue: [AXUIElement] = [window as! AXUIElement]
        var parts: [String] = []
        var chars = 0, visited = 0
        while !queue.isEmpty && visited < maxNodes && chars < maxChars && !shouldStop() {
            let el = queue.removeFirst()
            visited += 1
            if isSecure(el) { continue }
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = string(el, attr), !s.isEmpty {
                    parts.append(s); chars += s.count
                }
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let children = kids as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return String(parts.joined(separator: "\n").prefix(maxChars))
    }

    nonisolated static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
