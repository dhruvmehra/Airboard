import Foundation
import LLM

/// Service for running Gemma 2 2B for context-aware text formatting.
actor LlamaService {
    
    // MARK: - Singleton and Properties
    static let shared = LlamaService()
    
    private var llmInstance: LLM?
    private var isModelLoaded = false
    
    // Track the ongoing loading process atomically
    private var loadingTask: Task<Void, Error>?
    
    // MARK: - Initialization
    private init() {
        // Initialization is clean.
    }
    
    // MARK: - Public Methods
    
    /// Check if Llama service is fully available and ready
    func isAvailable() async -> Bool {
        let modelReady = await ModelDownloadManager.shared.isModelReady
        return modelReady && isModelLoaded
    }
    
    /// Load the Llama model into memory
    func loadModel() async throws {
        // 1. If the model is already loaded, exit immediately.
        if isModelLoaded {
            return
        }
        
        // 2. If a loading task is already running, wait for it to complete.
        if let task = loadingTask {
            return try await task.value
        }

        // 3. Create a new Task to perform the loading and store it
        let task = Task<Void, Error> {
            let ready = await ModelDownloadManager.shared.isModelReady
            guard ready else {
                throw LlamaError.modelNotDownloaded
            }
            
            print("⏳ Loading LLM model into memory...")
            
            let modelURL = await ModelDownloadManager.shared.modelPath
            
            // CRITICAL: The strict, minimalist system prompt for text correction only.
            let systemPrompt = """
            You are a text formatting tool. Your ONLY job is to fix spacing, capitalization, and punctuation.

            RULES:
            - DO NOT change any words
            - DO NOT respond conversationally
            - DO NOT add explanations
            - ONLY output the corrected text

            Example:
            Input: help me write a test sentence
            Output: Help me write a test sentence.

            Format this text:
            """
            
            // FIXED: LLM initializer returns an optional, handle it properly
            guard let loadedModel = LLM(
                from: modelURL,
                template: .chatML(systemPrompt)
            ) else {
                throw LlamaError.modelLoadFailed("Failed to initialize LLM from model file")
            }
            
            // Update state on the actor's isolated context
            await self.setLoadedModel(loadedModel)
            print("✅ LLM Model loaded successfully")
        }
        
        // Store the task immediately.
        self.loadingTask = task
        
        // Wait for the stored task to complete
        do {
            try await task.value
            self.loadingTask = nil
        } catch {
            self.loadingTask = nil
            throw error
        }
    }
    
    /// Internal actor function to safely set the model instance.
    private func setLoadedModel(_ model: LLM) async {
        self.llmInstance = model
        self.isModelLoaded = true
    }
    
    /// Cleanup text using LLM
    func cleanupText(_ text: String) async throws -> String {
        // Check if model is downloaded
        let ready = await ModelDownloadManager.shared.isModelReady
        guard ready else {
            throw LlamaError.modelNotDownloaded
        }
        
        print("🤖 Running LLM inference...")
        print("📝 Input text: '\(text)'")
        
        // Get model URL
        let modelURL = await ModelDownloadManager.shared.modelPath
        
        // System prompt
        let systemPrompt = """
        You are a text formatting tool. Your ONLY job is to fix spacing, capitalization, and punctuation.

        RULES:
        - DO NOT change any words
        - DO NOT respond conversationally
        - DO NOT add explanations
        - ONLY output the corrected text

        Example:
        Input: help me write a test sentence
        Output: Help me write a test sentence.

        Format this text:
        """
        
        // Create fresh LLM instance for this call (prevents context overflow)
        guard let llm = LLM(
            from: modelURL,
            template: .chatML(systemPrompt)
        ) else {
            throw LlamaError.modelLoadFailed("Failed to initialize LLM")
        }
        
        // Run inference
        let processedPrompt = llm.preprocess(text, [])
        let response = await Task.detached(priority: .userInitiated) {
            return await llm.getCompletion(from: processedPrompt)
        }.value
        
        print("🔍 Raw LLM response: '\(response)'")

        // AGGRESSIVE cleanup
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove ChatML markers
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>assistant", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>user", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>system", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_end|>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|end_of_text|>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|eot_id|>", with: "")
        
        // Take only first line
        if let firstLine = cleaned.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) {
            cleaned = firstLine
        }
        
        // Remove leaked role markers
        cleaned = cleaned.replacingOccurrences(of: "^user\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^assistant\\s*", with: "", options: .regularExpression)

        // Detect conversational responses
        let badPhrases = ["I'd be happy", "I can help", "Here is", "Sure", "Let me", "What is", "Please provide"]
        for phrase in badPhrases {
            if cleaned.lowercased().hasPrefix(phrase.lowercased()) {
                print("⚠️ LLM being conversational - using original")
                return text
            }
        }

        // Clean spaces
        cleaned = cleaned.replacingOccurrences(of: " +", with: " ", options: .regularExpression)

        print("✨ Cleaned output: '\(cleaned)'")
        print("✅ LLM inference complete")

        // Safety checks
        if cleaned.isEmpty || cleaned.count > text.count * 2 {
            print("⚠️ LLM output invalid - using original")
            return text
        }

        return cleaned
    }
    
    /// Format text based on app context using LLM
    func formatWithContext(_ text: String, context: AppContext) async throws -> String {
        // Check if model is downloaded
        let ready = await ModelDownloadManager.shared.isModelReady
        guard ready else {
            throw LlamaError.modelNotDownloaded
        }
        
        print("🤖 Running context-aware formatting for \(context.appType)...")
        print("📝 Input text: '\(text)'")
        
        // Get model URL
        let modelURL = await ModelDownloadManager.shared.modelPath
        
        // Build context-specific system prompt
        let systemPrompt = buildContextPrompt(for: context.appType)
        
        // Create fresh LLM instance
        guard let llm = LLM(
            from: modelURL,
            template: .chatML(systemPrompt)
        ) else {
            throw LlamaError.modelLoadFailed("Failed to initialize LLM")
        }
        
        // Run inference
        let processedPrompt = llm.preprocess(text, [])
        let response = await Task.detached(priority: .userInitiated) {
            return await llm.getCompletion(from: processedPrompt)
        }.value
        
        print("🔍 Raw LLM response: '\(response)'")
        
        // Clean up response - MORE AGGRESSIVE
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove ALL ChatML markers and surrounding text
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>assistant", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>user", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>system", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_start|>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|im_end|>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|end_of_text|>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<|eot_id|>", with: "")
        
        // CRITICAL: Take only the FIRST line (before any newline that indicates prompt leakage)
        let lines = cleaned.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let firstLine = lines.first, !firstLine.isEmpty {
            cleaned = firstLine
        }
        
        // Remove "user" or "assistant" if they appear (leaked role markers)
        cleaned = cleaned.replacingOccurrences(of: "^user\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^assistant\\s*", with: "", options: .regularExpression)
        
        // Clean spaces
        cleaned = cleaned.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        
        print("✨ Formatted output: '\(cleaned)'")
        
        // Safety check
        if cleaned.isEmpty {
            print("⚠️ LLM output empty - using original")
            return text
        }
        
        return cleaned
    }
    
    /// Build system prompt based on app context
    private func buildContextPrompt(for appType: AppType) -> String {
        switch appType {
        case .email:
            return """
            You are a TEXT FORMATTER. The user will give you dictated speech. Your job is to format it as an email.

            DO NOT respond to questions. DO NOT help with tasks. ONLY format the text.

            If the input is a question like "can you help me write X", format it as: "Can you help me write X?"

            Format:
            [Greeting],

            [Body]

            [Closing]

            Rules:
            - Extract greeting from speech (Hi/Hey/Dear + name)
            - Body with proper punctuation
            - Closing (Thanks/Best regards)
            - NO conversational responses
            - NO "Sure", NO "Here's", NO explanations

            Transform this dictated text into email format:
            """
            
        case .code:
            return """
            You are a TEXT FORMATTER for code editors.

            The user will give you dictated text. Format it with proper code capitalization and punctuation.

            DO NOT respond to questions. ONLY format the text.

            Example:
            Input: can you help me write a function
            Output: can you help me write a function

            Format this text for code:
            """
            
        case .messaging:
            return """
            You are a TEXT FORMATTER for casual messages.

            The user will give you dictated text. Format it naturally with minimal punctuation.

            DO NOT respond to questions. ONLY format the text.

            Example:
            Input: can you help me with something
            Output: Can you help me with something

            Format this message:
            """
            
        case .document, .notes:
            return """
            You are a TEXT FORMATTER for documents.

            The user will give you dictated text. Add proper punctuation and capitalization.

            DO NOT respond to questions. ONLY format the text.

            Example:
            Input: can you help me write a report
            Output: Can you help me write a report.

            Format this text:
            """
            
        case .social:
            return """
            You are a TEXT FORMATTER for social media.

            The user will give you dictated text. Format it with natural punctuation.

            DO NOT respond to questions. ONLY format the text.

            Example:
            Input: can you help me write a post
            Output: Can you help me write a post

            Format this post:
            """
            
        case .browser, .general:
            return """
            You are a TEXT FORMATTER. The user will dictate text and you format it with proper punctuation and capitalization.

            CRITICAL: DO NOT respond to questions or requests. ONLY add punctuation and capitalization to the exact words given.

            Examples:
            Input: can you help me write a prompt
            Output: Can you help me write a prompt?

            Input: hey how are you doing today
            Output: Hey, how are you doing today?

            Input: i need to finish this report by friday
            Output: I need to finish this report by Friday.

            Input: what time is the meeting tomorrow
            Output: What time is the meeting tomorrow?

            Rules:
            - Add punctuation (. ? !)
            - Capitalize first letter and proper nouns
            - Add commas where natural
            - DO NOT add words
            - DO NOT respond conversationally
            - DO NOT say "Sure", "Here's", "Let me", "I can help"
            - If input is a question, add question mark
            - Output ONLY the formatted text, nothing else

            Format this dictated text:
            """
        }
    }
    
    /// Unload model from memory
    func unloadModel() {
        guard isModelLoaded else { return }
        
        llmInstance = nil
        isModelLoaded = false
        loadingTask = nil
        print("♻️ LLM model unloaded from memory")
    }
    
    // MARK: - Private Methods
    
    /// Basic cleanup as fallback when LLM fails
    private func performBasicCleanup(_ text: String) -> String {
        var result = text
        
        // Fix common concatenation issues
        result = result.replacingOccurrences(of: "thisis", with: "this is", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "amalso", with: "am also", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "transcribesomething", with: "transcribe something", options: .caseInsensitive)
        
        // Add period at end if missing
        if !result.hasSuffix(".") && !result.hasSuffix("?") && !result.hasSuffix("!") {
            result += "."
        }
        
        // Capitalize first letter properly
        if let firstCharacter = result.first {
            let capitalized = String(firstCharacter).uppercased()
            result = capitalized + result.dropFirst()
        }
        
        return result
    }
}

// MARK: - Errors
enum LlamaError: LocalizedError {
    case modelNotDownloaded
    case modelNotLoaded
    case modelLoadFailed(String)
    case inferenceFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "LLM model is not downloaded. Please download it first."
        case .modelNotLoaded:
            return "LLM model is not loaded into memory."
        case .modelLoadFailed(let reason):
            return "Failed to load LLM model: \(reason)"
        case .inferenceFailed(let reason):
            return "LLM inference failed: \(reason)"
        }
    }
}
