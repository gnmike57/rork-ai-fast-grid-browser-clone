import Foundation
import Security

/// Keychain home for the two secret parts of a saved card.
///
/// Deliberately a separate service identifier from the credential vault so a
/// card can never be enumerated by the password code paths, and vice versa.
/// Storage is device-only and requires the device to be unlocked, matching
/// how saved passwords are kept.
nonisolated final class CardKeychainService: Sendable {
    static let shared = CardKeychainService()
    private let serviceIdentifier = "com.fastfillbrowser.cards"

    private init() {}

    @discardableResult
    func save(_ secrets: CardSecrets, for cardID: String) -> Bool {
        let digits = CardNumber.digits(secrets.number)
        guard !digits.isEmpty else { return false }
        let normalized = CardSecrets(
            number: digits,
            securityCode: secrets.securityCode.filter(\.isNumber)
        )
        guard let data = try? JSONEncoder().encode(normalized) else { return false }

        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: cardID
        ]
        let updatedValues: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, updatedValues as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        let newItem = itemQuery.merging(updatedValues) { _, new in new }
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    func secrets(for cardID: String) -> CardSecrets? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: cardID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CardSecrets.self, from: data)
    }

    func deleteResult(for cardID: String) -> KeychainDeletionResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: cardID
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return .deleted
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    @discardableResult
    func delete(for cardID: String) -> Bool {
        deleteResult(for: cardID).isSuccessful
    }
}
