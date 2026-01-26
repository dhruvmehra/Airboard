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
    private let chunkedRecorder = ChunkedAudioRecorder()
    private let transcriptionService = LocalTranscriptionService()
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var currentMode: RecordingMode = .dictation
    @Published private(set) var isHandsFreeMode = false

    private var recordingStartTime: Date?
    private var currentContext: AppContext?

    // Store the target app when recording starts
    private var targetApp: NSRunningApplication?
    private var targetAppPID: pid_t?

    @Published private(set) var lastTranscribedText: String?
    @Published private(set) var lastContext: AppContext?

    private var hasCompletedFirstTranscription = false

    // Chunked recording state
    private var accumulatedText: String = ""
    private var processingChunks: Set<Int> = []

    private let hallucinations = [
        "thank you", "thanks for watching", "bye", "goodbye", "you", ".",
        "", "[blank_audio]", "blank_audio", "[music]", "[silence]", "music", "silence"
    ]

    // Common Whisper hallucinations (phrases that indicate the model is hallucinating)
    private let hallucinationPhrases = [
        "subscribe to the channel",
        "hit the bell icon",
        "thanks for watching",
        "please like and subscribe",
        "don't forget to subscribe",
        "hope you enjoyed",
        "see you in the next",
        "catch you in the next"
    ]
    
    private init() {
        setupObservers()
        setupChunkedRecorder()
    }

    private func setupChunkedRecorder() {
        // Handle chunk completion - transcribe each chunk as it's ready
        chunkedRecorder.onChunkComplete = { [weak self] url, chunkNumber in
            self?.handleChunkCompletion(url: url, chunkNumber: chunkNumber)
        }

        // Handle full recording completion
        chunkedRecorder.onRecordingComplete = { [weak self] in
            self?.handleRecordingCompletion()
        }
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

        // Track performance
        PerformanceMonitor.shared.startRecording()

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

        // Stop recording timer, start transcription timer
        PerformanceMonitor.shared.stopRecording()
        PerformanceMonitor.shared.startTranscription()

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

    // MARK: - Hands-Free Mode (Chunked Recording)

    func startHandsFreeRecording() {
        guard !isRecording && !isTranscribing else { return }

        if transcriptionService.isDownloadingModel || GrammarCorrectionService.shared.isDownloadingModel {
            showDownloadingAlert()
            return
        }

        // Capture target app and context
        targetApp = NSWorkspace.shared.frontmostApplication
        targetAppPID = targetApp?.processIdentifier
        currentContext = AppContextDetector.getCurrentAppContext()
        currentMode = .dictation // Hands-free is always dictation mode

        print("🆓 Starting hands-free mode (double-tap activated)")
        print("🎯 Target app: \(targetApp?.localizedName ?? "Unknown")")

        isRecording = true
        isHandsFreeMode = true
        recordingStartTime = Date()
        accumulatedText = ""
        processingChunks.removeAll()

        // Track performance
        PerformanceMonitor.shared.startRecording()

        // Show recording indicator
        FloatingWindowManager.shared.showFloatingIndicator(
            isRecording: true,
            isTranscribing: false,
            isCommandMode: false
        )

        // Start chunked recording
        chunkedRecorder.startRecording()
    }

    func stopHandsFreeRecording() {
        guard isRecording && isHandsFreeMode else {
            // If already stopping (isRecording=false but isHandsFreeMode=true),
            // ignore duplicate stop requests
            if isHandsFreeMode && !isRecording {
                print("⚠️ Hands-free mode already stopping, ignoring duplicate request")
                return
            }
            return
        }

        print("🛑 Stopping hands-free mode")

        isRecording = false
        isTranscribing = true // Mark as transcribing to prevent new recordings
        chunkedRecorder.stopRecording()

        // Update UI to show transcribing state
        FloatingWindowManager.shared.showFloatingIndicator(
            isRecording: false,
            isTranscribing: true,
            isCommandMode: false
        )

        // Wait for all pending chunks to finish transcribing
        // The final state reset will happen in handleRecordingCompletion()
    }

    // MARK: - Chunk Processing

    private func handleChunkCompletion(url: URL, chunkNumber: Int) {
        print("📥 Processing chunk \(chunkNumber)...")

        processingChunks.insert(chunkNumber)

        // Transcribe chunk in background
        Task {
            await transcriptionService.transcribe(audioURL: url, context: currentContext)

            if let error = transcriptionService.error {
                print("❌ Chunk \(chunkNumber) transcription error: \(error)")
                processingChunks.remove(chunkNumber)
                return
            }

            let text = transcriptionService.transcription.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !isLikelyHallucination(text.lowercased()), !text.isEmpty else {
                print("⚠️ Chunk \(chunkNumber) is hallucination, skipping")
                processingChunks.remove(chunkNumber)
                return
            }

            print("✅ Chunk \(chunkNumber) FINAL TEXT (after grammar): '\(text)'")

            // Accumulate text
            await MainActor.run {
                if !accumulatedText.isEmpty {
                    accumulatedText += " "
                }
                accumulatedText += text

                // Insert text immediately for real-time feedback
                if isHandsFreeMode {
                    insertTextIntoTargetApp(text)
                }
            }

            processingChunks.remove(chunkNumber)
        }
    }

    private func handleRecordingCompletion() {
        print("🏁 Hands-free recording completed")

        // Wait for ALL pending chunks to finish processing
        Task {
            var waitTime = 0.0
            let checkInterval = 0.5 // Check every 500ms
            let maxWaitTime = 30.0 // Maximum 30 seconds

            while !processingChunks.isEmpty && waitTime < maxWaitTime {
                print("⏳ Waiting for \(processingChunks.count) chunks to finish...")
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                waitTime += checkInterval
            }

            if !processingChunks.isEmpty {
                print("⚠️ Timeout: \(processingChunks.count) chunks still processing after \(Int(maxWaitTime))s")
            }

            await MainActor.run {
                if let startTime = self.recordingStartTime {
                    let duration = Date().timeIntervalSince(startTime)
                    print("⏱️ Total hands-free session: \(String(format: "%.1f", duration))s")
                    print("📝 Total transcribed: \(self.accumulatedText.count) characters")
                }

                // Reset state
                self.isTranscribing = false // Allow new recordings now
                PerformanceMonitor.shared.stopRecording()
                self.resetHandsFreeState()

                // Hide indicator
                FloatingWindowManager.shared.hideFloatingIndicator()
            }
        }
    }

    private func resetHandsFreeState() {
        isHandsFreeMode = false
        accumulatedText = ""
        processingChunks.removeAll()
        resetState()
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

        // End transcription timing
        PerformanceMonitor.shared.endTranscription(inputText: text)

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
        let lowercased = text.lowercased()

        // Check exact matches
        if hallucinations.contains(cleaned) {
            return true
        }

        // Check for common hallucination phrases (YouTube outros, etc.)
        for phrase in hallucinationPhrases {
            if lowercased.contains(phrase) {
                print("🚫 Detected hallucination phrase: '\(phrase)'")
                return true
            }
        }

        // Check for other hallucination indicators
        if cleaned.contains("blankaudio") || cleaned.count <= 2 {
            return true
        }

        return false
    }
    
    private func showDownloadingAlert() {
        FloatingWindowManager.shared.showDownloadModal()
    }
}
