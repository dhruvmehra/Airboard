//
//  AXText.swift
//
//  Read-only-by-default Accessibility helpers for vocabulary learning:
//  the focused field's text, a bounded walk of the focused window's text,
//  and a single in-place word replacement. Secure (password) fields are
//  never read. Uses the Accessibility permission Airboard already holds —
//  no keystroke capture.
//

import AppKit
import ApplicationServices

enum AXText {

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// The focused field's full text; nil if unreadable or secure.
    static func focusedFieldText(pid: pid_t) -> String? {
        guard let el = focusedElement(pid: pid), !isSecure(el) else { return nil }
        return string(el, kAXValueAttribute)
    }

    /// Replace the LAST occurrence of `span` in the focused field with `term`
    /// by selecting it and setting the selected text. Returns false (and
    /// changes nothing) when the app doesn't allow it.
    @discardableResult
    static func replaceInFocusedField(span: String, with term: String, pid: pid_t) -> Bool {
        guard let el = focusedElement(pid: pid), !isSecure(el),
              let text = string(el, kAXValueAttribute),
              let r = text.range(of: span, options: .backwards) else { return false }
        let ns = NSRange(r, in: text)
        var cf = CFRange(location: ns.location, length: ns.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
              AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, term as CFString) == .success
        else { return false }
        return true
    }

    /// Visible text of the focused window: a breadth-first walk collecting
    /// AXValue/AXTitle/AXDescription strings, skipping secure fields.
    /// Bounded (nodes and characters) so a huge web page can't stall us.
    static func windowText(pid: pid_t, maxNodes: Int = 1500, maxChars: Int = 20_000) -> String {
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return "" }
        var queue: [AXUIElement] = [window as! AXUIElement]
        var parts: [String] = []
        var chars = 0, visited = 0
        while !queue.isEmpty && visited < maxNodes && chars < maxChars {
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

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
