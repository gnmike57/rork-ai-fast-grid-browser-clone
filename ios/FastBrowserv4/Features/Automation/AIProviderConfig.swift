import Foundation
import SwiftData

/// A user-configured OpenAI-compatible AI provider ("bring your own key").
/// Only connection details live here — the API keys themselves are stored in
/// the iOS Keychain under `LLMKeyVault` (slots 0..<keyCount) and never touch
/// SwiftData.
@Model
final class AIProviderConfig {
    #Index<AIProviderConfig>([\.sortOrder])

    @Attribute(.unique) var id: String
    /// What the user calls it, e.g. "My OpenAI".
    var displayName: String
    /// Base address of the OpenAI-compatible API, WITHOUT the trailing
    /// "/chat/completions" — e.g. "https://api.openai.com/v1".
    var baseURL: String
    /// Model identifier sent with each request, e.g. "gpt-5-mini".
    var modelName: String
    var isEnabled: Bool
    var sortOrder: Int
    var createdAt: Date
    /// How many API key slots exist (keys in the Keychain, slots 0-based).
    var keyCount: Int
    /// Round-robin pointer for key rotation — persisted so usage spreads
    /// across launches. Wraps mod keyCount at use time.
    var rotationIndex: Int
    /// Last Test-connection result shown in the UI ("OK · 240ms" or the
    /// failure reason). Nil until tested.
    var lastTestSummary: String?
    var lastTestOK: Bool

    init(
        displayName: String,
        baseURL: String,
        modelName: String,
        sortOrder: Int
    ) {
        self.id = UUID().uuidString
        self.displayName = displayName
        self.baseURL = baseURL
        self.modelName = modelName
        self.isEnabled = true
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.keyCount = 0
        self.rotationIndex = 0
        self.lastTestSummary = nil
        self.lastTestOK = false
    }
}
