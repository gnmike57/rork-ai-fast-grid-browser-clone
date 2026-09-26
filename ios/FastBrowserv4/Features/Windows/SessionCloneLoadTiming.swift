import Foundation

/// When a cloned window is allowed to load its page relative to the arrival
/// of the donated session.
nonisolated enum SessionCloneLoadTiming: String, CaseIterable, Identifiable, Sendable {
    /// Hold the window on a "restoring session" state until its cookies are
    /// written, then load once. No logged-out flash, slightly slower paint.
    case waitForSession
    /// Load immediately and refresh once the cookies land. Faster first
    /// paint, brief logged-out flash.
    case loadThenRefresh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .waitForSession: return "Wait for session"
        case .loadThenRefresh: return "Load now, refresh"
        }
    }

    var detail: String {
        switch self {
        case .waitForSession:
            return "Windows hold briefly until the cloned session is in place, then load once signed in."
        case .loadThenRefresh:
            return "Windows load straight away and refresh when the cloned session lands."
        }
    }

    static var saved: SessionCloneLoadTiming {
        SessionCloneLoadTiming(
            rawValue: UserDefaults.standard.string(forKey: SettingsKey.sessionCloneLoadTiming) ?? ""
        ) ?? .waitForSession
    }
}
