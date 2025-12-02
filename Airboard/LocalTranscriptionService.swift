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
            
            let progressTask = Task {
                for i in 1...600 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let progress = min(0.95, Double(i) / 600.0)
                    await MainActor.run {
                        self.downloadProgress = progress
                    }
                    if Task.isCancelled { break }
                }
                await MainActor.run {
                    self.downloadProgress = 0.95
                }
            }
            
            // Initialize WhisperKit with config
            let config = WhisperKitConfig(model: "small")
            whisperKit = try await WhisperKit(config)
            
            progressTask.cancel()
            
            await MainActor.run {
                self.downloadProgress = 1.0
            }
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            
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
            
            if let context = context {
                print("📝 Context: \(context.appType)")
            }
            
            // Transcribe with default settings (WhisperKit handles optimization internally)
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
            
            var transcribedText = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Post-process for better punctuation
            transcribedText = improveTranscription(transcribedText, context: context)
            
            await MainActor.run {
                self.transcription = transcribedText
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
    
    /// Improve transcription with smart punctuation rules
    private func improveTranscription(_ text: String, context: AppContext?) -> String {
        var improved = text
        
        // Fix common Whisper issues
        improved = fixCommonIssues(improved)
        
        // Add smart punctuation
        improved = addSmartPunctuation(improved, context: context)
        
        return improved
    }
    
    /// Fix common Whisper transcription issues
    private func fixCommonIssues(_ text: String) -> String {
        var fixed = text
        
        // Fix missing spaces after punctuation
        fixed = fixed.replacingOccurrences(of: "\\.([A-Z])", with: ". $1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: ",([A-Z])", with: ", $1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: "\\?([A-Z])", with: "? $1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: "!([A-Z])", with: "! $1", options: .regularExpression)
        
        // Fix double spaces
        fixed = fixed.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        
        // Fix spacing around contractions
        fixed = fixed.replacingOccurrences(of: " n't", with: "n't")
        fixed = fixed.replacingOccurrences(of: " 's", with: "'s")
        fixed = fixed.replacingOccurrences(of: " 're", with: "'re")
        fixed = fixed.replacingOccurrences(of: " 'll", with: "'ll")
        fixed = fixed.replacingOccurrences(of: " 've", with: "'ve")
        fixed = fixed.replacingOccurrences(of: " 'd", with: "'d")
        
        return fixed
    }
    
    /// Add smart punctuation based on context
    private func addSmartPunctuation(_ text: String, context: AppContext?) -> String {
        var punctuated = text
        
        // Don't add punctuation if it already has ending punctuation
        let hasEndPunctuation = [".", "!", "?", ",", ";", ":"].contains(where: { punctuated.hasSuffix($0) })
        
        if !hasEndPunctuation && !punctuated.isEmpty {
            // Check if it's a question
            let questionWords = ["who", "what", "when", "where", "why", "how", "is", "are", "can", "could", "would", "should", "do", "does", "did"]
            let firstWord = punctuated.lowercased().components(separatedBy: " ").first ?? ""
            
            if questionWords.contains(firstWord) {
                punctuated += "?"
            } else {
                punctuated += "."
            }
        }
        
        // Capitalize first letter
        if let first = punctuated.first, first.isLowercase {
            punctuated = punctuated.prefix(1).uppercased() + punctuated.dropFirst()
        }
        
        // Capitalize after sentence-ending punctuation
        if let regex = try? NSRegularExpression(pattern: "([.!?])\\s+([a-z])") {
            let matches = regex.matches(in: punctuated, range: NSRange(punctuated.startIndex..., in: punctuated))
            
            var result = punctuated
            for match in matches.reversed() {
                if let range = Range(match.range(at: 2), in: result) {
                    let letter = result[range].uppercased()
                    result.replaceSubrange(range, with: letter)
                }
            }
            punctuated = result
        }
        
        return punctuated
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
