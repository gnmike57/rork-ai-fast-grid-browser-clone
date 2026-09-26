import Foundation
import SwiftData

/// A live, still-signed-in browsing session pulled aside after an
/// AI-confirmed login. The isolated WebKit store identity is what keeps
/// the cookies — this row is only the metadata the replay deck needs to
/// re-open or forget the session after a restart.
@Model
final class ParkedSession {
    #Index<ParkedSession>([\.parkedAt])

    @Attribute(.unique) var id: String
    /// `WKWebsiteDataStore(forIdentifier:)` identity. Never shared with a
    /// live window after parking, and never reused for the next credential.
    var storeID: String
    var urlString: String
    var username: String
    var domain: String
    var credentialID: String
    /// `"single"` or `"S1"`…`"S16"`.
    var sessionTag: String
    var thumbnailFilename: String?
    var parkedAt: Date
    /// Window index this session came from, when parked from the grid.
    var sourceWindowIndex: Int

    init(
        storeID: UUID,
        urlString: String,
        username: String,
        domain: String,
        credentialID: String,
        sessionTag: String,
        thumbnailFilename: String?,
        sourceWindowIndex: Int
    ) {
        self.id = UUID().uuidString
        self.storeID = storeID.uuidString
        self.urlString = urlString
        self.username = username
        self.domain = domain
        self.credentialID = credentialID
        self.sessionTag = sessionTag
        self.thumbnailFilename = thumbnailFilename
        self.parkedAt = Date()
        self.sourceWindowIndex = sourceWindowIndex
    }

    var storeUUID: UUID {
        UUID(uuidString: storeID) ?? UUID()
    }

    /// Replay-deck identity, or nil when this session's host isn't one of
    /// the two replay target sites.
    var replaySite: ReplaySite? {
        ReplaySite.from(domain: domain)
    }

    var url: URL? {
        URL(string: urlString)
    }
}
