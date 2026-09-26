import Foundation
import SwiftData

/// One entry in the AI run log: a repair the healer attempted, a success
/// verdict the judge issued, or a privacy note. Written in plain English so
/// the user can review exactly what the AI did after a batch finishes.
@Model
final class AIRepairEvent {
    #Index<AIRepairEvent>([\.timestamp], [\.kind])

    @Attribute(.unique) var id: String
    var timestamp: Date
    /// Domain the event concerns ("" when not site-specific).
    var domain: String
    /// Session tag — "single" or "S1"…"S16".
    var sessionTag: String
    /// "heal" | "judge" | "info"
    var kind: String
    /// Which brain answered: "On-device", "Apple Cloud", or the provider name.
    var brain: String
    /// Plain-English summary, e.g. "Couldn't find the password field —
    /// retried with #pass-word after repair."
    var summary: String
    /// Whether the action ended up helping (nil = not applicable / unknown).
    var succeeded: Bool

    init(
        domain: String,
        sessionTag: String,
        kind: String,
        brain: String,
        summary: String,
        succeeded: Bool
    ) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.domain = domain
        self.sessionTag = sessionTag
        self.kind = kind
        self.brain = brain
        self.summary = summary
        self.succeeded = succeeded
    }
}
