//
//  TextInserter.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//


import Foundation
import ApplicationServices
import AppKit

class TextInserter {
    
    static func insertText(_ text: String, context: AppContext? = nil) {
        // Check if we have accessibility permission
        guard AXIsProcessTrusted() else {
            print("❌ Accessibility permission not granted")
            return
        }
        
        print("🔤 Original text: '\(text)'")
        
        // Use intelligent formatting with pattern detection
        var formattedText = text
        if let context = context {
            formattedText = IntelligentFormatter.format(text, context: context)
            print("📝 After formatting: '\(formattedText)'")
        }
        
        // Check if we need to add a space before inserting
        let needsLeadingSpace = shouldAddLeadingSpace()
        print("🔍 Needs leading space: \(needsLeadingSpace)")
        
        if needsLeadingSpace {
            formattedText = " " + formattedText
            print("➕ Adding leading space")
        }
        
        print("✅ Final text to insert: '\(formattedText)'")
        
        // Small delay to ensure the app is ready
        usleep(100000) // 0.1 seconds
        
        // Type each character
        for character in formattedText {
            typeCharacter(character)
        }
        
        print("✅ Finished inserting text")
    }
    
    private static func shouldAddLeadingSpace() -> Bool {
        // SIMPLIFIED: Use a more reliable method to check for text before cursor
        
        // Get the frontmost app
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            print("  ⚠️ No frontmost app")
            return false
        }
        
        let pid = frontmostApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        
        // Get focused UI element
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard result == .success, let element = focusedElement else {
            print("  ⚠️ No focused element (result: \(result.rawValue))")
            return false
        }
        
        // Method 1: Try to get selected text
        var selectedText: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)
        
        if selectedResult == .success, let text = selectedText as? String, !text.isEmpty {
            print("  📍 Selected text: '\(text)'")
            if let lastChar = text.last, !lastChar.isWhitespace && lastChar != "\n" {
                print("  ✅ Last char is non-whitespace: '\(lastChar)'")
                return true
            }
        }
        
        // Method 2: Try to get value (full text content)
        var value: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value)
        
        if valueResult == .success, let text = value as? String, !text.isEmpty {
            print("  📍 Field value length: \(text.count) chars")
            
            // Try to get selection range to find cursor position
            var selectedRangeValue: CFTypeRef?
            let rangeResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)
            
            if rangeResult == .success, let rangeValue = selectedRangeValue as! AXValue? {
                var range = CFRange()
                if AXValueGetValue(rangeValue, .cfRange, &range) {
                    let cursorPosition = range.location
                    print("  📍 Cursor position: \(cursorPosition) / \(text.count)")
                    
                    // Check character before cursor
                    if cursorPosition > 0 && cursorPosition <= text.count {
                        let index = text.index(text.startIndex, offsetBy: cursorPosition - 1)
                        let charBeforeCursor = text[index]
                        print("  📍 Char before cursor: '\(charBeforeCursor)'")
                        
                        if !charBeforeCursor.isWhitespace && charBeforeCursor != "\n" {
                            print("  ✅ Should add space!")
                            return true
                        } else {
                            print("  ❌ Already has space/newline")
                            return false
                        }
                    }
                }
            }
            
            // Fallback: If we have text but couldn't get cursor position,
            // check if the last character is non-whitespace
            if let lastChar = text.last, !lastChar.isWhitespace && lastChar != "\n" {
                print("  ✅ Fallback: Last char is non-whitespace: '\(lastChar)'")
                return true
            }
        }
        
        print("  ❌ No text found before cursor")
        return false
    }
    
    private static func typeCharacter(_ character: Character) {
        // Handle special characters
        if character == "\n" {
            // Press Return key
            pressKey(keyCode: 36)
            return
        }
        
        // For regular characters, simulate typing
        guard let keyCode = keyCodeForCharacter(character) else {
            print("⚠️ Could not find key code for character: '\(character)'")
            return
        }
        
        let needsShift = character.isUppercase || "!@#$%^&*()_+{}|:\"<>?".contains(character)
        
        if needsShift {
            pressKeyWithShift(keyCode: keyCode)
        } else {
            pressKey(keyCode: keyCode)
        }
        
        // Small delay between characters for reliability
        usleep(5000) // 0.005 seconds
    }
    
    private static func pressKey(keyCode: CGKeyCode) {
        let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
    
    private static func pressKeyWithShift(keyCode: CGKeyCode) {
        let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        
        keyDownEvent?.flags = .maskShift
        keyUpEvent?.flags = []
        
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
    
    private static func keyCodeForCharacter(_ character: Character) -> CGKeyCode? {
        let char = String(character).lowercased().first ?? character
        
        // Map of characters to key codes
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
            "`": 50
        ]
        
        return keyMap[char]
    }
}
