//
//  CleanupSettingsView.swift
//
//  Settings for the optional remote AI cleanup: any OpenAI-compatible
//  endpoint (OpenRouter, AWS Bedrock, Ollama, vLLM, ...). API key lives in
//  the Keychain. See docs/cleanup-server-recipes.md for setup recipes.
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
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Cleanup Server")
                .font(.headline)
            Text("Any OpenAI-compatible endpoint works — OpenRouter, AWS Bedrock, a local Ollama, or your own vLLM box. See docs/cleanup-server-recipes.md in the repo.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Quick setup:")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
            TextField("Model  (e.g. qwen/qwen3-30b-a3b-instruct-2507)", text: $modelName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                SecureField(hasStoredKey ? "API key saved — type to replace" : "API key (not needed for local servers)",
                            text: $apiKeyField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    KeychainHelper.saveAPIKey(apiKeyField)
                    apiKeyField = ""
                    hasStoredKey = KeychainHelper.hasAPIKey
                    testResult = nil
                }
                .disabled(apiKeyField.isEmpty)
                if hasStoredKey {
                    Button("Remove") {
                        KeychainHelper.deleteAPIKey()
                        hasStoredKey = false
                        testResult = nil
                    }
                }
            }

            HStack {
                Button(isTesting ? "Testing…" : "Test connection") {
                    isTesting = true
                    testResult = nil
                    Task {
                        switch await TranscriptRefiner.shared.testConnection() {
                        case .success(let reply):
                            testResult = "✅ Working — \"\(TranscriptRefiner.testPhrase)\" came back as: \"\(reply.prefix(80))\""
                        case .failure(let error):
                            testResult = "❌ \(TranscriptRefiner.friendlyMessage(for: error))"
                        }
                        isTesting = false
                    }
                }
                .disabled(isTesting || !TranscriptRefiner.shared.isConfigured)
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            Divider()

            Text("When configured, dictated text is sent to this server for cleanup. Nothing is ever sent when these fields are empty or AI cleanup is toggled off.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }
}

#Preview {
    CleanupSettingsView()
}
