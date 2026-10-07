//
//  VocabularySettingsSection.swift
//
//  "Learn my vocabulary" block inside Memory settings: master toggle,
//  OpenRouter key (BYOK — the same key the Assistant uses), and what
//  leaves the Mac.
//

import SwiftUI

struct VocabularySettingsSection: View {
    @State private var enabled = VocabularyLearning.shared.isEnabled
    @State private var apiKey = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost) ?? ""
    @State private var keySaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { enabled }, set: { enabled = $0; VocabularyLearning.shared.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn my vocabulary")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Label.primary)
                    Text("Learns names and terms from the words you fix after dictating and from text on your screen, and asks before saving each one.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Label.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(DS.Accent.success)

            HStack(spacing: 8) {
                SecureField("OpenRouter key (sk-or-…)", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.mono(11))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8).stroke(DS.Border.control, lineWidth: 1))
                Button(keySaved ? "Saved ✓" : "Save") {
                    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainHelper.deleteAPIKey(forHost: AssistantService.openRouterHost)
                    } else {
                        KeychainHelper.saveAPIKey(trimmed, forHost: AssistantService.openRouterHost)
                    }
                    VocabularyLearning.shared.keyChanged()
                    keySaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
                }
            }
            Text("Your own key, shared with the Assistant, kept in your Keychain. Each check sends one sentence and one word to OpenRouter — never your memory file or screen. Turn on zero data retention for this key at openrouter.ai. Without a key, only confirmed multi-word spellings (like \"bright AI\") are applied.")
                .font(.system(size: 10))
                .foregroundColor(DS.Label.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
