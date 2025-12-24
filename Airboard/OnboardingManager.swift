//
//  OnboardingManager.swift
//  Airboard
//

import AppKit

class OnboardingManager {
    
    private let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    
    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey) }
    }
    
    init() {}
    
    func showOnboardingIfNeeded() {
        guard !hasCompletedOnboarding else {
            print("✅ Onboarding already completed")
            return
        }
        
        print("📖 Showing onboarding")
        
        // Step 1: Welcome
        showWelcomeStep()
        
        // Step 2: Icon location
        showIconStep()
        
        // Step 3: How to use
        showHotkeyStep()
        
        hasCompletedOnboarding = true
        print("✅ Onboarding completed")
    }
    
    private func showWelcomeStep() {
        let alert = NSAlert()
        alert.messageText = "Welcome to Airboard"
        alert.informativeText = "Voice dictation that never leaves your Mac.\n\nYour voice is transcribed locally using Apple's Neural Engine — nothing is sent to the cloud."
        alert.icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .medium, scale: .large))
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Skip")
        
        if alert.runModal() == .alertSecondButtonReturn {
            return
        }
    }
    
    private func showIconStep() {
        // Pulse the floating icon
        NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
        
        let alert = NSAlert()
        alert.messageText = "Airboard Lives Here"
        alert.informativeText = "Look for this icon in the bottom-right corner of your screen.\n\n• Gray = Ready\n• Red = Recording\n• Orange = Processing"
        alert.icon = NSImage(systemSymbolName: "arrow.down.right.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .medium, scale: .large))
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Skip")
        
        if alert.runModal() == .alertSecondButtonReturn {
            return
        }
    }
    
    private func showHotkeyStep() {
        let alert = NSAlert()
        alert.messageText = "How to Use"
        alert.informativeText = "1. Hold the Right Option key (⌥)\n2. Speak naturally\n3. Release the key\n4. Text appears instantly!\n\nTip: Works in any app — emails, documents, messages, code editors."
        alert.icon = NSImage(systemSymbolName: "option", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .medium, scale: .large))
        alert.addButton(withTitle: "Get Started")
        
        alert.runModal()
    }
}
