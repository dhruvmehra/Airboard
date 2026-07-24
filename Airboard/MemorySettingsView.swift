//
//  MemorySettingsView.swift
//
//  View and edit Airboard's memory: the vocabulary glossary (contextual
//  spellings — never applied by find-and-replace), personal notes, and the
//  "Share memory with AI Cleanup" switch. This window is the safe path for
//  deletion (voice deletion is deliberately not a thing).
//

import SwiftUI

struct MemorySettingsView: View {
    @ObservedObject private var store = MemoryStore.shared
    @State private var newTerm = ""
    @State private var newHeardAs = ""
    @State private var newNote = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header — mirrors the cleanup settings header style
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DS.Tint.purple)
                        .frame(width: DS.Badge.size, height: DS.Badge.size)
                    Image(systemName: "brain")
                        .font(.system(size: DS.Badge.glyph, weight: .medium))
                        .foregroundStyle(DS.Accent.command)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Label.primary)
                    Text("Spellings and facts Airboard remembers — teach by voice in command mode")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Label.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // ---- Glossary ----
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vocabulary")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Label.primary)
                        Text("Applied in context by AI Cleanup — \"the water pipe\" stays \"pipe\"; \"send it to pipe\" becomes \"Pype\".")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Label.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(store.data.glossary) { entry in
                            HStack(spacing: 8) {
                                Text(entry.term)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(DS.Label.primary)
                                if !entry.heardAs.isEmpty {
                                    Text("heard as \"\(entry.heardAs)\"")
                                        .font(.system(size: 11))
                                        .foregroundColor(DS.Label.secondary)
                                }
                                Spacer()
                                Button {
                                    store.removeGlossary(id: entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(DS.Label.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                                .fill(DS.Fill.quaternary))
                        }
                        HStack(spacing: 8) {
                            TextField("Correct spelling (e.g. Pype)", text: $newTerm)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .foregroundColor(DS.Label.primary).dsMemoryFieldChrome()
                            TextField("Heard as (e.g. pipe)", text: $newHeardAs)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .foregroundColor(DS.Label.primary).dsMemoryFieldChrome()
                            Button("Add") {
                                store.addGlossary(term: newTerm, heardAs: newHeardAs)
                                newTerm = ""; newHeardAs = ""
                            }
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Divider()

                    // ---- Notes ----
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Facts")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Label.primary)
                        Text("Free-form notes. Recall by voice: \"write my address\", \"fill in where I work\".")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Label.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(store.data.notes.enumerated()), id: \.offset) { index, note in
                            HStack(spacing: 8) {
                                Text(note)
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Label.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button {
                                    store.removeNote(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(DS.Label.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                                .fill(DS.Fill.quaternary))
                        }
                        HStack(spacing: 8) {
                            TextField("New fact (e.g. I work at Pype)", text: $newNote)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .foregroundColor(DS.Label.primary).dsMemoryFieldChrome()
                            Button("Add") {
                                store.addNote(newNote)
                                newNote = ""
                            }
                            .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Divider()

                    // ---- Sharing ----
                    Toggle(isOn: Binding(
                        get: { store.data.shareWithLLM },
                        set: { store.setShareWithLLM($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share memory with AI Cleanup")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Label.primary)
                            Text("Sends the glossary and facts with cleanup requests so dictation resolves them in context. Off = memory stays entirely on this Mac (voice recall still works).")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Label.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Accent.success)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 480)
        .background(DS.Surface.panel)
    }
}

/// Field chrome matching CleanupSettingsView's (private there, so mirrored).
private extension View {
    func dsMemoryFieldChrome() -> some View {
        self
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8).stroke(DS.Border.control, lineWidth: 1))
    }
}
