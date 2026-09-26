import Foundation
import Security

/// Stores AI-provider API keys in the iOS Keychain, under a service separate
/// from the credential vault. Each provider owns numbered slots
/// ("<providerID>.<slot>") so several keys can rotate per provider.
nonisolated final class LLMKeyVault: Sendable {
    static let shared = LLMKeyVault()
    private let service = "com.fastfillbrowser.llmkeys"

    private init() {}

    private func account(providerID: String, slot: Int) -> String {
        "\(providerID).\(slot)"
    }

    @discardableResult
    func setKey(_ key: String, providerID: String, slot: Int) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, slot: slot)
        ]
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecSuccess {
            return true
        }
        let item = query.merging(values) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func key(providerID: String, slot: Int) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, slot: slot),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes every key slot for a provider (called before row deletion, so
    /// no orphan keys are left in the Keychain).
    func deleteAllKeys(providerID: String) {
        // Slots are numbered; delete generously past the stored count.
        for slot in 0..<32 {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account(providerID: providerID, slot: slot)
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    @discardableResult
    func deleteKey(providerID: String, slot: Int) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, slot: slot)
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Masked display form — "sk-…wxyz". Never returns the full key.
    func maskedKey(providerID: String, slot: Int) -> String? {
        guard let raw = key(providerID: providerID, slot: slot) else { return nil }
        return Self.mask(raw)
    }

    static func mask(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 7 else { return "••••••" }
        return "\(trimmed.prefix(3))…\(trimmed.suffix(4))"
    }
}
