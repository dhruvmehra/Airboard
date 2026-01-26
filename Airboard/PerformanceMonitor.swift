//
//  PerformanceMonitor.swift
//  Airboard
//
//  Tracks real-time performance metrics for transcription and grammar correction
//

import Foundation
import Combine

class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    // MARK: - Published Metrics

    @Published var currentSession: SessionMetrics?
    @Published var memoryUsageMB: Double = 0
    @Published var totalSystemMemoryMB: Double = 0
    @Published var isRecording: Bool = false

    // MARK: - Data Structures

    struct SessionMetrics {
        var recordingDuration: TimeInterval = 0
        var transcriptionTime: TimeInterval = 0
        var grammarCorrectionTime: TimeInterval = 0
        var totalProcessingTime: TimeInterval = 0

        var inputText: String = ""
        var outputText: String = ""

        var inputTokenCount: Int = 0
        var outputTokenCount: Int = 0

        var timestamp: Date = Date()
    }

    struct TimingBreakdown {
        var audioRecording: TimeInterval = 0
        var whisperTranscription: TimeInterval = 0
        var t5Tokenization: TimeInterval = 0
        var t5Encoding: TimeInterval = 0
        var t5Decoding: TimeInterval = 0
        var sentencePieceDecode: TimeInterval = 0
    }

    // MARK: - Private State

    private var recordingStartTime: Date?
    private var processingStartTime: Date? // When recording stops and processing begins
    private var transcriptionStartTime: Date?
    private var grammarStartTime: Date?

    private var memoryUpdateTimer: Timer?

    private init() {
        getTotalSystemMemory()
        startMemoryMonitoring()
    }

    // MARK: - System Memory

    private func getTotalSystemMemory() {
        let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        totalSystemMemoryMB = Double(totalMemoryBytes) / 1024.0 / 1024.0
    }

    // MARK: - Session Tracking

    func startRecording() {
        recordingStartTime = Date()
        isRecording = true
        currentSession = SessionMetrics()
    }

    func stopRecording() {
        if let start = recordingStartTime {
            currentSession?.recordingDuration = Date().timeIntervalSince(start)
        }
        recordingStartTime = nil
        isRecording = false

        // Start tracking total processing time (from when recording stops to final output)
        processingStartTime = Date()
    }

    func startTranscription() {
        transcriptionStartTime = Date()
    }

    func endTranscription(inputText: String) {
        if let start = transcriptionStartTime {
            let duration = Date().timeIntervalSince(start)
            currentSession?.transcriptionTime = duration
            currentSession?.inputText = inputText
        }
        transcriptionStartTime = nil
    }

    func startGrammarCorrection() {
        grammarStartTime = Date()
    }

    func endGrammarCorrection(outputText: String, inputTokens: Int, outputTokens: Int) {
        if let start = grammarStartTime {
            let duration = Date().timeIntervalSince(start)
            currentSession?.grammarCorrectionTime = duration
            currentSession?.outputText = outputText
            currentSession?.inputTokenCount = inputTokens
            currentSession?.outputTokenCount = outputTokens
        }
        grammarStartTime = nil

        // Calculate ACTUAL end-to-end total processing time
        // From when recording stopped to when final corrected text is ready
        if let processingStart = processingStartTime {
            let actualTotal = Date().timeIntervalSince(processingStart)
            currentSession?.totalProcessingTime = actualTotal

            print("📊 PerformanceMonitor: End-to-end latency")
            print("   Transcription: \(Int((currentSession?.transcriptionTime ?? 0) * 1000))ms")
            print("   Grammar: \(Int((currentSession?.grammarCorrectionTime ?? 0) * 1000))ms")
            print("   TOTAL (wall-clock): \(Int(actualTotal * 1000))ms")

            processingStartTime = nil
        }
    }

    func finalizeWithoutGrammar() {
        // Called when grammar correction is skipped
        // Calculate total time from processing start to now
        if let processingStart = processingStartTime {
            let actualTotal = Date().timeIntervalSince(processingStart)
            currentSession?.totalProcessingTime = actualTotal

            print("📊 PerformanceMonitor: End-to-end latency (no grammar)")
            print("   Transcription: \(Int((currentSession?.transcriptionTime ?? 0) * 1000))ms")
            print("   Grammar: SKIPPED")
            print("   TOTAL (wall-clock): \(Int(actualTotal * 1000))ms")

            processingStartTime = nil
        }
    }

    func clearSession() {
        currentSession = nil
    }

    // MARK: - Memory Monitoring

    private func startMemoryMonitoring() {
        // Update memory usage every 2 seconds
        memoryUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMemoryUsage()
        }
        updateMemoryUsage()
    }

    private func updateMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let usedMemoryBytes = Double(info.resident_size)
            DispatchQueue.main.async {
                self.memoryUsageMB = usedMemoryBytes / 1024.0 / 1024.0
            }
        }
    }

    deinit {
        memoryUpdateTimer?.invalidate()
    }
}
