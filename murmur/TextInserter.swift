//
//  TextInserter.swift
//  murmur
//
//  Created by Dhruv Mehra on 01/12/25.
//


import Foundation
import ApplicationServices
import AppKit

class TextInserter {
    
    static func insertText(_ text: String) {
        // Check if we have accessibility permission
        guard AXIsProcessTrusted() else {
            print("❌ Accessibility permission not granted")
            return
        }
        
        print("✅ Inserting text: \(text)")
        
        // Small delay to ensure the app is ready
        usleep(100000) // 0.1 seconds
        
        // Type each character
        for character in text {
            typeCharacter(character)
        }
    }
    
    private static func typeCharacter(_ character: Character) {
        _ = String(character)
        
        // Handle special characters
        if character == "\n" {
            // Press Return key
            pressKey(keyCode: 36) // Return key
            return
        }
        
        // For regular characters, simulate typing
        guard let keyCode = keyCodeForCharacter(character) else {
            print("⚠️ Could not find key code for character: \(character)")
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
