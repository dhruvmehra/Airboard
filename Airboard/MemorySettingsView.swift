//
//  MemorySettingsView.swift
//
//  Airboard's memory, displayed as-is: the flat list of memory lines from
//  memory.md, each deletable, plus an add field and the share switch. No
//  schema, no sections — the file is the truth and this window mirrors it.
//

import SwiftUI

struct MemorySettingsView: View {
    @ObservedObject private var store = MemoryStore.shared
    @State private var newMemory = ""

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
                    Text("Plain lines in memory.md — teach by voice, or edit the file by hand")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Label.secondary)
                }
                Spacer()
                Button(action: {
                    NSWorkspace.shared.open(MemoryStore.defaultURL())
                }) {
                    Text("Open File")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Label.secondary)
                }
                .buttonStyle(.plain)
                .help("Open memory.md in your editor — it's just markdown")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.memories.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nothing remembered yet. Hold your hotkey + ⌘ and just say it:")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Label.secondary)
                            Text("\"Remember that I work at Pype\"")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DS.Label.tertiary)
                            Text("\"Correct pipe to Pype\"  —  teaches a spelling")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DS.Label.tertiary)
                            Text("\"Write my address\"  —  types a saved fact anywhere")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DS.Label.tertiary)
                            Text("Start with spellings (your company, teammates' names) — facts you save afterwards come out spelled right.")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Label.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(Array(store.memories.enumerated()), id: \.offset) { index, memory in
                        HStack(spacing: 8) {
                            Text(memory)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Label.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                store.removeMemory(at: index)
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
                        TextField("New memory (e.g. I work at Pype)", text: $newMemory)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .foregroundColor(DS.Label.primary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                                .fill(DS.Surface.control))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8)
                                .stroke(DS.Border.control, lineWidth: 1))
                            .onSubmit { addNew() }
                        Button("Add", action: addNew)
                            .disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)

                    Divider().padding(.vertical, 6)

                    Toggle(isOn: Binding(
                        get: { store.shareWithLLM },
                        set: { store.setShareWithLLM($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share memory with AI Cleanup")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Label.primary)
                            Text("Sends these lines with cleanup requests so dictation uses your facts and spellings. Off = memory stays entirely on this Mac (voice recall still works).")
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

    private func addNew() {
        store.addMemory(newMemory)
        newMemory = ""
    }
}
