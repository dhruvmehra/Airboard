//
//  KeychainHelper.swift
//
//  Minimal Keychain storage for cleanup-server API keys. Keys must never
//  live in UserDefaults or any plaintext file. One key is stored PER SERVER
//  HOST (api.cerebras.ai, openrouter.ai, ...) so switching providers
//  switches keys — a Cerebras key is never sent to anyone else's server.
//

import Foundation
import Security

enum KeychainHelper {
    /// Per-bundle service name: dev and prod are signed with different
    /// certificates, so a shared Keychain item triggers macOS ACL prompts
    /// when the "other" app reads it. Separate items = no prompts, and each
    /// app manages its own key. (prod: com.pype.airboard.cleanup,
    /// dev: com.pype.airboard.dev.cleanup)
    private static let service = (Bundle.main.bundleIdentifier ?? "com.pype.airboard") + ".cleanup"

    /// Account name used before keys became per-host (one global key).
    private static let legacyAccount = "apiKey"

    /// The Keychain account for a server URL: its host, lowercased.
    /// Falls back to the trimmed string for values URL(string:) rejects,
    /// so a malformed-but-consistent entry still round-trips its own key.
    static func host(of serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let host = URL(string: trimmed)?.host { return host.lowercased() }
        return trimmed.lowercased()
    }

    static func saveAPIKey(_ key: String, forHost host: String) {
        deleteAPIKey(forHost: host)
        guard !host.isEmpty, !key.isEmpty, let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain save failed: \(status)")
        }
    }

    static func readAPIKey(forHost host: String) -> String? {
        guard !host.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasAPIKey(forHost host: String) -> Bool {
        readAPIKey(forHost: host)?.isEmpty == false
    }

    static func deleteAPIKey(forHost host: String) {
        guard !host.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration from the single-global-key era: the old "apiKey"
    /// item belonged to whatever server was configured when it was saved,
    /// so re-home it under that server's host. No-op once migrated, and the
    /// legacy item is left alone if no server URL is configured (there is
    /// no host to attribute it to yet).
    static func migrateLegacyKeyIfNeeded(currentServerURL: String) {
        let destination = host(of: currentServerURL)
        guard !destination.isEmpty,
              destination != legacyAccount,
              let legacyKey = readAPIKey(forHost: legacyAccount),
              !legacyKey.isEmpty else { return }
        if !hasAPIKey(forHost: destination) {
            saveAPIKey(legacyKey, forHost: destination)
            print("🔑 Migrated cleanup API key to per-host storage (\(destination))")
        }
        deleteAPIKey(forHost: legacyAccount)
    }
}
