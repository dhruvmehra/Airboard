import Foundation
import AVFoundation
import Combine

class AudioRecorder: ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartTime: Date?
    
    @Published var isRecording = false
    @Published var recordingURL: URL?
    
    init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        #if os(macOS)
        // macOS doesn't require audio session setup
        print("✅ macOS - no audio session setup needed")
        #else
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
            print("✅ Audio session configured")
        } catch {
            print("❌ Audio session setup failed: \(error.localizedDescription)")
        }
        #endif
    }
    
    func startRecording() {
        // ✅ Changed from .m4a to .wav
        let audioFilename = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        
        // ✅ FIXED: PCM format instead of AAC for WhisperKit compatibility
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),  // ← Changed from AAC
            AVSampleRateKey: 16000.0,  // ← Changed from 44100 to 16000 (Whisper optimal)
            AVNumberOfChannelsKey: 1,  // Mono
            AVLinearPCMBitDepthKey: 16,  // ← PCM specific
            AVLinearPCMIsFloatKey: false,  // ← PCM specific
            AVLinearPCMIsBigEndianKey: false,  // ← PCM specific
            AVLinearPCMIsNonInterleaved: false  // ← PCM specific
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.prepareToRecord()  // ← Added prepare
            
            let success = audioRecorder?.record() ?? false
            if success {
                isRecording = true
                recordingURL = audioFilename
                recordingStartTime = Date()
                print("🎙️ Recording started: \(audioFilename)")
            } else {
                print("❌ Recording failed to start")
            }
        } catch {
            print("❌ Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        
        // Calculate recording duration
        let duration: TimeInterval
        if let startTime = recordingStartTime {
            duration = Date().timeIntervalSince(startTime)
            print("⏱️ Recording duration: \(String(format: "%.2f", duration))s")
        } else {
            duration = 0
        }
        
        // ✅ Added file validation
        if let url = recordingURL {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = attributes[.size] as? Int64 {
                    let sizeKB = Double(fileSize) / 1024.0
                    print("📊 Recording size: \(String(format: "%.1f", sizeKB))KB")
                    
                    if fileSize < 1000 {
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
        
        // ✅ Deactivate audio session (iOS only)
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error.localizedDescription)")
        }
        #endif
    }
    
    // ✅ Added cleanup method
    deinit {
        if isRecording {
            stopRecording()
        }
    }
}