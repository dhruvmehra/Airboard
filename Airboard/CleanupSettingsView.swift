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
    @AppStorage("aiCleanupEnabled") private var aiCleanupEnabled = false
    @State private var apiKeyField = ""
    @State private var hasStoredKey = false
    @State private var promptText = TranscriptRefiner.shared.systemPrompt

    /// A custom prompt is SAVED (in use for requests).
    private var isCustomPrompt: Bool {
        TranscriptRefiner.shared.systemPrompt != TranscriptRefiner.defaultInstructions
    }

    /// The editor differs from what's saved — Save becomes available.
    private var promptDirty: Bool {
        promptText != TranscriptRefiner.shared.systemPrompt
    }

    private func savePrompt() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || promptText == TranscriptRefiner.defaultInstructions {
            UserDefaults.standard.removeObject(forKey: TranscriptRefiner.systemPromptKey)
            promptText = TranscriptRefiner.defaultInstructions
        } else {
            UserDefaults.standard.set(promptText, forKey: TranscriptRefiner.systemPromptKey)
        }
    }

    private func resetPrompt() {
        UserDefaults.standard.removeObject(forKey: TranscriptRefiner.systemPromptKey)
        promptText = TranscriptRefiner.defaultInstructions
    }
    @State private var testResult: String?
    @State private var isTesting = false

    /// Keys are stored per server host; everything key-related in this view
    /// (save, remove, status) targets the host of the CURRENT server URL.
    private var currentHost: String { KeychainHelper.host(of: serverURL) }

    private func refreshKeyStatus() {
        hasStoredKey = KeychainHelper.hasAPIKey(forHost: currentHost)
    }

    /// The auto-enable moment: the user just made the config workable
    /// (saved a key or passed a connection test), so flip cleanup on —
    /// that's what they were trying to do when the toggle sent them here.
    private func enableCleanupIfReady() {
        if !aiCleanupEnabled && TranscriptRefiner.shared.isFullyConfigured {
            aiCleanupEnabled = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — mirrors the popover row style
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DS.Tint.purple)
                        .frame(width: DS.Badge.size, height: DS.Badge.size)

                    Image(systemName: "wand.and.stars")
                        .font(.system(size: DS.Badge.glyph, weight: .medium))
                        .foregroundStyle(DS.Accent.command)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Cleanup")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Label.primary)

                    Text("Any OpenAI-compatible server: Cerebras, OpenRouter, Ollama, vLLM")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Label.secondary)
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
                        .foregroundColor(DS.Label.secondary)
                    Button("Cerebras (fastest)") {
                        serverURL = "https://api.cerebras.ai"
                        modelName = "gpt-oss-120b"
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

                TextField("Server URL  (e.g. https://api.cerebras.ai)", text: $serverURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Label.primary)
                    .dsFieldChrome()
                TextField("Model  (e.g. gpt-oss-120b)", text: $modelName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Label.primary)
                    .dsFieldChrome()

                HStack(spacing: 8) {
                    SecureField(hasStoredKey ? "Type to replace the saved key" : "API key (not needed for local servers)",
                                text: $apiKeyField)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Label.primary)
                        .dsFieldChrome()
                    Button("Save") {
                        KeychainHelper.saveAPIKey(apiKeyField, forHost: currentHost)
                        apiKeyField = ""
                        refreshKeyStatus()
                        testResult = nil
                        enableCleanupIfReady()
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(apiKeyField.isEmpty || currentHost.isEmpty)
                    if hasStoredKey {
                        Button("Remove") {
                            KeychainHelper.deleteAPIKey(forHost: currentHost)
                            refreshKeyStatus()
                            testResult = nil
                        }
                        .controlSize(.small)
                    }
                }

                // Key status — always visible, always names the server the
                // key belongs to. Keys are per-server: switching the URL
                // above switches which key (if any) is used.
                HStack(spacing: 5) {
                    if currentHost.isEmpty {
                        Text("Keys are saved per server — enter a server URL first")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    } else if hasStoredKey {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Accent.success)
                        Text("Key saved for \(currentHost)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Accent.success)
                    } else {
                        Image(systemName: "key.slash")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Label.tertiary)
                        Text("No key saved for \(currentHost)")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    }
                    Spacer()
                }
                .padding(.top, -6)

                HStack(spacing: 10) {
                    Button(isTesting ? "Testing…" : "Test connection") {
                        isTesting = true
                        testResult = nil
                        Task {
                            switch await TranscriptRefiner.shared.testConnection() {
                            case .success:
                                testResult = "✅ Connected — cleanup is working"
                                enableCleanupIfReady()
                            case .failure(let error):
                                testResult = "❌ \(TranscriptRefiner.friendlyMessage(for: error))"
                            }
                            isTesting = false
                        }
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(isTesting || !TranscriptRefiner.shared.isConfigured)

                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 11))
                            .foregroundColor(testResult.hasPrefix("✅") ? DS.Accent.success : DS.Label.secondary)
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

            // The exact system prompt sent with every cleanup request —
            // visible AND editable; edits save as you type. The <dictation>
            // envelope and refusal guard live in code, not in this text.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("System prompt")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Label.primary)
                    if isCustomPrompt {
                        Text("custom")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Accent.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DS.Tint.blue))
                    }
                    Spacer()
                    if isCustomPrompt || promptDirty {
                        Button("Reset to default", action: resetPrompt)
                            .controlSize(.small)
                    }
                    if promptDirty {
                        Button("Save", action: savePrompt)
                            .buttonStyle(DSPrimaryButtonStyle())
                    }
                }
                Text("Sent with every request — edit below and press Save. Your dictation is always wrapped in <dictation> tags and framed as text to edit — so a request you speak (\"give me three points on…\") is transcribed, never answered. Answering is Command mode's job.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $promptText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Label.primary)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 110)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.r8)
                            .fill(DS.Surface.control)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.r8)
                            .stroke(DS.Border.control, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 12)

            Text("When configured, dictated text is sent to this server for cleanup. Nothing is ever sent when these fields are empty or AI cleanup is toggled off.")
                .font(.system(size: 10))
                .foregroundColor(DS.Label.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 440)
        .background(DS.Surface.panel)
        .onAppear(perform: refreshKeyStatus)
        .onChange(of: serverURL) { _, _ in
            refreshKeyStatus()
            testResult = nil
        }
    }
}

/// Shared DS chrome for text/secure fields: control surface + hairline stroke.
private extension View {
    func dsFieldChrome() -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .fill(DS.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .stroke(DS.Border.control, lineWidth: 1)
            )
    }
}

/// DS primary CTA: accent fill, on-accent label, r8 radius. Dims when disabled.
private struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Label.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .fill(DS.Accent.primary)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

#Preview {
    CleanupSettingsView()
}
