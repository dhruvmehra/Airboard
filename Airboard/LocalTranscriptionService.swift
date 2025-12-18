//
//  LocalTranscriptionService.swift
//
//  Local Whisper transcription using WhisperKit with vocabulary prompts
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
        print("🔥 Warming up model with dummy transcription...")
        
        // Create a tiny silent audio file to force model + tokenizer initialization
        let silentAudio = createSilentAudio(duration: 0.1) // 100ms of silence
        
        do {
            // This will force WhisperKit to fully initialize including the tokenizer
            _ = try await whisperKit?.transcribe(audioArray: silentAudio)
            
            // Now verify tokenizer is available
            if let tokenizer = whisperKit?.tokenizer {
                let testTokens = tokenizer.encode(text: "test")
                print("✅ Tokenizer ready (\(testTokens.count) tokens for 'test')")
            } else {
                print("⚠️ Tokenizer still not available after warmup")
            }
        } catch {
            print("⚠️ Warmup transcription failed: \(error.localizedDescription)")
        }
    }

    /// Create a silent audio array for warmup
    private func createSilentAudio(duration: Double) -> [Float] {
        let sampleRate = 16000 // WhisperKit uses 16kHz
        let sampleCount = Int(duration * Double(sampleRate))
        return [Float](repeating: 0.0, count: sampleCount)
    }
    
    /// Build Whisper prompt from vocabulary and conversation history
    private func buildWhisperPrompt(for context: AppContext?) -> [Int] {
        var promptParts: [String] = []
        
        // 1. Add custom vocabulary
        let vocabularyPrompt = VocabularyManager.shared.getPromptString()
        if !vocabularyPrompt.isEmpty {
            promptParts.append(vocabularyPrompt)
        }
        
        // 2. Add context-specific hints
        if let context = context {
            switch context.appType {
            case .email:
                promptParts.append("Email: Hi, Dear, Thanks, Best regards.")
                
            case .code:
                promptParts.append("Code: function, variable, const, import, return.")
                
            case .messaging:
                promptParts.append("Message: hey, lol, btw, gonna.")
                
            case .document, .notes:
                promptParts.append("Document: However, Therefore, Additionally.")
                
            default:
                break
            }
        }
        
        let promptText = promptParts.joined(separator: " ")
        
        // Whisper prompts should be under 224 tokens (~200 words)
        let words = promptText.split(separator: " ")
        let truncated = words.prefix(200).joined(separator: " ")
        
        if !truncated.isEmpty {
            print("🎯 Whisper context prompt: '\(truncated)'")
            
            // Convert text to token IDs using WhisperKit's tokenizer
            guard let whisperKit = whisperKit, let tokenizer = whisperKit.tokenizer else {
                print("⚠️ Tokenizer not available yet")
                return []
            }
            
            let tokens = tokenizer.encode(text: truncated)
            if tokens.isEmpty {
                print("⚠️ Tokenization failed - returned empty array")
            } else {
                print("🔢 Converted to \(tokens.count) tokens")
                print("📝 Prompt Tokens: \(tokens)")
            }
            return tokens
        }
        
        return []
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
            
            // Build context prompt
            let promptTokens = buildWhisperPrompt(for: context)
            print("📝 Prompt Tokens: \(promptTokens)")
            // Transcribe with context prompt
            let decodeOptions = DecodingOptions(
                task: .transcribe,
                language: "en",
                temperature: 0.0,
                wordTimestamps: true,
                clipTimestamps: [],
                promptTokens: promptTokens.isEmpty ? nil : promptTokens
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
            
            // Try LLM context-aware formatting if available
            let llmAvailable = await LlamaService.shared.isAvailable()
            
            if llmAvailable {
                do {
                    if let context = context {
                        // Use context-aware formatting
                        transcribedText = try await LlamaService.shared.formatWithContext(transcribedText, context: context)
                        print("✨ Context-aware formatting applied")
                    } else {
                        // No context, just basic cleanup
                        transcribedText = try await LlamaService.shared.cleanupText(transcribedText)
                        print("✨ Basic LLM cleanup applied")
                    }
                } catch {
                    print("⚠️ LLM formatting failed, using basic: \(error.localizedDescription)")
                    // Already have basic cleanup, continue
                }
            }
            
            // Apply context-specific formatting (only if LLM didn't handle it)
            if !llmAvailable {
                if let context = context {
                    transcribedText = IntelligentFormatter.format(transcribedText, context: context)
                } else {
                    // Apply smart punctuation if no context
                    transcribedText = addSmartPunctuation(transcribedText)
                }
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
        fixed = fixed.replacingOccurrences(of: "\\.([A-Za-z])", with: ". $1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: ",([A-Za-z])", with: ", $1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: "\\?([A-Za-z])", with: "? $1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: "!([A-Za-z])", with: "! $1", options: .regularExpression)
        
        // Fix concatenated words (common Whisper bug)
        fixed = fixed.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        
        // Fix double/triple spaces
        fixed = fixed.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        // Fix spacing around contractions
        fixed = fixed.replacingOccurrences(of: " n't", with: "n't")
        fixed = fixed.replacingOccurrences(of: " 's", with: "'s")
        fixed = fixed.replacingOccurrences(of: " 're", with: "'re")
        fixed = fixed.replacingOccurrences(of: " 'll", with: "'ll")
        fixed = fixed.replacingOccurrences(of: " 've", with: "'ve")
        fixed = fixed.replacingOccurrences(of: " 'd", with: "'d")
        fixed = fixed.replacingOccurrences(of: " 'm", with: "'m")
        
        // Fix spacing before punctuation
        fixed = fixed.replacingOccurrences(of: " +\\.", with: ".", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: " +,", with: ",", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: " +\\?", with: "?", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: " +!", with: "!", options: .regularExpression)
        
        // Fix weird punctuation combinations
        fixed = fixed.replacingOccurrences(of: "\\.+", with: ".", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: ",+", with: ",", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: "\\?,", with: "?", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: ",\\.", with: ".", options: .regularExpression)
        
        return fixed
    }
    
    /// Add smart punctuation
    private func addSmartPunctuation(_ text: String) -> String {
        var punctuated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Don't add punctuation if it already has ending punctuation
        let hasEndPunctuation = [".", "!", "?", ",", ";", ":"].contains(where: { punctuated.hasSuffix($0) })
        
        if !hasEndPunctuation && !punctuated.isEmpty {
            // Check if it's a question
            let questionWords = ["who", "what", "when", "where", "why", "how",
                                "is", "are", "can", "could", "would", "should",
                                "do", "does", "did", "will", "was", "were"]
            let firstWord = punctuated.lowercased().components(separatedBy: " ").first ?? ""
            
            if questionWords.contains(firstWord) {
                punctuated += "?"
            } else {
                // Check if it looks like a complete sentence (has a verb)
                let hasVerb = punctuated.lowercased().range(of: "\\b(is|are|was|were|am|be|been|have|has|had|do|does|did|can|could|will|would|should|may|might)\\b", options: .regularExpression) != nil
                
                if hasVerb || punctuated.split(separator: " ").count > 3 {
                    punctuated += "."
                }
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
