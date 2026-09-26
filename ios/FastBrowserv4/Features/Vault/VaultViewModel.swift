import SwiftUI
import SwiftData

enum VaultSortOption: String, CaseIterable, Identifiable {
    case domain = "Domain"
    case recentlyUsed = "Recently Used"
    case mostUsed = "Most Used"
    case recentlyAdded = "Recently Added"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .domain: return "textformat.abc"
        case .recentlyUsed: return "clock.arrow.circlepath"
        case .mostUsed: return "chart.bar.fill"
        case .recentlyAdded: return "calendar.badge.plus"
        }
    }
}

@Observable
@MainActor
class VaultViewModel {
    var searchText: String = ""
    var isShowingAddCredential: Bool = false
    var isShowingImport: Bool = false
    var isShowingPasteImport: Bool = false
    var isShowingPasswordGenerator: Bool = false
    var isShowingExcludedDomains: Bool = false
    var selectedCredential: Credential?
    /// Display order for the vault list. Persisted so the choice survives
    /// relaunches; RCR runs keep their own fixed queue order regardless.
    var sortOption: VaultSortOption = VaultSortOption(
        rawValue: UserDefaults.standard.string(forKey: "vaultSortOption") ?? ""
    ) ?? .domain {
        didSet {
            guard sortOption != oldValue else { return }
            UserDefaults.standard.set(sortOption.rawValue, forKey: "vaultSortOption")
        }
    }

    /// IDs of credentials selected while in multi-select (edit) mode.
    var selectedIDs: Set<String> = []
    var isEditMode: Bool = false

    func toggleSelection(_ credential: Credential) {
        if selectedIDs.contains(credential.id) {
            selectedIDs.remove(credential.id)
        } else {
            selectedIDs.insert(credential.id)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    /// Deletes a credential and its Keychain payload. A missing Keychain item
    /// is treated as already deleted; other Keychain or persistence errors keep
    /// the model row visible so the caller can report the failure.
    @discardableResult
    func deleteCredential(_ credential: Credential, context: ModelContext) -> Bool {
        let keychainResult = KeychainService.shared.deletePasswordResult(for: credential.id)
        guard keychainResult.isSuccessful else { return false }

        context.delete(credential)
        do {
            try context.save()
            selectedIDs.remove(credential.id)
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    /// Delete every credential in `credentials`, purging each keychain entry.
    @discardableResult
    func bulkDelete(_ credentials: [Credential], context: ModelContext) -> [String] {
        var failedIDs: [String] = []
        for credential in credentials {
            if !deleteCredential(credential, context: context) {
                failedIDs.append(credential.id)
            }
        }
        return failedIDs
    }

    struct BulkMoveResult {
        /// Number of unique canonical domains added to the exclude list
        /// (existing entries are not double-counted).
        let domainsAdded: Int
        /// Credential IDs whose keychain entry could not be purged. Their
        /// SwiftData rows were left in place (see `bulkDelete`) so the caller
        /// can surface the inconsistency instead of silently orphaning them.
        let failedCredentialIDs: [String]
    }

    /// Move the given credentials to the exclude list: their canonical domains
    /// are added to `ExcludedDomain` (deduped) and the credentials + keychain
    /// entries are removed. The domain side is honored even when individual
    /// credentials fail to delete, so the user's intent to stop autofill on
    /// those domains still takes effect.
    @discardableResult
    func bulkMoveToExcludeList(_ credentials: [Credential], context: ModelContext) -> BulkMoveResult {
        let domains = Set(credentials.map { ExcludedDomain.canonicalize($0.domain) })
            .filter { !$0.isEmpty }
        let domainsAdded = domains.reduce(into: 0) { count, domain in
            if addExcludedDomain(domain, context: context) {
                count += 1
            }
        }
        let failed = bulkDelete(credentials, context: context)
        if credentials.isEmpty {
            try? context.save()
        }
        return BulkMoveResult(domainsAdded: domainsAdded, failedCredentialIDs: failed)
    }

    /// Adds a domain to the exclude list if needed and returns whether a new
    /// row was inserted.
    @discardableResult
    func addExcludedDomain(_ domain: String, context: ModelContext) -> Bool {
        let canonical = ExcludedDomain.canonicalize(domain)
        guard !canonical.isEmpty else { return false }
        let descriptor = FetchDescriptor<ExcludedDomain>(
            predicate: #Predicate<ExcludedDomain> { $0.domain == canonical }
        )
        guard let existing = try? context.fetch(descriptor), existing.isEmpty else {
            return false
        }
        context.insert(ExcludedDomain(domain: canonical))
        return true
    }

    /// Sort a flat list of credentials according to the current sort option.
    /// Exposed as a `nonisolated static` helper so it is cheap to unit-test
    /// without needing a ModelContext.
    nonisolated static func sortCredentials(
        _ credentials: [Credential],
        by option: VaultSortOption
    ) -> [Credential] {
        switch option {
        case .domain:
            return credentials.sorted {
                if $0.displayDomain == $1.displayDomain { return $0.username < $1.username }
                return $0.displayDomain < $1.displayDomain
            }
        case .recentlyUsed:
            return credentials.sorted { lhs, rhs in
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if lhs.displayDomain != rhs.displayDomain {
                    return lhs.displayDomain < rhs.displayDomain
                }
                return lhs.username < rhs.username
            }
        case .mostUsed:
            return credentials.sorted { lhs, rhs in
                if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
                if lhs.displayDomain != rhs.displayDomain {
                    return lhs.displayDomain < rhs.displayDomain
                }
                return lhs.username < rhs.username
            }
        case .recentlyAdded:
            return credentials.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                if lhs.displayDomain != rhs.displayDomain {
                    return lhs.displayDomain < rhs.displayDomain
                }
                return lhs.username < rhs.username
            }
        }
    }
}