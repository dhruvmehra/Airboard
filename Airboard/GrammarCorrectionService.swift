//
//  GrammarCorrectionService.swift
//  Airboard
//
//  Fast on-device grammar correction using fine-tuned Flan-T5 ONNX model
//

import Foundation
import Combine
import OnnxRuntimeBindings

class GrammarCorrectionService: ObservableObject {
    static let shared = GrammarCorrectionService()

    private var ortEnv: ORTEnv?
    private var encoderSession: ORTSession?
    private var decoderSession: ORTSession?
    private var sessionOptions: ORTSessionOptions?
    private var sentencePieceProcessor: SentencePieceProcessor?
    private var isInitialized = false
    @Published var isDownloadingModel: Bool = false
    @Published var downloadProgress: Double = 0.0
    private var vocabularyTokens: [String: Int] = [:]
    private var reverseVocab: [Int: String] = [:]

    // Model storage path (in cache, like WhisperKit)
    private let modelDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("airboard/models/vennify")

    private init() {
        Task {
            await initializeModel()
        }
    }

    /// Initialize ONNX model (downloads on first run, loads from cache afterwards)
    private func initializeModel() async {
        do {
            print("🔄 Initializing Vennify grammar model (ONNX Runtime)...")

            // Check if models are already cached
            let encoderPath = modelDir.appendingPathComponent("encoder.onnx")
            let decoderPath = modelDir.appendingPathComponent("decoder.onnx")
            let vocabPath = modelDir.appendingPathComponent("vocab.json")
            let configPath = modelDir.appendingPathComponent("config.json")

            let allCached = FileManager.default.fileExists(atPath: encoderPath.path) &&
                           FileManager.default.fileExists(atPath: decoderPath.path) &&
                           FileManager.default.fileExists(atPath: vocabPath.path) &&
                           FileManager.default.fileExists(atPath: configPath.path)

            if allCached {
                print("✅ Vennify model found in cache, loading...")
                try await loadModelsFromCache()
            } else {
                print("📥 Vennify model not cached, downloading (first run only)...")
                await MainActor.run { self.isDownloadingModel = true }
                try await downloadAndLoadModels()
                await MainActor.run { self.isDownloadingModel = false }
            }

            isInitialized = true
            print("✅ Vennify grammar model ready (ONNX Runtime)")
            print("📦 Model cached at: \(modelDir.path)")

        } catch {
            print("❌ Failed to initialize Vennify model: \(error.localizedDescription)")
            print("⚠️ Falling back to rule-based grammar correction")
            await MainActor.run {
                self.isDownloadingModel = false
                self.downloadProgress = 0.0
            }
            isInitialized = true // Still mark as initialized to use fallback
        }
    }

    /// Load models from cache
    private func loadModelsFromCache() async throws {
        let encoderPath = modelDir.appendingPathComponent("encoder.onnx")
        let decoderPath = modelDir.appendingPathComponent("decoder.onnx")
        let vocabPath = modelDir.appendingPathComponent("vocab.json")
        let spiecePath = modelDir.appendingPathComponent("spiece.model")

        // Load SentencePiece model
        if FileManager.default.fileExists(atPath: spiecePath.path) {
            print("🔨 Loading SentencePiece model...")
            sentencePieceProcessor = try SentencePieceProcessor(modelPath: spiecePath.path)
            print("✅ SentencePiece model loaded")
        } else {
            throw GrammarError.downloadFailed("SentencePiece model not found")
        }

        // Load vocabulary (for debugging)
        let vocabData = try Data(contentsOf: vocabPath)
        vocabularyTokens = try JSONDecoder().decode([String: Int].self, from: vocabData)

        // Build reverse vocabulary
        for (token, id) in vocabularyTokens {
            reverseVocab[id] = token
        }

        // Create ONNX Runtime environment
        print("🔨 Initializing ONNX Runtime...")
        self.ortEnv = try ORTEnv(loggingLevel: .warning)

        // Create session options for optimization
        self.sessionOptions = try ORTSessionOptions()
        try sessionOptions?.setIntraOpNumThreads(4) // Use 4 CPU threads
        try sessionOptions?.setGraphOptimizationLevel(.all)

        // Load ONNX models
        print("🔨 Loading ONNX models...")
        self.encoderSession = try ORTSession(
            env: ortEnv!,
            modelPath: encoderPath.path,
            sessionOptions: sessionOptions
        )
        self.decoderSession = try ORTSession(
            env: ortEnv!,
            modelPath: decoderPath.path,
            sessionOptions: sessionOptions
        )

        print("✅ ONNX models loaded from cache")
    }

    /// Download models from Hugging Face and load them with retry logic
    private func downloadAndLoadModels() async throws {
        // Create model directory
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Use standard HuggingFace URL (already CDN-backed via Cloudflare)
        let baseURL = "https://huggingface.co/dhruv-pype/vennify-t5-base-grammar-onnx/resolve/main"

        let files = [
            ("encoder.onnx", 438_689_730),  // ~439 MB
            ("decoder.onnx", 650_809_108),  // ~651 MB
            ("config.json", 1_570),
            ("tokenizer_config.json", 20_800),
            ("special_tokens_map.json", 2_540),
            ("vocab.json", 686_000),
            ("special_tokens.json", 136),
            ("spiece.model", 792_000)
        ]

        let totalSize = files.reduce(0) { $0 + $1.1 }
        var downloadedSize = 0

        // Configure optimized URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60  // 60 seconds per request
        config.timeoutIntervalForResource = 600  // 10 minutes total
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4  // Parallel connections
        let session = URLSession(configuration: config)

        for (filename, estimatedSize) in files {
            print("📥 Downloading \(filename)...")

            let remoteURL = URL(string: "\(baseURL)/\(filename)")!
            let localURL = modelDir.appendingPathComponent(filename)

            // Retry logic: try up to 3 times
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    // Use streaming download for large files (>100MB)
                    if estimatedSize > 100_000_000 {
                        try await downloadLargeFile(session: session, from: remoteURL, to: localURL, estimatedSize: estimatedSize)
                    } else {
                        let (data, _) = try await session.data(from: remoteURL)
                        try data.write(to: localURL)
                    }

                    downloadedSize += estimatedSize
                    let progress = Double(downloadedSize) / Double(totalSize)
                    await MainActor.run {
                        self.downloadProgress = progress
                    }

                    print("✅ Downloaded \(filename) (\(attempt == 1 ? "first try" : "retry \(attempt-1)"))")
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    print("⚠️ Download attempt \(attempt) failed for \(filename): \(error.localizedDescription)")
                    if attempt < 3 {
                        print("🔄 Retrying in 2 seconds...")
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }

            if let error = lastError {
                throw GrammarError.downloadFailed("Failed to download \(filename) after 3 attempts: \(error.localizedDescription)")
            }
        }

        session.invalidateAndCancel()

        print("✅ All model files downloaded")
        await MainActor.run {
            self.downloadProgress = 1.0
        }

        // Now load the models
        try await loadModelsFromCache()
    }

    /// Download large files with streaming to avoid memory issues
    private func downloadLargeFile(session: URLSession, from url: URL, to destination: URL, estimatedSize: Int) async throws {
        // Use download task for large files (more efficient than streaming bytes)
        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GrammarError.downloadFailed("Invalid HTTP response")
        }

        // Move downloaded file to final destination
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Correct grammar in text (< 500ms target with ONNX, < 10ms fallback)
    func correctGrammar(_ text: String) async throws -> String {
        let startTime = Date()

        guard !text.isEmpty else {
            return text
        }

        // Check if ONNX model is loaded
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🧠 GRAMMAR CORRECTION DEBUG (ONNX Runtime)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📥 Input text: '\(text)'")
        print("🔍 Model Status:")
        print("   - ONNX Runtime env: \(ortEnv != nil)")
        print("   - Encoder session: \(encoderSession != nil)")
        print("   - Decoder session: \(decoderSession != nil)")
        print("   - SentencePiece loaded: \(sentencePieceProcessor != nil)")
        print("   - Vocabulary size: \(vocabularyTokens.count)")
        print("   - ONNX available: \(encoderSession != nil && decoderSession != nil && sentencePieceProcessor != nil)")

        // Try ONNX model if available
        if let encoderSession = encoderSession, let decoderSession = decoderSession, let sp = sentencePieceProcessor {
            print("✅ Using ONNX Runtime model for grammar correction")
            do {
                // Check if text needs chunking
                let tokenCount = sp.encode(text).count
                print("📊 Input token count: \(tokenCount)")

                let corrected: String
                if tokenCount > 100 {
                    // Split into chunks for long text
                    print("✂️ Text is long (\(tokenCount) tokens), splitting into chunks...")
                    corrected = try await correctWithChunks(text, encoderSession: encoderSession, decoderSession: decoderSession, sp: sp)
                } else {
                    // Process normally for short text
                    corrected = try await correctWithONNX(text, encoderSession: encoderSession, decoderSession: decoderSession, sp: sp)
                }

                let duration = Date().timeIntervalSince(startTime) * 1000
                print("📤 ONNX Output: '\(corrected)'")
                print("⏱️ ONNX Duration: \(Int(duration))ms")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                return corrected
            } catch {
                print("❌ ONNX correction failed: \(error.localizedDescription)")
                print("⚠️ Falling back to rule-based correction")
            }
        } else {
            print("⚠️ ONNX model not available, using fallback")
        }

        // Fallback to rule-based grammar correction
        let corrected = applyRuleBasedCorrection(text)
        let duration = Date().timeIntervalSince(startTime) * 1000
        print("📤 Rule-based Output: '\(corrected)'")
        print("⏱️ Rule-based Duration: \(Int(duration))ms")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        return corrected
    }

    /// Split long text into chunks and correct each chunk separately
    private func correctWithChunks(_ text: String, encoderSession: ORTSession, decoderSession: ORTSession, sp: SentencePieceProcessor) async throws -> String {
        // Split by sentence endings while preserving punctuation
        let pattern = "(?<=[.!?])\\s+"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var sentences: [String] = []
        var lastIndex = text.startIndex

        for match in matches {
            if let matchRange = Range(match.range, in: text) {
                let sentence = String(text[lastIndex..<matchRange.lowerBound])
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                lastIndex = matchRange.upperBound
            }
        }

        // Add the last sentence
        if lastIndex < text.endIndex {
            let lastSentence = String(text[lastIndex...])
            if !lastSentence.isEmpty {
                sentences.append(lastSentence)
            }
        }

        // If regex failed or no sentences found, split by approximation
        if sentences.isEmpty {
            sentences = [text]
        }

        print("📝 Split into \(sentences.count) sentence(s)")

        // Group sentences into chunks of ~80 tokens
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentTokenCount = 0

        for sentence in sentences {
            let sentenceTokens = sp.encode(sentence)

            // If adding this sentence would exceed 80 tokens, start new chunk
            if currentTokenCount + sentenceTokens.count > 80 && !currentChunk.isEmpty {
                chunks.append(currentChunk.joined(separator: " "))
                currentChunk = [sentence]
                currentTokenCount = sentenceTokens.count
            } else {
                currentChunk.append(sentence)
                currentTokenCount += sentenceTokens.count
            }
        }

        // Add the last chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: " "))
        }

        print("✂️ Created \(chunks.count) chunk(s):")
        for (i, chunk) in chunks.enumerated() {
            let tokenCount = sp.encode(chunk).count
            print("   Chunk \(i + 1): \(tokenCount) tokens - '\(chunk.prefix(60))...'")
        }

        // Correct each chunk
        var correctedChunks: [String] = []
        for (i, chunk) in chunks.enumerated() {
            print("🔄 Correcting chunk \(i + 1)/\(chunks.count)...")
            let corrected = try await correctWithONNX(chunk, encoderSession: encoderSession, decoderSession: decoderSession, sp: sp)
            correctedChunks.append(corrected)
        }

        // Combine chunks back together
        let result = correctedChunks.joined(separator: " ")
        print("✅ Combined \(correctedChunks.count) corrected chunk(s)")

        return result
    }

    /// Use ONNX T5 model for grammar correction with autoregressive decoding
    private func correctWithONNX(_ text: String, encoderSession: ORTSession, decoderSession: ORTSession, sp: SentencePieceProcessor) async throws -> String {
        // Validate input length
        guard text.count <= 1000 else {
            throw GrammarError.inputTooLong
        }

        // Tokenize input directly (no prefix needed)
        let rawTokens = sp.encode(text)

        // CRITICAL FIX: swift-sentencepiece uses 1-based indexing, but T5 expects 0-based
        // Subtract 1 from all token IDs to match Python's HuggingFace tokenizer
        var inputTokens = rawTokens.map { $0 - 1 }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📝 TOKENIZATION DEBUG (Swift SentencePiece)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Input text: '\(text)'")
        print()
        print("STEP 1: Raw SentencePiece encode (1-based indexing)")
        print("   Token count: \(rawTokens.count)")
        print("   Raw token IDs: \(rawTokens.prefix(20))")
        print()
        print("STEP 2: Convert to 0-based indexing (subtract 1)")
        print("   Adjusted token count: \(inputTokens.count)")
        print("   Adjusted token IDs: \(inputTokens.prefix(20))")

        // Show individual token mappings
        if inputTokens.count > 0 {
            print("   Token breakdown:")
            for (i, tokenID) in inputTokens.prefix(15).enumerated() {
                let vocabWord = reverseVocab[tokenID] ?? "<not in vocab>"
                let decoded = sp.decode([tokenID])
                print("      [\(i)] ID=\(String(format: "%5d", tokenID)) → Vocab:'\(vocabWord)' | Decoded:'\(decoded)'")
            }
        }

        // CRITICAL: T5 models require EOS token (1) at the end of encoder input
        // This is what HuggingFace's T5Tokenizer does automatically
        print()
        print("STEP 2: Adding EOS token (1)")
        inputTokens.append(1)  // Add EOS token
        print("   Final token count: \(inputTokens.count)")
        print("   Final token IDs: \(inputTokens.prefix(20))")

        // Test decode the full input
        let testDecode = sp.decode(inputTokens)
        print()
        print("STEP 3: Test decode full sequence (including EOS)")
        print("   Result: '\(testDecode)'")
        print("   Expected: '\(text)' (or similar)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        guard inputTokens.count > 1 else {  // Must have at least 1 token + EOS
            throw GrammarError.tokenizationFailed
        }

        // Prepare encoder inputs
        let maxLength = 256
        var paddedTokens = inputTokens
        if paddedTokens.count > maxLength {
            // Keep EOS at the end even when truncating
            paddedTokens = Array(paddedTokens.prefix(maxLength - 1)) + [1]
        } else if paddedTokens.count < maxLength {
            paddedTokens.append(contentsOf: Array(repeating: 0, count: maxLength - paddedTokens.count))
        }

        // Create attention mask
        var attentionMask = [Int64](repeating: 0, count: maxLength)
        for i in 0..<min(inputTokens.count, maxLength) {
            attentionMask[i] = 1
        }

        // Convert to Int64 for ONNX
        let inputIdsInt64 = paddedTokens.map { Int64($0) }

        // Create ONNX input tensors
        let inputIdsValue = try ORTValue(
            tensorData: NSMutableData(bytes: inputIdsInt64, length: inputIdsInt64.count * 8),
            elementType: .int64,
            shape: [1, NSNumber(value: maxLength)]
        )
        let attentionMaskValue = try ORTValue(
            tensorData: NSMutableData(bytes: attentionMask, length: attentionMask.count * 8),
            elementType: .int64,
            shape: [1, NSNumber(value: maxLength)]
        )

        print("🔄 Running encoder...")
        print("   Input IDs shape: [1, \(maxLength)]")
        print("   Attention mask: \(attentionMask.prefix(20))")

        // Run encoder
        let encoderOutputs = try encoderSession.run(
            withInputs: [
                "input_ids": inputIdsValue,
                "attention_mask": attentionMaskValue
            ],
            outputNames: ["last_hidden_state"],
            runOptions: nil
        )

        guard let encoderHiddenStates = encoderOutputs["last_hidden_state"] else {
            throw GrammarError.encoderOutputInvalid
        }

        // Get encoder output info
        let hiddenStatesInfo = try encoderHiddenStates.tensorTypeAndShapeInfo()
        print("✅ Encoder output shape: \(hiddenStatesInfo.shape)")

        // Extract encoder hidden states as Float32 array for inspection
        let hiddenStatesData = try encoderHiddenStates.tensorData() as Data
        let hiddenStatesArray = hiddenStatesData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }

        if hiddenStatesArray.count > 0 {
            let min = hiddenStatesArray.min() ?? 0
            let max = hiddenStatesArray.max() ?? 0
            let mean = hiddenStatesArray.reduce(0, +) / Float(hiddenStatesArray.count)
            print("   Range: [\(min), \(max)]")
            print("   Mean: \(mean)")
            print("   Sample: \(hiddenStatesArray.prefix(5))")
        }

        // Autoregressive decoding
        var generatedTokens: [Int] = []
        let maxGenerationLength = max(inputTokens.count * 2, 256)
        let decoderStartTokenID: Int64 = 0 // T5 pad token
        let endTokenID: Int64 = 1 // EOS token

        print("🔄 Starting autoregressive generation (max \(maxGenerationLength) tokens)...")

        var decoderInputSequence: [Int64] = [decoderStartTokenID]

        for step in 0..<maxGenerationLength {
            // Create decoder input (full sequence so far)
            let decoderInputIds = Array(decoderInputSequence)

            let decoderInputValue = try ORTValue(
                tensorData: NSMutableData(bytes: decoderInputIds, length: decoderInputIds.count * 8),
                elementType: .int64,
                shape: [1, NSNumber(value: decoderInputIds.count)]
            )

            // Run decoder
            let decoderOutputs = try decoderSession.run(
                withInputs: [
                    "decoder_input_ids": decoderInputValue,
                    "encoder_hidden_states": encoderHiddenStates,
                    "encoder_attention_mask": attentionMaskValue
                ],
                outputNames: ["logits"],
                runOptions: nil
            )

            guard let logitsTensor = decoderOutputs["logits"] else {
                print("❌ Failed to get logits at step \(step)")
                break
            }

            // Extract logits
            let logitsInfo = try logitsTensor.tensorTypeAndShapeInfo()
            let shape = logitsInfo.shape.map { $0.intValue }
            let batchSize = shape[0]
            let seqLen = shape[1]
            let vocabSize = shape[2]

            let logitsData = try logitsTensor.tensorData() as Data
            let allLogits = logitsData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }

            if step == 0 {
                print("🔍 Decoder output shape: \(logitsInfo.shape)")
                print("   Batch: \(batchSize), SeqLen: \(seqLen), Vocab: \(vocabSize)")
                print("   Total logits: \(allLogits.count)")
            }

            // Get logits for the LAST position in the sequence (where the new token should be predicted)
            let lastPos = seqLen - 1
            let logitsOffset = lastPos * vocabSize
            let logits = Array(allLogits[logitsOffset..<(logitsOffset + vocabSize)])

            if step == 0 {
                print("   Reading logits from position: \(lastPos)")
                print("   Sample logits: \(logits.prefix(5))")
            }

            // Check for NaN
            if logits.contains(where: { $0.isNaN || $0.isInfinite }) {
                print("❌ CRITICAL: Logits contain NaN or Inf at step \(step)!")
                throw GrammarError.encoderOutputInvalid
            }

            // Find token with max logit (greedy decoding)
            guard let maxIndex = logits.enumerated().max(by: { $0.element < $1.element })?.offset else {
                print("❌ Failed to find max logit at step \(step)")
                break
            }

            let nextToken = Int64(maxIndex)

            if step == 0 {
                // Show top 5 predictions for first step
                let sorted = logits.enumerated().sorted { $0.element > $1.element }
                print("🔍 Top 5 predictions:")
                for (i, item) in sorted.prefix(5).enumerated() {
                    let tokenStr = reverseVocab[item.offset] ?? "<unk>"
                    let spDecode = sp.decode([item.offset])
                    print("   \(i+1). Token \(item.offset): logit=\(item.element) | Vocab:'\(tokenStr)' | SP:'\(spDecode)'")
                }
                print("🔍 Selected token \(nextToken) with logit \(logits[maxIndex])")
            } else {
                print("   Step \(step): Token \(nextToken)")
            }

            // Stop if we hit end token
            if nextToken == endTokenID {
                print("✅ Hit end token, stopping generation")
                break
            }

            // Add to sequences
            generatedTokens.append(Int(nextToken))
            decoderInputSequence.append(nextToken)
        }

        // Convert generated tokens to text using SentencePiece
        print()
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📝 DECODING DEBUG (Swift SentencePiece)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("STEP 1: Raw decoder output")
        print("   Generated token count: \(generatedTokens.count)")
        print("   Token IDs: \(generatedTokens.prefix(20))")

        // Show token breakdown
        if generatedTokens.count > 0 {
            print("   Token breakdown:")
            for (i, tokenID) in generatedTokens.prefix(10).enumerated() {
                let vocabWord = reverseVocab[tokenID] ?? "<not in vocab>"
                print("      [\(i)] ID=\(String(format: "%5d", tokenID)) → Vocab:'\(vocabWord)'")
            }
        }

        // Check if we got stuck generating only special tokens/punctuation
        let uniqueTokens = Set(generatedTokens)
        if generatedTokens.count > 5 && uniqueTokens.count <= 3 && uniqueTokens.isSubset(of: [0, 1, 2, 3, 4, 5, 6]) {
            print()
            print("⚠️ WARNING: Model appears stuck generating repetitive tokens: \(uniqueTokens)")
            print("   This suggests an issue with the decoder input or model state")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw GrammarError.decoderGenerationFailed
        }

        print()
        print("STEP 2: Filter special tokens (remove 0=pad, 1=eos, 2=unk)")
        let tokensToDecode = generatedTokens.filter { $0 > 2 }
        print("   Filtered token count: \(tokensToDecode.count)")
        print("   Filtered IDs (0-based): \(tokensToDecode.prefix(20))")

        if tokensToDecode.isEmpty {
            print()
            print("⚠️ WARNING: No valid content tokens generated (only special tokens)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            return text  // Return original text
        }

        print()
        print("STEP 3: Convert back to 1-based indexing for SentencePiece decode")
        // swift-sentencepiece expects 1-based indexing, so add 1 back
        let tokensFor1BasedDecode = tokensToDecode.map { $0 + 1 }
        print("   Tokens for decode (1-based): \(tokensFor1BasedDecode.prefix(20))")

        print()
        print("STEP 4: SentencePiece decode")
        var correctedText = sp.decode(tokensFor1BasedDecode)
        print("   SP decode result: '\(correctedText)'")
        print("   Length: \(correctedText.count) characters")

        // WORKAROUND: If SentencePiece decode fails, use vocabulary-based decode
        if correctedText.isEmpty && !tokensToDecode.isEmpty {
            print("   ⚠️ SentencePiece decode returned empty, using vocabulary fallback")
            var textParts: [String] = []
            for tokenID in tokensToDecode {
                if let word = reverseVocab[tokenID] {
                    // Remove the ▁ (space marker) and add space before words that had it
                    if word.hasPrefix("▁") {
                        let cleanWord = String(word.dropFirst())
                        textParts.append(" " + cleanWord)
                    } else {
                        textParts.append(word)
                    }
                }
            }
            correctedText = textParts.joined().trimmingCharacters(in: .whitespaces)
            print("   Vocabulary-based decode: '\(correctedText)'")
        }

        print()
        print("STEP 5: Comparison")
        print("   Input:  '\(text)'")
        print("   Output: '\(correctedText)'")
        print("   Same: \(text == correctedText)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Track performance metrics
        PerformanceMonitor.shared.endGrammarCorrection(
            outputText: correctedText,
            inputTokens: inputTokens.count,
            outputTokens: generatedTokens.count
        )

        return correctedText
    }

    /// Rule-based grammar correction (fallback)
    private func applyRuleBasedCorrection(_ text: String) -> String {
        var corrected = text

        // 1. Fix common spacing issues
        corrected = corrected.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Fix punctuation spacing
        corrected = corrected.replacingOccurrences(of: " +([.,!?;:])", with: "$1", options: .regularExpression)
        corrected = corrected.replacingOccurrences(of: "([.,!?])([A-Za-z])", with: "$1 $2", options: .regularExpression)

        // 3. Fix contractions
        corrected = corrected.replacingOccurrences(of: " n't", with: "n't")
        corrected = corrected.replacingOccurrences(of: " 's", with: "'s")
        corrected = corrected.replacingOccurrences(of: " 're", with: "'re")
        corrected = corrected.replacingOccurrences(of: " 'll", with: "'ll")
        corrected = corrected.replacingOccurrences(of: " 've", with: "'ve")
        corrected = corrected.replacingOccurrences(of: " 'd", with: "'d")
        corrected = corrected.replacingOccurrences(of: " 'm", with: "'m")

        // 4. Capitalize first letter
        if let first = corrected.first, first.isLowercase {
            corrected = corrected.prefix(1).uppercased() + corrected.dropFirst()
        }

        // 5. Capitalize after sentence-ending punctuation
        if let regex = try? NSRegularExpression(pattern: "([.!?])\\s+([a-z])") {
            let matches = regex.matches(in: corrected, range: NSRange(corrected.startIndex..., in: corrected))

            var result = corrected
            for match in matches.reversed() {
                if let range = Range(match.range(at: 2), in: result) {
                    let letter = result[range].uppercased()
                    result.replaceSubrange(range, with: letter)
                }
            }
            corrected = result
        }

        // 6. Add ending punctuation if missing
        let hasEndPunctuation = [".", "!", "?", ",", ";", ":"].contains(where: { corrected.hasSuffix($0) })

        if !hasEndPunctuation && !corrected.isEmpty {
            let questionWords = ["who", "what", "when", "where", "why", "how",
                                "is", "are", "can", "could", "would", "should",
                                "do", "does", "did", "will", "was", "were"]
            let firstWord = corrected.lowercased().components(separatedBy: " ").first ?? ""

            if questionWords.contains(firstWord) {
                corrected += "?"
            } else {
                let hasVerb = corrected.lowercased().range(of: "\\b(is|are|was|were|am|be|been|have|has|had|do|does|did|can|could|will|would|should|may|might)\\b", options: .regularExpression) != nil

                if hasVerb || corrected.split(separator: " ").count > 3 {
                    corrected += "."
                }
            }
        }

        return corrected
    }

    /// Check if model is ready
    func isAvailable() -> Bool {
        return isInitialized
    }
}

enum GrammarError: Error {
    case modelNotInitialized
    case inputTooLong
    case tokenizationFailed
    case encoderOutputInvalid
    case downloadFailed(String)
    case decoderGenerationFailed
}
