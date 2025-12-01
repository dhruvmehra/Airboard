//
//  CorrectionDetector.swift
//  murmur
//
//  Created by Dhruv Mehra on 02/12/25.
//


//
//  CorrectionDetector.swift
//  murmur
//
//  Detects and removes self-corrections from transcribed text
//

import Foundation

class CorrectionDetector {
    
    // Common correction phrases
    private static let correctionPhrases = [
        "no no",
        "wait wait",
        "sorry",
        "i mean",
        "actually",
        "scratch that",
        "never mind",
        "correction",
        "oops"
    ]
    
    /// Removes self-corrections from transcribed text
    static func cleanCorrections(_ text: String) -> String {
        let cleaned = text.lowercased()
        
        // Pattern 1: "X no no Y" → Keep only Y
        if let corrected = handleNoNoPattern(cleaned) {
            return capitalizeFirstLetter(corrected)
        }
        
        // Pattern 2: "X sorry Y" or "X I mean Y" → Keep only Y
        if let corrected = handleCorrectionPhrases(cleaned) {
            return capitalizeFirstLetter(corrected)
        }
        
        // No corrections detected, return original
        return text
    }
    
    /// Handles "no no" pattern: "2 burgers no no 1 burger" → "1 burger"
    private static func handleNoNoPattern(_ text: String) -> String? {
        // Look for "no no" or "no wait" or "wait no"
        let patterns = [
            "no no",
            "no wait",
            "wait no",
            "wait wait"
        ]
        
        for pattern in patterns {
            if let range = text.range(of: pattern) {
                // Take everything after the correction phrase
                let afterCorrection = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                
                // If there's meaningful content after, use it
                if afterCorrection.split(separator: " ").count >= 2 {
                    return afterCorrection
                }
            }
        }
        
        return nil
    }
    
    /// Handles phrases like "sorry" or "I mean"
    private static func handleCorrectionPhrases(_ text: String) -> String? {
        let phrases = [
            "sorry",
            "i mean",
            "actually",
            "scratch that"
        ]
        
        for phrase in phrases {
            if let range = text.range(of: phrase) {
                let afterPhrase = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                
                // Only use if there's substantial content after
                if afterPhrase.split(separator: " ").count >= 3 {
                    return afterPhrase
                }
            }
        }
        
        return nil
    }
    
    /// Removes filler words that often accompany corrections
    static func removeFiller(_ text: String) -> String {
        var cleaned = text
        
        let fillers = [
            " um ",
            " uh ",
            " er ",
            " ah ",
            " like ",
            " you know "
        ]
        
        for filler in fillers {
            cleaned = cleaned.replacingOccurrences(of: filler, with: " ", options: .caseInsensitive)
        }
        
        // Clean up multiple spaces
        cleaned = cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
    
    private static func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
