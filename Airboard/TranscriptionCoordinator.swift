//
//  TranscriptionCoordinator.swift
//  Airboard
//
//  Created by Dhruv Mehra on 03/12/25.
//

import Foundation
import AVFoundation
import Combine
import AppKit
import UserNotifications

class TranscriptionCoordinator: ObservableObject {
    static let shared = TranscriptionCoordinator()
    
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = LocalTranscriptionService()
    private var cancellables = Set<AnyCancellable>()
    
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    
    private var recordingStartTime: Date?
    private var currentContext: AppContext?
    
    // NEW: Store the target app when recording starts
    private var targetApp: NSRunningApplication?
    private var targetAppPID: pid_t?
    
    @Published private(set) var lastTranscribedText: String?
    @Published private(set) var lastContext: AppContext?

    private var hasCompletedFirstTranscription = false
    
    private let hallucinations = [
        "thank you", "thanks for watching", "bye", "goodbye", "you", ".",
        "", "[blank_audio]", "blank_audio", "[music]", "[silence]", "music", "silence"
    ]
    
    private init() {
        setupObservers()
    }
    
    private func setupObservers() {
        // WhisperKit download progress
        transcriptionService.$downloadProgress
            .sink { FloatingWindowManager.shared.showDownloadProgress(progress: $0) }
            .store(in: &cancellables)
        
        transcriptionService.$isDownloadingModel
            .sink { isDownloading in
                if !isDownloading {
                    FloatingWindowManager.shared.hideFloatingIndicator()
                }
            }
            .store(in: &cancellables)
        
        // Llama model download progress -> Show on floating icon
        ModelDownloadManager.shared.$downloadProgress
            .sink { progress in
                if ModelDownloadManager.shared.isDownloading {
                    FloatingWindowManager.shared.showDownloadProgress(progress: progress)
                }
            }
            .store(in: &cancellables)
        
        // Llama model download completion -> Notify user
        ModelDownloadManager.shared.$isModelReady
            .sink { [weak self] isReady in
                if isReady {
                    self?.notifyModelReady()
                }
            }
            .store(in: &cancellables)
    }
    
    private func notifyModelReady() {
        // Buzz the floating icon
        FloatingWindowManager.shared.hideFloatingIndicator()
        
        // Show macOS notification using modern API
        let content = UNMutableNotificationContent()
        content.title = "Airboard"
        content.body = "AI Enhancements ready"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Notification error: \(error.localizedDescription)")
            }
        }
        
        // Load Llama model in background
        Task.detached(priority: .background) {
            try? await LlamaService.shared.loadModel()
        }
        
        print("🎉 LLM is ready - AI enhancements activated")
    }
    
    func initialize() async {
        await transcriptionService.ensureModelReady()
        
        // Request notification permission (async version)
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if granted {
                print("✅ Notification permission granted")
            } else {
                print("⚠️ Notification permission denied")
            }
        } catch {
            print("⚠️ Notification permission error: \(error.localizedDescription)")
        }
        
        if ModelDownloadManager.shared.isModelReady {
            Task.detached(priority: .background) {
                try? await LlamaService.shared.loadModel()
            }
        }
    }
    
    func startRecording() {
        guard !isRecording && !isTranscribing else { return }
        
        if transcriptionService.isDownloadingModel {
            showDownloadingAlert()
            return
        }
        
        // IMPORTANT: Capture the target app NOW, before recording starts
        // This is the app where text will be inserted
        targetApp = NSWorkspace.shared.frontmostApplication
        targetAppPID = targetApp?.processIdentifier
        
        // Also capture context now
        currentContext = AppContextDetector.getCurrentAppContext()
        
        print("🎯 Target app captured: \(targetApp?.localizedName ?? "Unknown") (PID: \(targetAppPID ?? 0))")
        
        isRecording = true
        recordingStartTime = Date()
        
        FloatingWindowManager.shared.showFloatingIndicator(isRecording: true, isTranscribing: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.audioRecorder.startRecording()
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        if transcriptionService.isDownloadingModel {
            return
        }
        
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < 0.3 {
                cancelRecording()
                return
            }
        }
        
        isRecording = false
        isTranscribing = true
        audioRecorder.stopRecording()
        
        guard let audioURL = audioRecorder.recordingURL else {
            resetState()
            return
        }
        
        FloatingWindowManager.shared.showFloatingIndicator(isRecording: false, isTranscribing: true)
        
        // NOTE: We already captured currentContext in startRecording()
        // Don't recapture here as the user may have switched apps
        
        Task { await processTranscription(audioURL: audioURL) }
    }
    
    private func processTranscription(audioURL: URL) async {
        await transcriptionService.transcribe(audioURL: audioURL, context: currentContext)
        
        if let error = transcriptionService.error {
            print("❌ Transcription error: \(error)")
            await resetStateAsync()
            return
        }
        
        let text = transcriptionService.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !isLikelyHallucination(text.lowercased()), !text.isEmpty else {
            print("⚠️ Invalid transcription")
            await resetStateAsync()
            return
        }
        
        lastTranscribedText = text  // Store for feedback
        lastContext = currentContext
        
        // IMPORTANT: Insert text into the TARGET app, not the current frontmost app
        await MainActor.run {
            insertTextIntoTargetApp(text)
        }
        
        // Show ModelDownloadView after first successful transcription (if model not ready)
        if !hasCompletedFirstTranscription && !ModelDownloadManager.shared.isModelReady {
            hasCompletedFirstTranscription = true
            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
            }
        }
        
        await MainActor.run {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                FloatingWindowManager.shared.hideFloatingIndicator()
                self.resetState()
            }
        }
    }
    
    /// Insert text into the app that was active when recording started
    private func insertTextIntoTargetApp(_ text: String) {
        guard let targetPID = targetAppPID else {
            print("⚠️ No target app captured, inserting into frontmost app")
            TextInserter.insertText(text, context: currentContext)
            return
        }
        
        // Check if target app is still running
        guard let targetApp = targetApp, !targetApp.isTerminated else {
            print("⚠️ Target app is no longer running, inserting into frontmost app")
            TextInserter.insertText(text, context: currentContext)
            return
        }
        
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let needToSwitch = currentFrontmost?.processIdentifier != targetPID
        
        if needToSwitch {
            print("🔄 Switching back to target app: \(targetApp.localizedName ?? "Unknown")")
            
            // Activate the target app
            targetApp.activate()
            
            // Wait a moment for the app to come to front
            usleep(150000) // 0.15 seconds
        }
        
        // Now insert the text
        TextInserter.insertText(text, context: currentContext)
        
        print("✅ Text inserted into: \(targetApp.localizedName ?? "Unknown")")
    }
    
    private func cancelRecording() {
        isRecording = false
        audioRecorder.stopRecording()
        if let audioURL = audioRecorder.recordingURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        resetState()
    }
    
    private func resetState() {
        isRecording = false
        isTranscribing = false
        recordingStartTime = nil
        currentContext = nil
        targetApp = nil
        targetAppPID = nil
        FloatingWindowManager.shared.hideFloatingIndicator()
    }
    
    private func resetStateAsync() async {
        await MainActor.run { resetState() }
    }
    
    private func isLikelyHallucination(_ text: String) -> Bool {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        return hallucinations.contains(cleaned) ||
               cleaned.contains("blankaudio") ||
               cleaned.count <= 2
    }
    
    private func showDownloadingAlert() {
        let alert = NSAlert()
        alert.messageText = "Whisper Model Downloading"
        alert.informativeText = "Please wait while the speech recognition model downloads."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
