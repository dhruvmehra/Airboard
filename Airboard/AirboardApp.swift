//
//  AirboardApp.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AVFoundation
import ApplicationServices

@main
struct AirboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager = HotkeyManager()
    private lazy var coordinator = TranscriptionCoordinator.shared
    
    private func suppressLibraryLogs() {
        let devNull = open("/dev/null", O_WRONLY)
        if devNull != -1 {
            dup2(devNull, STDERR_FILENO)
            close(devNull)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Airboard launched")
        suppressLibraryLogs()
        
        // Prevent multiple instances
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningInstances.count > 1 {
            print("⚠️ Another instance running")
            NSApp.terminate(nil)
            return
        }
        
        // Show in Dock (always visible)
        NSApp.setActivationPolicy(.regular)
        
        // Setup menu bar
        MenuBarManager.shared.setup()
        
        // Initialize coordinator (creates floating icon)
        Task { await coordinator.initialize() }
        
        // Show setup window if needed, then start hotkey monitoring
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            SetupWindowController.shared.startSetupIfNeeded {
                self?.startHotkeyMonitoring()
                MenuBarManager.shared.rebuildMenu()
            }
        }
        
        // Listen for feedback report
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openFeedbackReport),
            name: .openFeedbackReport,
            object: nil
        )
        
        // Listen for hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: .hotkeyChanged,
            object: nil
        )
    }
    
    private func startHotkeyMonitoring() {
        hotkeyManager.startMonitoring(
            onDictationStart: { [weak self] in
                self?.coordinator.startRecording()
            },
            onCommandStart: { [weak self] in
                self?.coordinator.startCommandRecording()
            },
            onRelease: { [weak self] in
                guard let self = self else { return }
                self.coordinator.stopRecording(mode: self.hotkeyManager.currentMode)
            }
        )
    }
    
    @objc func hotkeyDidChange() {
        print("🔄 Hotkey changed, restarting monitoring")
        hotkeyManager.restartMonitoring(
            onDictationStart: { [weak self] in
                self?.coordinator.startRecording()
            },
            onCommandStart: { [weak self] in
                self?.coordinator.startCommandRecording()
            },
            onRelease: { [weak self] in
                guard let self = self else { return }
                self.coordinator.stopRecording(mode: self.hotkeyManager.currentMode)
            }
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("👋 App terminating")
        hotkeyManager.stopMonitoring()
        FloatingWindowManager.shared.cleanup()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when setup window closes
        return false
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func openFeedbackReport() {
        DispatchQueue.main.async {
            let coord = TranscriptionCoordinator.shared
            FeedbackManager.shared.reportIssue(
                transcribedText: coord.lastTranscribedText,
                context: coord.lastContext
            )
        }
    }
}
