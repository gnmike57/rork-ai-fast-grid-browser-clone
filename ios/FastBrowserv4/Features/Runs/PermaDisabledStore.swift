import Foundation

/// Tracks credentials that returned the "been disabled" phrase. Unlike
/// `TempDisabledStore`, entries never expire — the credential is excluded
/// from every future RCR run on every site until the user explicitly clears
/// results.
@MainActor
final class PermaDisabledStore {
    static let shared = PermaDisabledStore()
    private let key = "permaDisabledCredentialsV1"

    private init() {}

    private var raw: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    func markDisabled(credentialID: String) {
        var set = raw
        set.insert(credentialID)
        raw = set
    }

    func isDisabled(credentialID: String) -> Bool {
        raw.contains(credentialID)
    }

    func all() -> Set<String> { raw }

    func clear(credentialID: String) {
        var set = raw
        set.remove(credentialID)
        raw = set
    }

    func clearAll() { raw = [] }
}
