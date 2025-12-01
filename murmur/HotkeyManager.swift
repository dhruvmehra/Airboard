import Foundation
import AppKit
import Carbon
import Combine

class HotkeyManager: ObservableObject {
    @Published var isHotkeyPressed = false
    
    private var eventMonitor: Any?
    private let targetKeyCode: UInt16 = 58 // Right Option key (⌥)
    // Alternative key codes:
    // 58 = Right Option
    // 61 = Left Option
    // 59 = Right Control
    // 56 = Left Shift
    
    func startMonitoring(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        print("🎤 Starting hotkey monitoring")
        
        // Monitor global key events
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            self.handleFlagsChanged(event: event, onPress: onPress, onRelease: onRelease)
        }
        
        // Also monitor local events (when app is in focus)
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            self.handleFlagsChanged(event: event, onPress: onPress, onRelease: onRelease)
            return event
        }
    }
    
    private func handleFlagsChanged(event: NSEvent, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        // Check if Right Option key is pressed
        let rightOptionPressed = event.modifierFlags.contains(.option) && event.keyCode == targetKeyCode
        
        if rightOptionPressed && !isHotkeyPressed {
            // Key just pressed
            isHotkeyPressed = true
            print("🔴 Hotkey pressed")
            onPress()
        } else if !rightOptionPressed && isHotkeyPressed {
            // Key just released
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
    }
}
