//
//  DictionaryView.swift
//  Airboard
//
//  Dictionary management UI
//

import SwiftUI

struct DictionaryView: View {
    @ObservedObject var vocabularyManager = VocabularyManager.shared
    @State private var newTerm = ""
    @State private var showingClearConfirm = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Dictionary")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                if !vocabularyManager.terms.isEmpty {
                    Button(action: { showingClearConfirm = true }) {
                        Text("Clear All")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
            
            // Add Term Field
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 16))
                
                TextField("Add a term (e.g., Pype AI, Dhruv)", text: $newTerm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        addTerm()
                    }
                
                if !newTerm.isEmpty {
                    Button(action: addTerm) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.04))
            
            Divider()
            
            // Terms List
            if vocabularyManager.terms.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    
                    Text("No terms yet")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    
                    Text("Add names, companies, or technical terms")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(vocabularyManager.terms, id: \.self) { term in
                            HStack {
                                Text(term)
                                    .font(.system(size: 13))
                                
                                Spacer()
                                
                                Button(action: {
                                    vocabularyManager.removeTerm(term)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 380, height: 450)
        .background(Color(NSColor.windowBackgroundColor))
        .confirmationDialog("Clear Dictionary?", isPresented: $showingClearConfirm) {
            Button("Clear All", role: .destructive) {
                vocabularyManager.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all \(vocabularyManager.terms.count) terms.")
        }
    }
    
    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            vocabularyManager.addTerm(trimmed)
            newTerm = ""
        }
    }
}

// MARK: - Preview

#Preview {
    DictionaryView()
}
