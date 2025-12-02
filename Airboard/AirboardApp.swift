//
//  AirboardApp.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

@main
struct AirboardApp: App {
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
    private var currentContext: AppContext?
    
    // Common Whisper hallucinations when there's silence
    private let hallucinations = [
        "thank you",
        "thanks for watching",
        "bye",
        "goodbye",
        "you",
        ".",
        "",
        "[blank_audio]",
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
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("🎤 Microphone permission status: \(micStatus.rawValue)")
        
        if micStatus == .notDetermined {
            print("🎤 Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("🎤 Microphone permission granted: \(granted)")
            }
        } else if micStatus == .denied || micStatus == .restricted {
            print("❌ Microphone permission denied")
            showPermissionAlert(for: "Microphone")
        } else {
            print("✅ Microphone permission granted")
        }
        
        let accessibilityEnabled = AXIsProcessTrusted()
        print("🔐 Accessibility permission: \(accessibilityEnabled)")
        
        if !accessibilityEnabled {
            print("⚠️ Accessibility permission not granted")
            showAccessibilityAlert()
        } else {
            print("✅ Accessibility permission granted")
        }
    }
    
    private func showPermissionAlert(for permission: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(permission) Permission Required"
            alert.informativeText = "Airboard needs \(permission.lowercased()) access to work properly."
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
            alert.informativeText = "Airboard needs Accessibility access to insert text."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
                AXIsProcessTrustedWithOptions(options)
            }
        }
    }
    
    private func showModelDownloadingAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Model Downloading..."
            alert.informativeText = "Airboard is downloading the AI model. This will take 1-2 minutes.\n\nProgress shown in bottom-right corner."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func startRecording() {
        if transcriptionService.isDownloadingModel {
            print("⚠️ Model downloading")
            showModelDownloadingAlert()
            return
        }
        
        guard !isRecording && !isTranscribing else {
            print("⚠️ Busy")
            return
        }
        
        print("✅ Starting recording...")
        isRecording = true
        recordingStartTime = Date()
        
        DispatchQueue.main.async {
            FloatingWindowManager.shared.showFloatingIndicator(isRecording: true, isTranscribing: false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.audioRecorder.startRecording()
        }
    }
    
    private func stopRecording() {
        if transcriptionService.isDownloadingModel {
            print("⚠️ Model downloading")
            return
        }
        
        guard isRecording else {
            print("⚠️ Not recording")
            return
        }
        
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < 0.3 {
                print("⚠️ Recording too short")
                isRecording = false
                audioRecorder.stopRecording()
                
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
            print("❌ No audio URL")
            resetState()
            return
        }
        
        DispatchQueue.main.async {
            FloatingWindowManager.shared.showFloatingIndicator(isRecording: false, isTranscribing: true)
        }
        
        // Get context and store it
        let appContext = AppContextDetector.getCurrentAppContext()
        currentContext = appContext
        
        Task { [weak self] in
            guard let self = self else { return }
            
            await self.transcriptionService.transcribe(audioURL: audioURL, context: appContext)
            
            if let error = self.transcriptionService.error {
                print("❌ Error: \(error)")
                await MainActor.run {
                    self.resetState()
                }
            } else {
                let text = self.transcriptionService.transcription
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .lowercased()
                
                if self.isLikelyHallucination(text) {
                    print("⚠️ Hallucination detected")
                } else if text.isEmpty {
                    print("⚠️ Empty transcription")
                } else {
                    let originalText = self.transcriptionService.transcription
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    
                    // Pass context to TextInserter for formatting and smart spacing
                    TextInserter.insertText(originalText, context: self.currentContext)
                }
                
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
            .replacingOccurrences(of: " ", with: "")
        
        if hallucinations.contains(cleaned) {
            return true
        }
        
        if cleaned.contains("blankaudio") || cleaned.contains("blankmusic") {
            return true
        }
        
        if cleaned.count <= 2 {
            return true
        }
        
        return false
    }
    
    private func resetState() {
        isRecording = false
        isTranscribing = false
        recordingStartTime = nil
        currentContext = nil
        DispatchQueue.main.async {
            FloatingWindowManager.shared.hideFloatingIndicator()
        }
        print("♻️ Reset")
    }
}
