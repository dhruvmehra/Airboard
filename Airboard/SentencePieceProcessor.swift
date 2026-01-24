//
//  SentencePieceProcessor.swift
//  Airboard
//
//  Native Swift SentencePiece tokenizer using swift-sentencepiece package
//  Install via SPM: https://github.com/jkrukowski/swift-sentencepiece
//

import Foundation
import SentencepieceTokenizer

class SentencePieceProcessor {
    private let processor: SentencepieceTokenizer

    init(modelPath: String) throws {
        // Verify the model file exists
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw SentencePieceError.modelNotFound
        }

        // Load the SentencePiece model
        do {
            self.processor = try SentencepieceTokenizer(modelPath: modelPath)
            print("✅ SentencePiece model loaded from: \(modelPath)")
        } catch {
            print("❌ Failed to load SentencePiece model: \(error)")
            throw SentencePieceError.loadFailed(error)
        }
    }

    /// Encode text to token IDs
    func encode(_ text: String) -> [Int] {
        do {
            let tokens = try processor.encode(text)
            return tokens
        } catch {
            print("❌ Failed to encode text: \(error)")
            return []
        }
    }

    /// Decode token IDs to text
    func decode(_ tokens: [Int]) -> String {
        do {
            let text = try processor.decode(tokens)
            print("✅ SentencePiece decoded \(tokens.count) tokens -> '\(text)'")
            return text
        } catch {
            print("❌ Failed to decode tokens: \(error)")
            print("   Tokens that failed: \(tokens)")
            return ""
        }
    }
}

enum SentencePieceError: Error {
    case modelNotFound
    case loadFailed(Error)
    case encodingFailed
    case decodingFailed
}
