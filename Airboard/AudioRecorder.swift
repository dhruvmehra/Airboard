import Foundation
import AVFoundation
import Combine

class AudioRecorder: ObservableObject {
    private let captureEngine = MicCaptureEngine()
    private var recordingStartTime: Date?

    @Published var isRecording = false
    @Published var recordingURL: URL?

    init() {
        // Warm the engine so startRecording() is fast at hotkey time
        // (replaces the old pre-prepared AVAudioRecorder trick).
        captureEngine.prepare()
    }

    func startRecording() {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        let deviceID = MicDeviceManager.shared.resolveActiveDeviceID()

        do {
            try captureEngine.start(deviceID: deviceID, fileURL: url)
            isRecording = true
            recordingURL = url
            recordingStartTime = Date()
            print("🎙️ Recording started (\(MicDeviceManager.shared.activeMicName)): \(url.lastPathComponent)")
        } catch {
            print("❌ Recording failed to start: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let finishedURL = captureEngine.stop()
        isRecording = false

        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            print("⏱️ Recording duration: \(String(format: "%.2f", duration))s")
        }
        recordingStartTime = nil

        guard let url = finishedURL else {
            print("⚠️ No recording URL available")
            return
        }
        recordingURL = url

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                let sizeKB = Double(fileSize) / 1024.0
                print("📊 Recording size: \(String(format: "%.1f", sizeKB))KB")
                if fileSize >= 1000 {
                    normalizeRecordedAudio(url: url)
                } else {
                    print("⚠️ Recording too small - likely invalid")
                }
            }
        } catch {
            print("⚠️ Could not verify recording file: \(error.localizedDescription)")
        }
        print("🎙️ Recording stopped: \(url.path)")
    }

    /// Process audio for better speech recognition
    /// Only normalizes volume - the speech model handles noise well on its own
    private func normalizeRecordedAudio(url: URL) {
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
            // The speech model handles noise well, we just need adequate volume
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
    
    /// Normalize audio to boost quiet recordings so the speech model can hear them
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
