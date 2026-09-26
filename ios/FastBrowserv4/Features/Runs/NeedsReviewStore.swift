import Foundation
import SwiftData

/// Credentials flagged "disabled" mid-run are quarantined here instead of
/// being deleted immediately. `PermaDisabledStore` still keeps them out of
/// every run's queue while they sit here, but nothing is removed from the
/// vault or the keychain until the user explicitly confirms deletion from
/// the Needs Review screen — shown automatically when a run ends with new
/// flags, and reachable any time from the Vault.
@Observable
@MainActor
final class NeedsReviewStore {
    static let shared = NeedsReviewStore()
    private let key = "needsReviewEntriesV1"

    struct Entry: Codable, Identifiable, Equatable {
        var id: String // credential ID
        var username: String
        var domain: String
        var reason: String
        var flaggedAt: Date
    }

    private(set) var entries: [Entry] = []
    /// Entries flagged since the last `markRunStarted()` call — lets the
    /// caller offer an end-of-run summary scoped to just this run.
    private(set) var flaggedThisRun: [Entry] = []

    private init() { load() }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var hasFlaggedThisRun: Bool { !flaggedThisRun.isEmpty }

    /// Call at the start of every run so the end-of-run summary reflects
    /// only what happened during it.
    func markRunStarted() {
        flaggedThisRun = []
    }

    /// Holds a credential aside instead of deleting it. No-ops if the
    /// credential is already flagged, so a resumed run can't duplicate it.
    func flag(credentialID: String, username: String, domain: String, reason: String) {
        guard !entries.contains(where: { $0.id == credentialID }) else { return }
        let entry = Entry(id: credentialID, username: username, domain: domain, reason: reason, flaggedAt: Date())
        entries.append(entry)
        flaggedThisRun.append(entry)
        save()
    }

    /// False positive — keeps the credential and lets future runs try it
    /// again.
    func keep(credentialID: String) {
        entries.removeAll { $0.id == credentialID }
        flaggedThisRun.removeAll { $0.id == credentialID }
        PermaDisabledStore.shared.clear(credentialID: credentialID)
        save()
    }

    /// Confirms the delete the user asked for: wipes the keychain password
    /// and the SwiftData row, then drops it from the queue. Only ever call
    /// this after an explicit user confirmation.
    func confirmDelete(_ credential: Credential, context: ModelContext) {
        let id = credential.id
        KeychainService.shared.deletePassword(for: id)
        context.delete(credential)
        try? context.save()
        entries.removeAll { $0.id == id }
        flaggedThisRun.removeAll { $0.id == id }
        save()
    }

    /// Drops a stale entry whose credential is already gone some other way
    /// (e.g. deleted straight from the Vault) so the summary can't show a
    /// ghost row.
    func remove(credentialID: String) {
        entries.removeAll { $0.id == credentialID }
        flaggedThisRun.removeAll { $0.id == credentialID }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
