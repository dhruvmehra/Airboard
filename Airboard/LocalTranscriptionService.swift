//
//  LocalTranscriptionService.swift
//
//  Local Whisper transcription using WhisperKit with Llama cleanup
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
        
        // Try to load Llama if available
        Task {
            if ModelDownloadManager.shared.isModelReady {
                try? await LlamaService.shared.loadModel()
            }
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
        print("⏭️ Skipping warmup - first transcription will initialize model")
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
            let decodeOptions = DecodingOptions(
                task: .transcribe,
                language: "en",
                temperature: 0.0,
                wordTimestamps: true,
                clipTimestamps: [],
                promptTokens: []
            )

            let results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: decodeOptions
            )
            
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
            
            // LOG: Show raw Whisper output
            print("📝 Raw Whisper output: '\(transcribedText)'")

            // Post-process: Basic cleanup first
            transcribedText = fixCommonIssues(transcribedText)
            print("🔧 After basic cleanup: '\(transcribedText)'")
            
            // Try Llama cleanup if available
//            if await LlamaService.shared.isAvailable() {
//                do {
//                    transcribedText = try await LlamaService.shared.cleanupText(transcribedText)
//                    print("✨ Llama cleanup applied")
//                } catch {
//                    print("⚠️ Llama cleanup failed, using basic: \(error.localizedDescription)")
//                    // Already have basic cleanup, continue
//                }
//            }
//            
            // Apply context-specific formatting
            if let context = context {
                transcribedText = IntelligentFormatter.format(transcribedText, context: context)
            } else {
                // Apply smart punctuation if no context
                transcribedText = addSmartPunctuation(transcribedText)
            }
            
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
        
        // Fix spacing before punctuation
        fixed = fixed.replacingOccurrences(of: " \\.", with: ".", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: " ,", with: ",")
        fixed = fixed.replacingOccurrences(of: " \\?", with: "?", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: " !", with: "!")
        
        return fixed
    }
    
    /// Add smart punctuation
    private func addSmartPunctuation(_ text: String) -> String {
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
