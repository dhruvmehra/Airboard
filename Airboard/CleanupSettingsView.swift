//
//  CleanupSettingsView.swift
//
//  Settings for the optional remote AI cleanup: any OpenAI-compatible
//  endpoint (OpenRouter, AWS Bedrock, Ollama, vLLM, ...). API key lives in
//  the Keychain. See docs/cleanup-server-recipes.md for setup recipes.
//  Styled to match the AirboardPopover design language.
//

import SwiftUI

struct CleanupSettingsView: View {
    @AppStorage("cleanupServerURL") private var serverURL = ""
    @AppStorage("cleanupModelName") private var modelName = ""
    @State private var apiKeyField = ""
    @State private var hasStoredKey = KeychainHelper.hasAPIKey
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — mirrors the popover row style
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.1))
                        .frame(width: 32, height: 32)

                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Cleanup")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("Any OpenAI-compatible server: OpenRouter, Bedrock, Ollama, vLLM")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Quick setup:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button("Cerebras (fastest)") {
                        serverURL = "https://api.cerebras.ai"
                        modelName = "llama-3.3-70b"
                        testResult = nil
                    }
                    .controlSize(.small)
                    Button("OpenRouter") {
                        serverURL = "https://openrouter.ai/api"
                        modelName = "qwen/qwen3-30b-a3b-instruct-2507"
                        testResult = nil
                    }
                    .controlSize(.small)
                    Button("Ollama (local)") {
                        serverURL = "http://127.0.0.1:11434"
                        modelName = "qwen3:8b"
                        testResult = nil
                    }
                    .controlSize(.small)
                    Spacer()
                }

                TextField("Server URL  (e.g. https://openrouter.ai/api)", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextField("Model  (e.g. qwen/qwen3-30b-a3b-instruct-2507)", text: $modelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                HStack(spacing: 8) {
                    SecureField(hasStoredKey ? "API key saved — type to replace" : "API key (not needed for local servers)",
                                text: $apiKeyField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Save") {
                        KeychainHelper.saveAPIKey(apiKeyField)
                        apiKeyField = ""
                        hasStoredKey = KeychainHelper.hasAPIKey
                        testResult = nil
                    }
                    .controlSize(.small)
                    .disabled(apiKeyField.isEmpty)
                    if hasStoredKey {
                        Button("Remove") {
                            KeychainHelper.deleteAPIKey()
                            hasStoredKey = false
                            testResult = nil
                        }
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    Button(isTesting ? "Testing…" : "Test connection") {
                        isTesting = true
                        testResult = nil
                        Task {
                            switch await TranscriptRefiner.shared.testConnection() {
                            case .success:
                                testResult = "✅ Connected — cleanup is working"
                            case .failure(let error):
                                testResult = "❌ \(TranscriptRefiner.friendlyMessage(for: error))"
                            }
                            isTesting = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(isTesting || !TranscriptRefiner.shared.isConfigured)

                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 12)

            Text("When configured, dictated text is sent to this server for cleanup. Nothing is ever sent when these fields are empty or AI cleanup is toggled off.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 440)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
        )
    }
}

#Preview {
    CleanupSettingsView()
}
