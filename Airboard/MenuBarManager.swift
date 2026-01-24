//
//  MenuBarManager.swift
//  Airboard
//

import AppKit
import AVFoundation

class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    
    private override init() {
        super.init()
    }
    
    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Airboard")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }
        
        rebuildMenu()
        
        print("✅ Menu bar icon created")
    }
    
    func rebuildMenu() {
        let menu = NSMenu()
        
        // Status
        let allGranted = SetupWindowController.shared.allPermissionsGranted
        let statusText = allGranted ? "✓ Airboard Ready" : "⚠ Setup Required"
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Set Up Permissions (always show if not granted)
        if !allGranted {
            let setupItem = NSMenuItem(title: "Set Up Permissions...", action: #selector(setupPermissions), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // Check Permissions
        let checkItem = NSMenuItem(title: "Check Permissions...", action: #selector(checkPermissions), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
        
        menu.addItem(NSMenuItem.separator())

        // Test Grammar Correction (DEBUG)
        let testItem = NSMenuItem(title: "🧪 Test Grammar Fix", action: #selector(testGrammarCorrection), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Airboard", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func setupPermissions() {
        SetupWindowController.shared.showPermissionSetup()
    }
    
    @objc private func checkPermissions() {
        let mic = SetupWindowController.shared.isMicrophoneGranted ? "✅" : "❌"
        let acc = SetupWindowController.shared.isAccessibilityGranted ? "✅" : "❌"
        
        let alert = NSAlert()
        alert.messageText = "Permission Status"
        alert.informativeText = "\(mic) Microphone\n\(acc) Accessibility"
        alert.alertStyle = SetupWindowController.shared.allPermissionsGranted ? .informational : .warning
        
        if !SetupWindowController.shared.allPermissionsGranted {
            alert.addButton(withTitle: "Set Up")
            alert.addButton(withTitle: "Close")
            
            if alert.runModal() == .alertFirstButtonReturn {
                SetupWindowController.shared.showPermissionSetup()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    @objc private func testGrammarCorrection() {
        Task {
            let testText = "I go to market yesterday."
            print("🧪 Testing grammar correction with: '\(testText)'")

            do {
                let corrected = try await GrammarCorrectionService.shared.correctGrammar(testText)
                print("🧪 Result: '\(corrected)'")

                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Grammar Test Result"
                    alert.informativeText = "Input: \(testText)\n\nOutput: \(corrected)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                print("🧪 Error: \(error)")

                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Grammar Test Failed"
                    alert.informativeText = "Error: \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
