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
        // WhisperKit download progress (represents 50% of total progress)
        transcriptionService.$downloadProgress
            .sink { progress in
                FloatingWindowManager.shared.showDownloadProgress(progress: progress * 0.5)
            }
            .store(in: &cancellables)

        transcriptionService.$isDownloadingModel
            .sink { isDownloading in
                if !isDownloading {
                    // Check if grammar is also done
                    if !GrammarCorrectionService.shared.isDownloadingModel {
                        FloatingWindowManager.shared.hideFloatingIndicator()
                    }
                }
            }
            .store(in: &cancellables)

        // Grammar service download progress (represents the other 50% of total progress)
        GrammarCorrectionService.shared.$downloadProgress
            .sink { progress in
                FloatingWindowManager.shared.showDownloadProgress(progress: 0.5 + (progress * 0.5))
            }
            .store(in: &cancellables)

        GrammarCorrectionService.shared.$isDownloadingModel
            .sink { isDownloading in
                if !isDownloading {
                    // Check if WhisperKit is also done
                    if !self.transcriptionService.isDownloadingModel {
                        FloatingWindowManager.shared.hideFloatingIndicator()
                    }
                }
            }
            .store(in: &cancellables)
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
        
        // Grammar service initializes automatically
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
        
        if transcriptionService.isDownloadingModel || GrammarCorrectionService.shared.isDownloadingModel {
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
        
        if transcriptionService.isDownloadingModel || GrammarCorrectionService.shared.isDownloadingModel {
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
        
        // No model download needed - grammar service is instant
    }
    
    // MARK: - Insert Text
    
    private func insertTextIntoTargetApp(_ text: String) {
        guard let targetPID = targetAppPID else {
            print("⚠️ No target app captured, inserting into frontmost app")
            handleInsertionResult(TextInserter.insertText(text, context: currentContext))
            return
        }

        guard let targetApp = targetApp, !targetApp.isTerminated else {
            print("⚠️ Target app is no longer running, inserting into frontmost app")
            handleInsertionResult(TextInserter.insertText(text, context: currentContext))
            return
        }

        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let needToSwitch = currentFrontmost?.processIdentifier != targetPID

        if needToSwitch {
            print("🔄 Switching back to target app: \(targetApp.localizedName ?? "Unknown")")

            // Retry app switching up to 3 times
            var switched = false
            for attempt in 1...3 {
                targetApp.activate()
                usleep(150000) // 0.15 seconds

                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                    switched = true
                    break
                }

                if attempt < 3 {
                    print("⚠️ App switch attempt \(attempt) failed, retrying...")
                    usleep(100000) // Additional delay before retry
                }
            }

            if !switched {
                print("❌ Failed to switch to target app after 3 attempts")
            }
        }

        let result = TextInserter.insertText(text, context: currentContext)
        handleInsertionResult(result)

        if case .success = result {
            print("✅ Text inserted into: \(targetApp.localizedName ?? "Unknown")")
        }
    }

    private func handleInsertionResult(_ result: Result<Void, TextInsertionError>) {
        switch result {
        case .success:
            break // Success is handled by caller
        case .failure(let error):
            print("❌ Text insertion failed: \(error)")

            switch error {
            case .accessibilityPermissionDenied:
                DispatchQueue.main.async {
                    SetupWindowController.shared.showPermissionSetup()
                }
            case .noFrontmostApp:
                showNotification(title: "Insertion Failed", body: "No app is active to receive text")
            case .eventCreationFailed:
                showNotification(title: "Insertion Failed", body: "Failed to create keyboard events")
            case .insertionFailed(let message):
                showNotification(title: "Insertion Failed", body: message)
            }
        }
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to show notification: \(error)")
            }
        }
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
        FloatingWindowManager.shared.showDownloadModal()
    }
}
