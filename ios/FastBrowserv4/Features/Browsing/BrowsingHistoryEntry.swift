import SwiftData
import Foundation

@Model
class BrowsingHistoryEntry {
    #Index<BrowsingHistoryEntry>([\.visitedAt], [\.domain])

    var id: String
    var url: String
    var title: String
    var domain: String
    var visitedAt: Date

    init(url: String, title: String, domain: String) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title
        self.domain = domain.lowercased()
        self.visitedAt = Date()
    }
}
