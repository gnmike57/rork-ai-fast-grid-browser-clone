import SwiftData
import Foundation

@Model
class Credential {
    #Unique<Credential>([\.domain, \.username])
    #Index<Credential>([\.domain], [\.lastUsedAt])

    @Attribute(.unique) var id: String
    var domain: String
    var username: String
    var notes: String?
    var totpSecret: Data?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var usageCount: Int

    init(
        domain: String,
        username: String,
        notes: String? = nil,
        totpSecret: Data? = nil
    ) {
        self.id = UUID().uuidString
        self.domain = domain.lowercased()
        self.username = username
        self.notes = notes
        self.totpSecret = totpSecret
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastUsedAt = nil
        self.usageCount = 0
    }

    var displayDomain: String {
        if domain == "imported" { return "Imported" }
        return domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    }
}
