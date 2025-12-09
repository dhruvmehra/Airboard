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
    private var modelManagerWindow: NSWindow?
    private var keyMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Airboard launched")
        
        // Prevent multiple instances from running
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningInstances.count > 1 {
            print("⚠️ Another instance is already running - terminating this one")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        setupKeyboardShortcut()
        checkPermissions()
        
        Task { await coordinator.initialize() }
        
        hotkeyManager.startMonitoring(
            onPress: { [weak self] in self?.coordinator.startRecording() },
            onRelease: { [weak self] in self?.coordinator.stopRecording() }
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openModelManager),
            name: .openModelManager,
            object: nil
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
        modelManagerWindow?.close()
        modelManagerWindow = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        FloatingWindowManager.shared.cleanup()
    }
    
    private func setupKeyboardShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "m" {
                self?.openModelManager()
                return nil
            }
            return event
        }
    }
    
    @objc func openModelManager() {
        print("✨ Opening AI Enhancements")
        
        if let window = modelManagerWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "AI Enhancements"
        window.contentView = NSHostingView(rootView: ModelDownloadView())
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        
        modelManagerWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func openFeedbackReport() {
        print("📝 Opening feedback report - START")
        
        DispatchQueue.main.async { [weak self] in
            print("📝 On main thread")
            
            guard let self = self else {
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == modelManagerWindow {
            if ModelDownloadManager.shared.isDownloading {
                let alert = NSAlert()
                alert.messageText = "Cancel Download?"
                alert.informativeText = "Download is in progress."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel Download")
                alert.addButton(withTitle: "Continue")
                
                if alert.runModal() == .alertFirstButtonReturn {
                    ModelDownloadManager.shared.cancelDownload()
                }
            }
            modelManagerWindow = nil
        }
    }
}
