//
//  HotkeyManager.swift
//  Airboard
//
//  Detects hotkey combinations for dictation and command modes
//

import Foundation
import AppKit
import Carbon
import Combine

enum HotkeyOption: String, CaseIterable {
    case rightOption = "rightOption"
    case leftOption = "leftOption"
    case rightCommand = "rightCommand"
    case leftCommand = "leftCommand"
    case rightControl = "rightControl"
    case fn = "fn"
    
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightCommand, .leftCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }
    
    var displayName: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn"
        }
    }
}

class HotkeyManager: ObservableObject {
    @Published var isHotkeyPressed = false
    @Published var currentMode: RecordingMode = .dictation
    
    private var eventMonitor: Any?
    private var localMonitor: Any?
    private var recordingStarted = false
    
    // Store callbacks
    private var onDictationStart: (() -> Void)?
    private var onCommandStart: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onModeUpgrade: (() -> Void)?
    
    // Keys for UserDefaults
    private static let primaryHotkeyKey = "primaryHotkey"
    private static let commandModifierKey = "commandModifierHotkey"
    
    // MARK: - Hotkey Settings
    
    static var primaryHotkey: HotkeyOption {
        get {
            if let saved = UserDefaults.standard.string(forKey: primaryHotkeyKey),
               let option = HotkeyOption(rawValue: saved) {
                return option
            }
            return .leftOption
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: primaryHotkeyKey)
        }
    }
    
    static var commandModifierHotkey: HotkeyOption {
        get {
            if let saved = UserDefaults.standard.string(forKey: commandModifierKey),
               let option = HotkeyOption(rawValue: saved) {
                return option
            }
            return .leftCommand
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: commandModifierKey)
        }
    }
    
    static var currentHotkeyDisplayName: String {
        return primaryHotkey.displayName
    }
    
    static var commandModeDisplayName: String {
        return "\(primaryHotkey.displayName) + \(commandModifierHotkey.displayName)"
    }
    
    // MARK: - Monitoring
    
    func startMonitoring(
        onDictationStart: @escaping () -> Void,
        onCommandStart: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        print("🎤 Starting hotkey monitoring")
        print("   Primary (Dictation): \(HotkeyManager.primaryHotkey.displayName)")
        print("   Modifier (Command mode): \(HotkeyManager.commandModifierHotkey.displayName)")
        
        self.onDictationStart = onDictationStart
        self.onCommandStart = onCommandStart
        self.onRelease = onRelease
        
        // Global monitor
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged()
        }
        
        // Local monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged()
            return event
        }
    }
    
    private func handleFlagsChanged() {
        let primaryFlag = HotkeyManager.primaryHotkey.modifierFlag
        let commandFlag = HotkeyManager.commandModifierHotkey.modifierFlag
        
        // Get CURRENT system modifier state
        let currentFlags = NSEvent.modifierFlags
        
        let primaryHeld = currentFlags.contains(primaryFlag)
        let commandHeld = currentFlags.contains(commandFlag)
        let bothHeld = primaryHeld && commandHeld
        
        if !recordingStarted {
            // === NOT RECORDING ===
            
            // Start recording when PRIMARY key is pressed
            if primaryHeld {
                if !checkPermissions() { return }
                
                recordingStarted = true
                isHotkeyPressed = true
                
                if bothHeld {
                    // Both keys held from the start
                    currentMode = .command
                    print("⚡ Command mode activated (both keys)")
                    onCommandStart?()
                } else {
                    // Only primary key
                    currentMode = .dictation
                    print("🔴 Dictation mode activated")
                    onDictationStart?()
                }
            }
            
        } else {
            // === CURRENTLY RECORDING ===
            
            // Check if user added the command modifier (upgrade to command mode)
            if currentMode == .dictation && bothHeld {
                currentMode = .command
                print("⚡ Upgraded to Command mode (added modifier)")
                // Update the UI to show purple icon
                DispatchQueue.main.async {
                    FloatingWindowManager.shared.showFloatingIndicator(
                        isRecording: true,
                        isTranscribing: false,
                        isCommandMode: true
                    )
                }
            }
            
            // Stop when primary key is released
            if !primaryHeld {
                recordingStarted = false
                isHotkeyPressed = false
                print("⚪️ Hotkey released (was \(currentMode == .command ? "command" : "dictation") mode)")
                onRelease?()
            }
        }
    }
    
    private func checkPermissions() -> Bool {
        if !SetupWindowController.shared.allPermissionsGranted {
            print("⚠️ Hotkey pressed but permissions not granted")
            DispatchQueue.main.async {
                SetupWindowController.shared.showPermissionSetup()
            }
            return false
        }
        return true
    }
    
    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        
        onDictationStart = nil
        onCommandStart = nil
        onRelease = nil
        
        print("🛑 Hotkey monitoring stopped")
    }
    
    func restartMonitoring(
        onDictationStart: @escaping () -> Void,
        onCommandStart: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        stopMonitoring()
        startMonitoring(
            onDictationStart: onDictationStart,
            onCommandStart: onCommandStart,
            onRelease: onRelease
        )
    }
}
