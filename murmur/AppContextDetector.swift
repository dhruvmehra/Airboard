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
        // NOTE: Whisper's "prompt" parameter is for vocabulary/context hints, 
        // NOT formatting instructions. It helps Whisper understand domain-specific terms.
        // Keep prompts short and relevant - they provide context about what might be said.
        
        switch appType {
        case .email:
            return "Email message with professional vocabulary."
            
        case .messaging:
            return "Casual conversation message."
            
        case .code:
            return "Code, programming terms, variable names, function names, technical vocabulary."
            
        case .document, .notes:
            return "Professional document with proper grammar and punctuation."
            
        case .browser:
            return "Web search or form input."
            
        case .social:
            return "Social media post."
            
        case .general:
            return "" // No specific context
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
