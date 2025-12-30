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
    @Published private(set) var currentMode: RecordingMode = .dictation
    
    private var recordingStartTime: Date?
    private var currentContext: AppContext?
    
    // Store the target app when recording starts
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
        FloatingWindowManager.shared.hideFloatingIndicator()
        
        let content = UNMutableNotificationContent()
        content.title = "Airboard"
        content.body = "AI Enhancements ready"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Notification error: \(error.localizedDescription)")
            }
        }
        
        Task.detached(priority: .background) {
            try? await LlamaService.shared.loadModel()
        }
        
        print("🎉 LLM is ready - AI enhancements activated")
    }
    
    func initialize() async {
        await transcriptionService.ensureModelReady()
        
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
    
    // MARK: - Recording (Dictation Mode)
    
    func startRecording() {
        startRecordingWithMode(.dictation)
    }
    
    // MARK: - Recording (Command Mode)
    
    func startCommandRecording() {
        startRecordingWithMode(.command)
    }
    
    // MARK: - Unified Recording Start
    
    private func startRecordingWithMode(_ mode: RecordingMode) {
        guard !isRecording && !isTranscribing else { return }
        
        if transcriptionService.isDownloadingModel {
            showDownloadingAlert()
            return
        }
        
        // Set the mode
        currentMode = mode
        
        // Capture the target app NOW, before recording starts
        targetApp = NSWorkspace.shared.frontmostApplication
        targetAppPID = targetApp?.processIdentifier
        
        // Also capture context now
        currentContext = AppContextDetector.getCurrentAppContext()
        
        print("🎯 Target app captured: \(targetApp?.localizedName ?? "Unknown") (PID: \(targetAppPID ?? 0))")
        print("📍 Recording mode: \(mode == .command ? "COMMAND ⚡" : "DICTATION 🎤")")
        
        isRecording = true
        recordingStartTime = Date()
        
        // Show appropriate visual feedback based on mode
        FloatingWindowManager.shared.showFloatingIndicator(
            isRecording: true,
            isTranscribing: false,
            isCommandMode: mode == .command
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.audioRecorder.startRecording()
        }
    }
    
    // MARK: - Stop Recording

    func stopRecording(mode: RecordingMode? = nil) {
        guard isRecording else { return }
        
        // Use passed mode if available (handles mid-recording mode upgrades)
        if let mode = mode {
            self.currentMode = mode
            print("📍 Final mode: \(mode == .command ? "COMMAND" : "DICTATION")")
        }
        
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
        
        FloatingWindowManager.shared.showFloatingIndicator(
            isRecording: false,
            isTranscribing: true,
            isCommandMode: currentMode == .command
        )
        
        Task { await processTranscription(audioURL: audioURL) }
    }
    
    // MARK: - Process Transcription
    
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
        
        lastTranscribedText = text
        lastContext = currentContext
        
        print("📝 Transcription: \"\(text)\"")
        print("📍 Mode: \(currentMode == .command ? "COMMAND" : "DICTATION")")
        
        // Handle based on mode
        if currentMode == .command {
            await handleCommandMode(text: text)
        } else {
            await handleDictationMode(text: text)
        }
        
        await MainActor.run {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                FloatingWindowManager.shared.hideFloatingIndicator()
                self.resetState()
            }
        }
    }
    
    // MARK: - Command Mode Handler
    
    private func handleCommandMode(text: String) async {
        print("⚡ Processing as COMMAND: \(text)")
        
        let parsedCommand = CommandDetector.detect(text)
        
        await MainActor.run {
            if parsedCommand.isValid {
                print("✅ Valid command detected: \(parsedCommand.type)")
                let success = CommandExecutor.execute(parsedCommand)
                
                if success {
                    FloatingWindowManager.shared.showCommandExecuted()
                }
            } else {
                print("❓ Could not parse command: \(text)")
                // Show notification for unknown command
                let content = UNMutableNotificationContent()
                content.title = "Unknown Command"
                content.body = "Couldn't understand: \(text)"
                content.sound = .default
                
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request)
            }
        }
    }
    
    // MARK: - Dictation Mode Handler
    
    private func handleDictationMode(text: String) async {
        print("🎤 Processing as DICTATION: \(text)")
        
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
    }
    
    // MARK: - Insert Text
    
    private func insertTextIntoTargetApp(_ text: String) {
        guard let targetPID = targetAppPID else {
            print("⚠️ No target app captured, inserting into frontmost app")
            TextInserter.insertText(text, context: currentContext)
            return
        }
        
        guard let targetApp = targetApp, !targetApp.isTerminated else {
            print("⚠️ Target app is no longer running, inserting into frontmost app")
            TextInserter.insertText(text, context: currentContext)
            return
        }
        
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let needToSwitch = currentFrontmost?.processIdentifier != targetPID
        
        if needToSwitch {
            print("🔄 Switching back to target app: \(targetApp.localizedName ?? "Unknown")")
            targetApp.activate()
            usleep(150000) // 0.15 seconds
        }
        
        TextInserter.insertText(text, context: currentContext)
        print("✅ Text inserted into: \(targetApp.localizedName ?? "Unknown")")
    }
    
    // MARK: - Cancel & Reset
    
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
        currentMode = .dictation
        FloatingWindowManager.shared.hideFloatingIndicator()
    }
    
    private func resetStateAsync() async {
        await MainActor.run { resetState() }
    }
    
    // MARK: - Helpers
    
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
