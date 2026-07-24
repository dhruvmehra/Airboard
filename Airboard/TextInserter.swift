//
//  TextInserter.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//


import Foundation
import ApplicationServices
import AppKit

enum TextInsertionError: Error {
    case accessibilityPermissionDenied
    case noFrontmostApp
    case eventCreationFailed
    case insertionFailed(String)
}

class TextInserter {

    static func insertText(_ text: String, context: AppContext? = nil) -> Result<Void, TextInsertionError> {
        // Check if we have accessibility permission
        guard AXIsProcessTrusted() else {
            print("❌ Accessibility permission not granted")
            return .failure(.accessibilityPermissionDenied)
        }

        // Verify frontmost app exists
        guard NSWorkspace.shared.frontmostApplication != nil else {
            print("❌ No frontmost application")
            return .failure(.noFrontmostApp)
        }
        
        print("🔤 Text to insert: '\(text)'")

        // Check if we need to add a space before inserting
        let needsLeadingSpace = shouldAddLeadingSpace()
        print("🔍 Needs leading space: \(needsLeadingSpace)")

        var finalText = text
        if needsLeadingSpace {
            finalText = " " + finalText
            print("➕ Adding leading space")
        }

        print("✅ Final text to insert: '\(finalText)'")

        // Small delay to ensure the app is ready
        usleep(100000) // 0.1 seconds

        // Multi-line text typed as keystrokes triggers editors' auto-list
        // continuation (typing "- item⏎" makes the app add its own bullet,
        // doubling ours), and characters outside our key map (curly quotes,
        // em dashes — common in LLM output) can't be typed at all. Paste
        // handles both: editors treat pasted text as literal.
        if finalText.contains("\n") || finalText.contains(where: { keyCodeForCharacter($0) == nil }) {
            let result = pasteText(finalText)
            if case .success = result { recordInsertion(finalText) }
            return result
        }

        // Type each character with error checking
        for character in finalText {
            if let error = typeCharacter(character) {
                print("❌ Failed to type character '\(character)': \(error)")
                return .failure(.insertionFailed("Failed to type character '\(character)'"))
            }
        }

        print("✅ Finished inserting text")
        recordInsertion(finalText)
        return .success(())
    }

    /// Insert via clipboard paste, preserving whatever the user had copied.
    private static func pasteText(_ text: String) -> Result<Void, TextInsertionError> {
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Cmd+V (key code 9 = "v")
        guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            print("❌ Failed to create paste events")
            return .failure(.eventCreationFailed)
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        // Restore the user's clipboard once the paste has landed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let savedClipboard {
                pasteboard.setString(savedClipboard, forType: .string)
            }
        }

        print("✅ Inserted via paste (multi-line or special characters)")
        return .success(())
    }
    
    // Chars that want a space after them before new text starts.
    private static let spaceableChars: Set<Character> =
        [".", ",", "!", "?", ";", ":", ")", "]", "\"", "'"]

    private static func isSpaceable(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || spaceableChars.contains(c)
    }

    /// What we last inserted, and where. Terminal-style apps (Ghostty,
    /// Claude Code) report the cursor as position 0 regardless of reality,
    /// so when AX can't tell us the char before the cursor, the only
    /// trustworthy signal is our own history: if WE just put text ending
    /// in a word character into this same app, the user is chaining
    /// utterances and needs a separating space.
    private static var lastInsertion: (pid: pid_t, spaceable: Bool, at: Date)?

    static func recordInsertion(_ text: String) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let last = text.last else { return }
        lastInsertion = (pid, isSpaceable(last), Date())
    }

    /// Fallback when the char before the cursor is unknowable: chain-space
    /// only after OUR OWN recent insertion into the same app. A fresh
    /// dictation (new prompt, different app, or after the window expires)
    /// gets no space — that was the old "every dictation starts with a
    /// stray space" bug, which guessed from the field's last character.
    private static func chainedInsertionNeedsSpace() -> Bool {
        guard let last = lastInsertion,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              last.pid == pid,
              last.spaceable,
              Date().timeIntervalSince(last.at) < 30 else { return false }
        print("  🔗 Chaining after our own insertion — adding space")
        return true
    }

    /// Add a separating space when the character before the cursor needs
    /// one. Prefers actually READING that character via AX; when the app
    /// won't reveal the cursor (terminals report position 0), falls back
    /// to the chained-insertion signal above.
    private static func shouldAddLeadingSpace() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let app = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            print("  ❌ No focused element")
            return chainedInsertionNeedsSpace()
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else {
            print("  ❌ Empty field — no leading space")
            return false
        }

        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let rangeValue = selectedRangeValue as! AXValue? else {
            print("  ❌ Cursor position unreadable")
            return chainedInsertionNeedsSpace()
        }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            return chainedInsertionNeedsSpace()
        }
        // range.location = cursor, or the START of a selection (typed text
        // replaces the selection, so the char BEFORE it is what matters).
        let cursorPosition = range.location
        guard cursorPosition > 0 && cursorPosition <= text.count else {
            // Position 0 in a non-empty buffer is how terminals lie about
            // the cursor — treat it as unknown, not as "at the start".
            print("  ❌ Cursor reported at start of non-empty text")
            return chainedInsertionNeedsSpace()
        }

        let index = text.index(text.startIndex, offsetBy: cursorPosition - 1)
        let charBeforeCursor = text[index]
        print("  📍 Char before cursor: '\(charBeforeCursor)'")

        // Space only after word characters and sentence-closing punctuation.
        // Never after whitespace, and never after openers like ( [ " — a
        // space there splits the construct the user is typing into.
        return isSpaceable(charBeforeCursor)
    }

    private static func typeCharacter(_ character: Character) -> TextInsertionError? {
        // Handle special characters
        if character == "\n" {
            // Press Return key
            return pressKey(keyCode: 36)
        }

        // For regular characters, simulate typing
        guard let keyCode = keyCodeForCharacter(character) else {
            print("⚠️ Could not find key code for character: '\(character)'")
            return .insertionFailed("No key code for character '\(character)'")
        }

        let needsShift = character.isUppercase || "!@#$%^&*()_+{}|:\"<>?".contains(character)

        let result: TextInsertionError?
        if needsShift {
            result = pressKeyWithShift(keyCode: keyCode)
        } else {
            result = pressKey(keyCode: keyCode)
        }

        // Small delay between characters for reliability
        usleep(5000) // 0.005 seconds

        return result
    }
    
    private static func pressKey(keyCode: CGKeyCode) -> TextInsertionError? {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            print("❌ Failed to create keyboard events for keyCode: \(keyCode)")
            return .eventCreationFailed
        }

        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        return nil
    }

    private static func pressKeyWithShift(keyCode: CGKeyCode) -> TextInsertionError? {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            print("❌ Failed to create keyboard events for keyCode: \(keyCode)")
            return .eventCreationFailed
        }

        keyDownEvent.flags = .maskShift
        keyUpEvent.flags = []

        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        return nil
    }
    
    private static func keyCodeForCharacter(_ character: Character) -> CGKeyCode? {
        let char = String(character).lowercased().first ?? character
        
        // Map of characters to key codes (including shifted punctuation)
        let keyMap: [Character: CGKeyCode] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
            "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
            "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
            "w": 13, "x": 7, "y": 16, "z": 6,
            
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25,
            
            " ": 49, // Space
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
            ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
            "`": 50,
            
            // Shifted punctuation (uses same key codes as their base keys)
            "!": 18, // Shift+1
            "@": 19, // Shift+2
            "#": 20, // Shift+3
            "$": 21, // Shift+4
            "%": 23, // Shift+5
            "^": 22, // Shift+6
            "&": 26, // Shift+7
            "*": 28, // Shift+8
            "(": 25, // Shift+9
            ")": 29, // Shift+0
            "_": 27, // Shift+-
            "+": 24, // Shift+=
            "{": 33, // Shift+[
            "}": 30, // Shift+]
            "|": 42, // Shift+\
            ":": 41, // Shift+;
            "\"": 39, // Shift+'
            "<": 43, // Shift+,
            ">": 47, // Shift+.
            "?": 44, // Shift+/
            "~": 50  // Shift+`
        ]
        
        return keyMap[char]
    }
}
