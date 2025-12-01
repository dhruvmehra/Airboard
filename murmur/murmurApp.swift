//
//  murmurApp.swift
//  murmur
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AVFoundation
import ApplicationServices

@main
struct murmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var audioRecorder = AudioRecorder()
    var hotkeyManager = HotkeyManager()
    var transcriptionService = TranscriptionService(apiKey: Config.openAIAPIKey)
    
    // State management
    private var isRecording = false
    private var isTranscribing = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 App launched")
        
        // Hide the app from the Dock
        NSApp.setActivationPolicy(.accessory)
        
        // Check and request permissions
        checkPermissions()
        
        // Set up hotkey monitoring
        hotkeyManager.startMonitoring(
            onPress: { [weak self] in
                self?.startRecording()
            },
            onRelease: { [weak self] in
                self?.stopRecording()
            }
        )
    }
    
    private func checkPermissions() {
        // Check Microphone Permission
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("🎤 Microphone permission status: \(micStatus.rawValue)")
        
        if micStatus == .notDetermined {
            print("🎤 Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("🎤 Microphone permission granted: \(granted)")
            }
        } else if micStatus == .denied || micStatus == .restricted {
            print("❌ Microphone permission denied - please enable in System Settings")
            showPermissionAlert(for: "Microphone")
        } else {
            print("✅ Microphone permission granted")
        }
        
        // Check Accessibility Permission
        let accessibilityEnabled = AXIsProcessTrusted()
        print("🔐 Accessibility permission: \(accessibilityEnabled)")
        
        if !accessibilityEnabled {
            print("⚠️ Accessibility permission not granted - opening System Settings...")
            showAccessibilityAlert()
        } else {
            print("✅ Accessibility permission granted")
        }
    }
    
    private func showPermissionAlert(for permission: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(permission) Permission Required"
            alert.informativeText = "Murmur needs \(permission.lowercased()) access to work properly. Please enable it in System Settings > Privacy & Security > \(permission)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Murmur needs Accessibility access to insert text into other apps. Please enable it in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open Accessibility settings
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
                AXIsProcessTrustedWithOptions(options)
            }
        }
    }
    
    private func startRecording() {
        // Prevent starting if busy
        guard !isRecording && !isTranscribing else {
            print("⚠️ Busy - isRecording: \(isRecording), isTranscribing: \(isTranscribing)")
            return
        }
        
        print("✅ Starting recording...")
        isRecording = true
        
        // Show indicator FIRST
        DispatchQueue.main.async {
            FloatingWindowManager.shared.showFloatingIndicator(isRecording: true, isTranscribing: false)
        }
        
        // Then start recording with small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.audioRecorder.startRecording()
        }
    }
    
    private func stopRecording() {
        // Only proceed if we're actually recording
        guard isRecording else {
            print("⚠️ Not recording, ignoring stop")
            return
        }
        
        print("✅ Stopping recording...")
        isRecording = false
        isTranscribing = true
        
        audioRecorder.stopRecording()
        
        guard let audioURL = audioRecorder.recordingURL else {
            print("❌ Failed to get audio URL")
            self.resetState()
            return
        }
        
        print("📁 Audio saved to: \(audioURL.path)")
        
        // Show transcribing state
        DispatchQueue.main.async {
            FloatingWindowManager.shared.showFloatingIndicator(isRecording: false, isTranscribing: true)
        }
        
        // Detect app context
        let appContext = AppContextDetector.getCurrentAppContext()
        print("📱 Current app: \(appContext.appName)")
        
        // Transcribe
        Task { [weak self] in
            guard let self = self else { return }
            
            await self.transcriptionService.transcribe(audioURL: audioURL, context: appContext)
            
            // Check if transcription was successful
            if let error = self.transcriptionService.error {
                print("❌ Transcription error: \(error)")
                await MainActor.run {
                    self.resetState()
                }
            } else {
                let text = self.transcriptionService.transcription
                print("✅ Transcription: \(text)")
                
                // Only insert text if we got something
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TextInserter.insertText(text)
                } else {
                    print("⚠️ Empty transcription")
                }
                
                // Hide indicator after a delay
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        FloatingWindowManager.shared.hideFloatingIndicator()
                        self.resetState()
                    }
                }
            }
        }
    }
    
    private func resetState() {
        isRecording = false
        isTranscribing = false
        DispatchQueue.main.async {
            FloatingWindowManager.shared.hideFloatingIndicator()
        }
        print("♻️ State reset to idle")
    }
}
