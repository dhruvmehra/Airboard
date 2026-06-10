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
    private var meterTimer: Timer?
    private var recordingStartTime: Date?
    private var chunkStartTime: Date?
    private var currentChunkURL: URL?

    // Finished chunks are normalized off the main thread so the next chunk can
    // start recording immediately — no dead air at rotation boundaries.
    private let processingQueue = DispatchQueue(label: "airboard.chunk-processing", qos: .userInitiated)

    // Callbacks for chunk completion
    var onChunkComplete: ((URL, Int) -> Void)?
    var onRecordingComplete: (() -> Void)?

    // Configuration: rotate at a *pause in speech* after minChunkDuration so we
    // never cut a word in half; hard-cap at maxChunkDuration regardless.
    private let minChunkDuration: TimeInterval = 25.0
    private let maxChunkDuration: TimeInterval = 40.0
    private let silenceThresholdDb: Float = -38.0
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
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()

            let success = audioRecorder?.record() ?? false
            if success {
                currentChunkURL = chunkFilename
                chunkStartTime = Date()
                print("📼 Chunk \(currentChunkNumber) started: \(chunkFilename.lastPathComponent)")

                // After the minimum duration, start watching for a pause in speech
                scheduleChunkRotation()
            } else {
                print("❌ Failed to start chunk \(currentChunkNumber)")
            }
        } catch {
            print("❌ Failed to create chunk recorder: \(error.localizedDescription)")
        }
    }

    private func scheduleChunkRotation() {
        chunkTimer = Timer.scheduledTimer(withTimeInterval: minChunkDuration, repeats: false) { [weak self] _ in
            self?.beginSilenceWatch()
        }

        // Add to common run loop mode so it fires even when UI is active
        RunLoop.main.add(chunkTimer!, forMode: .common)
    }

    /// Poll the mic level and rotate at the first pause in speech, so words are
    /// never sliced in half at a chunk boundary. Hard-cap at maxChunkDuration.
    private func beginSilenceWatch() {
        guard isRecording else { return }

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, let recorder = self.audioRecorder else { return }

            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let elapsed = Date().timeIntervalSince(self.chunkStartTime ?? Date())

            if power < self.silenceThresholdDb || elapsed >= self.maxChunkDuration {
                self.meterTimer?.invalidate()
                self.meterTimer = nil
                let reason = power < self.silenceThresholdDb ? "pause detected" : "max duration"
                print("🔄 Rotating chunk (\(reason), \(String(format: "%.1f", elapsed))s)")
                self.rotateChunk()
            }
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func rotateChunk() {
        guard isRecording else { return }

        // Stop the old chunk and start the next one IMMEDIATELY — the finished
        // file is normalized in the background so there's no recording gap.
        let finishedURL = currentChunkURL
        let finishedNumber = currentChunkNumber
        audioRecorder?.stop()
        currentChunkURL = nil

        currentChunkNumber += 1
        if let startTime = recordingStartTime {
            totalDuration = Date().timeIntervalSince(startTime)
        }
        startNextChunk()

        if let url = finishedURL {
            processingQueue.async { [weak self] in
                self?.finalizeChunkFile(url: url, chunkNumber: finishedNumber)
            }
        }
    }

    /// Runs on processingQueue. Finalizes, normalizes, and hands off a finished chunk.
    private func finalizeChunkFile(url: URL, chunkNumber: Int) {
        // Give AVAudioRecorder time to finish writing the file
        Thread.sleep(forTimeInterval: 0.1)

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                let sizeKB = Double(fileSize) / 1024.0
                print("✅ Chunk \(chunkNumber) finalized: \(String(format: "%.1f", sizeKB))KB")

                if fileSize >= 1000 {
                    processAudioForWhisper(url: url)
                    DispatchQueue.main.async { [weak self] in
                        self?.onChunkComplete?(url, chunkNumber)
                    }
                } else {
                    print("⚠️ Chunk too small, skipping")
                    try? FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            print("❌ Failed to finalize chunk: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop Recording

    func stopRecording() {
        guard isRecording else { return }

        print("🛑 Stopping chunked recording...")

        // Cancel pending rotation + silence watch
        chunkTimer?.invalidate()
        chunkTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil

        let lastURL = currentChunkURL
        let lastNumber = currentChunkNumber
        audioRecorder?.stop()
        currentChunkURL = nil

        isRecording = false

        if let startTime = recordingStartTime {
            totalDuration = Date().timeIntervalSince(startTime)
            print("⏱️ Total recording duration: \(String(format: "%.1f", totalDuration))s across \(currentChunkNumber + 1) chunks")
        }

        recordingStartTime = nil

        // Finalize the last chunk off the main thread, then signal completion —
        // ordering is preserved because both callbacks hop back to main in order.
        processingQueue.async { [weak self] in
            if let url = lastURL {
                self?.finalizeChunkFile(url: url, chunkNumber: lastNumber)
            }
            DispatchQueue.main.async {
                self?.onRecordingComplete?()
            }
        }

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
