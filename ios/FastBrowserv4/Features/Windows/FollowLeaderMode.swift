import Foundation

/// How faithfully Follow the Leader copies the leader window.
///
/// Two genuinely different contracts, not a speed dial:
///
/// - `relaxed` is the original behaviour. The recorder debounces typing and
///   samples scrolling, the queue collapses consecutive edits of one field
///   into their final value, and an action that cannot be applied after a few
///   tries is counted as a misfire and skipped. Quick, forgiving, and it can
///   silently leave a window a step behind.
/// - `unbreakable` records every keystroke, key combination, focus change, tap
///   point, hover change and scroll position; never merges or drops anything;
///   confirms each action landed before that window moves on; repairs a window
///   that falls out of step by replaying the page from the start; and holds the
///   leader at the irreversible steps until every window has caught up.
///
/// The mode is a property of the *session of the mode*, not of a window, so
/// switching it while windows are still catching up is refused rather than
/// applied halfway through a flow.
nonisolated enum FollowLeaderSyncMode: String, CaseIterable, Identifiable, Sendable {
    case relaxed
    case unbreakable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .unbreakable: return "Unbreakable"
        }
    }

    /// Chevrons for best-effort following; a closed lock for lockstep.
    var iconName: String {
        switch self {
        case .relaxed: return "chevron.right.2"
        case .unbreakable: return "lock.fill"
        }
    }

    /// One line, in plain English, for the strip menu and the routine list.
    var blurb: String {
        switch self {
        case .relaxed:
            return "Copies what you do quickly, merging bursts of typing. A window that can't keep up is flagged and carries on."
        case .unbreakable:
            return "Copies every keystroke, tap point and scroll exactly, proves each one landed, and repairs a window that falls out of step."
        }
    }

    var isStrict: Bool { self == .unbreakable }

    private static let storageKey = "followLeaderSyncMode"

    /// The persisted choice; defaults to Relaxed so an existing user's grid
    /// behaves exactly as it did before this mode existed.
    static var saved: FollowLeaderSyncMode {
        FollowLeaderSyncMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .relaxed
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

/// What actually became of one mirrored action in one window.
///
/// The distinction between `confirmed` and `delivered` is the whole reason
/// Unbreakable can promise exactness without risking a double submit: a tap
/// can be *provably* delivered to a control whose effect this document cannot
/// observe (a tab that only swaps its own panel, an add-to-cart that updates a
/// badge off screen). Those are done, and must never be fired again. Only a
/// `missed` action — nothing found, nothing delivered — is allowed to retry.
nonisolated enum FollowLeaderSettlement: String, Sendable {
    /// Applied and the page provably changed.
    case confirmed
    /// Provably reached the control, but the effect was unobservable.
    case delivered
    /// Never landed. This is the only retryable result.
    case missed

    init(outcome: FollowLeaderApplyOutcome) {
        if !outcome.ok {
            self = .missed
        } else if outcome.verified {
            self = .confirmed
        } else {
            self = .delivered
        }
    }

    /// True when the window may move on to its next action.
    var isSettled: Bool { self != .missed }
}
