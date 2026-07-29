//
//  AssistantSettingsView.swift
//
//  Setup + settings for the voice assistant: install the pi engine
//  (one click, official installer), OpenRouter API key, model override.
//

import SwiftUI

struct AssistantSettingsView: View {
    @State private var piInstalled = AssistantService.shared.isPiInstalled()
    @State private var apiKey: String = KeychainHelper.readAPIKey(forHost: AssistantService.openRouterHost) ?? ""
    @State private var model: String = UserDefaults.standard.string(forKey: AssistantService.modelDefaultsKey) ?? AssistantService.defaultModel
    @State private var installing = false
    @State private var installFailed = false
    @State private var keySaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assistant")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Label.primary)

            Text("Ask anything in command mode (hold hotkey + ⌘) — time zones, currencies, quick facts. Questions go to OpenRouter; the assistant can fetch web pages but can never touch your files.")
                .font(.system(size: 11))
                .foregroundColor(DS.Label.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Step 1: engine
            HStack(spacing: 8) {
                Image(systemName: piInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(piInstalled ? DS.Accent.success : DS.Label.tertiary)
                Text(piInstalled ? "Assistant engine installed" : "Assistant engine (pi) not installed")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Label.primary)
                Spacer()
                if !piInstalled {
                    Button(installing ? "Installing…" : (installFailed ? "Retry install" : "Install")) {
                        runInstaller()
                    }
                    .disabled(installing)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Fill.quaternary))

            // Step 2: key
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Label.primary)
                HStack(spacing: 8) {
                    SecureField("sk-or-…", text: $apiKey)
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
                        keySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
                    }
                }
                Text("Get one at openrouter.ai/keys. Used only for assistant questions.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.tertiary)
            }

            // Model override
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Label.primary)
                TextField(AssistantService.defaultModel, text: $model)
                    .textFieldStyle(.plain)
                    .font(DS.Typo.mono(11))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8).stroke(DS.Border.control, lineWidth: 1))
                    .onSubmit {
                        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: AssistantService.modelDefaultsKey)
                    }
                Text("Any OpenRouter model id, optionally with :off/:minimal/:low/:medium/:high thinking suffix. Harder questions are fine on slower thinking models.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 380, height: 360)
        .background(DS.Surface.panel)
        .onAppear {
            // pi-path lookup failure is negatively cached; someone may have
            // installed pi outside Airboard while the app was running, so
            // re-probe fresh every time this window opens.
            AssistantService.shared.invalidatePiPathCache()
            piInstalled = AssistantService.shared.isPiInstalled()
        }
    }

    private func runInstaller() {
        installing = true
        installFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "curl -fsSL https://pi.dev/install.sh | sh"]
            proc.standardInput = FileHandle.nullDevice
            let ok = (try? proc.run()) != nil
            if ok { proc.waitUntilExit() }
            DispatchQueue.main.async {
                AssistantService.shared.invalidatePiPathCache()
                piInstalled = AssistantService.shared.isPiInstalled()
                installFailed = !piInstalled
                installing = false
            }
        }
    }
}
