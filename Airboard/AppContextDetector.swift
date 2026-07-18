//
//  AppContextDetector.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//


import Foundation
import AppKit

class AppContextDetector {
    
    static func getCurrentAppContext() -> AppContext {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(appName: "Unknown", appType: .general)
        }
        
        let bundleIdentifier = frontmostApp.bundleIdentifier ?? ""
        let appName = frontmostApp.localizedName ?? "Unknown"
        
        print("📱 Active app: \(appName) (\(bundleIdentifier))")
        
        // Check if it's a browser and get URL
        let isBrowser = detectIfBrowser(bundleIdentifier: bundleIdentifier, appName: appName)
        
        var appType: AppType = .general
        
        if isBrowser {
            // Get browser URL and determine context from it
            if let browserURL = getBrowserURL(bundleIdentifier: bundleIdentifier) {
                print("🌐 Browser URL: \(browserURL)")
                appType = detectAppTypeFromURL(url: browserURL)
            } else {
                appType = .browser
            }
        } else {
            // Non-browser app detection
            appType = detectAppType(bundleIdentifier: bundleIdentifier, appName: appName)
        }
        
        return AppContext(appName: appName, appType: appType)
    }
    
    private static func detectIfBrowser(bundleIdentifier: String, appName: String) -> Bool {
        let lowerBundle = bundleIdentifier.lowercased()
        
        return lowerBundle.contains("safari") ||
               lowerBundle.contains("chrome") ||
               lowerBundle.contains("firefox") ||
               lowerBundle.contains("arc") ||
               lowerBundle.contains("brave") ||
               lowerBundle.contains("edge")
    }
    
    private static func getBrowserURL(bundleIdentifier: String) -> String? {
//        let lowerBundle = bundleIdentifier.lowercased()
//        
//        // Try to get URL using AppleScript based on browser
//        var script = ""
//        
//        if lowerBundle.contains("chrome") || lowerBundle.contains("brave") || lowerBundle.contains("edge") {
//            script = """
//            tell application "Google Chrome"
//                if (count of windows) > 0 then
//                    get URL of active tab of front window
//                end if
//            end tell
//            """
//        } else if lowerBundle.contains("safari") {
//            script = """
//            tell application "Safari"
//                if (count of windows) > 0 then
//                    get URL of current tab of front window
//                end if
//            end tell
//            """
//        } else if lowerBundle.contains("firefox") {
//            // Firefox doesn't support AppleScript well, return nil
//            return nil
//        } else if lowerBundle.contains("arc") {
//            script = """
//            tell application "Arc"
//                if (count of windows) > 0 then
//                    get URL of active tab of front window
//                end if
//            end tell
//            """
//        }
//        
//        guard !script.isEmpty else { return nil }
//        
//        var error: NSDictionary?
//        if let scriptObject = NSAppleScript(source: script) {
//            let output = scriptObject.executeAndReturnError(&error)
//            if error == nil, let urlString = output.stringValue {
//                return urlString
//            }
//        }
//        
        return nil
    }
    
    private static func detectAppTypeFromURL(url: String) -> AppType {
        let lowerURL = url.lowercased()
        
        // Email services
        if lowerURL.contains("mail.google.com") ||
           lowerURL.contains("gmail.com") ||
           lowerURL.contains("outlook.live.com") ||
           lowerURL.contains("outlook.office.com") ||
           lowerURL.contains("mail.yahoo.com") ||
           lowerURL.contains("protonmail.com") {
            return .email
        }
        
        // Document editors
        if lowerURL.contains("docs.google.com") ||
           lowerURL.contains("notion.so") ||
           lowerURL.contains("coda.io") ||
           lowerURL.contains("dropbox.com/paper") {
            return .document
        }
        
        // Code editors / dev tools
        if lowerURL.contains("github.com") ||
           lowerURL.contains("gitlab.com") ||
           lowerURL.contains("replit.com") ||
           lowerURL.contains("codesandbox.io") ||
           lowerURL.contains("stackblitz.com") {
            return .code
        }
        
        // Messaging / chat
        if lowerURL.contains("web.whatsapp.com") ||
           lowerURL.contains("web.telegram.org") ||
           lowerURL.contains("app.slack.com") ||
           lowerURL.contains("discord.com/channels") ||
           lowerURL.contains("teams.microsoft.com") {
            return .messaging
        }
        
        // Social media
        if lowerURL.contains("twitter.com") ||
           lowerURL.contains("x.com") ||
           lowerURL.contains("linkedin.com") ||
           lowerURL.contains("facebook.com") ||
           lowerURL.contains("instagram.com") {
            return .social
        }
        
        // Default to browser
        return .browser
    }
    
    private static func detectAppType(bundleIdentifier: String, appName: String) -> AppType {
        let lowerName = appName.lowercased()
        let lowerBundle = bundleIdentifier.lowercased()
        
        // Email clients
        if lowerBundle.contains("mail") || 
           lowerName.contains("mail") ||
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
        
        // Social media
        if lowerBundle.contains("twitter") ||
           lowerBundle.contains("linkedin") ||
           lowerBundle.contains("facebook") {
            return .social
        }
        
        return .general
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
}
