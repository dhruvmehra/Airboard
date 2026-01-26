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

    // Track which specific keys are currently pressed
    private var primaryKeyPressed = false
    private var commandKeyPressed = false

    // Store callbacks
    private var onDictationStart: (() -> Void)?
    private var onCommandStart: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onModeUpgrade: (() -> Void)?

    // Tap detection for hands-free mode
    private var lastTapTime: Date?
    private var tapCount: Int = 0
    private let doubleTapWindow: TimeInterval = 0.3 // 0.3 seconds for double-tap
    private var handsFreeModeActive = false // Tracks if we're in hands-free recording

    // Escape hatch: rapid triple-press detection to reset stuck state
    private var lastPressTime: Date?
    private var rapidPressCount: Int = 0
    private let rapidPressWindow: TimeInterval = 0.5 // 0.5 seconds
    private let rapidPressThreshold: Int = 3
    
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

    // Helper to update key state based on event
    private func updateKeyState(event: NSEvent) {
        let primaryHotkey = HotkeyManager.primaryHotkey
        let commandHotkey = HotkeyManager.commandModifierHotkey
        let currentFlags = NSEvent.modifierFlags

        // Check if the event is about our specific keys
        let keyCode = event.keyCode

        if keyCode == primaryHotkey.keyCode {
            // This event is about the primary key
            primaryKeyPressed = currentFlags.contains(primaryHotkey.modifierFlag)
        }

        if keyCode == commandHotkey.keyCode {
            // This event is about the command key
            commandKeyPressed = currentFlags.contains(commandHotkey.modifierFlag)
        }

        // Also check if modifier flags changed (for keys we weren't tracking the specific key code)
        if !currentFlags.contains(primaryHotkey.modifierFlag) {
            primaryKeyPressed = false
        }

        if !currentFlags.contains(commandHotkey.modifierFlag) {
            commandKeyPressed = false
        }
    }

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
            self?.handleFlagsChanged(event: event)
        }

        // Local monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event: event)
            return event
        }
    }
    
    private func handleFlagsChanged(event: NSEvent) {
        // Update our tracked key states based on this event
        updateKeyState(event: event)

        // Use our tracked states instead of just checking modifier flags
        let primaryHeld = primaryKeyPressed
        let commandHeld = commandKeyPressed
        let bothHeld = primaryHeld && commandHeld

        // Detect key press (transition from not held to held) for hands-free mode
        if primaryHeld && !isHotkeyPressed {
            if handsFreeModeActive {
                // In hands-free mode, any tap stops recording
                handleSingleTapStop()
                return
            } else if !recordingStarted {
                // Not recording - detect tap pattern for starting
                detectTapPattern()
            }
        }

        if !recordingStarted {
            // === NOT RECORDING ===

            // Detect rapid triple-press for escape hatch
            if primaryHeld {
                let now = Date()
                if let lastPress = lastPressTime, now.timeIntervalSince(lastPress) < rapidPressWindow {
                    rapidPressCount += 1
                    if rapidPressCount >= rapidPressThreshold {
                        print("🚨 Escape hatch activated! Resetting state...")
                        resetState()
                        return
                    }
                } else {
                    rapidPressCount = 1
                }
                lastPressTime = now
            }

            // Start recording when PRIMARY key is pressed (only if not in hands-free mode)
            if primaryHeld && !handsFreeModeActive {
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
                    print("🔴 Dictation mode activated (hold mode)")
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

            // Stop when primary key is released (only if not in hands-free mode)
            if !primaryHeld && !handsFreeModeActive {
                recordingStarted = false
                isHotkeyPressed = false
                print("⚪️ Hotkey released (was \(currentMode == .command ? "command" : "dictation") mode)")
                onRelease?()
            }
        }

        // Update isHotkeyPressed state
        if !primaryHeld {
            isHotkeyPressed = false
        }
    }

    private func detectTapPattern() {
        let now = Date()

        // Check if this is within the double-tap window
        if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < doubleTapWindow {
            tapCount += 1

            // Double-tap detected!
            if tapCount == 2 {
                handleDoubleTap()
                tapCount = 0
                lastTapTime = nil
                return
            }
        } else {
            // Reset if outside window
            tapCount = 1
            lastTapTime = now
        }

        // Schedule check for single tap (if no second tap comes)
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow) { [weak self] in
            guard let self = self else { return }
            if self.tapCount == 1 && !self.handsFreeModeActive {
                // Single tap detected while not recording - do nothing (normal hold mode)
                self.tapCount = 0
                self.lastTapTime = nil
            } else if self.tapCount == 1 && self.handsFreeModeActive {
                // Single tap while in hands-free mode - stop recording
                self.handleSingleTapStop()
                self.tapCount = 0
                self.lastTapTime = nil
            }
        }
    }

    private func handleDoubleTap() {
        guard !handsFreeModeActive else { return }
        guard checkPermissions() else { return }

        print("👆👆 Double-tap detected - starting hands-free recording")
        handsFreeModeActive = true
        recordingStarted = true
        currentMode = .dictation

        onDictationStart?()
    }

    private func handleSingleTapStop() {
        guard handsFreeModeActive else { return }

        print("👆 Single tap - stopping hands-free recording")
        handsFreeModeActive = false
        recordingStarted = false
        isHotkeyPressed = false

        onRelease?()
    }

    private func resetState() {
        recordingStarted = false
        isHotkeyPressed = false
        handsFreeModeActive = false
        rapidPressCount = 0
        lastPressTime = nil
        tapCount = 0
        lastTapTime = nil
        primaryKeyPressed = false
        commandKeyPressed = false

        print("🔄 State reset via escape hatch")
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
