//
//  OpenRouterKeyView.swift
//
//  The ONE place the OpenRouter key is set. It powers vocabulary decisions
//  (Jev) and assistant answers. Temporary by design: both move to local
//  models, and then this screen goes away. Stored only in the Keychain
//  (KeychainHelper, host openrouter.ai — per-bundle, dev/prod separate).
//

import SwiftUI

extension Notification.Name {
    static let openRouterKeyChanged = Notification.Name("openRouterKeyChanged")
}

struct OpenRouterKeyView: View {
    @State private var apiKey = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost) ?? ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenRouter key")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Label.primary)

            Text("Used for vocabulary decisions and assistant answers. Each vocabulary check sends one sentence and one word — never your files, screen, or recordings. Temporary: both will run on your Mac.")
                .font(.system(size: 11))
                .foregroundColor(DS.Label.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField("sk-or-…", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.mono(11))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8).stroke(DS.Border.control, lineWidth: 1))
                    .onSubmit(save)
                Button(saved ? "Saved ✓" : "Save", action: save)
            }

            Text("Get one at openrouter.ai/keys. Tip: turn on zero data retention for this key in OpenRouter's privacy settings. Clear the field and Save to remove it.")
                .font(.system(size: 10))
                .foregroundColor(DS.Label.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
        .background(DS.Surface.panel)
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteAPIKey(forHost: AssistantService.openRouterHost)
        } else {
            KeychainHelper.saveAPIKey(trimmed, forHost: AssistantService.openRouterHost)
        }
        VocabularyLearning.shared.keyChanged()
        NotificationCenter.default.post(name: .openRouterKeyChanged, object: nil)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}
