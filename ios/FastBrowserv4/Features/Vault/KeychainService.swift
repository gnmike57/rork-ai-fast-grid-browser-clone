import Foundation
import Security

nonisolated enum KeychainDeletionResult: Sendable, Equatable {
    case deleted
    case notFound
    case failed(OSStatus)

    var isSuccessful: Bool {
        switch self {
        case .deleted, .notFound: return true
        case .failed: return false
        }
    }
}

nonisolated final class KeychainService: Sendable {
    static let shared = KeychainService()
    private let serviceIdentifier = "com.fastfillbrowser.credentials"
    /// Magic prefix tagging a payload as a JSON-encoded list of passwords.
    /// Single-password legacy entries are stored as plain UTF-8 strings, so a
    /// prefix that is not a valid password character keeps the two formats
    /// unambiguous.
    private let multiPrefix = "\u{01}FFBMULTI:"

    private init() {}

    @discardableResult
    func savePassword(_ password: String, for credentialID: String) -> Bool {
        savePasswords([password], for: credentialID)
    }

    @discardableResult
    func savePasswords(_ passwords: [String], for credentialID: String) -> Bool {
        let nonEmptyPasswords = passwords.filter { !$0.isEmpty }
        guard !nonEmptyPasswords.isEmpty else { return false }

        let payload: String
        if nonEmptyPasswords.count == 1 {
            payload = nonEmptyPasswords[0]
        } else {
            guard let data = try? JSONEncoder().encode(nonEmptyPasswords),
                  let json = String(data: data, encoding: .utf8) else { return false }
            payload = multiPrefix + json
        }

        guard let data = payload.data(using: .utf8) else { return false }
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: credentialID
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

    func getPassword(for credentialID: String) -> String? {
        getPasswords(for: credentialID).first
    }

    func getPasswords(for credentialID: String) -> [String] {
        guard let raw = readRawString(for: credentialID) else { return [] }
        if raw.hasPrefix(multiPrefix) {
            let json = String(raw.dropFirst(multiPrefix.count))
            if let data = json.data(using: .utf8),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                return arr
            }
            return []
        }
        return [raw]
    }

    private func readRawString(for credentialID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: credentialID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func batchGetPasswords(for credentialIDs: [String]) -> [String: [String]] {
        var results: [String: [String]] = [:]
        for id in credentialIDs {
            let passwords = getPasswords(for: id)
            if !passwords.isEmpty {
                results[id] = passwords
            }
        }
        return results
    }

    func deletePasswordResult(for credentialID: String) -> KeychainDeletionResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: credentialID
        ]

        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return .deleted
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    @discardableResult
    func deletePassword(for credentialID: String) -> Bool {
        deletePasswordResult(for: credentialID).isSuccessful
    }
}
