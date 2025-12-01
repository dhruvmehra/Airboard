//
//  AppContextDetector.swift
//  murmur
//
//  Created by Dhruv Mehra on 01/12/25.
//


import Foundation
import AppKit

class AppContextDetector {
    
    static func getCurrentAppContext() -> AppContext {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(appName: "Unknown", appType: .general, prompt: "")
        }
        
        let bundleIdentifier = frontmostApp.bundleIdentifier ?? ""
        let appName = frontmostApp.localizedName ?? "Unknown"
        
        print("📱 Active app: \(appName) (\(bundleIdentifier))")
        
        // Determine app type and context
        let appType = detectAppType(bundleIdentifier: bundleIdentifier, appName: appName)
        let prompt = generatePrompt(for: appType, appName: appName)
        
        return AppContext(appName: appName, appType: appType, prompt: prompt)
    }
    
    private static func detectAppType(bundleIdentifier: String, appName: String) -> AppType {
        let lowerName = appName.lowercased()
        let lowerBundle = bundleIdentifier.lowercased()
        
        // Email clients
        if lowerBundle.contains("mail") || 
           lowerName.contains("mail") ||
           lowerBundle.contains("gmail") ||
           lowerBundle.contains("outlook") ||
           lowerBundle.contains("spark") ||
           lowerBundle.contains("airmail") {
            return .email
        }
        
        // Messaging apps
        if lowerBundle.contains("slack") ||
           lowerBundle.contains("discord") ||
           lowerBundle.contains("teams") ||
           lowerBundle.contains("messages") ||
           lowerBundle.contains("telegram") ||
           lowerBundle.contains("whatsapp") {
            return .messaging
        }
        
        // Code editors
        if lowerBundle.contains("xcode") ||
           lowerBundle.contains("vscode") ||
           lowerBundle.contains("code") ||
           lowerBundle.contains("sublime") ||
           lowerBundle.contains("atom") ||
           lowerBundle.contains("intellij") ||
           lowerName.contains("cursor") {
            return .code
        }
        
        // Document editors
        if lowerBundle.contains("word") ||
           lowerBundle.contains("pages") ||
           lowerBundle.contains("docs") ||
           lowerBundle.contains("notion") ||
           lowerBundle.contains("bear") ||
           lowerBundle.contains("obsidian") {
            return .document
        }
        
        // Note-taking
        if lowerBundle.contains("notes") ||
           lowerBundle.contains("evernote") ||
           lowerBundle.contains("onenote") {
            return .notes
        }
        
        // Browsers (could be anything)
        if lowerBundle.contains("safari") ||
           lowerBundle.contains("chrome") ||
           lowerBundle.contains("firefox") ||
           lowerBundle.contains("arc") ||
           lowerBundle.contains("brave") {
            return .browser
        }
        
        // Social media
        if lowerBundle.contains("twitter") ||
           lowerBundle.contains("linkedin") ||
           lowerBundle.contains("facebook") {
            return .social
        }
        
        return .general
    }
    
    private static func generatePrompt(for appType: AppType, appName: String) -> String {
        switch appType {
        case .email:
            return "Format this as a professional email. Use proper email structure with greetings and sign-offs if appropriate. Be concise and clear."
            
        case .messaging:
            return "Format this as a casual message for \(appName). Keep it conversational and natural. Use appropriate punctuation but keep it brief."
            
        case .code:
            return "If this is code-related, format appropriately with proper syntax. If it's a comment, format as a code comment. Otherwise, keep it as plain text."
            
        case .document:
            return "Format this as professional document text. Use proper grammar, punctuation, and paragraph structure."
            
        case .notes:
            return "Format this as a note. Keep it clear and well-structured with proper punctuation."
            
        case .browser:
            return "The user is in a web browser. This could be a search query, form input, or social media post. Format accordingly - if it seems like a search query, keep it concise; if it's longer content, use proper formatting."
            
        case .social:
            return "Format this as a social media post. Keep it engaging and appropriately formatted for social media."
            
        case .general:
            return "Transcribe this accurately with proper punctuation and formatting."
        }
    }
}

enum AppType {
    case email
    case messaging
    case code
    case document
    case notes
    case browser
    case social
    case general
}

struct AppContext {
    let appName: String
    let appType: AppType
    let prompt: String
}
