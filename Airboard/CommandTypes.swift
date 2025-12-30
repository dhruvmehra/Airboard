//
//  RecordingMode.swift
//  Airboard
//
//  Created by Dhruv Mehra on 29/12/25.
//


//
//  CommandTypes.swift
//  Airboard
//
//  Defines command types and structures for voice commands
//

import Foundation

// MARK: - Recording Mode

enum RecordingMode {
    case dictation  // Option key only → types text
    case command    // Option + Command → executes action
}

// MARK: - Command Types

enum CommandType: Equatable {
    case openWebsite(url: String)
    case openApp(appName: String)
    case searchWeb(platform: String, query: String)
    case playMedia(platform: String, query: String)
    case systemControl(action: SystemAction)
    case setTimer(minutes: Int)
    case openFolder(folder: String)
    case unknown(command: String)
    case none  // Not a command
}

// MARK: - System Actions

enum SystemAction: Equatable {
    case mute
    case unmute
    case volumeUp
    case volumeDown
    case playPause
    case nextTrack
    case previousTrack
    case lockScreen
    case screenshot
    case emptyTrash
    case sleep
}

// MARK: - Parsed Command

struct ParsedCommand {
    let type: CommandType
    let originalText: String
    
    var isValid: Bool {
        if case .none = type { return false }
        if case .unknown = type { return false }
        return true
    }
}