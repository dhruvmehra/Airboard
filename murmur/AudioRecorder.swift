import Foundation
import AVFoundation
import Combine

class AudioRecorder: ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartTime: Date?
    
    @Published var isRecording = false
    @Published var recordingURL: URL?
    
    init() {
        // No setup needed for macOS
    }
    
    func startRecording() {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
        
        // IMPROVED: Higher quality audio settings
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,  // Increased from 16000 to 44100 (CD quality)
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000  // Add bit rate for better quality
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            isRecording = true
            recordingURL = audioFilename
            recordingStartTime = Date()
            print("🎙️ Recording started: \(audioFilename)")
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
        
        print("🎙️ Recording stopped: \(recordingURL?.path ?? "unknown")")
        recordingStartTime = nil
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
