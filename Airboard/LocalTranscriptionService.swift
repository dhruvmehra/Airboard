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
    /// True only once the model is downloaded, loaded AND warmed up — safe to transcribe.
    @Published var isModelReady: Bool = false

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
    
    /// Whisper variant to load. large-v3 turbo (Sept 2024 weights, quantized ~632MB):
    /// large accuracy jump over `small`, still real-time on Apple Silicon.
    static let whisperModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private func initializeWhisper() async {
        do {
            print("🔄 Initializing WhisperKit...")

            // Check if model is already cached (WhisperKit stores models under
            // ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/)
            let modelPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(Self.whisperModelName)")

            let isCached = FileManager.default.fileExists(atPath: modelPath.path)

            if isCached {
                print("✅ Model found in cache, loading instantly...")
            } else {
                print("📥 Model not cached, downloading (first run only)...")
                await MainActor.run {
                    isDownloadingModel = true
                    downloadProgress = 0.0
                }
            }

            // Start progress animation only if downloading
            let progressTask: Task<Void, Never>? = !isCached ? Task {
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
            } : nil

            // Initialize WhisperKit with config
            let config = WhisperKitConfig(model: Self.whisperModelName)
            whisperKit = try await WhisperKit(config)

            progressTask?.cancel()

            if !isCached {
                await MainActor.run {
                    self.downloadProgress = 1.0
                }
            }

            print("✅ WhisperKit initialized with \(Self.whisperModelName)")
            print("📦 Model cached at: ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/")

            // Keep the "getting ready" state visible through warm-up — the first
            // CoreML load of a large model can take a while, and transcribing
            // before it finishes would silently block (stuck-orange bug).
            await warmUpModel()

            await MainActor.run {
                self.isInitialized = true
                self.isModelReady = true
                self.isDownloadingModel = false
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

        // 3. Add number examples to help with number recognition
        // Only add if vocabulary doesn't already contain numbers
        let hasNumbers = vocabularyPrompt.rangeOfCharacter(from: .decimalDigits) != nil
        if !hasNumbers {
            promptParts.append("Numbers: 1, 2, 3, 10, 100, 555, 1234, 2024.")
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
                promptTokens: promptTokens.isEmpty ? nil : promptTokens,
                supressTokens: []  // Don't suppress any tokens (especially numbers)
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

            // Check if transcription is empty
            if transcribedText.isEmpty {
                await MainActor.run {
                    self.error = "No speech detected"
                    self.isTranscribing = false
                }
                deleteAudioFile(at: audioURL)
                return
            }

            // IMMEDIATELY show raw Whisper output for instant feedback
            await MainActor.run {
                self.transcription = transcribedText
            }

            PerformanceMonitor.shared.finalizeSession()

            // Mark transcription as complete
            await MainActor.run {
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
