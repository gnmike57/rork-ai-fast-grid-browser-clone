import Foundation

/// The two target sites whose successful logins are eligible for Replay
/// Mode. A parked session on any other host is still kept (and still
/// manageable in Settings), it just never gets a circle in the deck.
enum ReplaySite: String, CaseIterable, Sendable {
    case joeFortune
    case ignition

    /// Classifies a parked session's stored host.
    ///
    /// Matching is done on a substring of the host rather than an exact
    /// list because both brands rotate top-level domains (`joefortune.win`,
    /// `joefortune.fun`, `ignitioncasino.ooo`, …) and sessions parked by an
    /// older build may carry any of them.
    nonisolated static func from(domain: String) -> ReplaySite? {
        let host = domain.lowercased()
        guard !host.isEmpty else { return nil }
        if host.contains("joefortune") { return .joeFortune }
        if host.contains("ignition") { return .ignition }
        return nil
    }

    nonisolated var label: String {
        switch self {
        case .joeFortune: return "Joe Fortune"
        case .ignition: return "Ignition"
        }
    }
}
