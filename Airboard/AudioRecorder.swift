import Foundation
import AVFoundation
import Combine

class AudioRecorder: ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartTime: Date?

    // A recorder primed ahead of time so record() starts with minimal latency.
    // Creating + preparing an AVAudioRecorder on demand costs 100-300ms of mic
    // spin-up, which clipped the first word of speech.
    private var preparedRecorder: AVAudioRecorder?
    private var preparedURL: URL?

    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,  // Mono
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    @Published var isRecording = false
    @Published var recordingURL: URL?

    init() {
        setupAudioSession()
        prepareNextRecorder()
    }

    private func prepareNextRecorder() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            recorder.prepareToRecord()
            preparedRecorder = recorder
            preparedURL = url
        } catch {
            print("⚠️ Failed to pre-prepare recorder: \(error.localizedDescription)")
            preparedRecorder = nil
            preparedURL = nil
        }
    }
    
    private func setupAudioSession() {
        #if os(macOS)
        print("✅ macOS - using AVAudioRecorder with post-processing")
        #else
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // iOS: Enable noise cancellation
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
            print("✅ Audio session configured with noise suppression")
        } catch {
            print("❌ Audio session setup failed: \(error.localizedDescription)")
        }
        #endif
    }
    
    func startRecording() {
        // Use the pre-prepared recorder for instant start; fall back to inline creation
        if preparedRecorder == nil {
            prepareNextRecorder()
        }
        guard let recorder = preparedRecorder, let url = preparedURL else {
            print("❌ No recorder available")
            return
        }
        preparedRecorder = nil
        preparedURL = nil

        audioRecorder = recorder
        let success = recorder.record()
        if success {
            isRecording = true
            recordingURL = url
            recordingStartTime = Date()
            print("🎙️ Recording started: \(url)")
        } else {
            print("❌ Recording failed to start")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()

        // CRITICAL: Give AVAudioRecorder time to finalize the file
        // Without this, the file may not be fully written when Whisper tries to read it
        Thread.sleep(forTimeInterval: 0.1)

        isRecording = false

        let duration: TimeInterval
        if let startTime = recordingStartTime {
            duration = Date().timeIntervalSince(startTime)
            print("⏱️ Recording duration: \(String(format: "%.2f", duration))s")
        } else {
            duration = 0
        }

        if let url = recordingURL {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = attributes[.size] as? Int64 {
                    let sizeKB = Double(fileSize) / 1024.0
                    print("📊 Recording size: \(String(format: "%.1f", sizeKB))KB")

                    if fileSize >= 1000 {
                        // Apply audio processing on macOS (post-processing)
                        processAudioForWhisper(url: url)
                    } else {
                        print("⚠️ Recording too small - likely invalid")
                    }
                }
            } catch {
                print("⚠️ Could not verify recording file: \(error.localizedDescription)")
            }

            print("🎙️ Recording stopped: \(url.path)")
        } else {
            print("⚠️ No recording URL available")
        }

        recordingStartTime = nil

        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif

        // Prime the next recorder so the next dictation starts instantly
        prepareNextRecorder()
    }

    /// Process audio for better Whisper recognition
    /// Only normalizes volume - Whisper handles noise well on its own
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
            
            // Analyze current audio levels
            let peakLevel = findPeakLevel(samples: samples, count: sampleCount)
            let rmsLevel = findRMSLevel(samples: samples, count: sampleCount)
            print("📊 Audio levels - Peak: \(String(format: "%.4f", peakLevel)), RMS: \(String(format: "%.4f", rmsLevel))")
            
            // ONLY normalize - no filtering, no noise gate
            // Whisper handles noise well, we just need adequate volume
            normalizeAudio(samples: samples, count: sampleCount, currentPeak: peakLevel)
            
            // Write back
            let outputFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try outputFile.write(from: buffer)
            
            print("✅ Audio processing complete (normalize only)")
        } catch {
            print("⚠️ Audio processing failed: \(error.localizedDescription)")
        }
    }
    
    /// Find peak amplitude in audio
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
    
    /// Find RMS (average) level in audio
    private func findRMSLevel(samples: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var sumSquares: Float = 0.0
        for i in 0..<count {
            sumSquares += samples[i] * samples[i]
        }
        return sqrt(sumSquares / Float(count))
    }
    
    /// Normalize audio to boost quiet recordings so Whisper can hear them
    private func normalizeAudio(samples: UnsafeMutablePointer<Float>, count: Int, currentPeak: Float, targetPeak: Float = 0.8) {
        // Skip if audio is already loud enough or too quiet (likely silence)
        guard currentPeak < 0.5 && currentPeak > 0.001 else {
            if currentPeak <= 0.001 {
                print("📊 Audio too quiet (likely silence), skipping normalization")
            } else {
                print("📊 Audio level OK (\(String(format: "%.4f", currentPeak))), no normalization needed")
            }
            return
        }
        
        let gain = targetPeak / currentPeak
        let safeGain = min(gain, 15.0)  // Allow up to 15x for very quiet speech
        
        print("🔊 Boosting audio by \(String(format: "%.1f", safeGain))x (peak: \(String(format: "%.4f", currentPeak)) → \(String(format: "%.2f", min(currentPeak * safeGain, targetPeak))))")
        
        for i in 0..<count {
            samples[i] *= safeGain
            // Soft clipping to prevent harsh distortion
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
