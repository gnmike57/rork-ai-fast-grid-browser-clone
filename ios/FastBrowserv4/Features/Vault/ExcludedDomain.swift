import SwiftData
import Foundation

/// A domain for which the browser should never auto-fill credentials or
/// offer to save new credentials. Used to "move" credentials out of the
/// active vault without losing the intent to skip that site in the future.
@Model
class ExcludedDomain {
    #Index<ExcludedDomain>([\.domain])

    @Attribute(.unique) var domain: String
    var createdAt: Date

    init(domain: String) {
        self.domain = ExcludedDomain.canonicalize(domain)
        self.createdAt = Date()
    }

    var displayDomain: String {
        domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    }

    /// Normalize a user-supplied domain / URL into the canonical host form
    /// used by the rest of the app (lowercased host, no scheme, no path,
    /// leading `www.` stripped). Matches the normalization performed by
    /// `CredentialImportService.extractDomain` / `BrowserTab.domain` so that
    /// excluded entries reliably hide credentials and disable autofill.
    nonisolated static func canonicalize(_ input: String) -> String {
        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return "" }

        let parsedHost = URL(string: trimmed)?.host(percentEncoded: false)
            ?? URL(string: "https://\(trimmed)")?.host(percentEncoded: false)

        let base = parsedHost ?? trimmed
        let firstSegment = base
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""

        if firstSegment.hasPrefix("www.") {
            return String(firstSegment.dropFirst(4))
        }
        return firstSegment
    }
}
