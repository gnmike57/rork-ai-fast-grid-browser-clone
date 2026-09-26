import SwiftData
import Foundation

@Model
class SiteSetting {
    #Index<SiteSetting>([\.domain])

    @Attribute(.unique) var domain: String
    var usernameSelector: String
    var passwordSelector: String
    var submitButtonSelector: String
    var isAutoLoginEnabled: Bool
    var isSureLoginEnabled: Bool
    var sureLoginRetryCount: Int
    var sureLoginDelaySeconds: Double
    var createdAt: Date
    var updatedAt: Date

    init(domain: String) {
        self.domain = domain.lowercased()
        self.usernameSelector = ""
        self.passwordSelector = ""
        self.submitButtonSelector = ""
        self.isAutoLoginEnabled = false
        self.isSureLoginEnabled = false
        self.sureLoginRetryCount = 1
        self.sureLoginDelaySeconds = 1.0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
