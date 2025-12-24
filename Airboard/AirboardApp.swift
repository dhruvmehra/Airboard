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
    private var keyMonitor: Any?
    private var onboardingManager: OnboardingManager?

    
    private func suppressLibraryLogs() {
        // Redirect stderr to /dev/null
        let devNull = open("/dev/null", O_WRONLY)
        if devNull != -1 {
            dup2(devNull, STDERR_FILENO)
            close(devNull)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Airboard launched")
        // supress logs
        
        suppressLibraryLogs()
        // Prevent multiple instances from running
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningInstances.count > 1 {
            print("⚠️ Another instance is already running - terminating this one")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        checkPermissions()
        
        MenuBarManager.shared.setup()
        // Show onboarding after app is fully initialized
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.onboardingManager = OnboardingManager()
            self?.onboardingManager?.showOnboardingIfNeeded()
        }
        
        Task { await coordinator.initialize() }
        
        hotkeyManager.startMonitoring(
            onPress: { [weak self] in self?.coordinator.startRecording() },
            onRelease: { [weak self] in self?.coordinator.stopRecording() }
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openFeedbackReport),
            name: .openFeedbackReport,
            object: nil
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("👋 App terminating - cleaning up")
        hotkeyManager.stopMonitoring()
        FloatingWindowManager.shared.cleanup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        FloatingWindowManager.shared.cleanup()
    }
    
    @objc func openFeedbackReport() {
        print("📝 Opening feedback report - START")
        
        DispatchQueue.main.async { [weak self] in
            print("📝 On main thread")
            
            guard self != nil else {
                print("❌ Self is nil")
                return
            }
            
            print("📝 Self exists")
            
            // Try to access coordinator very carefully
            let coord = TranscriptionCoordinator.shared
            print("📝 Got coordinator reference")
            
            let text = coord.lastTranscribedText
            print("📝 Got text: \(text ?? "nil")")
            
            let context = coord.lastContext
            print("📝 Got context: \(String(describing: context))")
            
            print("📝 Calling FeedbackManager")
            FeedbackManager.shared.reportIssue(
                transcribedText: text,
                context: context
            )
            print("📝 FeedbackManager called")
        }
    }
    
    private func checkPermissions() {
        Task {
            await checkMicrophonePermission()
            await checkAccessibilityPermission()
        }
    }
    
    private func checkMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else if status == .denied || status == .restricted {
            await MainActor.run {
                showAlert(
                    title: "Microphone Access Required",
                    message: "Please enable microphone access in System Settings."
                )
            }
        }
    }
    
    private func checkAccessibilityPermission() async {
        guard !AXIsProcessTrusted() else { return }
        
        await MainActor.run {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAlert(
                    title: "Accessibility Access Required",
                    message: "Please enable accessibility access in System Settings."
                )
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if title.contains("Accessibility") {
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
                AXIsProcessTrustedWithOptions(options)
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
}
