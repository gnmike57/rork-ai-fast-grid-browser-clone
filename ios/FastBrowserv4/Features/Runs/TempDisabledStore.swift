import Foundation

/// Tracks credentials that hit a "temporarily" disabled response. Each entry
/// expires 1 hour after it's added; while active, RCR skips that credential
/// entirely and moves on. Persisted in UserDefaults so cooldowns survive
/// relaunches.
@MainActor
final class TempDisabledStore {
    static let shared = TempDisabledStore()
    private let key = "tempDisabledCredentialsV1"
    /// 1 hour cooldown.
    static let cooldown: TimeInterval = 3600

    private init() {}

    private var raw: [String: TimeInterval] {
        get {
            (UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval]) ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func markDisabled(credentialID: String) {
        var dict = raw
        dict[credentialID] = Date().addingTimeInterval(Self.cooldown).timeIntervalSince1970
        raw = dict
    }

    func isDisabled(credentialID: String) -> Bool {
        guard let expiry = raw[credentialID] else { return false }
        if Date().timeIntervalSince1970 >= expiry {
            clear(credentialID: credentialID)
            return false
        }
        return true
    }

    func expiresAt(credentialID: String) -> Date? {
        guard let expiry = raw[credentialID] else { return nil }
        let date = Date(timeIntervalSince1970: expiry)
        return date > Date() ? date : nil
    }

    func allActive() -> [(credentialID: String, expiresAt: Date)] {
        let now = Date().timeIntervalSince1970
        return raw.compactMap { (id, expiry) in
            expiry > now ? (id, Date(timeIntervalSince1970: expiry)) : nil
        }
    }

    func clear(credentialID: String) {
        var dict = raw
        dict.removeValue(forKey: credentialID)
        raw = dict
    }

    func clearAll() {
        raw = [:]
    }

    func purgeExpired() {
        let now = Date().timeIntervalSince1970
        raw = raw.filter { $0.value > now }
    }
}
