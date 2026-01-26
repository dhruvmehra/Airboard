//
//  ChunkedAudioRecorder.swift
//  Airboard
//
//  Handles long-duration audio recording by splitting into manageable chunks
//  Each chunk is transcribed independently for real-time streaming results
//

import Foundation
import AVFoundation
import Combine

class ChunkedAudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var currentChunkNumber = 0
    @Published var totalDuration: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var chunkTimer: Timer?
    private var recordingStartTime: Date?
    private var currentChunkURL: URL?

    // Callbacks for chunk completion
    var onChunkComplete: ((URL, Int) -> Void)?
    var onRecordingComplete: (() -> Void)?

    // Configuration
    private let chunkDuration: TimeInterval = 30.0 // 30 seconds per chunk
    private let audioFormat: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,  // Mono
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    // MARK: - Start Recording

    func startRecording() {
        guard !isRecording else { return }

        setupAudioSession()

        isRecording = true
        recordingStartTime = Date()
        currentChunkNumber = 0
        totalDuration = 0

        print("🎬 Starting chunked recording (30s chunks)")
        startNextChunk()
    }

    private func setupAudioSession() {
        #if os(macOS)
        print("✅ macOS - using AVAudioRecorder with chunking")
        #else
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
            print("✅ Audio session configured for chunked recording")
        } catch {
            print("❌ Audio session setup failed: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Chunk Management

    private func startNextChunk() {
        let chunkFilename = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk_\(Date().timeIntervalSince1970)_\(currentChunkNumber).wav")

        do {
            audioRecorder = try AVAudioRecorder(url: chunkFilename, settings: audioFormat)
            audioRecorder?.prepareToRecord()

            let success = audioRecorder?.record() ?? false
            if success {
                currentChunkURL = chunkFilename
                print("📼 Chunk \(currentChunkNumber) started: \(chunkFilename.lastPathComponent)")

                // Schedule chunk rotation after 30 seconds
                scheduleChunkRotation()
            } else {
                print("❌ Failed to start chunk \(currentChunkNumber)")
            }
        } catch {
            print("❌ Failed to create chunk recorder: \(error.localizedDescription)")
        }
    }

    private func scheduleChunkRotation() {
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: false) { [weak self] _ in
            self?.rotateChunk()
        }

        // Add to common run loop mode so it fires even when UI is active
        RunLoop.main.add(chunkTimer!, forMode: .common)
    }

    private func rotateChunk() {
        guard isRecording else { return }

        print("🔄 Rotating to next chunk...")

        // Stop current chunk
        finalizeCurrentChunk()

        // Update metrics
        currentChunkNumber += 1
        if let startTime = recordingStartTime {
            totalDuration = Date().timeIntervalSince(startTime)
        }

        // Start next chunk immediately
        startNextChunk()
    }

    private func finalizeCurrentChunk() {
        guard let url = currentChunkURL else { return }

        audioRecorder?.stop()

        // Give recorder time to finalize file
        Thread.sleep(forTimeInterval: 0.1)

        // Process the chunk
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                let sizeKB = Double(fileSize) / 1024.0
                print("✅ Chunk \(currentChunkNumber) finalized: \(String(format: "%.1f", sizeKB))KB")

                if fileSize >= 1000 {
                    // Process audio for Whisper
                    processAudioForWhisper(url: url)

                    // Notify that chunk is ready for transcription
                    onChunkComplete?(url, currentChunkNumber)
                } else {
                    print("⚠️ Chunk too small, skipping")
                    try? FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            print("❌ Failed to finalize chunk: \(error.localizedDescription)")
        }

        currentChunkURL = nil
    }

    // MARK: - Stop Recording

    func stopRecording() {
        guard isRecording else { return }

        print("🛑 Stopping chunked recording...")

        // Cancel pending chunk rotation
        chunkTimer?.invalidate()
        chunkTimer = nil

        // Finalize the last chunk
        finalizeCurrentChunk()

        isRecording = false

        if let startTime = recordingStartTime {
            totalDuration = Date().timeIntervalSince(startTime)
            print("⏱️ Total recording duration: \(String(format: "%.1f", totalDuration))s across \(currentChunkNumber + 1) chunks")
        }

        recordingStartTime = nil
        onRecordingComplete?()

        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Audio Processing

    private func processAudioForWhisper(url: URL) {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("⚠️ Failed to create audio buffer")
                return
            }

            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else {
                print("⚠️ No channel data available")
                return
            }

            let samples = channelData[0]
            let sampleCount = Int(buffer.frameLength)

            // Analyze audio levels
            let peakLevel = findPeakLevel(samples: samples, count: sampleCount)
            let rmsLevel = findRMSLevel(samples: samples, count: sampleCount)

            // Normalize if needed
            if peakLevel < 0.5 && peakLevel > 0.001 {
                normalizeAudio(samples: samples, count: sampleCount, currentPeak: peakLevel)
            }

            // Write back
            let outputFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try outputFile.write(from: buffer)

            print("✅ Chunk audio processed")
        } catch {
            print("⚠️ Audio processing failed: \(error.localizedDescription)")
        }
    }

    private func findPeakLevel(samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var peak: Float = 0.0
        for i in 0..<count {
            let absValue = Swift.abs(samples[i])
            if absValue > peak {
                peak = absValue
            }
        }
        return peak
    }

    private func findRMSLevel(samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var sumSquares: Float = 0.0
        for i in 0..<count {
            sumSquares += samples[i] * samples[i]
        }
        return sqrt(sumSquares / Float(count))
    }

    private func normalizeAudio(samples: UnsafeMutablePointer<Float>, count: Int, currentPeak: Float, targetPeak: Float = 0.8) {
        let gain = targetPeak / currentPeak
        let safeGain = min(gain, 15.0)

        for i in 0..<count {
            samples[i] *= safeGain
            // Soft clipping
            if samples[i] > 0.95 {
                samples[i] = 0.95
            } else if samples[i] < -0.95 {
                samples[i] = -0.95
            }
        }
    }

    deinit {
        if isRecording {
            stopRecording()
        }
    }
}
