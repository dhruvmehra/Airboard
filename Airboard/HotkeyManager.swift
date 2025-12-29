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
    
    private var eventMonitor: Any?
    private var localMonitor: Any?
    
    private static let hotkeyKey = "selectedHotkey"
    
    static var currentHotkey: HotkeyOption {
        get {
            if let saved = UserDefaults.standard.string(forKey: hotkeyKey),
               let option = HotkeyOption(rawValue: saved) {
                return option
            }
            return .rightOption // Default
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: hotkeyKey)
        }
    }
    
    static var currentHotkeyDisplayName: String {
        currentHotkey.displayName
    }
    
    func startMonitoring(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        print("🎤 Starting hotkey monitoring for: \(HotkeyManager.currentHotkey.displayName)")
        
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event: event, onPress: onPress, onRelease: onRelease)
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event: event, onPress: onPress, onRelease: onRelease)
            return event
        }
    }
    
    private func handleFlagsChanged(event: NSEvent, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        let hotkey = HotkeyManager.currentHotkey
        let hotkeyPressed = event.modifierFlags.contains(hotkey.modifierFlag) && event.keyCode == hotkey.keyCode
        
        if hotkeyPressed && !isHotkeyPressed {
            if !SetupWindowController.shared.allPermissionsGranted {
                print("⚠️ Hotkey pressed but permissions not granted")
                DispatchQueue.main.async {
                    SetupWindowController.shared.showPermissionSetup()
                }
                return
            }
            
            isHotkeyPressed = true
            print("🔴 Hotkey pressed")
            onPress()
        } else if !hotkeyPressed && isHotkeyPressed {
            isHotkeyPressed = false
            print("⚪️ Hotkey released")
            onRelease()
        }
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
    }
    
    func restartMonitoring(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        stopMonitoring()
        startMonitoring(onPress: onPress, onRelease: onRelease)
    }
}
