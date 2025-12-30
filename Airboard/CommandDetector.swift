//
//  CommandDetector.swift
//  Airboard
//
//  Parses transcription text into executable commands
//

import Foundation
import AppKit

class CommandDetector {
    
    // MARK: - Website Shortcuts
    
    private static let websiteMap: [String: String] = [
        "youtube": "https://youtube.com",
        "google": "https://google.com",
        "gmail": "https://gmail.com",
        "twitter": "https://twitter.com",
        "x": "https://x.com",
        "linkedin": "https://linkedin.com",
        "github": "https://github.com",
        "reddit": "https://reddit.com",
        "amazon": "https://amazon.com",
        "netflix": "https://netflix.com",
        "spotify": "https://open.spotify.com",
        "chatgpt": "https://chat.openai.com",
        "claude": "https://claude.ai",
        "facebook": "https://facebook.com",
        "instagram": "https://instagram.com",
        "whatsapp": "https://web.whatsapp.com",
        "notion": "https://notion.so",
        "figma": "https://figma.com",
        "slack": "https://slack.com",
        "discord": "https://discord.com",
        "twitch": "https://twitch.tv",
        "pinterest": "https://pinterest.com",
        "medium": "https://medium.com",
        "stackoverflow": "https://stackoverflow.com",
        "stack overflow": "https://stackoverflow.com",
    ]
    
    // MARK: - Supported Platforms for Search/Play
    
    private static let platforms = [
        "youtube", "spotify", "apple music", "google", "amazon",
        "twitter", "reddit", "github", "wikipedia", "bing",
        "duckduckgo", "netflix", "twitch"
    ]
    
    // MARK: - Main Detection
    
    static func detect(_ text: String) -> ParsedCommand {
        // Clean the input: lowercase, trim, remove trailing punctuation
        var cleaned = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove trailing punctuation
        while cleaned.last == "." || cleaned.last == "!" || cleaned.last == "?" || cleaned.last == "," {
            cleaned = String(cleaned.dropLast())
        }
        
        // Fix common Whisper transcription issues
        cleaned = fixCommonTranscriptionIssues(cleaned)
        
        // Remove filler words at the start
        let processedText = removeFillerWords(cleaned)
        
        print("🔍 Command detection - cleaned: '\(processedText)'")
        
        // Try each parser in order
        if let command = parseOpenCommand(processedText) {
            return ParsedCommand(type: command, originalText: text)
        }
        
        if let command = parsePlayCommand(processedText) {
            return ParsedCommand(type: command, originalText: text)
        }
        
        if let command = parseSearchCommand(processedText) {
            return ParsedCommand(type: command, originalText: text)
        }
        
        if let command = parseSystemCommand(processedText) {
            return ParsedCommand(type: command, originalText: text)
        }
        
        if let command = parseTimerCommand(processedText) {
            return ParsedCommand(type: command, originalText: text)
        }
        
        if let command = parseFolderCommand(processedText) {
            return ParsedCommand(type: command, originalText: text)
        }
        
        // Unknown command
        return ParsedCommand(type: .unknown(command: text), originalText: text)
    }
    
    // MARK: - Fix Common Transcription Issues
    
    private static func fixCommonTranscriptionIssues(_ text: String) -> String {
        var result = text
        
        // Fix split words that Whisper commonly produces
        let fixes = [
            "you tube": "youtube",
            "g mail": "gmail",
            "linked in": "linkedin",
            "chat gpt": "chatgpt",
            "git hub": "github",
            "face book": "facebook",
            "whats app": "whatsapp",
            "what's app": "whatsapp",
            "net flix": "netflix",
            "spot ify": "spotify",
            "stack over flow": "stackoverflow",
            "stack overflow": "stackoverflow",
        ]
        
        for (wrong, correct) in fixes {
            result = result.replacingOccurrences(of: wrong, with: correct)
        }
        
        return result
    }
    
    // MARK: - Filler Word Removal

    private static func removeFillerWords(_ text: String) -> String {
        // Remove leading filler words
        let leadingFillers = [
            "please ", "can you ", "could you ", "i want to ",
            "i'd like to ", "go ahead and ", "hey ", "okay ",
            "ok ", "so ", "just ", "actually "
        ]
        var result = text
        
        for filler in leadingFillers {
            if result.hasPrefix(filler) {
                result = String(result.dropFirst(filler.count))
                break
            }
        }
        
        // Remove trailing filler words
        let trailingFillers = [
            " this", " that", " now", " please", " it",
            " for me", " right now"
        ]
        
        for filler in trailingFillers {
            if result.hasSuffix(filler) {
                result = String(result.dropLast(filler.count))
                break
            }
        }
        
        return result
    }
    
    // MARK: - Open Command
    // "open youtube", "launch spotify", "go to gmail", "start slack"
    
    private static func parseOpenCommand(_ text: String) -> CommandType? {
        let patterns = ["open ", "launch ", "start ", "go to "]
        
        for pattern in patterns {
            if text.hasPrefix(pattern) {
                let target = String(text.dropFirst(pattern.count)).trimmingCharacters(in: .whitespaces)
                
                // Empty target
                if target.isEmpty { return nil }
                
                // Check if it's a known website
                if let url = websiteMap[target] {
                    return .openWebsite(url: url)
                }
                
                // Check if it's a folder
                let folders = ["downloads", "documents", "desktop", "applications", "home", "pictures", "music", "movies"]
                if folders.contains(target) || folders.contains(target.replacingOccurrences(of: " folder", with: "")) {
                    return .openFolder(folder: target.replacingOccurrences(of: " folder", with: ""))
                }
                
                // Check if it looks like a URL (contains dot but not a common TLD issue)
                if target.contains(".") && !target.contains(" ") {
                    let url = target.hasPrefix("http") ? target : "https://\(target)"
                    return .openWebsite(url: url)
                }
                
                // Assume it's an app
                return .openApp(appName: target)
            }
        }
        
        return nil
    }
    
    // MARK: - Play Command
    // "play shape of you", "play lofi music on spotify", "play something on youtube"
    
    private static func parsePlayCommand(_ text: String) -> CommandType? {
        let patterns = ["play ", "listen to ", "put on "]
        
        for pattern in patterns {
            if text.hasPrefix(pattern) {
                let rest = String(text.dropFirst(pattern.count)).trimmingCharacters(in: .whitespaces)
                
                if rest.isEmpty { return nil }
                
                let (query, platform) = extractQueryAndPlatform(rest, defaultPlatform: "youtube")
                return .playMedia(platform: platform, query: query)
            }
        }
        
        return nil
    }
    
    // MARK: - Search Command
    // "search for restaurants", "google best pizza", "search youtube for tutorials"
    // "search iphone 15 on amazon", "look up weather"
    
    private static func parseSearchCommand(_ text: String) -> CommandType? {
        // Pattern: "google [query]"
        if text.hasPrefix("google ") {
            let query = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                return .searchWeb(platform: "google", query: query)
            }
        }
        
        // Pattern: "look up [query]"
        if text.hasPrefix("look up ") {
            let query = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                return .searchWeb(platform: "google", query: query)
            }
        }
        
        // Pattern: "search ..."
        if text.hasPrefix("search ") {
            let rest = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            
            if rest.isEmpty { return nil }
            
            // Pattern: "search [platform] for [query]"
            for platform in platforms {
                let platformFor = "\(platform) for "
                if rest.hasPrefix(platformFor) {
                    let query = String(rest.dropFirst(platformFor.count)).trimmingCharacters(in: .whitespaces)
                    if !query.isEmpty {
                        return .searchWeb(platform: platform, query: query)
                    }
                }
            }
            
            // Pattern: "search for [query]" or "search for [query] on [platform]"
            if rest.hasPrefix("for ") {
                let afterFor = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let (query, platform) = extractQueryAndPlatform(afterFor, defaultPlatform: "google")
                if !query.isEmpty {
                    return .searchWeb(platform: platform, query: query)
                }
            }
            
            // Pattern: "search [query] on [platform]" or just "search [query]"
            let (query, platform) = extractQueryAndPlatform(rest, defaultPlatform: "google")
            if !query.isEmpty {
                return .searchWeb(platform: platform, query: query)
            }
        }
        
        return nil
    }
    
    // MARK: - System Commands
    
    private static func parseSystemCommand(_ text: String) -> CommandType? {
        // Mute
        let muteCommands = [
            "mute", "mute audio", "mute sound", "mute volume",
            "put it on mute", "go on mute", "silence", "mute it",
            "turn off sound", "sound off"
        ]
        if muteCommands.contains(text) {
            return .systemControl(action: .mute)
        }
        
        // Unmute
        let unmuteCommands = [
            "unmute", "unmute audio", "unmute sound", "unmute volume",
            "take off mute", "unmute it", "turn on sound", "sound on"
        ]
        if unmuteCommands.contains(text) {
            return .systemControl(action: .unmute)
        }
        
        // Volume up
        let volumeUpCommands = [
            "volume up", "turn up volume", "louder", "increase volume",
            "turn it up", "raise volume", "more volume", "crank it up",
            "turn up the volume", "make it louder"
        ]
        if volumeUpCommands.contains(text) {
            return .systemControl(action: .volumeUp)
        }
        
        // Volume down
        let volumeDownCommands = [
            "volume down", "turn down volume", "quieter", "decrease volume",
            "turn it down", "lower volume", "reduce volume", "less volume",
            "turn down the volume", "make it quieter"
        ]
        if volumeDownCommands.contains(text) {
            return .systemControl(action: .volumeDown)
        }
        
        // Play/Pause
        let pauseCommands = [
            "pause", "pause music", "stop music", "stop",
            "pause it", "stop it", "pause playback"
        ]
        if pauseCommands.contains(text) {
            return .systemControl(action: .playPause)
        }
        
        let playCommands = [
            "play", "play music", "resume", "resume music",
            "resume playback", "continue playing", "unpause"
        ]
        if playCommands.contains(text) {
            return .systemControl(action: .playPause)
        }
        
        // Next track
        let nextCommands = [
            "next", "next song", "next track", "skip", "skip song",
            "skip track", "play next", "next one"
        ]
        if nextCommands.contains(text) {
            return .systemControl(action: .nextTrack)
        }
        
        // Previous track
        let previousCommands = [
            "previous", "previous song", "previous track",
            "go back", "last song", "play previous", "back"
        ]
        if previousCommands.contains(text) {
            return .systemControl(action: .previousTrack)
        }
        
        // Lock screen
        let lockCommands = [
            "lock", "lock screen", "lock computer", "lock mac",
            "lock my computer", "lock my mac", "lock it"
        ]
        if lockCommands.contains(text) {
            return .systemControl(action: .lockScreen)
        }
        
        // Screenshot
        let screenshotCommands = [
            "screenshot", "take screenshot", "take a screenshot",
            "capture screen", "screen capture", "grab screen",
            "take a screen shot", "screen shot"
        ]
        if screenshotCommands.contains(text) {
            return .systemControl(action: .screenshot)
        }
        
        // Empty trash
        let trashCommands = [
            "empty trash", "empty the trash", "clear trash",
            "empty bin", "clear the trash"
        ]
        if trashCommands.contains(text) {
            return .systemControl(action: .emptyTrash)
        }
        
        // Sleep
        let sleepCommands = [
            "sleep", "go to sleep", "sleep mac", "sleep computer",
            "put to sleep", "sleep mode"
        ]
        if sleepCommands.contains(text) {
            return .systemControl(action: .sleep)
        }
        
        return nil
    }
    
    // MARK: - Timer Command
    // "set timer for 5 minutes", "timer 10 minutes", "set a 5 minute timer"
    
    private static func parseTimerCommand(_ text: String) -> CommandType? {
        let patterns = [
            "set timer for ",
            "set a timer for ",
            "timer for ",
            "timer ",
            "set a ",
            "start timer for ",
            "start a timer for "
        ]
        
        for pattern in patterns {
            if text.hasPrefix(pattern) {
                let rest = String(text.dropFirst(pattern.count))
                if let minutes = extractMinutes(from: rest) {
                    return .setTimer(minutes: minutes)
                }
            }
        }
        
        // Pattern: "5 minute timer"
        if text.hasSuffix(" timer") || text.hasSuffix(" minute timer") || text.hasSuffix(" minutes timer") {
            if let minutes = extractMinutes(from: text) {
                return .setTimer(minutes: minutes)
            }
        }
        
        return nil
    }
    
    private static func extractMinutes(from text: String) -> Int? {
        // Extract all numbers from the string
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        
        if let minutes = Int(numbers), minutes > 0, minutes <= 1440 { // Max 24 hours
            return minutes
        }
        
        // Handle word numbers
        let wordNumbers: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "fifteen": 15, "twenty": 20, "thirty": 30, "forty five": 45, "sixty": 60
        ]
        
        for (word, value) in wordNumbers {
            if text.contains(word) {
                return value
            }
        }
        
        return nil
    }
    
    // MARK: - Folder Command
    // "open downloads", "open documents folder", "show desktop"
    
    private static func parseFolderCommand(_ text: String) -> CommandType? {
        let folderPatterns = ["open ", "show ", "go to "]
        let folders = ["downloads", "documents", "desktop", "applications", "home", "pictures", "music", "movies"]
        
        for pattern in folderPatterns {
            if text.hasPrefix(pattern) {
                let target = String(text.dropFirst(pattern.count))
                    .replacingOccurrences(of: " folder", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                if folders.contains(target) {
                    return .openFolder(folder: target)
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Helpers
    
    /// Extract query and platform from patterns like "query on platform"
    private static func extractQueryAndPlatform(_ text: String, defaultPlatform: String) -> (query: String, platform: String) {
        let lowercased = text.lowercased()
        
        // Check for "on [platform]" at the end
        for platform in platforms {
            let suffix = " on \(platform)"
            if lowercased.hasSuffix(suffix) {
                let query = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                return (query, platform)
            }
        }
        
        // No platform specified
        return (text.trimmingCharacters(in: .whitespaces), defaultPlatform)
    }
}
