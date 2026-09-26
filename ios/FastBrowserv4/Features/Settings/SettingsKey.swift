import Foundation

/// Shared `UserDefaults` keys for settings read from more than one place
/// (a settings screen's `@AppStorage` plus a service reading it directly).
/// Defined once so a typo in a copy-pasted string literal can't silently
/// desync a reader from the writer.
nonisolated enum SettingsKey {
    static let autoFillOnPageLoad = "autoFillOnPageLoad"
    static let offerToSavePasswords = "offerToSavePasswords"
    /// `SessionCloneLoadTiming.rawValue` — whether cloned windows wait for
    /// their session before loading or load first and refresh after.
    static let sessionCloneLoadTiming = "sessionCloneLoadTiming"
}
