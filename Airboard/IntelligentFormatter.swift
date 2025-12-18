//
//  IntelligentFormatter.swift
//
//  Smart pattern detection and auto-formatting
//

import Foundation

class IntelligentFormatter {
    
    /// Main formatting function - detects patterns and applies intelligence
    static func format(_ text: String, context: AppContext) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else { return trimmed }
        
        print("🔍 Formatter input: '\(trimmed)'")
        print("🔍 Context: \(context.appType)")
        
        // STEP 0: Fix missing spaces after punctuation (Whisper bug)
        trimmed = fixMissingSpaces(trimmed)
        print("🔧 After space fix: '\(trimmed)'")
        
        // STEP 1: Check for explicit formatting commands FIRST
        // Only apply special formatting if clear patterns detected
        if let formatted = detectAndFormatPattern(trimmed, context: context) {
            print("✨ Applied pattern formatting")
            return formatted
        }
        
        // STEP 2: If NO special patterns, just do minimal cleanup
        // Don't auto-add periods or aggressive formatting for normal dictation
        let cleaned = minimalCleanup(trimmed)
        print("🧹 Applied minimal cleanup only")
        return cleaned
    }
    
    /// Fix missing spaces after punctuation (common Whisper bug)
    private static func fixMissingSpaces(_ text: String) -> String {
        var result = ""
        var previousChar: Character? = nil
        
        for char in text {
            // If previous char was punctuation and current is letter (no space), add space
            if let prev = previousChar {
                let isPunctuation = [".", "!", "?", ","].contains(prev)
                let isLetter = char.isLetter
                let needsSpace = isPunctuation && isLetter
                
                if needsSpace {
                    result.append(" ")
                }
            }
            
            result.append(char)
            previousChar = char
        }
        
        return result
    }
    
    /// Minimal cleanup - just capitalize first letter, no auto-punctuation
    private static func minimalCleanup(_ text: String) -> String {
        var result = text
        
        // Only capitalize first letter if it's clearly a sentence start
        if let first = result.first, first.isLowercase {
            // Check if it looks like start of sentence (not mid-sentence dictation)
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        
        // DON'T add periods automatically
        // DON'T force capitalization after periods
        // Just return the text as-is
        
        return result
    }
    
    // MARK: - Pattern Detection
    
    private static func detectAndFormatPattern(_ text: String, context: AppContext) -> String? {
        let lower = text.lowercased()
        
        // Only apply special formatting if EXPLICIT patterns detected
        
        // Detect bullet points (must have explicit indicators)
        if isBulletPointList(lower) {
            return formatAsBulletPoints(text)
        }
        
        // Detect email composition (must have explicit indicators)
        if isEmailComposition(lower) {
            return formatAsEmail(text, context: context)
        }
        
        // Detect numbered list (must have explicit indicators)
        if isNumberedList(lower) {
            return formatAsNumberedList(text)
        }
        
        // No patterns detected - return nil to use minimal cleanup
        return nil
    }
    
    // MARK: - Bullet Points Detection & Formatting
    
    private static func isBulletPointList(_ text: String) -> Bool {
        // MUST have explicit bullet point indicators
        let bulletIndicators = [
            "bullet point",
            "bullet points",
            "bulleted list",
            "following points"
        ]
        
        for indicator in bulletIndicators {
            if text.contains(indicator) {
                return true
            }
        }
        
        // Don't assume it's a list just from "and" or commas
        // This was causing false positives
        return false
    }
    
    private static func formatAsBulletPoints(_ text: String) -> String {
        var cleaned = text
        
        // Remove bullet point indicators
        let indicatorsToRemove = [
            "bullet point",
            "bullet points",
            "bulleted list",
            "list of",
            "the items are",
            "following points",
            "colon",
            ":"
        ]
        
        for indicator in indicatorsToRemove {
            cleaned = cleaned.replacingOccurrences(of: indicator, with: "", options: .caseInsensitive)
        }
        
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Split by common separators
        var items: [String] = []
        
        // Try splitting by "and" if multiple present
        if cleaned.lowercased().components(separatedBy: " and ").count > 2 {
            items = cleaned.components(separatedBy: .init(charactersIn: ","))
                .flatMap { $0.components(separatedBy: " and ") }
        } else {
            // Split by commas
            items = cleaned.components(separatedBy: .init(charactersIn: ","))
        }
        
        // Clean and capitalize each item
        items = items.map { item in
            var cleaned = item.trimmingCharacters(in: .whitespaces)
            
            // Remove leading "and"
            if cleaned.lowercased().hasPrefix("and ") {
                cleaned = String(cleaned.dropFirst(4))
            }
            
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            
            // Capitalize first letter
            if let first = cleaned.first, first.isLowercase {
                cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            }
            
            return cleaned
        }.filter { !$0.isEmpty }
        
        // Format as bullet points
        return items.map { "• \($0)" }.joined(separator: "\n")
    }
    
    // MARK: - Email Detection & Formatting
    
    private static func isEmailComposition(_ text: String) -> Bool {
        // MUST have explicit email indicators
        let emailIndicators = [
            "send email",
            "email to",
            "write email",
            "compose email"
        ]
        
        for indicator in emailIndicators {
            if text.contains(indicator) {
                return true
            }
        }
        
        // Don't assume it's an email just from greetings
        return false
    }
    
    private static func formatAsEmail(_ text: String, context: AppContext) -> String {
        var body = text
        
        // Extract recipient if mentioned
        var recipient: String? = nil
        let patterns = [
            "send email to ([a-zA-Z]+)",
            "email to ([a-zA-Z]+)",
            "to ([a-zA-Z]+)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let nameRange = Range(match.range(at: 1), in: body) {
                recipient = String(body[nameRange])
                break
            }
        }
        
        // Remove email command phrases
        let phrasesToRemove = [
            "send email to \\w+",
            "email to \\w+",
            "write email",
            "compose email",
            "saying",
            "about",
            "regarding"
        ]
        
        for phrase in phrasesToRemove {
            if let regex = try? NSRegularExpression(pattern: phrase, options: .caseInsensitive) {
                body = regex.stringByReplacingMatches(
                    in: body,
                    range: NSRange(body.startIndex..., in: body),
                    withTemplate: ""
                )
            }
        }
        
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Capitalize first letter of body
        if let first = body.first, first.isLowercase {
            body = body.prefix(1).uppercased() + body.dropFirst()
        }
        
        // Add period if missing
        if !body.isEmpty && ![".", "!", "?"].contains(body.last) {
            body += "."
        }
        
        // Build email structure
        var email = ""
        
        // Greeting
        if let name = recipient {
            email += "Dear \(name.capitalized),\n\n"
        } else {
            email += "Hi,\n\n"
        }
        
        // Body
        email += body
        
        // Signature
        email += "\n\nBest regards"
        
        return email
    }
    
    // MARK: - Numbered List Detection & Formatting
    
    private static func isNumberedList(_ text: String) -> Bool {
        // MUST have explicit numbered list indicators
        let indicators = [
            "numbered list",
            "number the list",
            "numbered items"
        ]
        
        for indicator in indicators {
            if text.contains(indicator) {
                return true
            }
        }
        
        return false
    }
    
    private static func formatAsNumberedList(_ text: String) -> String {
        var cleaned = text
        
        // Remove numbered list indicators
        let indicatorsToRemove = [
            "numbered list",
            "number the list",
            "numbered items",
            "the steps are"
        ]
        
        for indicator in indicatorsToRemove {
            cleaned = cleaned.replacingOccurrences(of: indicator, with: "", options: .caseInsensitive)
        }
        
        // Split into items
        var items = cleaned.components(separatedBy: .init(charactersIn: ","))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        // Capitalize each item
        items = items.map { item in
            var cleaned = item
            if let first = cleaned.first, first.isLowercase {
                cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            }
            return cleaned
        }
        
        // Format as numbered list
        return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}
