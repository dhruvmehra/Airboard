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
    private let transcriptionService = ParakeetTranscriptionService()
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

    // Model readiness mirrors for onboarding's Try It step (the service
    // itself is private to the coordinator).
    @Published private(set) var isModelReady = false
    @Published private(set) var modelDownloadProgress: Double = 0

    private var hasCompletedFirstTranscription = false

    // Bumped every time a new recording session starts. Deferred/async work
    // tied to an older session captures its generation up front and checks
    // it before touching shared state — a flag-based guard (isRecording/
    // isTranscribing) can't tell "my own session is still in flight" apart
    // from "a newer session started," which bricked recording after a
    // normal dictation (see commit b391f13 postmortem).
    private var sessionGeneration = 0

    // Chunked recording state
    private var accumulatedText: String = ""
    private var processingChunks: Set<Int> = []

    private let hallucinations = [
        "thank you", "thanks for watching", "bye", "goodbye", "you", ".",
        "", "[blank_audio]", "blank_audio", "[music]", "[silence]", "music", "silence"
    ]

    // Common speech-model hallucinations (phrases that indicate the model is hallucinating)
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
        // Transcription service download progress
        transcriptionService.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.modelDownloadProgress = progress
                FloatingWindowManager.shared.showDownloadProgress(progress: progress)
            }
            .store(in: &cancellables)

        // When the model becomes fully ready (downloaded + warmed up), clear the
        // download state and pulse the floating icon so the user knows it's usable.
        transcriptionService.$isModelReady
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                self?.isModelReady = ready
                guard ready else { return }
                FloatingWindowManager.shared.hideFloatingIndicator()
                NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
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

        // Covers both downloading AND warm-up — transcribing before the model is
        // fully ready would block for minutes with the icon stuck on orange.
        if !transcriptionService.isModelReady {
            showDownloadingAlert()
            return
        }
        
        // New session — invalidate any deferred cleanup/indicator work still
        // in flight from a previous session.
        sessionGeneration += 1

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

        // Start the mic FIRST — users speak the moment they press the key, and
        // any delay here clips the first word. UI feedback comes second.
        audioRecorder.startRecording()

        // Track performance
        PerformanceMonitor.shared.startRecording()

        // Show appropriate visual feedback based on mode
        FloatingWindowManager.shared.showFloatingIndicator(
            isRecording: true,
            isTranscribing: false,
            isCommandMode: mode == .command
        )
    }
    
    // MARK: - Stop Recording

    func stopRecording(mode: RecordingMode? = nil) {
        guard isRecording else { return }
        
        // Use passed mode if available (handles mid-recording mode upgrades)
        if let mode = mode {
            self.currentMode = mode
            print("📍 Final mode: \(mode == .command ? "COMMAND" : "DICTATION")")
        }
        
        // Model became unavailable mid-recording — cancel cleanly instead of
        // returning with isRecording still true (which left the mic running
        // and the indicator stuck).
        if !transcriptionService.isModelReady {
            cancelRecording()
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

        FloatingWindowManager.shared.showFloatingIndicator(
            isRecording: false,
            isTranscribing: true,
            isCommandMode: currentMode == .command
        )

        // Capture a short tail after key release — users release the key as they
        // finish speaking, and stopping instantly clips the last syllable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }

            self.audioRecorder.stopRecording()

            // Stop recording timer, start transcription timer
            PerformanceMonitor.shared.stopRecording()
            PerformanceMonitor.shared.startTranscription()

            guard let audioURL = self.audioRecorder.recordingURL else {
                self.resetState()
                return
            }

            Task { await self.processTranscription(audioURL: audioURL) }
        }
    }

    // MARK: - Hands-Free Mode (Chunked Recording)

    func startHandsFreeRecording() {
        guard !isRecording && !isTranscribing else { return }

        if !transcriptionService.isModelReady {
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
            await transcriptionService.transcribe(audioURL: url)

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

            let chunkOutcome = await TranscriptPostProcessor.process(text, context: currentContext, mode: .handsFreeChunk)
            let cleanedText = chunkOutcome.text
            recordDictationMetrics(mode: "handsfree", outcome: chunkOutcome)
            print("✅ Chunk \(chunkNumber) FINAL TEXT: '\(cleanedText)'")

            // Accumulate text
            await MainActor.run {
                if !accumulatedText.isEmpty {
                    accumulatedText += " "
                }
                accumulatedText += cleanedText

                // Insert text immediately for real-time feedback
                if isHandsFreeMode {
                    insertTextIntoTargetApp(cleanedText)
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
        await transcriptionService.transcribe(audioURL: audioURL)
        
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
        
        // End transcription timing BEFORE the cleanup await — the metric
        // measures ASR, not LLM round-trip time.
        PerformanceMonitor.shared.endTranscription(inputText: text)

        let mode = currentMode
        let processOutcome = await TranscriptPostProcessor.process(
            text,
            context: currentContext,
            mode: mode == .command ? .command : .dictation
        )
        let cleanedText = processOutcome.text
        recordDictationMetrics(
            mode: mode == .command ? "command" : "dictation",
            outcome: processOutcome)
        // Keep the RAW transcript for the report-issue flow so cleanup bugs
        // are diagnosable (what the ASR heard vs what was inserted).
        lastTranscribedText = text
        lastContext = currentContext

        print("📝 Transcription: \"\(cleanedText)\"")
        print("📍 Mode: \(mode == .command ? "COMMAND" : "DICTATION")")

        // Handle based on mode
        if mode == .command {
            await handleCommandMode(text: cleanedText)
        } else {
            await handleDictationMode(text: cleanedText)
        }
        
        await MainActor.run {
            // Snapshot this session's generation before scheduling — if a
            // new session starts before this fires, the counter will have
            // moved on and this stale block becomes a no-op instead of
            // wiping out the new session's state (or, when nothing new
            // started, this is always still our own session so it must run
            // unconditionally to actually clear isTranscribing).
            let gen = self.sessionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard gen == self.sessionGeneration else { return }
                FloatingWindowManager.shared.hideFloatingIndicator()
                self.resetState()
            }
        }
    }
    
    /// One funnel for every completed dictation: local log always,
    /// telemetry when its gates allow.
    private func recordDictationMetrics(mode: String, outcome: ProcessOutcome) {
        let record = DictationRecord(
            ts: Date(),
            mode: mode,
            audioSeconds: transcriptionService.lastAudioSeconds,
            sttMs: transcriptionService.lastSttMs,
            llmMs: outcome.llmMs,
            llmOutcome: outcome.llmOutcome,
            words: outcome.text.split(separator: " ").count,
            preview: String(outcome.text.prefix(40)))
        PerformanceLog.shared.append(record)
        TelemetryService.shared.dictationCompleted(record: record)
    }

    private func recordAssistantMetrics(question: String, outcome: AssistantOutcome, durationMs: Int) {
        let outcomeString: String
        switch outcome {
        case .answer: outcomeString = "ok"
        case .unsupported: outcomeString = "unsupported"
        case .needsPi, .needsKey: outcomeString = "setup_missing"
        case .timeout: outcomeString = "timeout"
        case .failure: outcomeString = "error"
        }
        let record = DictationRecord(
            ts: Date(),
            mode: "assistant",
            audioSeconds: transcriptionService.lastAudioSeconds,
            sttMs: transcriptionService.lastSttMs,
            llmMs: durationMs,
            llmOutcome: outcomeString,
            words: question.split(separator: " ").count,
            preview: String(question.prefix(40)))
        PerformanceLog.shared.append(record)
        TelemetryService.shared.assistantAsked(durationMs: durationMs, outcome: outcomeString)
    }

    // MARK: - Command Mode Handler
    
    private func handleCommandMode(text: String) async {
        print("⚡ Processing as COMMAND: \(text)")

        // Memory commands (teach / correct / recall) take precedence over
        // the regular command table. Non-memory text falls straight through.
        var llm: ((String, String) async throws -> String)?
        if TranscriptRefiner.shared.isFullyConfigured {
            // 6s deadline per call (same discipline as the cleanup path):
            // command mode can chain two calls (classify → recall), and a
            // hung server must not freeze the pill for the transport's
            // full 10s each.
            llm = { system, user in
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await TranscriptRefiner.shared.complete(system: system, user: user)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 6_000_000_000)
                        throw TranscriptRefiner.RefineError.timeout
                    }
                    guard let first = try await group.next() else {
                        throw TranscriptRefiner.RefineError.timeout
                    }
                    group.cancelAll()
                    return first
                }
            }
        }
        let memoryOutcome = await MemoryCommands.handle(
            text: text, store: MemoryStore.shared, llm: llm)
        if await dispatchMemoryOutcome(memoryOutcome) { return }

        // Voice editing: "delete all", "delete last N words/sentences",
        // "scratch that" — exact patterns, keystroke-executed, instant.
        if let editIntent = EditCommands.detect(text) {
            await MainActor.run {
                if let description = TextInserter.performEdit(editIntent) {
                    print("🗑️ Edit: \(description)")
                    FloatingWindowManager.shared.showCommandExecuted()
                    FloatingWindowManager.shared.showToast(description)
                } else {
                    FloatingWindowManager.shared.showToast(
                        "Nothing to delete — dictate something here first")
                }
            }
            return
        }

        let parsedCommand = CommandDetector.detect(text)
        if parsedCommand.isValid {
            print("✅ Valid command detected: \(parsedCommand.type)")
            await MainActor.run {
                let success = CommandExecutor.execute(parsedCommand)
                if success {
                    FloatingWindowManager.shared.showCommandExecuted()
                }
            }
            return
        }

        // Nothing matched exactly — one LLM pass interprets the utterance
        // before giving up. Any phrasing of "save this" ("don't forget…",
        // "note that…", "keep in mind…") becomes a memory intent; the
        // confirmation card remains the guard against misreads.
        let interpreted = await MemoryCommands.classify(
            text: text, store: MemoryStore.shared, llm: llm)
        if await dispatchMemoryOutcome(interpreted) { return }

        // Nothing claimed the utterance — hand it to the assistant.
        print("🤖 Assistant ask: \(text)")
        await MainActor.run {
            FloatingWindowManager.shared.showFloatingIndicator(
                isRecording: false, isTranscribing: true, isCommandMode: true)
        }
        // Asks can take up to ~60s (timeout). Clear the recording-lock flag
        // now so a hotkey press during the ask starts a fresh dictation
        // instead of silently no-opping against a stale "still busy" state.
        // The floating indicator above stays as assistant-visual feedback;
        // this only clears the gate `startRecordingWithMode` checks.
        let gen = await MainActor.run { () -> Int in
            self.isTranscribing = false
            return self.sessionGeneration
        }
        let (outcome, durationMs) = await AssistantService.shared.ask(text)
        await MainActor.run {
            // A new session may have started while we awaited the ask —
            // don't stomp its indicator with "nothing happening" state.
            if gen == self.sessionGeneration {
                FloatingWindowManager.shared.showFloatingIndicator(
                    isRecording: false, isTranscribing: false, isCommandMode: false)
            }
            switch outcome {
            case .answer(let answer):
                FloatingWindowManager.shared.showCommandExecuted()
                FloatingWindowManager.shared.showToast(answer, duration: 8.0)
            case .unsupported:
                FloatingWindowManager.shared.showToast("The assistant can't do that yet", duration: 4.0)
            case .needsPi:
                FloatingWindowManager.shared.showToast("Assistant isn't set up yet — open Assistant settings", duration: 5.0)
            case .needsKey:
                FloatingWindowManager.shared.showToast("Add your OpenRouter key in Assistant settings", duration: 5.0)
            case .timeout:
                FloatingWindowManager.shared.showToast("Assistant timed out", duration: 4.0)
            case .failure:
                FloatingWindowManager.shared.showToast("Assistant had a problem", duration: 4.0)
            }
        }
        recordAssistantMetrics(question: text, outcome: outcome, durationMs: durationMs)
    }

    /// Act on a memory outcome. Returns false for .notMemoryCommand so the
    /// caller can keep interpreting the utterance.
    private func dispatchMemoryOutcome(_ outcome: MemoryCommandOutcome) async -> Bool {
        switch outcome {
        case .notMemoryCommand:
            return false
        case .confirmFact(let cleaned, let heard):
            print("🧠 Memory: confirming fact '\(cleaned)' (heard: '\(heard)')")
            await MainActor.run {
                FloatingWindowManager.shared.showMemoryConfirm(
                    cleaned: cleaned, heard: heard,
                    onSave: { savedText in
                        let store = MemoryStore.shared
                        store.addMemory(savedText)
                        // Edits teach: single-word corrections become
                        // spelling memories ("reparty" -> "Ashish").
                        for pair in MemoryBias.editDiffPairs(heard: heard, saved: savedText) {
                            store.addMemory(MemoryBias.spellingMemory(term: pair.term, heardAs: pair.heardAs))
                        }
                        print("🧠 Memory: stored '\(savedText)'")
                        FloatingWindowManager.shared.showToast("Remembered: \(savedText)")
                    },
                    onCancel: {
                        print("🧠 Memory: confirmation cancelled")
                    })
            }
            return true
        case .learned(let term):
            print("🧠 Memory: learned spelling '\(term)'")
            await MainActor.run {
                FloatingWindowManager.shared.showCommandExecuted()
                FloatingWindowManager.shared.showToast("Learned spelling: \(term)")
                self.showNotification(title: "Learned spelling", body: term)
            }
            return true
        case .recall(let recalledText):
            print("🧠 Memory: recall inserting '\(recalledText)'")
            await MainActor.run {
                self.insertTextIntoTargetApp(recalledText)
            }
            return true
        case .recallFailed(let query):
            print("🧠 Memory: recall failed for '\(query)'")
            await MainActor.run {
                FloatingWindowManager.shared.showToast("Nothing remembered about \(query)")
                self.showNotification(title: "Airboard Memory",
                                      body: "Nothing remembered about \(query)")
            }
            return true
        }
    }

    // MARK: - Dictation Mode Handler
    
    private func handleDictationMode(text: String) async {
        print("🎤 Processing as DICTATION: \(text)")
        
        await MainActor.run {
            insertTextIntoTargetApp(text)
        }
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
