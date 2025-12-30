//
//  CommandExecutor.swift
//  Airboard
//
//  Created by Dhruv Mehra on 29/12/25.
//


//
//  CommandExecutor.swift
//  Airboard
//
//  Executes parsed commands using NSWorkspace and AppleScript
//

import Foundation
import AppKit
import UserNotifications

class CommandExecutor {
    
    // MARK: - Search URL Templates
    
    private static let searchTemplates: [String: String] = [
        "google": "https://google.com/search?q=",
        "youtube": "https://youtube.com/results?search_query=",
        "amazon": "https://amazon.com/s?k=",
        "twitter": "https://twitter.com/search?q=",
        "reddit": "https://reddit.com/search/?q=",
        "github": "https://github.com/search?q=",
        "wikipedia": "https://en.wikipedia.org/wiki/Special:Search?search=",
        "bing": "https://bing.com/search?q=",
        "duckduckgo": "https://duckduckgo.com/?q=",
        "netflix": "https://netflix.com/search?q=",
        "twitch": "https://twitch.tv/search?term=",
        "spotify": "https://open.spotify.com/search/",
    ]
    
    // MARK: - Main Execute
    
    static func execute(_ command: ParsedCommand) -> Bool {
        print("🎯 Executing command: \(command.type)")
        
        switch command.type {
        case .openWebsite(let url):
            return openURL(url)
            
        case .openApp(let appName):
            return openApp(appName)
            
        case .searchWeb(let platform, let query):
            return searchWeb(platform: platform, query: query)
            
        case .playMedia(let platform, let query):
            return playMedia(platform: platform, query: query)
            
        case .systemControl(let action):
            return executeSystemAction(action)
            
        case .setTimer(let minutes):
            return setTimer(minutes: minutes)
            
        case .openFolder(let folder):
            return openFolder(folder)
            
        case .unknown(let command):
            print("❓ Unknown command: \(command)")
            showNotification(title: "Unknown Command", body: "Couldn't understand: \(command)")
            return false
            
        case .none:
            return false
        }
    }
    
    // MARK: - Open URL
    
    private static func openURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            return false
        }
        
        NSWorkspace.shared.open(url)
        print("✅ Opened URL: \(urlString)")
        return true
    }
    
    // MARK: - Open App
    
    // MARK: - Open App

    private static func openApp(_ appName: String) -> Bool {
        let workspace = NSWorkspace.shared
        
        // Normalize app name
        let normalizedName = appName.trimmingCharacters(in: .whitespaces)
        
        // Try common app name variations
        let variations = [
            normalizedName,
            normalizedName.capitalized,
            normalizedName.replacingOccurrences(of: " ", with: ""),
            normalizedName.capitalized.replacingOccurrences(of: " ", with: ""),
            normalizedName.uppercased(),
        ]
        
        // Search in Applications folders
        let appPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        
        for basePath in appPaths {
            for variation in variations {
                let fullPath = "\(basePath)/\(variation).app"
                if FileManager.default.fileExists(atPath: fullPath) {
                    let url = URL(fileURLWithPath: fullPath)
                    let config = NSWorkspace.OpenConfiguration()
                    workspace.openApplication(at: url, configuration: config) { _, error in
                        if let error = error {
                            print("❌ Error launching: \(error)")
                        } else {
                            print("✅ Launched: \(variation)")
                        }
                    }
                    return true
                }
            }
        }
        
        // Try using open command via shell (last resort)
        let result = runShellCommand("open -a \"\(normalizedName)\"")
        if result {
            print("✅ Launched via shell: \(normalizedName)")
            return true
        }
        
        print("❌ Could not find app: \(appName)")
        showNotification(title: "App Not Found", body: "Couldn't find: \(appName)")
        return false
    }
    
    // MARK: - Search Web
    
    private static func searchWeb(platform: String, query: String) -> Bool {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        
        if let template = searchTemplates[platform.lowercased()] {
            let urlString = template + encodedQuery
            print("🔍 Searching \(platform) for: \(query)")
            return openURL(urlString)
        }
        
        // Default to Google
        let urlString = "https://google.com/search?q=" + encodedQuery
        print("🔍 Searching Google for: \(query)")
        return openURL(urlString)
    }
    
    // MARK: - Play Media
    
    private static func playMedia(platform: String, query: String) -> Bool {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        
        switch platform.lowercased() {
        case "youtube":
            return openURL("https://youtube.com/results?search_query=\(encodedQuery)")
            
        case "spotify":
            // Try Spotify URI scheme first (opens in app)
            if let url = URL(string: "spotify:search:\(encodedQuery)") {
                NSWorkspace.shared.open(url)
                print("✅ Opening in Spotify app: \(query)")
                return true
            }
            // Fallback to web
            return openURL("https://open.spotify.com/search/\(encodedQuery)")
            
        case "apple music":
            if let url = URL(string: "music://search?term=\(encodedQuery)") {
                NSWorkspace.shared.open(url)
                print("✅ Opening in Apple Music: \(query)")
                return true
            }
            return false
            
        case "netflix":
            return openURL("https://netflix.com/search?q=\(encodedQuery)")
            
        case "twitch":
            return openURL("https://twitch.tv/search?term=\(encodedQuery)")
            
        default:
            // Default to YouTube
            return openURL("https://youtube.com/results?search_query=\(encodedQuery)")
        }
    }
    
    // MARK: - System Actions (AppleScript)
    
    private static func executeSystemAction(_ action: SystemAction) -> Bool {
        var script: String
        var successMessage: String
        
        switch action {
        case .mute:
            script = "set volume output muted true"
            successMessage = "Muted"
            
        case .unmute:
            script = "set volume output muted false"
            successMessage = "Unmuted"
            
        case .volumeUp:
            script = """
            set currentVolume to output volume of (get volume settings)
            set newVolume to currentVolume + 15
            if newVolume > 100 then set newVolume to 100
            set volume output volume newVolume
            """
            successMessage = "Volume up"
            
        case .volumeDown:
            script = """
            set currentVolume to output volume of (get volume settings)
            set newVolume to currentVolume - 15
            if newVolume < 0 then set newVolume to 0
            set volume output volume newVolume
            """
            successMessage = "Volume down"
            
        case .playPause:
            script = """
            tell application "System Events"
                set musicApps to {"Spotify", "Music", "iTunes"}
                repeat with appName in musicApps
                    if exists (processes where name is appName) then
                        tell application appName to playpause
                        return
                    end if
                end repeat
            end tell
            -- Fallback: send media key
            tell application "System Events" to key code 16 using {command down, option down}
            """
            successMessage = "Play/Pause"
            
        case .nextTrack:
            script = """
            tell application "System Events"
                set musicApps to {"Spotify", "Music", "iTunes"}
                repeat with appName in musicApps
                    if exists (processes where name is appName) then
                        tell application appName to next track
                        return
                    end if
                end repeat
            end tell
            """
            successMessage = "Next track"
            
        case .previousTrack:
            script = """
            tell application "System Events"
                set musicApps to {"Spotify", "Music", "iTunes"}
                repeat with appName in musicApps
                    if exists (processes where name is appName) then
                        tell application appName to previous track
                        return
                    end if
                end repeat
            end tell
            """
            successMessage = "Previous track"
            
        case .lockScreen:
            script = """
            tell application "System Events" to keystroke "q" using {control down, command down}
            """
            successMessage = "Screen locked"
            
        case .screenshot:
            script = """
            do shell script "screencapture ~/Desktop/Screenshot_$(date +%Y%m%d_%H%M%S).png"
            """
            successMessage = "Screenshot saved to Desktop"
            
        case .emptyTrash:
            script = """
            tell application "Finder" to empty trash
            """
            successMessage = "Trash emptied"
            
        case .sleep:
            script = """
            tell application "System Events" to sleep
            """
            successMessage = "Going to sleep"
        }
        
        let success = runAppleScript(script)
        
        if success {
            print("✅ \(successMessage)")
            showNotification(title: "Airboard", body: successMessage)
        }
        
        return success
    }
    
    // MARK: - Timer
    
    private static func setTimer(minutes: Int) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Timer Complete"
        content.body = "Your \(minutes) minute timer is done!"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60),
            repeats: false
        )
        
        let identifier = "airboard-timer-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Timer error: \(error)")
            } else {
                print("✅ Timer set for \(minutes) minutes")
            }
        }
        
        showNotification(title: "Timer Set", body: "\(minutes) minute timer started")
        return true
    }
    
    // MARK: - Open Folder
    
    private static func openFolder(_ folder: String) -> Bool {
        var path: String
        
        switch folder.lowercased() {
        case "downloads":
            path = NSHomeDirectory() + "/Downloads"
        case "documents":
            path = NSHomeDirectory() + "/Documents"
        case "desktop":
            path = NSHomeDirectory() + "/Desktop"
        case "applications":
            path = "/Applications"
        case "home":
            path = NSHomeDirectory()
        case "pictures":
            path = NSHomeDirectory() + "/Pictures"
        case "music":
            path = NSHomeDirectory() + "/Music"
        case "movies":
            path = NSHomeDirectory() + "/Movies"
        default:
            path = NSHomeDirectory() + "/\(folder)"
        }
        
        let url = URL(fileURLWithPath: path)
        
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
            print("✅ Opened folder: \(path)")
            return true
        } else {
            print("❌ Folder not found: \(path)")
            return false
        }
    }
    
    // MARK: - Helpers
    
    private static func runAppleScript(_ script: String) -> Bool {
        var error: NSDictionary?
        
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            
            if let error = error {
                print("❌ AppleScript error: \(error)")
                return false
            }
            return true
        }
        
        return false
    }
    
    private static func runShellCommand(_ command: String) -> Bool {
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-c", command]
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("❌ Shell error: \(error)")
            return false
        }
    }
    
    private static func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}
