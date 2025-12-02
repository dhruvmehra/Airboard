//
//  LocalTranscriptionService.swift
//
//  Local Whisper transcription using WhisperKit
//

import Foundation
import Combine
import WhisperKit
import AVFoundation

class LocalTranscriptionService: ObservableObject {
    @Published var transcription: String = ""
    @Published var isTranscribing: Bool = false
    @Published var error: String?
    @Published var isDownloadingModel: Bool = false
    @Published var downloadProgress: Double = 0.0
    
    private var whisperKit: WhisperKit?
    private var isInitialized = false
    private var initializationTask: Task<Void, Never>?
    
    init() {
        initializationTask = Task {
            await initializeWhisper()
        }
    }
    
    func ensureModelReady() async {
        await initializationTask?.value
    }
    
    private func initializeWhisper() async {
        await MainActor.run {
            isDownloadingModel = true
            downloadProgress = 0.0
        }
        
        do {
            print("🔄 Initializing WhisperKit...")
            print("📥 Downloading model if needed (first run only)...")
            
            // Start a realistic progress simulation for ~60 seconds (small model download)
            let progressTask = Task {
                // Slower, more realistic progress
                for i in 1...600 {  // 600 steps over 60 seconds
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    
                    // Use logarithmic progress - fast at start, slower near end
                    let progress = min(0.95, Double(i) / 600.0)
                    
                    await MainActor.run {
                        self.downloadProgress = progress
                    }
                    
                    if Task.isCancelled { break }
                }
                
                // Stay at 95% until actual download completes
                await MainActor.run {
                    self.downloadProgress = 0.95
                }
            }
            
            // Actually download the model (this is the real download)
            whisperKit = try await WhisperKit(model: "small")
            
            // Cancel progress simulation and jump to 100%
            progressTask.cancel()
            
            await MainActor.run {
                self.downloadProgress = 1.0
            }
            
            // Small delay to show 100% before hiding
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            await MainActor.run {
                self.isDownloadingModel = false
            }
            
            print("✅ WhisperKit initialized with small model")
            print("📦 Model cached at: ~/Library/Caches/whisperkit/")
            
            await warmUpModel()
            
            await MainActor.run {
                self.isInitialized = true
            }
            
            print("🎉 Ready to transcribe!")
            
        } catch {
            print("❌ Failed to initialize WhisperKit: \(error.localizedDescription)")
            await MainActor.run {
                self.error = "Failed to initialize Whisper: \(error.localizedDescription)"
                self.isDownloadingModel = false
                self.downloadProgress = 0.0
            }
        }
    }
    
    private func warmUpModel() async {
        guard let whisperKit = whisperKit else { return }
        print("🔥 Warming up model...")
        
        do {
            let silentAudioURL = try createSilentAudioFile()
            _ = try await whisperKit.transcribe(audioPath: silentAudioURL.path)
            try? FileManager.default.removeItem(at: silentAudioURL)
            print("✅ Model warmed up")
        } catch {
            print("⚠️ Warmup failed: \(error.localizedDescription)")
        }
    }
    
    private func createSilentAudioFile() throws -> URL {
        // Use bundled silent audio file instead of creating one
        guard let bundlePath = Bundle.main.path(forResource: "silent_warmup", ofType: "m4a") else {
            throw NSError(domain: "LocalTranscriptionService", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Silent warmup file not found in bundle"])
        }
        return URL(fileURLWithPath: bundlePath)
    }
    
    func transcribe(audioURL: URL, context: AppContext? = nil) async {
        let startTime = Date()
        
        await MainActor.run {
            isTranscribing = true
            error = nil
            transcription = ""
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            if let fileSize = attributes[.size] as? Int64 {
                print("📊 Audio: \(String(format: "%.1f", Double(fileSize) / 1024.0))KB")
                
                if fileSize < 1000 {
                    print("⚠️ File too small")
                    await MainActor.run {
                        self.error = "Recording too short"
                        self.isTranscribing = false
                    }
                    deleteAudioFile(at: audioURL)
                    return
                }
            }
        } catch {
            print("⚠️ Could not check file size")
        }
        
        await ensureModelReady()
        
        guard let whisperKit = whisperKit else {
            await MainActor.run {
                self.error = "Whisper not initialized"
                self.isTranscribing = false
            }
            deleteAudioFile(at: audioURL)
            return
        }
        
        do {
            print("🌐 Transcribing...")
            
            if let context = context, !context.prompt.isEmpty {
                print("📝 Context: \(context.appType)")
            }
            
            let results = try await whisperKit.transcribe(audioPath: audioURL.path)
            
            let duration = Date().timeIntervalSince(startTime) * 1000
            
            guard let result = results.first else {
                await MainActor.run {
                    self.error = "No result"
                    self.isTranscribing = false
                }
                deleteAudioFile(at: audioURL)
                return
            }
            
            let transcribedText = result.text
            
            await MainActor.run {
                self.transcription = transcribedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                self.isTranscribing = false
            }
            
            print("✅ Done: \(transcribedText)")
            print("⏱️ \(Int(duration))ms")
            
            deleteAudioFile(at: audioURL)
            
        } catch {
            let duration = Date().timeIntervalSince(startTime) * 1000
            
            await MainActor.run {
                self.error = error.localizedDescription
                self.isTranscribing = false
            }
            
            print("❌ Failed: \(error.localizedDescription)")
            print("⏱️ \(Int(duration))ms")
            
            deleteAudioFile(at: audioURL)
        }
    }
    
    private func deleteAudioFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            print("🗑️ Deleted: \(url.lastPathComponent)")
        } catch {
            print("⚠️ Delete failed")
        }
    }
}
