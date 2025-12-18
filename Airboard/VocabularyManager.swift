//
//  VocabularyManager.swift
//  Airboard
//
//  Created by Dhruv Mehra on 11/12/25.
//


//
//  VocabularyManager.swift
//  Airboard
//
//  Manages custom vocabulary for Whisper transcription
//

import Foundation
import Combine

/// Simple manager for custom vocabulary terms
class VocabularyManager: ObservableObject {
    static let shared = VocabularyManager()
    
    @Published var terms: [String] = []
    
    private let userDefaults = UserDefaults.standard
    private let vocabularyKey = "airboard_vocabulary"
    
    private init() {
        loadTerms()
    }
    
    // MARK: - Public Methods
    
    /// Add a new term to vocabulary
    func addTerm(_ term: String) {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanTerm.isEmpty else { return }
        guard !terms.contains(cleanTerm) else { return } // Avoid duplicates
        
        terms.append(cleanTerm)
        terms.sort() // Keep alphabetically sorted
        saveTerms()
        
        print("📚 Added to dictionary: '\(cleanTerm)'")
    }
    
    /// Remove a term from vocabulary
    func removeTerm(_ term: String) {
        terms.removeAll { $0 == term }
        saveTerms()
        
        print("🗑️ Removed from dictionary: '\(term)'")
    }
    
    /// Get all terms as a formatted string for Whisper prompt
    func getPromptString() -> String {
        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }
    
    /// Clear all terms
    func clearAll() {
        terms.removeAll()
        saveTerms()
        
        print("🗑️ Cleared all dictionary terms")
    }
    
    // MARK: - Private Methods
    
    private func loadTerms() {
        if let saved = userDefaults.stringArray(forKey: vocabularyKey) {
            terms = saved.sorted()
            print("📚 Loaded \(terms.count) dictionary terms")
        }
    }
    
    private func saveTerms() {
        userDefaults.set(terms, forKey: vocabularyKey)
        print("💾 Saved dictionary (\(terms.count) terms)")
    }
}
