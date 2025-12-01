//
//  murmurApp.swift
//  murmur
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

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
    
    // Initialize transcription service immediately on launch
    var transcriptionService = LocalTranscriptionService()
    
    // State management
    private var isRecording = false
    private var isTranscribing = false
    private var recordingStartTime: Date?
    private var cancellables = Set<AnyCancellable>()
    
    // Common Whisper hallucinations when there's silence
    private let hallucinations = [
        "thank you",
        "thanks for watching",
        "bye",
        "goodbye",
        "you",
        ".",
        "",
        "[blank_audio]",  // Whisper outputs this for silent audio
        "blank_audio",
        "[music]",
        "[silence]",
        "music",
        "silence"
    ]
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 App launched - Using local Whisper transcription")
        
        // Hide the app from the Dock
        NSApp.setActivationPolicy(.accessory)
        
        // Check and request permissions
        checkPermissions()
        
        // Observe download progress
        transcriptionService.$downloadProgress
            .sink { progress in
                FloatingWindowManager.shared.showDownloadProgress(progress: progress)
            }
            .store(in: &cancellables)
        
        // Observe download completion
        transcriptionService.$isDownloadingModel
            .sink { isDownloading in
                if !isDownloading {
                    // Download complete, show idle state
                    FloatingWindowManager.shared.hideFloatingIndicator()
                }
            }
            .store(in: &cancellables)
        
        // Initialize WhisperKit model in background
        Task {
            await transcriptionService.ensureModelReady()
        }
        
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
    
    private func showModelDownloadingAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Model Downloading..."
            alert.informativeText = "Murmur is downloading the AI model for the first time. This will take 1-2 minutes. The app will be ready to use shortly.\n\nYou can see the progress in the floating indicator at the bottom-right of your screen."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func startRecording() {
        // Check if model is still downloading
        if transcriptionService.isDownloadingModel {
            print("⚠️ Model still downloading - showing alert")
            showModelDownloadingAlert()
            return
        }
        
        // Prevent starting if busy
        guard !isRecording && !isTranscribing else {
            print("⚠️ Busy - isRecording: \(isRecording), isTranscribing: \(isTranscribing)")
            return
        }
        
        print("✅ Starting recording...")
        isRecording = true
        recordingStartTime = Date()
        
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
        // Check if model is still downloading
        if transcriptionService.isDownloadingModel {
            print("⚠️ Model still downloading - ignoring")
            return
        }
        
        // Only proceed if we're actually recording
        guard isRecording else {
            print("⚠️ Not recording, ignoring stop")
            return
        }
        
        // Check minimum recording duration (0.3 seconds)
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < 0.3 {
                print("⚠️ Recording too short (\(String(format: "%.2f", duration))s), skipping transcription")
                isRecording = false
                audioRecorder.stopRecording()
                
                // Delete the short recording
                if let audioURL = audioRecorder.recordingURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                
                resetState()
                return
            }
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
        
        // Transcribe locally
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
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .lowercased()
                
                print("✅ Transcription: \(text)")
                
                // Check if it's a hallucination or too short
                if self.isLikelyHallucination(text) {
                    print("⚠️ Detected likely hallucination, not inserting")
                } else if text.isEmpty {
                    print("⚠️ Empty transcription")
                } else {
                    // Insert the original text (not lowercased)
                    let originalText = self.transcriptionService.transcription
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    TextInserter.insertText(originalText)
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
    
    private func isLikelyHallucination(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")  // Remove spaces
        
        // Check if it's in our hallucination list
        if hallucinations.contains(cleaned) {
            return true
        }
        
        // Check if it contains [BLANK_AUDIO] or similar patterns
        if cleaned.contains("blankaudio") || cleaned.contains("blankmusic") {
            return true
        }
        
        // Check if it's very short (likely not real speech)
        if cleaned.count <= 2 {
            return true
        }
        
        return false
    }
    
    private func resetState() {
        isRecording = false
        isTranscribing = false
        recordingStartTime = nil
        DispatchQueue.main.async {
            FloatingWindowManager.shared.hideFloatingIndicator()
        }
        print("♻️ State reset to idle")
    }
}
