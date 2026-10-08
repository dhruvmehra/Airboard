//
//  VocabularySettingsView.swift
//
//  "Vocabulary" — the names and terms Airboard has learned about you.
//  Shows confirmed spellings (SpellingRule lines in memory.md), lets you
//  delete any, and holds the learning toggle. The OpenRouter key lives in
//  ONE place (OpenRouterKeyView); this screen only shows whether it's set.
//

import SwiftUI

struct VocabularySettingsView: View {
    @ObservedObject private var store = MemoryStore.shared
    @State private var enabled = VocabularyLearning.shared.isEnabled
    @State private var hasKey = VocabularyLearning.shared.client() != nil

    /// Confirmed spellings with their line index in memory.md (for delete).
    private var rules: [(index: Int, rule: SpellingRule)] {
        store.memories.enumerated().compactMap { i, line in
            SpellingRule.parse(line).map { (i, $0) }
        }
    }

    /// Lines from the retired Memory feature — kept untouched in the file.
    private var otherLines: Int { store.memories.count - rules.count }

    var body: some View {
        VStack(spacing: 0) {
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
                    Text("Vocabulary")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Label.primary)
                    Text("Names and terms Airboard has learned — it asks before saving each one")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Label.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if rules.isEmpty {
                        Text("Nothing learned yet. Dictate, then fix a misheard name by hand — Airboard will ask to remember it.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                    ForEach(rules, id: \.index) { item in
                        HStack(spacing: 8) {
                            Text(item.rule.term)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Label.primary)
                            Text("heard as \"\(item.rule.heardAs)\"")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Label.tertiary)
                            Spacer()
                            Button {
                                store.removeMemory(at: item.index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Label.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Forget this spelling")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                            .fill(DS.Fill.quaternary))
                    }
                    if otherLines > 0 {
                        Text("\(otherLines) older memory note\(otherLines == 1 ? "" : "s") from the retired Memory feature \(otherLines == 1 ? "is" : "are") kept untouched in memory.md.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Label.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().padding(.vertical, 6)

                    Toggle(isOn: Binding(get: { enabled }, set: { enabled = $0; VocabularyLearning.shared.setEnabled($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Learn my vocabulary")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Label.primary)
                            Text("Learns from the words you fix after dictating and from names on your screen.")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Label.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Accent.success)

                    HStack(spacing: 6) {
                        Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundColor(hasKey ? DS.Accent.success : DS.Label.tertiary)
                            .font(.system(size: 11))
                        Text(hasKey ? "Using your OpenRouter key" : "Add your OpenRouter key to start learning")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                        Spacer()
                        Button("OpenRouter key…") {
                            FloatingWindowManager.shared.showOpenRouterKeyWindow()
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 480)
        .background(DS.Surface.panel)
        .onReceive(NotificationCenter.default.publisher(for: .openRouterKeyChanged)) { _ in
            hasKey = VocabularyLearning.shared.client() != nil
        }
    }
}
